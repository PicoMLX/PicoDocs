//
//  SpreadsheetMLReader.swift
//  PicoDocs
//
//  Streaming SpreadsheetML (XLSX/XLSM/XLTX) reader on Foundation's XMLParser.
//  Parts are found through relationships matched by the last segment of their
//  type URI, so transitional, Strict and vendor (`vbaProject`, `xlMacrosheet`)
//  relationships resolve alike and unknown ones are ignored rather than fatal.
//  Elements are matched by local name and depth, so prefixed markup (`<x:row>`)
//  reads like unprefixed markup and extension content can't be mistaken for
//  cells. Each part is parsed in one SAX pass into compact rows, in time linear
//  in its size.
//

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import ZIPFoundation

/// A `<row>` of a worksheet's `<sheetData>`: its 1-based index and its cells in
/// document order.
struct SpreadsheetRow: Equatable {
    var index: Int
    var cells: [SpreadsheetCell]
}

/// A `<c>` element: its 0-based column and what it holds.
struct SpreadsheetCell: Equatable {
    enum Content: Equatable {
        /// Formatting only: no `<v>` and no `<is>`.
        case empty
        /// A `t="s"` cell's index into the shared-string table.
        case sharedString(Int)
        /// An inline string, or a raw `<v>` (number, boolean, error, date or
        /// formula string), still `_xHHHH_`-escaped.
        case text(String)
    }

    var column: Int
    var content: Content

    /// Whether the cell carries content, as opposed to formatting alone.
    var hasValue: Bool {
        if case .empty = content { return false }
        return true
    }
}

/// One workbook package: a normalized entry index and one conversion's
/// inflate budget, shared by every part read from it.
final class SpreadsheetMLPackage {

    struct Relationship {
        let id: String
        /// The last segment of the type URI, e.g. `worksheet` for both
        /// `…/2006/relationships/worksheet` and Strict `…/relationships/worksheet`.
        let type: String
        /// The resolved part path for internal targets; the raw URI otherwise.
        let target: String
        let external: Bool
    }

    struct Sheet: Equatable {
        let name: String?
        let path: String
    }

    struct Workbook {
        var sheets: [Sheet]
        var sharedStringsPath: String?
    }

    /// Parse-time ceilings. They bound memory before `SpreadsheetConverter`'s
    /// projection budget runs, and sit above anything that budget can admit:
    /// a converted workbook holds under a million grid cells in total.
    struct Limits {
        var partBytes = 256 * 1024 * 1024
        var totalBytes = 512 * 1024 * 1024
        var entries = 65_536
        var relationships = 65_536
        var sheets = 65_536
        var rows = 1_048_576
        var cellsPerSheet = 1 << 22
        var sharedStrings = 1 << 21
    }

    private let archive: Archive
    private let limits: Limits
    private var remainingBytes: Int
    private var entries: [String: Entry] = [:]
    /// Lowercased names, for OPC's case-insensitive part names; nil when two
    /// entries fold to the same name.
    private var foldedEntries: [String: Entry?] = [:]

    init(archive: Archive, limits: Limits = Limits()) throws {
        self.archive = archive
        self.limits = limits
        remainingBytes = limits.totalBytes
        var count = 0
        for entry in archive {
            count += 1
            if count % 256 == 0 { try Task.checkCancellation() }
            guard count <= limits.entries else { throw PicoDocsError.parsingError }
            guard entry.type == .file else { continue }
            // Some Windows producers write `xl\workbook.xml`.
            var name = entry.path.replacingOccurrences(of: "\\", with: "/")
            if name.hasPrefix("/") { name.removeFirst() }
            // Two entries for one part would let readers disagree on its content.
            guard entries.updateValue(entry, forKey: name) == nil else { throw PicoDocsError.fileCorrupted }
            let folded = name.lowercased()
            foldedEntries[folded] = foldedEntries[folded] == nil ? entry : .some(nil)
        }
    }

    // MARK: Parts

    /// The ZIP entry for a part path, tolerating percent-encoding and case
    /// differences between a relationship target and the stored name.
    func entry(_ path: String) -> Entry? {
        let path = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if let entry = entries[path] { return entry }
        let decoded = path.removingPercentEncoding
        if let decoded, let entry = entries[decoded] { return entry }
        if let entry = foldedEntries[path.lowercased()] ?? nil { return entry }
        if let decoded, let entry = foldedEntries[decoded.lowercased()] ?? nil { return entry }
        return nil
    }

