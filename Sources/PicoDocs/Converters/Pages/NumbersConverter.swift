//
//  NumbersConverter.swift
//  PicoDocs
//
//  Converts Apple Numbers (`.numbers`, iWork '13+) spreadsheets to Markdown,
//  reusing the in-module iWork Archive (IWA) decoder and table reconstruction
//  built for Pages and Keynote. A `.numbers` is the same ZIP/IWA container; its
//  `Document.iwa` holds the TN.DocumentArchive (type 1) whose field 1 lists the
//  sheets in tab order, and each TN.SheetArchive (type 2) carries its name
//  (field 1) and drawables (field 2) — the tables, whose cells live in the
//  `Tables/*.iwa` tiles and datalists.
//
//  Output mirrors SpreadsheetConverter: one `.sheet` section per sheet, headed
//  `## <sheet name>`, holding that sheet's tables as Markdown grids in drawable
//  order. Each table is attributed to the sheet it's reachable from (as Keynote
//  attributes tables to slides). Text boxes, charts, and images on sheets are
//  not extracted.
//

import Foundation
import ZIPFoundation

public struct NumbersConverter: DocumentConverter {

    /// TN.DocumentArchive and TN.SheetArchive message types.
    private static let documentArchiveType: UInt64 = 1
    private static let sheetArchiveType: UInt64 = 2

    private let outputBudgetBytes: Int
    private let outputBudgetCells: Int
    private let objectBudgetBytes: Int

    public init() {
        outputBudgetBytes = 64 * 1024 * 1024
        outputBudgetCells = 1_000_000
        objectBudgetBytes = 64 * 1024 * 1024
    }

    init(outputBudgetBytes: Int, outputBudgetCells: Int = 1_000_000, objectBudgetBytes: Int = 64 * 1024 * 1024) {
        self.outputBudgetBytes = outputBudgetBytes
        self.outputBudgetCells = outputBudgetCells
        self.objectBudgetBytes = objectBudgetBytes
    }

    public func accepts(_ info: StreamInfo) -> Bool {
        info.detectedFormat == .numbers
    }

    public func convert(_ data: Data, info: StreamInfo) async throws -> ConverterResult {
        try Task.checkCancellation()
        guard let archive = Archive(data: data, accessMode: .read) else {
            throw PicoDocsError.fileCorrupted
        }
        let components = try PagesConverter.iwaComponents(in: archive, maximumEntryBytes: 32 * 1024 * 1024, maximumTotalBytes: 128 * 1024 * 1024)
        guard !components.isEmpty else {
            // Likely a legacy iWork '09 package — not supported.
            throw PicoDocsError.documentTypeNotSupported
        }

        // Decompress every component once. The document stream holds the sheet
        // list, so its failure is corruption; auxiliary streams are skipped
        // leniently (a table whose tiles are lost is simply not reconstructed).
        var streams: [[UInt8]] = []
        var remainingDecodedBytes = 128 * 1024 * 1024
        var documentStream: [UInt8]?
        for component in components {
            try Task.checkCancellation()
            do {
                let stream = try Snappy.decompressIWA(component.bytes, maximumOutputBytes: min(32 * 1024 * 1024, remainingDecodedBytes))
                if component.name.hasSuffix("Document.iwa") { documentStream = stream }
                remainingDecodedBytes -= stream.count
                streams.append(stream)
            } catch Snappy.SnappyError.outputLimitExceeded { throw PicoDocsError.fileCorrupted
            } catch is CancellationError { throw CancellationError()
            } catch {
                if component.name.hasSuffix("Document.iwa") { throw PicoDocsError.fileCorrupted }
            }
        }
        guard let documentStream else { throw PicoDocsError.fileCorrupted }

        let objectBudget = IWAObjectBudget(bytes: objectBudgetBytes)
        let budget = IWAOutputBudget(bytes: outputBudgetBytes, cells: outputBudgetCells)
        let sheets = Self.sheets(in: IWAArchive.objects(in: documentStream, objectBudget: objectBudget), budget: budget)
        try objectBudget.check()
        try budget.check()
        let attribution = IWATable.attributedTables(rootIDs: sheets.map(\.id), in: streams, excludingSubgraphs: [], budget: budget, objectBudget: objectBudget)
        try objectBudget.check()
        try budget.check()

        var sections: [DocumentSection] = []
        for sheet in sheets {
            try budget.check()
            guard budget.reserve(256) else { try budget.check(); throw PicoDocsError.fileCorrupted }
            let tables = attribution.byRoot[sheet.id] ?? []
            for table in tables { budget.reserve(table.utf8.count, copies: 2) }
            budget.reserve(tables.count, copies: 4)
            let heading = try sheet.name.map { try Self.literalHeading($0, budget: budget) }
            try budget.check()
            var markdown = tables.joined(separator: "\n\n")
            if let heading { markdown = "## " + heading + "\n\n" + markdown }
            sections.append(DocumentSection(title: sheet.name, kind: .sheet, markdown: markdown, sheetName: sheet.name, metadata: ["preservedWhitespace": "1"]))
        }
        // Partial reachability must not drop the remaining physical tables.
        for markdown in attribution.unclaimed {
            guard budget.reserve(256) else { try budget.check(); throw PicoDocsError.fileCorrupted }
            sections.append(DocumentSection(kind: .sheet, markdown: markdown))
        }

        try budget.check()
        guard !sections.isEmpty else { throw PicoDocsError.emptyDocument }
        let title = (info.filename?.isEmpty == false) ? info.filename : nil
        return ConverterResult(title: title, sections: sections)
    }

