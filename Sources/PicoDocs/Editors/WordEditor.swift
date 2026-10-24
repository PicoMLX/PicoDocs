//
//  WordEditor.swift
//  PicoDocs
//
//  In-place, source-preserving editing of DOCX. Edits are spliced into the raw
//  bytes of `word/document.xml` — the XML is never re-serialized — and the
//  package is rebuilt with every other part copied through unchanged.
//
//  Fidelity guarantee (asserted by WordEditorTests):
//   1. Only `word/document.xml` changes; every other part's uncompressed bytes
//      are identical. (The ZIP container itself is rebuilt and recompressed.)
//   2. Within `document.xml`, only the matched run text changes, with two
//      narrow exceptions that keep the result equivalent and well-formed:
//      `xml:space="preserve"` is added to an edited `<w:t>` left with leading
//      or trailing whitespace Word would drop, and a literal `>` right after an
//      edit is written as `&gt;` when the edit would otherwise form `]]>`.
//  Editing text reflows layout, so pagination can shift; that's inherent to any
//  text edit.
//
//  A match may span several runs (WordEditableText decides which joins are
//  safe). The replacement goes into the first run, keeping its formatting, and
//  the matched part of each later run is removed.
//

import Foundation
import ZIPFoundation

struct WordEditor {

    static let documentPath = "word/document.xml"

    /// The same ceiling `WordConverter.readEntry` reads `document.xml` with, so
    /// an edited file stays readable by PicoDocs.
    static let maximumDocumentBytes = 32 * 1024 * 1024

    /// Upper bound on the uncompressed bytes copied into an edited package.
    /// Every part has to be inflated to be rewritten, so this bounds the work a
    /// hostile archive can demand.
    static let maximumPackageBytes = 1024 * 1024 * 1024

    init() {}

    /// The document's editable text: the exact string to show a model and to
    /// quote `TextEdit.find` from.
    func editableText(_ data: Data) throws -> String {
        let archive = try Self.open(data)
        return try WordEditableText(documentXML: Self.documentXML(in: archive)).text
    }

    /// Applies `edits` in place and returns the edited package.
    ///
    /// All edits match against the same original text, their targets may not
    /// overlap, and the batch is all-or-nothing: any failing edit throws and no
    /// output is produced.
    func applyEdits(_ edits: [TextEdit], to data: Data) throws -> EditResult {
        let archive = try Self.open(data)
        let xml = try Self.documentXML(in: archive)
        let snapshot = try WordEditableText(documentXML: xml)
        let ranges = try TextEditMatcher.resolve(edits, in: snapshot.text)
        let splices = try Self.splices(for: edits, at: ranges, in: snapshot, xml: xml)
        guard !splices.isEmpty else { return EditResult(data: data, applied: []) }
        let edited = try Self.apply(splices, to: xml)
        return EditResult(data: try Self.rebuild(archive, documentXML: edited), applied: ranges.map(\.count))
    }

    // MARK: - Splicing

    private struct Splice {
        let range: Range<Int>
        let bytes: [UInt8]
    }

    /// A replacement's slice of one run, in UTF-16 offsets within the run.
    /// `bytes` is the escaped `text`, built once per edit and shared by all of
    /// its occurrences.
    private struct Cut {
        let range: Range<Int>
        let text: String
        let bytes: [UInt8]
    }

    private static func splices(for edits: [TextEdit], at ranges: [[Range<Int>]], in snapshot: WordEditableText, xml: [UInt8]) throws -> [Splice] {
        var cuts: [Int: [Cut]] = [:]
        for (edit, editRanges) in zip(edits, ranges) {
            try Task.checkCancellation()
            if let structure = structure(in: edit.replace) {
                throw PicoDocsError.editCrossesBoundary(kind: structure)
            }
            // Write what the file will actually hold: XML can't carry some
            // control characters, so they're dropped here as in the exporters.
            let replacement = OOXMLPackageWriter.xmlSafeText(edit.replace)
            let bytes = Array(OOXMLPackageWriter.escape(replacement).utf8)
            for range in editRanges {
                for (position, (segment, local)) in try coveredRuns(range, in: snapshot).enumerated() {
                    let cut = position == 0 ? Cut(range: local, text: replacement, bytes: bytes) : Cut(range: local, text: "", bytes: [])
                    cuts[segment, default: []].append(cut)
                }
            }
        }
        var splices: [Splice] = []
        let units = Array(snapshot.text.utf16)
        for (segment, runCuts) in cuts {
            try Task.checkCancellation()
            guard case .run(let run) = snapshot.segments[segment].content else { continue }
            let sorted = runCuts.sorted { $0.range.lowerBound < $1.range.lowerBound }
            var cursor = PieceCursor(run: run, xml: xml)
            for cut in sorted {
                guard let lower = cursor.byteIndex(at: cut.range.lowerBound),
                      let upper = cursor.byteIndex(at: cut.range.upperBound) else {
                    throw PicoDocsError.parsingError
                }
                splices.append(Splice(range: lower..<upper, bytes: cut.bytes))
            }
            if !run.preservesSpace,
               needsPreservedSpace(units[snapshot.segments[segment].range], after: sorted) {
                splices += preservingSpace(run)
            }
        }
        return splices
    }