    /// Inflates a part, or nil when the package has no such part. Charged to the
    /// per-part and package budgets; a CRC or size mismatch is corruption.
    func read(_ path: String) throws -> Data? {
        try Task.checkCancellation()
        guard let entry = entry(path) else { return nil }
        let archiveSize = UInt64(archive.data?.count ?? Int.max)
        guard entry.compressedSize <= archiveSize,
              entry.isCompressed || entry.uncompressedSize <= archiveSize else { throw PicoDocsError.fileCorrupted }
        let limit = min(limits.partBytes, remainingBytes)
        guard entry.uncompressedSize <= UInt64(limit) else { throw PicoDocsError.parsingError }
        var data = Data()
        data.reserveCapacity(Int(min(entry.uncompressedSize, 16 * 1024 * 1024)))
        let checksum: CRC32
        do {
            checksum = try archive.extract(entry) { chunk in
                try Task.checkCancellation()
                guard !chunk.isEmpty || entry.uncompressedSize == 0,
                      chunk.count <= limit - data.count else { throw PicoDocsError.fileCorrupted }
                data.append(chunk)
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            throw PicoDocsError.fileCorrupted
        }
        guard checksum == entry.checksum, UInt64(data.count) == entry.uncompressedSize else { throw PicoDocsError.fileCorrupted }
        remainingBytes -= data.count
        return data
    }

    /// The relationships of `part` ("" for the package itself) in document
    /// order, with internal targets resolved; empty when it has none.
    func relationships(of part: String) throws -> [Relationship] {
        let directory = Self.directory(of: part)
        let file = part.split(separator: "/").last.map(String.init) ?? ""
        let path = (directory.isEmpty ? "" : directory + "/") + "_rels/" + file + ".rels"
        guard let data = try read(path) else { return [] }
        let parser = RelationshipsParser(maximumCount: limits.relationships)
        try parser.parse(data)
        return parser.relationships.map { item in
            let type = item.type.split(separator: "/").last.map(String.init) ?? ""
            let target = item.external ? item.target : Self.resolve(item.target, from: part)
            return Relationship(id: item.id, type: type, target: target, external: item.external)
        }
    }

    /// The workbook's worksheets in tab order, and its shared-string part.
    func workbook() throws -> Workbook {
        let documents = try relationships(of: "").filter { !$0.external && $0.type == "officeDocument" }
        // Fall back to the conventional name when the root relationship is absent.
        guard let path = (documents.map(\.target) + ["xl/workbook.xml"]).first(where: { entry($0) != nil }),
              let data = try read(path) else { throw PicoDocsError.fileCorrupted }
        let parser = WorkbookParser(maximumCount: limits.sheets)
        try parser.parse(data)
        let relationships = try relationships(of: path)
        let worksheets = relationships.filter { !$0.external && $0.type == "worksheet" }
        var sheets: [Sheet] = []
        if parser.sheets.isEmpty {
            // No `<sheets>` list: take the worksheet relationships in order, unnamed.
            sheets = worksheets.map { Sheet(name: nil, path: $0.target) }
        } else {
            let byID = Dictionary(worksheets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // Chart, dialog and macro sheets have no worksheet relationship.
            sheets = parser.sheets.compactMap { sheet in
                sheet.relationshipID.flatMap { byID[$0] }.map { Sheet(name: sheet.name, path: $0.target) }
            }
        }
        // Without a relationship, read the conventional part as CoreXLSX did.
        let sharedStrings = relationships.first { !$0.external && $0.type == "sharedStrings" }?.target ?? "xl/sharedStrings.xml"
        return Workbook(sheets: sheets, sharedStringsPath: sharedStrings)
    }

    /// The shared-string table: plain and rich-text items, without phonetic
    /// runs. Empty when the workbook has none. A malformed table keeps the
    /// items before the damage; cells past it render empty, as before.
    func sharedStrings(at path: String?) throws -> [String] {
        guard let path, let data = try read(path) else { return [] }
        // A document type declaration marks a hostile package, not damage.
        guard !SpreadsheetMLParser.declaresDocumentType(data) else { throw PicoDocsError.fileCorrupted }
        let parser = SharedStringsParser(maximumCount: limits.sharedStrings)
        do {
            try parser.parse(data)
        } catch PicoDocsError.fileCorrupted {
            return parser.items
        }
        return parser.items
    }

    /// A worksheet's rows. The part must exist: its relationship names it.
    func rows(ofWorksheetAt path: String) throws -> [SpreadsheetRow] {
        guard let data = try read(path) else { throw PicoDocsError.fileCorrupted }
        return try Self.worksheetRows(data, limits: limits)
    }

    static func worksheetRows(_ data: Data, limits: Limits = Limits()) throws -> [SpreadsheetRow] {
        let parser = WorksheetParser(maximumRows: limits.rows, maximumCells: limits.cellsPerSheet)
        try parser.parse(data)
        return parser.rows
    }

    // MARK: Part names

    /// Resolves a relationship target against the part whose `.rels` holds it.
    /// A leading "/" is package-absolute; `.` and `..` collapse, clamped at the
    /// package root.
    static func resolve(_ target: String, from part: String) -> String {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/")
        let combined = target.hasPrefix("/") ? target : directory(of: part) + "/" + target
        var segments: [Substring] = []
        for segment in combined.split(separator: "/") {
            if segment == ".." { _ = segments.popLast() } else if segment != "." { segments.append(segment) }
        }
        return segments.joined(separator: "/")
    }

    private static func directory(of part: String) -> String {
        guard let slash = part.lastIndex(of: "/") else { return "" }
        return String(part[..<slash])
    }
}

// MARK: - SAX parsers

/// Plumbing shared by the part parsers: local names, element depth, entity
/// rejection and cancellation. Subclasses see `depth` as the depth of the
/// element being started or ended (the root is 1).
private class SpreadsheetMLParser: NSObject, XMLParserDelegate {
    private var failure: Error?
    private(set) var depth = 0
    private var events = 0

    func parse(_ data: Data) throws {
        guard !Self.declaresDocumentType(data) else { throw PicoDocsError.fileCorrupted }
        // A stream makes XMLParser push the part to libxml2 in small chunks.
        // Pushed whole, a part over 10 MB fails libxml2's lookup limit
        // ("Huge input lookup") once the chunk is parsed.
        let parser = XMLParser(stream: InputStream(data: data))
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        let parsed = parser.parse()
        if let failure { throw failure }
        try Task.checkCancellation()
        guard parsed else { throw PicoDocsError.fileCorrupted }
    }

    final func fail(_ parser: XMLParser, _ error: Error) {
        if failure == nil { failure = error }
        parser.abortParsing()
    }

    func start(_ name: Substring, attributes: [String: String], parser: XMLParser) {}
    func end(_ name: Substring) {}
    func text(_ string: String) {}

    final func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        guard failure == nil else { return }
        events += 1
        if events % 4096 == 0, Task.isCancelled { fail(parser, CancellationError()); return }
        depth += 1
        guard depth <= 512 else { fail(parser, PicoDocsError.fileCorrupted); return }
        start(Self.localName(elementName), attributes: attributes, parser: parser)
    }

    final func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard failure == nil else { return }
        end(Self.localName(elementName))
        depth -= 1
    }

