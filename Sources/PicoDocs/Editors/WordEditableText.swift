//
//  WordEditableText.swift
//  PicoDocs
//
//  The editable-text snapshot of a DOCX main document part (`word/document.xml`)
//  and the map from every snapshot position back to the raw bytes it came from.
//  This is what makes surgical, source-preserving edits possible:
//
//   • `text` is the one string a caller shows the model *and* the matcher
//     searches, so a verbatim quote always matches. It is not the rendered
//     Markdown/plaintext, which adds list markers, table pipes and footnote
//     numbers that don't exist in the file.
//   • `segments` partition `text` in UTF-16 code units. An editable segment
//     carries its `<w:t>`'s raw byte ranges, entity by entity (`&amp;` is five
//     bytes for one character), which a DOM can't supply — so this is a small
//     single-pass scanner over the raw UTF-8 bytes rather than a SwiftSoup walk.
//
//  What's in the snapshot: ordinary run text is editable. Tabs, line breaks and
//  paragraph breaks appear as `\t`/`\n` but are boundaries. Text in hyperlinks,
//  fields, content controls and tracked insertions is shown for reading order
//  but isn't editable. Hidden runs, deleted text, field instructions and
//  everything inside drawings, objects and alternate content (including text
//  boxes) are left out; when they sit between two editable runs, a zero-width
//  boundary keeps a match from silently spanning them.
//

import Foundation

struct WordEditableText {

    typealias Boundary = PicoDocsError.EditBoundary

    /// The text to show the model and to match `TextEdit.find` against.
    let text: String

    /// Contiguous, ordered segments covering `text` in UTF-16 offsets.
    /// Zero-width boundary segments mark structure between two editable runs.
    let segments: [Segment]

    struct Segment {
        /// UTF-16 offsets into `text`.
        let range: Range<Int>
        let content: Content
    }

    enum Content {
        /// Editable text from one `<w:t>`.
        case run(Run)
        /// Text (or a zero-width marker) a match may not touch or cross.
        case boundary(Boundary)
    }

    /// One editable `<w:t>` and where its visible text lives in the raw bytes.
    struct Run {
        /// The `<w:t …>` start tag.
        let startTag: Range<Int>
        /// Everything between the start tag and `</w:t>`.
        let content: Range<Int>
        /// The visible part of `content`: without `xml:space="preserve"`, Word
        /// drops leading and trailing whitespace, so those bytes aren't shown.
        let visible: Range<Int>
        let preservesSpace: Bool
        /// The value of an `xml:space` attribute that isn't `preserve`, if any.
        let spaceValue: Range<Int>?
        /// `visible`, split into literal byte runs and single references.
        let pieces: [Piece]
    }

    /// A stretch of raw bytes that decodes either one-to-one (a literal run of
    /// UTF-8) or as a unit (a single entity or character reference).
    struct Piece {
        let bytes: Range<Int>
        let utf16Count: Int
        let isLiteral: Bool
    }

    // MARK: - Scanning

    /// Scans `xml` (the raw bytes of `word/document.xml`).
    ///
    /// Throws `documentTypeNotSupported` for a part that isn't UTF-8 (its bytes
    /// couldn't be preserved), and `fileCorrupted` for input this scanner can't
    /// read safely — a DTD, mismatched tags, a malformed reference, or invalid
    /// UTF-8 in text — so a bad file is rejected rather than mis-edited.
    init(documentXML xml: [UInt8]) throws {
        var extractor = Extractor(xml: xml)
        try extractor.scan()
        text = extractor.text
        segments = extractor.segments
    }

    private struct RunState {
        var hidden = false
        var tracked = false
    }

    private struct OpenText {
        let startTag: Range<Int>
        let contentStart: Int
        let preservesSpace: Bool
        let spaceValue: Range<Int>?
        var isSimple = true
    }

    private struct Extractor {
        let xml: [UInt8]
        var text = ""
        var segments: [Segment] = []

        private var offset = 0
        private var stack: [String] = []
        private var paragraphs: [Int] = []
        private var nextParagraph = 0
        private var runs: [RunState] = []
        private var fields: [Bool] = []          // per open complex field: in its result part?
        private var propertyDepth = 0
        private var opaqueDepth = 0
        private var deletedDepth = 0
        private var insertedDepth = 0
        private var hyperlinkDepth = 0
        private var simpleFieldDepth = 0
        private var contentControlDepth = 0
        private var openText: OpenText?
        private var lastParagraph: Int?
        private var lastWasRun = false
        private var pending: Boundary?