    /// The structure a replacement would add, which can't be written as run text.
    private static func structure(in replacement: String) -> PicoDocsError.EditBoundary? {
        if replacement.unicodeScalars.contains("\t") { return .tab }
        if replacement.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) { return .paragraph }
        return nil
    }

    /// The editable runs a snapshot range covers, with the covered part of each
    /// in run-local UTF-16 offsets. Throws when the range touches a boundary.
    private static func coveredRuns(_ range: Range<Int>, in snapshot: WordEditableText) throws -> [(segment: Int, local: Range<Int>)] {
        let segments = snapshot.segments
        // First segment ending after the range starts. A zero-width boundary
        // exactly at an end of the range isn't crossed.
        var low = 0
        var high = segments.count
        while low < high {
            let middle = (low + high) / 2
            if segments[middle].range.upperBound <= range.lowerBound { low = middle + 1 } else { high = middle }
        }
        var covered: [(segment: Int, local: Range<Int>)] = []
        var index = low
        while index < segments.count, segments[index].range.lowerBound < range.upperBound {
            let segment = segments[index]
            switch segment.content {
            case .boundary(let kind):
                throw PicoDocsError.editCrossesBoundary(kind: kind)
            case .run:
                let lower = max(segment.range.lowerBound, range.lowerBound) - segment.range.lowerBound
                let upper = min(segment.range.upperBound, range.upperBound) - segment.range.lowerBound
                covered.append((index, lower..<upper))
            }
            index += 1
        }
        return covered
    }

    /// Walks a run's pieces forward, turning ascending run-local UTF-16 offsets
    /// into raw byte indexes without rescanning from the start for each one.
    private struct PieceCursor {
        let run: WordEditableText.Run
        let xml: [UInt8]
        private var piece = 0
        private var pieceStart = 0      // UTF-16 offset where `piece` begins
        private var utf16 = 0
        private var byte: Int

        init(run: WordEditableText.Run, xml: [UInt8]) {
            self.run = run
            self.xml = xml
            byte = run.visible.lowerBound
        }

        /// The byte index of `target`, or nil if it falls inside a character.
        mutating func byteIndex(at target: Int) -> Int? {
            while piece < run.pieces.count {
                if target == utf16 { return byte }
                let current = run.pieces[piece]
                let pieceEnd = pieceStart + current.utf16Count
                if target < pieceEnd {
                    guard current.isLiteral else { return nil }
                    while utf16 < target {
                        let lead = xml[byte]
                        let (length, units) = lead < 0x80 ? (1, 1) : lead < 0xE0 ? (2, 1) : lead < 0xF0 ? (3, 1) : (4, 2)
                        byte += length
                        utf16 += units
                    }
                    return utf16 == target ? byte : nil
                }
                piece += 1
                pieceStart = pieceEnd
                utf16 = pieceEnd
                byte = current.bytes.upperBound
            }
            return target == utf16 ? byte : nil
        }
    }

    /// Whether a run's text, after `cuts` (sorted, non-overlapping), starts or
    /// ends with whitespace Word would drop from a `<w:t>` without
    /// `xml:space="preserve"`. Only the edited text's first and last code units
    /// matter, so it's never materialized.
    private static func needsPreservedSpace(_ text: ArraySlice<UInt16>, after cuts: [Cut]) -> Bool {
        func isXMLWhitespace(_ unit: UInt16?) -> Bool { unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D }
        func first() -> UInt16? {
            var position = text.startIndex
            for cut in cuts {
                if position < text.startIndex + cut.range.lowerBound { return text[position] }
                if let unit = cut.text.utf16.first { return unit }
                position = text.startIndex + cut.range.upperBound
            }
            return position < text.endIndex ? text[position] : nil
        }
        func last() -> UInt16? {
            var position = text.endIndex
            for cut in cuts.reversed() {
                if text.startIndex + cut.range.upperBound < position { return text[position - 1] }
                if let unit = cut.text.utf16.last { return unit }
                position = text.startIndex + cut.range.lowerBound
            }
            return position > text.startIndex ? text[position - 1] : nil
        }
        return isXMLWhitespace(first()) || isXMLWhitespace(last())
    }

    /// Marks a run's `<w:t>` as preserving whitespace. The edge whitespace it
    /// held without the attribute was invisible, so it's removed rather than
    /// suddenly shown.
    private static func preservingSpace(_ run: WordEditableText.Run) -> [Splice] {
        var splices: [Splice] = []
        if let value = run.spaceValue {
            splices.append(Splice(range: value, bytes: Array("preserve".utf8)))
        } else {
            let close = run.startTag.upperBound - 1     // the start tag's ">"
            splices.append(Splice(range: close..<close, bytes: Array(" xml:space=\"preserve\"".utf8)))
        }
        if run.content.lowerBound < run.visible.lowerBound {
            splices.append(Splice(range: run.content.lowerBound..<run.visible.lowerBound, bytes: []))
        }
        if run.visible.upperBound < run.content.upperBound {
            splices.append(Splice(range: run.visible.upperBound..<run.content.upperBound, bytes: []))
        }
        return splices
    }

    private static func apply(_ splices: [Splice], to xml: [UInt8]) throws -> [UInt8] {
        let sorted = splices.sorted { $0.range.lowerBound < $1.range.lowerBound }
        let tooLarge = ExporterError.serializationFailed("The edited \(documentPath) exceeds the reader-compatible \(maximumDocumentBytes)-byte limit")
        // Check the size before allocating; escaping a `>` below only adds bytes.
        let size = sorted.reduce(xml.count) { $0 + $1.bytes.count - $1.range.count }
        guard size <= maximumDocumentBytes else { throw tooLarge }
        var output: [UInt8] = []
        output.reserveCapacity(size)
        var position = 0
        for (index, splice) in sorted.enumerated() {
            guard splice.range.lowerBound >= position else { throw PicoDocsError.editsOverlap }
            output += xml[position..<splice.range.lowerBound]
            output += splice.bytes
            position = splice.range.upperBound
            let limit = index + 1 < sorted.count ? sorted[index + 1].range.lowerBound : xml.count
            if let terminator = completedTerminator(at: position, before: limit, in: xml, after: output) {
                output += xml[position..<terminator]
                output += Array("&gt;".utf8)
                position = terminator + 1
            }
        }
        output += xml[position...]
        guard output.count <= maximumDocumentBytes else { throw tooLarge }
        return output
    }

    /// A literal `>` in the raw bytes at `position` (or one byte later) that,
    /// after the `output` written so far, would complete `]]>` — a sequence XML
    /// forbids in character data. Inserted text never contains `>` (it's
    /// escaped), so any new `]]>` ends within two bytes of a splice.
    private static func completedTerminator(at position: Int, before limit: Int, in xml: [UInt8], after output: [UInt8]) -> Int? {
        let bracket = UInt8(ascii: "]")
        let angle = UInt8(ascii: ">")
        if position < limit, xml[position] == angle, output.suffix(2).elementsEqual([bracket, bracket]) {
            return position
        }
        if position + 1 < limit, xml[position] == bracket, xml[position + 1] == angle, output.last == bracket {
            return position + 1
        }
        return nil
    }

    // MARK: - Package

    /// Opens the package and rejects duplicate part names: the edit and the
    /// copy would otherwise disagree about which `document.xml` is the document.
    private static func open(_ data: Data) throws -> Archive {
        guard let archive = Archive(data: data, accessMode: .read) else { throw PicoDocsError.fileCorrupted }
        var paths = Set<String>()
        for entry in archive {
            try Task.checkCancellation()
            guard paths.insert(entry.path.lowercased()).inserted else { throw PicoDocsError.fileCorrupted }
        }
        return archive
    }

    private static func documentXML(in archive: Archive) throws -> [UInt8] {
        guard let data = try WordConverter.readEntry(archive, path: documentPath, maxBytes: maximumDocumentBytes) else {
            throw PicoDocsError.fileCorrupted
        }
        return [UInt8](data)
    }

    /// Rebuilds the package in its original entry order, with the edited
    /// `document.xml` and every other part's bytes copied unchanged.
    private static func rebuild(_ archive: Archive, documentXML: [UInt8]) throws -> Data {
        var writer = try OOXMLPackageWriter()
        var remaining = maximumPackageBytes
        for entry in archive {
            try Task.checkCancellation()
            switch entry.type {
            case .directory:
                continue    // implied by the part paths
            case .symlink:
                throw PicoDocsError.fileCorrupted
            case .file:
                if entry.path == documentPath {
                    try writer.addData(entry.path, Data(documentXML))
                    continue
                }
                guard let bytes = try ZIPEntryReader.read(archive, entry: entry, maxBytes: remaining),
                      UInt64(bytes.count) == entry.uncompressedSize,
                      bytes.crc32(checksum: 0) == entry.checksum else {
                    throw PicoDocsError.fileCorrupted
                }
                remaining -= bytes.count
                try writer.addData(entry.path, bytes)
            }
        }
        return try writer.data()
    }
}