    final func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard failure == nil else { return }
        text(string)
    }

    /// Cell text keeps its whitespace however the platform reports it.
    final func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespaceString: String) {
        guard failure == nil else { return }
        text(whitespaceString)
    }

    final func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard failure == nil else { return }
        text(String(decoding: CDATABlock, as: UTF8.self))
    }

    final func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        fail(parser, PicoDocsError.fileCorrupted)
    }

    final func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        fail(parser, PicoDocsError.fileCorrupted)
    }

    final func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        fail(parser, PicoDocsError.fileCorrupted)
        return nil
    }

    /// `x:row` → `row`.
    static func localName(_ name: String) -> Substring {
        guard let colon = name.utf8.lastIndex(of: UInt8(ascii: ":")) else { return name[...] }
        return name[name.utf8.index(after: colon)...]
    }

    /// Whether the prolog holds a document type declaration. Parts never need
    /// one, and its entities can expand far past the part's size. Checked
    /// lexically, over UTF-8 or UTF-16 code units, so the rejection doesn't
    /// depend on which entity callbacks a platform's XMLParser delivers.
    static func declaresDocumentType(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var width = 1, little = false, start = 0
            if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { start = 3 }
            else if bytes.count >= 2 {
                switch (bytes[0], bytes[1]) {
                case (0xFE, 0xFF): width = 2; start = 2
                case (0xFF, 0xFE): width = 2; little = true; start = 2
                case (0x00, 0x3C): width = 2
                case (0x3C, 0x00): width = 2; little = true
                default: break
                }
            }
            let count = (bytes.count - start) / width
            func unit(_ index: Int) -> UInt16 {
                guard index < count else { return 0 }
                let offset = start + index * width
                guard width == 2 else { return UInt16(bytes[offset]) }
                let (high, low) = little ? (bytes[offset + 1], bytes[offset]) : (bytes[offset], bytes[offset + 1])
                return UInt16(high) << 8 | UInt16(low)
            }
            func matches(_ token: String, at index: Int) -> Bool {
                token.utf8.enumerated().allSatisfy { unit(index + $0.offset) == UInt16($0.element) }
            }
            var index = 0
            // Skip the prolog's whitespace, processing instructions (including
            // the XML declaration) and comments; stop at the first other markup.
            while index < count {
                switch unit(index) {
                case 0x20, 0x09, 0x0A, 0x0D:
                    index += 1
                case 0x3C where matches("<?", at: index) || matches("<!--", at: index):
                    let close = matches("<?", at: index) ? "?>" : "-->"
                    index += 2
                    while index < count, !matches(close, at: index) { index += 1 }
                    index += close.utf8.count
                default:
                    return matches("<!", at: index)
                }
            }
            return false
        }
    }
}