        init(xml: [UInt8]) {
            self.xml = xml
        }

        mutating func scan() throws {
            if xml.starts(with: [0xFE, 0xFF]) || xml.starts(with: [0xFF, 0xFE]) {
                throw PicoDocsError.documentTypeNotSupported
            }
            var i = 0
            var tags = 0
            while let lt = xml[i...].firstIndex(of: UInt8(ascii: "<")) {
                tags += 1
                if tags.isMultiple(of: 4096) { try Task.checkCancellation() }
                i = try markup(at: lt)
            }
            guard stack.isEmpty, openText == nil else { throw PicoDocsError.fileCorrupted }
        }

        /// Handles the markup starting at `lt` and returns the index after it.
        private mutating func markup(at lt: Int) throws -> Int {
            if has("<!--", at: lt) {
                openText?.isSimple = false
                return try index(after: "-->", from: lt + 4)
            }
            if has("<![CDATA[", at: lt) {
                openText?.isSimple = false
                return try index(after: "]]>", from: lt + 9)
            }
            if has("<?", at: lt) {
                let end = try index(after: "?>", from: lt + 2)
                if has("<?xml", at: lt), end - 2 > lt + 5, isSpace(xml[lt + 5]) {
                    try checkDeclaration(lt + 5..<end - 2)
                } else {
                    openText?.isSimple = false
                }
                return end
            }
            if has("<!", at: lt) {
                // OOXML parts may not carry a DTD; one could also define
                // entities this scanner wouldn't expand.
                throw PicoDocsError.fileCorrupted
            }
            guard let gt = tagEnd(from: lt) else { throw PicoDocsError.fileCorrupted }
            if xml[lt + 1] == UInt8(ascii: "/") {
                let name = elementName(from: lt + 2)
                guard stack.last == name else { throw PicoDocsError.fileCorrupted }
                stack.removeLast()
                try endElement(name, endTagStart: lt)
            } else {
                let name = elementName(from: lt + 1)
                guard !name.isEmpty else { throw PicoDocsError.fileCorrupted }
                let selfClosing = xml[gt - 1] == UInt8(ascii: "/")
                openText?.isSimple = false
                try startElement(name, tag: lt..<gt + 1, selfClosing: selfClosing)
                if !selfClosing {
                    stack.append(name)
                } else {
                    try endElement(name, endTagStart: nil)
                }
            }
            return gt + 1
        }

        // MARK: Elements

        private mutating func startElement(_ name: String, tag: Range<Int>, selfClosing: Bool) throws {
            let parent = stack.last
            if propertyDepth > 0 || name.hasSuffix("pr") {
                // Property subtrees (w:rPr, w:pPr, w:sdtPr, …) carry no text. A
                // run's own w:rPr decides whether its text is hidden or tracked.
                if parent == "w:rpr", stack.dropLast().last == "w:r", !runs.isEmpty {
                    if name == "w:vanish" { runs[runs.count - 1].hidden = try isOn(tag) }
                    if name == "w:rprchange" { runs[runs.count - 1].tracked = true }
                }
                if !selfClosing { propertyDepth += 1 }
                return
            }
            switch name {
            case "w:p":
                if !selfClosing {
                    paragraphs.append(nextParagraph)
                    nextParagraph += 1
                }
            case "w:r":
                if !selfClosing { runs.append(RunState()) }
            case "w:t" where parent == "w:r":
                if !selfClosing {
                    let space = try attribute("xml:space", in: tag)
                    let preserves = space.map { equals($0, "preserve") } ?? false
                    openText = OpenText(startTag: tag, contentStart: tag.upperBound, preservesSpace: preserves,
                                        spaceValue: preserves ? nil : space)
                }
            case "w:tab", "w:ptab":
                // Outside a run (w:tabs in paragraph properties) a tab is a tab
                // stop, already skipped as a property; these are run content.
                if parent == "w:r" { visibleStructure("\t", .tab) }
            case "w:br", "w:cr":
                if parent == "w:r" { visibleStructure("\n", .lineBreak) }
            case "w:nobreakhyphen", "w:softhyphen":
                // Shown as their Unicode characters so "e‑mail" doesn't read as
                // "email", but they're elements, not text, so they stay fixed.
                if parent == "w:r" { visibleStructure(name == "w:softhyphen" ? "\u{AD}" : "\u{2011}", .object) }
            case "w:fldchar":
                switch try attribute("w:fldCharType", in: tag).map({ String(decoding: xml[$0], as: UTF8.self) }) {
                case "begin": fields.append(false)
                case "separate": if !fields.isEmpty { fields[fields.count - 1] = true }
                case "end": if !fields.isEmpty { fields.removeLast() }
                default: break
                }
                mark(.field)
            default:
                if !selfClosing { adjustDepth(name, by: 1) }
                if let kind = Self.boundary(for: name) { mark(kind) }
            }
        }