    /// The workbook's sheets in tab order: the TN.DocumentArchive's sheet
    /// references (field 1), falling back to the sheet archives' stream order.
    /// Each sheet's name is its archive's field 1.
    static func sheets(in objects: [IWAArchive.Object], budget: IWAOutputBudget? = nil) -> [(id: UInt64, name: String?)] {
        var sheetObjects: [IWAArchive.Object] = []
        var byID: [UInt64: IWAArchive.Object] = [:]
        for object in objects {
            guard !Task.isCancelled, budget?.active != false else { return [] }
            if object.type == sheetArchiveType {
                sheetObjects.append(object)
                if byID[object.identifier] == nil { byID[object.identifier] = object }
            }
        }

        var order: [UInt64] = [], seen: Set<UInt64> = []
        if let document = objects.first(where: { $0.type == documentArchiveType }) {
            var reader = ProtobufReader(document.payload)
            while let field = reader.next() {
                guard field.number == 1, case .length(let reference) = field.value,
                      let id = referencedID(reference), byID[id] != nil, seen.insert(id).inserted else { continue }
                order.append(id)
            }
        }
        // Retain stream-order recovery after the references that did resolve.
        for sheet in sheetObjects {
            guard !Task.isCancelled else { return [] }
            if seen.insert(sheet.identifier).inserted { order.append(sheet.identifier) }
        }
        var sheets: [(id: UInt64, name: String?)] = []
        for id in order {
            guard !Task.isCancelled, budget?.reserve(64) != false else { return [] }
            let name = byID[id].flatMap { sheetName($0, budget: budget) }
            sheets.append((id, name))
        }
        return sheets
    }

    private static func literalHeading(_ name: String, budget: IWAOutputBudget) throws -> String {
        // Folding, numeric boundary entities (up to 10 bytes/scalar), and the
        // eventual section copy are admitted before any expanded string exists.
        budget.reserve(name.utf8.count, copies: 24)
        budget.reserve(10)
        try budget.check()
        let text = name.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let scalars = text.unicodeScalars
        let leading = scalars.prefix { CharacterSet.whitespaces.contains($0) }.count
        let trailing = scalars.reversed().prefix { CharacterSet.whitespaces.contains($0) }.count
        let end = scalars.count - trailing
        var heading = ""
        for (index, scalar) in scalars.enumerated() {
            if index.isMultiple(of: 1024) { try Task.checkCancellation() }
            if index < leading || index >= end || scalar == "\t" {
                heading += "&#\(scalar.value);"
            } else {
                if #"\`*_{}[]<>#&"#.unicodeScalars.contains(scalar) { heading += "\\" }
                heading.unicodeScalars.append(scalar)
            }
        }
        return heading
    }

    private static func sheetName(_ sheet: IWAArchive.Object, budget: IWAOutputBudget?) -> String? {
        var reader = ProtobufReader(sheet.payload)
        while let field = reader.next() {
            if field.number == 1, case .length(let bytes) = field.value {
                guard budget?.reserve(bytes.count, copies: 2) != false else { return nil }
                if let name = String(bytes: bytes, encoding: .utf8), !name.isEmpty { return name }
            }
        }
        return nil
    }

    /// The object id in a TSP.Reference (`{1: identifier}`).
    private static func referencedID(_ bytes: [UInt8]) -> UInt64? {
        var reader = ProtobufReader(bytes)
        while let field = reader.next() {
            if field.number == 1, case .varint(let id) = field.value { return id }
        }
        return nil
    }
}