/// `_rels/*.rels`: `Relationships › Relationship`.
private final class RelationshipsParser: SpreadsheetMLParser {
    struct Item { let id: String, type: String, target: String, external: Bool }
    private(set) var relationships: [Item] = []
    private let maximumCount: Int

    init(maximumCount: Int) { self.maximumCount = maximumCount }

    override func start(_ name: Substring, attributes: [String: String], parser: XMLParser) {
        guard depth == 2, name == "Relationship" else { return }
        guard relationships.count < maximumCount else { fail(parser, PicoDocsError.parsingError); return }
        guard let type = attributes["Type"], let target = attributes["Target"] else { return }
        let id = (attributes["Id"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = attributes["TargetMode"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        relationships.append(Item(id: id, type: type.trimmingCharacters(in: .whitespacesAndNewlines),
                                  target: target, external: mode == "External"))
    }
}

/// `workbook.xml`: `workbook › sheets › sheet`, in tab order.
private final class WorkbookParser: SpreadsheetMLParser {
    struct Sheet { let name: String?, relationshipID: String? }
    private(set) var sheets: [Sheet] = []
    private let maximumCount: Int
    private var inSheets = false

    init(maximumCount: Int) { self.maximumCount = maximumCount }

    override func start(_ name: Substring, attributes: [String: String], parser: XMLParser) {
        if depth == 2, name == "sheets" { inSheets = true; return }
        guard depth == 3, inSheets, name == "sheet" else { return }
        guard sheets.count < maximumCount else { fail(parser, PicoDocsError.parsingError); return }
        // The relationship id is the namespaced `id` (conventionally `r:id`).
        let id = attributes["r:id"] ?? attributes.first { $0.key.hasSuffix(":id") }?.value
        sheets.append(Sheet(name: attributes["name"], relationshipID: id?.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    override func end(_ name: Substring) {
        if depth == 2 { inSheets = false }
    }
}

/// `sharedStrings.xml`: `sst › si`, each the text of its `t` or of its rich
/// runs' `r › t`. Phonetic guides (`rPh › t`) are not part of the value.
private final class SharedStringsParser: SpreadsheetMLParser {
    private(set) var items: [String] = []
    private let maximumCount: Int
    private var inItem = false, inRun = false, capturing = false
    private var current = ""

    init(maximumCount: Int) { self.maximumCount = maximumCount }

    override func start(_ name: Substring, attributes: [String: String], parser: XMLParser) {
        switch depth {
        case 2 where name == "si":
            guard items.count < maximumCount else { fail(parser, PicoDocsError.parsingError); return }
            inItem = true
            current = ""
        case 3 where inItem:
            if name == "t" { capturing = true } else if name == "r" { inRun = true }
        case 4 where inRun && name == "t":
            capturing = true
        default:
            break
        }
    }

    override func end(_ name: Substring) {
        switch depth {
        case 2 where inItem:
            items.append(current)
            inItem = false
        case 3:
            capturing = false
            inRun = false
        case 4:
            capturing = false
        default:
            break
        }
    }

    override func text(_ string: String) {
        if capturing { current += string }
    }
}

/// A worksheet: `worksheet › sheetData › row › c`, each cell's `v` or inline
/// `is` (its `t`, or its rich runs' `r › t`).
///
/// `r` is optional on rows and cells. A row without one follows the previous
/// row, unless its first referenced cell names the row; a cell without one
/// follows the previous cell of its row.
private final class WorksheetParser: SpreadsheetMLParser {
    private(set) var rows: [SpreadsheetRow] = []
    private let maximumRows: Int, maximumCells: Int
    private var cellCount = 0

    private var inSheetData = false
    private var inRow = false
    private var rowIndex: Int?
    private var previousRow = 0
    private var cells: [SpreadsheetCell] = []

    private var inCell = false
    private var column = 0, previousColumn = -1
    private var isSharedString = false
    private var value = "", hasValue = false
    private var inline = "", hasInline = false
    private var inInline = false, inRun = false

    private enum Capture { case none, value, inline }
    private var capture = Capture.none

    init(maximumRows: Int, maximumCells: Int) {
        self.maximumRows = maximumRows
        self.maximumCells = maximumCells
    }

    override func start(_ name: Substring, attributes: [String: String], parser: XMLParser) {
        switch depth {
        case 2 where name == "sheetData":
            inSheetData = true
        case 3 where inSheetData && name == "row":
            beginRow(attributes, parser: parser)
        case 4 where inRow && name == "c":
            beginCell(attributes, parser: parser)
        case 5 where inCell:
            if name == "v" {
                value = ""
                hasValue = true
                capture = .value
            } else if name == "is" {
                inline = ""
                hasInline = true
                inInline = true
            }
        case 6 where inInline:
            if name == "t" { capture = .inline } else if name == "r" { inRun = true }
        case 7 where inRun && name == "t":
            capture = .inline
        default:
            break
        }
    }

    override func end(_ name: Substring) {
        switch depth {
        case 2:
            inSheetData = false
        case 3 where inRow:
            let index = rowIndex ?? Self.successor(previousRow)
            rows.append(SpreadsheetRow(index: index, cells: cells))
            previousRow = index
            cells = []
            inRow = false
        case 4 where inCell:
            endCell()
        case 5:
            capture = .none
            inInline = false
        case 6:
            capture = .none
            inRun = false
        case 7:
            capture = .none
        default:
            break
        }
    }

    override func text(_ string: String) {
        switch capture {
        case .none: break
        case .value: value += string
        case .inline: inline += string
        }
    }

    private func beginRow(_ attributes: [String: String], parser: XMLParser) {
        guard rows.count < maximumRows else { fail(parser, PicoDocsError.parsingError); return }
        inRow = true
        previousColumn = -1
        rowIndex = nil
        if let reference = attributes["r"], !reference.isEmpty {
            guard let index = Int(reference) ?? Int(reference.trimmingCharacters(in: .whitespaces)) else {
                fail(parser, PicoDocsError.fileCorrupted); return
            }
            rowIndex = index
        }
    }

    private func beginCell(_ attributes: [String: String], parser: XMLParser) {
        guard cellCount < maximumCells else { fail(parser, PicoDocsError.parsingError); return }
        cellCount += 1
        inCell = true
        hasValue = false
        hasInline = false
        isSharedString = attributes["t"] == "s"
        if let reference = attributes["r"], !reference.isEmpty {
            guard let (column, row) = Self.cellReference(reference) else { fail(parser, PicoDocsError.fileCorrupted); return }
            // A cell belongs to its row; one naming another row is corrupt.
            if let rowIndex {
                guard row == rowIndex else { fail(parser, PicoDocsError.fileCorrupted); return }
            } else {
                rowIndex = row
            }
            self.column = column
        } else {
            column = Self.successor(previousColumn)
        }
        previousColumn = column
    }

    private func endCell() {
        let content: SpreadsheetCell.Content
        if isSharedString, hasValue, let index = Int(value) ?? Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            content = .sharedString(index)
        } else if hasInline {
            content = .text(inline)
        } else if hasValue {
            content = .text(value)
        } else {
            content = .empty
        }
        cells.append(SpreadsheetCell(column: column, content: content))
        inCell = false
        capture = .none
    }

    private static func successor(_ value: Int) -> Int {
        value < Int(Int32.max) ? value + 1 : value
    }

    /// `B12` → (column 1, row 12). Letters are case-insensitive and `$`
    /// anchors are ignored; both parts saturate rather than overflow, leaving
    /// out-of-range coordinates for the grid bounds to reject.
    static func cellReference(_ text: String) -> (column: Int, row: Int)? {
        var column = 0, row = 0, letters = 0, digits = 0
        let limit = Int(Int32.max)
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"):
                guard digits == 0 else { return nil }
                letters += 1
                column = min(column * 26 + Int(byte & 0x1F), limit)
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                guard letters > 0 else { return nil }
                digits += 1
                row = min(row * 10 + Int(byte - UInt8(ascii: "0")), limit)
            case UInt8(ascii: "$"):
                continue
            default:
                return nil
            }
        }
        guard letters > 0, digits > 0 else { return nil }
        return (column - 1, row)
    }
}