        private mutating func endElement(_ name: String, endTagStart: Int?) throws {
            if propertyDepth > 0 {
                if endTagStart != nil { propertyDepth -= 1 }
                return
            }
            switch name {
            case "w:p":
                if endTagStart != nil { paragraphs.removeLast() }
            case "w:r":
                if endTagStart != nil { runs.removeLast() }
            case "w:t":
                if let open = openText, let end = endTagStart {
                    openText = nil
                    try closeText(open, contentEnd: end)
                }
            case "w:tab", "w:ptab", "w:br", "w:cr", "w:nobreakhyphen", "w:softhyphen", "w:fldchar":
                break
            default:
                if endTagStart != nil {
                    adjustDepth(name, by: -1)
                    if let kind = Self.boundary(for: name) { mark(kind) }
                }
            }
        }

        private mutating func adjustDepth(_ name: String, by delta: Int) {
            switch name {
            case "w:drawing", "w:pict", "w:object", "mc:alternatecontent", "w:txbxcontent",
                 "m:omath", "m:omathpara", "w:ruby":
                opaqueDepth += delta
            case "w:del", "w:movefrom": deletedDepth += delta
            case "w:ins", "w:moveto": insertedDepth += delta
            case "w:hyperlink": hyperlinkDepth += delta
            case "w:fldsimple": simpleFieldDepth += delta
            case "w:sdt": contentControlDepth += delta
            default: break
            }
        }

        /// The boundary an element creates between two editable runs, or nil for
        /// markup a match may span (run structure, bookmarks, proofing marks).
        private static func boundary(for name: String) -> Boundary? {
            switch name {
            case "w:p", "w:r", "w:t", "w:prooferr", "w:bookmarkstart", "w:bookmarkend",
                 "w:commentrangestart", "w:commentrangeend", "w:lastrenderedpagebreak":
                return nil
            case "w:hyperlink":
                return .hyperlink
            case "w:fldsimple", "w:fldchar", "w:instrtext", "w:delinstrtext":
                return .field
            case "w:sdt", "w:sdtcontent":
                return .contentControl
            case "w:ins", "w:del", "w:moveto", "w:movefrom", "w:deltext",
                 "w:movefromrangestart", "w:movefromrangeend", "w:movetorangestart", "w:movetorangeend":
                return .trackedChange
            default:
                return .object
            }
        }

        // MARK: Visibility

        /// Why content here isn't displayed at all, or nil when it is.
        private var excluded: Boundary? {
            if opaqueDepth > 0 { return .object }
            if deletedDepth > 0 { return .trackedChange }
            if fields.contains(false) { return .field }
            if runs.last?.hidden == true { return .hiddenText }
            return nil
        }

        /// Why displayed content here can't be edited, or nil when it can.
        private var fixed: Boundary? {
            if insertedDepth > 0 || runs.last?.tracked == true { return .trackedChange }
            if simpleFieldDepth > 0 || !fields.isEmpty { return .field }
            if hyperlinkDepth > 0 { return .hyperlink }
            if contentControlDepth > 0 { return .contentControl }
            return nil
        }

        /// Notes structure between the previous text and the next. The first
        /// boundary since the last emitted text names the zero-width marker.
        private mutating func mark(_ kind: Boundary) {
            if pending == nil { pending = kind }
        }

        private mutating func visibleStructure(_ character: String, _ kind: Boundary) {
            if let reason = excluded {
                mark(reason)
            } else {
                emit(character, .boundary(kind))
            }
        }

        private mutating func closeText(_ open: OpenText, contentEnd: Int) throws {
            if let reason = excluded {
                mark(reason)
                return
            }
            guard open.isSimple else {
                // Comments, CDATA or elements inside w:t: Word never writes these,
                // so leave the text out rather than map it.
                mark(.object)
                return
            }
            var decoded = try decode(open.contentStart..<contentEnd)
            if !open.preservesSpace { Self.trimXMLWhitespace(&decoded) }
            guard let first = decoded.first, let last = decoded.last else { return }
            let visibleText = decoded.map { $0.text }.joined()
            if let kind = fixed {
                emit(visibleText, .boundary(kind))
                return
            }
            let run = Run(
                startTag: open.startTag,
                content: open.contentStart..<contentEnd,
                visible: first.piece.bytes.lowerBound..<last.piece.bytes.upperBound,
                preservesSpace: open.preservesSpace,
                spaceValue: open.spaceValue,
                pieces: decoded.map { $0.piece }
            )
            emit(visibleText, .run(run))
        }

        // MARK: Emission

        private mutating func emit(_ string: String, _ content: Content) {
            let paragraph = paragraphs.last ?? -1
            if let previous = lastParagraph, previous != paragraph {
                append("\n", .boundary(.paragraph))
                lastWasRun = false
            }
            lastParagraph = paragraph
            if case .run = content {
                if lastWasRun, let kind = pending { append("", .boundary(kind)) }
                lastWasRun = true
            } else {
                lastWasRun = false
            }
            pending = nil
            append(string, content)
        }

        private mutating func append(_ string: String, _ content: Content) {
            let count = string.utf16.count
            segments.append(Segment(range: offset..<offset + count, content: content))
            text += string
            offset += count
        }

        // MARK: Text decoding

        /// Splits raw text content into pieces with their decoded text.
        private func decode(_ range: Range<Int>) throws -> [(piece: Piece, text: String)] {
            var result: [(piece: Piece, text: String)] = []
            var literalStart = range.lowerBound
            var i = range.lowerBound
            func flushLiteral(upTo end: Int) throws {
                guard literalStart < end else { return }
                let bytes = xml[literalStart..<end]
                let string = String(decoding: bytes, as: UTF8.self)
                guard string.utf8.elementsEqual(bytes) else { throw PicoDocsError.fileCorrupted }
                result.append((Piece(bytes: literalStart..<end, utf16Count: string.utf16.count, isLiteral: true), string))
            }
            while i < range.upperBound {
                if xml[i] == UInt8(ascii: "&") {
                    try flushLiteral(upTo: i)
                    let limit = min(range.upperBound, i + 32)
                    guard let semicolon = xml[i..<limit].firstIndex(of: UInt8(ascii: ";")),
                          let scalar = Self.reference(xml[i + 1..<semicolon]) else {
                        throw PicoDocsError.fileCorrupted
                    }
                    let string = String(Character(scalar))
                    result.append((Piece(bytes: i..<semicolon + 1, utf16Count: string.utf16.count, isLiteral: false), string))
                    i = semicolon + 1
                    literalStart = i
                } else {
                    i += 1
                }
            }
            try flushLiteral(upTo: range.upperBound)
            return result
        }

        /// The scalar an entity or character reference body (between `&` and `;`)
        /// stands for, or nil if it isn't one XML defines.
        private static func reference(_ body: ArraySlice<UInt8>) -> Unicode.Scalar? {
            let name = String(decoding: body, as: UTF8.self)
            switch name {
            case "amp": return "&"
            case "lt": return "<"
            case "gt": return ">"
            case "quot": return "\""
            case "apos": return "'"
            default: break
            }
            guard name.hasPrefix("#") else { return nil }
            let digits = name.dropFirst()
            let value = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
            guard let value, !digits.isEmpty, !digits.contains("+"), !digits.contains("-") else { return nil }
            return Unicode.Scalar(value)
        }

        /// Drops leading and trailing XML whitespace (space, tab, CR, LF), the
        /// way Word displays a `<w:t>` without `xml:space="preserve"`.
        private static func trimXMLWhitespace(_ decoded: inout [(piece: Piece, text: String)]) {
            func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
                scalar == " " || scalar == "\t" || scalar == "\r" || scalar == "\n"
            }
            while let first = decoded.first {
                let leading = first.text.unicodeScalars.prefix(while: isWhitespace).count
                if leading == 0 { break }
                if leading == first.text.unicodeScalars.count {
                    decoded.removeFirst()
                    continue
                }
                // Only a literal piece can be partly whitespace; whitespace is
                // one byte and one UTF-16 unit per character.
                let piece = first.piece
                decoded[0] = (Piece(bytes: piece.bytes.lowerBound + leading..<piece.bytes.upperBound,
                                    utf16Count: piece.utf16Count - leading, isLiteral: true),
                              String(first.text.unicodeScalars.dropFirst(leading)))
                break
            }
            while let last = decoded.last {
                let trailing = last.text.unicodeScalars.reversed().prefix(while: isWhitespace).count
                if trailing == 0 { break }
                if trailing == last.text.unicodeScalars.count {
                    decoded.removeLast()
                    continue
                }
                let piece = last.piece
                decoded[decoded.count - 1] = (Piece(bytes: piece.bytes.lowerBound..<piece.bytes.upperBound - trailing,
                                                    utf16Count: piece.utf16Count - trailing, isLiteral: true),
                                              String(last.text.unicodeScalars.dropLast(trailing)))
                break
            }
        }

        // MARK: Markup helpers

        private func has(_ literal: String, at index: Int) -> Bool {
            xml[index...].starts(with: literal.utf8)
        }

        private func index(after literal: String, from start: Int) throws -> Int {
            let needle = Array(literal.utf8)
            var i = start
            while let candidate = xml[i...].firstIndex(of: needle[0]) {
                if xml[candidate...].starts(with: needle) { return candidate + needle.count }
                i = candidate + 1
            }
            throw PicoDocsError.fileCorrupted
        }

        /// The `>` closing the tag at `start`, skipping quoted attribute values.
        private func tagEnd(from start: Int) -> Int? {
            var quote: UInt8?
            var i = start + 1
            while i < xml.count {
                let byte = xml[i]
                if let open = quote {
                    if byte == open { quote = nil }
                } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                    quote = byte
                } else if byte == UInt8(ascii: ">") {
                    return i
                } else if byte == UInt8(ascii: "<") {
                    return nil
                }
                i += 1
            }
            return nil
        }

        /// The lowercased qualified name starting at `start`.
        private func elementName(from start: Int) -> String {
            var end = start
            while end < xml.count, !isSpace(xml[end]), xml[end] != UInt8(ascii: "/"), xml[end] != UInt8(ascii: ">") {
                end += 1
            }
            return String(decoding: xml[start..<end], as: UTF8.self).lowercased()
        }

        private func isSpace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }

        /// The raw value range of attribute `name` in `tag`, or nil if absent.
        private func attribute(_ name: String, in tag: Range<Int>) throws -> Range<Int>? {
            var i = tag.lowerBound + 1
            while i < tag.upperBound, !isSpace(xml[i]), xml[i] != UInt8(ascii: "/"), xml[i] != UInt8(ascii: ">") { i += 1 }
            return try attribute(name, from: i, to: tag.upperBound)
        }

        private func attribute(_ name: String, from start: Int, to end: Int) throws -> Range<Int>? {
            var i = start
            while true {
                while i < end, isSpace(xml[i]) { i += 1 }
                guard i < end, xml[i] != UInt8(ascii: "/"), xml[i] != UInt8(ascii: ">"), xml[i] != UInt8(ascii: "?") else { return nil }
                let nameStart = i
                while i < end, !isSpace(xml[i]), xml[i] != UInt8(ascii: "=") { i += 1 }
                let attributeName = xml[nameStart..<i]
                while i < end, isSpace(xml[i]) { i += 1 }
                guard i < end, xml[i] == UInt8(ascii: "=") else { throw PicoDocsError.fileCorrupted }
                i += 1
                while i < end, isSpace(xml[i]) { i += 1 }
                guard i < end, xml[i] == UInt8(ascii: "\"") || xml[i] == UInt8(ascii: "'") else { throw PicoDocsError.fileCorrupted }
                let quote = xml[i]
                guard let close = xml[(i + 1)..<end].firstIndex(of: quote) else { throw PicoDocsError.fileCorrupted }
                if attributeName.elementsEqual(name.utf8) { return i + 1..<close }
                i = close + 1
            }
        }

        private func equals(_ range: Range<Int>, _ literal: String) -> Bool {
            xml[range].elementsEqual(literal.utf8)
        }

        /// Whether an on/off property such as `<w:vanish/>` is on: it is unless
        /// `w:val` says false, 0 or off.
        private func isOn(_ tag: Range<Int>) throws -> Bool {
            guard let value = try attribute("w:val", in: tag) else { return true }
            return !["false", "0", "off"].contains(String(decoding: xml[value], as: UTF8.self).lowercased())
        }

        /// Only UTF-8 parts are edited in place: any other encoding would need
        /// every byte re-encoded, defeating byte preservation.
        private func checkDeclaration(_ range: Range<Int>) throws {
            guard let encoding = try attribute("encoding", from: range.lowerBound, to: range.upperBound) else { return }
            let name = String(decoding: xml[encoding], as: UTF8.self).lowercased()
            guard name == "utf-8" || name == "utf8" else { throw PicoDocsError.documentTypeNotSupported }
        }
    }
}
