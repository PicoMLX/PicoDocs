//
//  WordEditor.swift
//  PicoDocs
//
//  In-place, source-preserving editor for DOCX. It applies exact-match
//  find/replace edits by splicing the raw bytes of `word/document.xml` — only the
//  matched text runs change; the XML is never re-serialized, so unrelated markup
//  (styles, run properties, structure) is left exactly as authored. The package
//  is then rebuilt with every other part copied unchanged (uncompressed contents
//  byte-identical; the ZIP container itself is recompressed).
//
//  Fidelity guarantee (asserted by WordEditorTests):
//   1. Only `word/document.xml` changes; other parts' uncompressed bytes are identical.
//   2. Within document.xml, only the matched run text changes.
//  Editing text reflows layout — pagination can shift — which is inherent to any
//  text edit, not a defect.
//

import Foundation
import ZIPFoundation

public struct WordEditor: DocumentEditor {

    public init() {}

    public func accepts(_ info: StreamInfo) -> Bool {
        info.detectedFormat == .docx
    }

    public func editableText(_ data: Data, info: StreamInfo) async throws -> String {
        let xml = try Self.loadDocumentXML(data)
        return try DocxEditableText.extract(documentXML: xml).snapshot
    }

    public func applyEdits(_ edits: [TextEdit], to data: Data, info: StreamInfo) async throws -> EditResult {
        guard !edits.isEmpty else { return EditResult(data: data, applied: []) }

        let (archive, xml) = try Self.loadArchiveAndXML(data)
        let doc = try DocxEditableText.extract(documentXML: xml)

        var innerReplacements: [(range: Range<String.Index>, text: String)] = []
        // De-duplicate `xml:space="preserve"` additions by the opening tag they
        // target, so two edits touching runs that each need it don't collide.
        var preserveTags: [String.Index: Range<String.Index>] = [:]
        var applied: [AppliedEdit] = []

        for edit in edits {
            try Task.checkCancellation()
            let matches = try TextEditMatcher.resolve(edit, in: doc.snapshot)
            for match in matches {
                let (reps, preserve) = try doc.splice(match: match, replace: edit.replace)
                innerReplacements.append(contentsOf: reps)
                if let preserve { preserveTags[preserve.lowerBound] = preserve }
            }
            applied.append(AppliedEdit(find: edit.find, replace: edit.replace, occurrences: matches.count))
        }

        var all = innerReplacements
        for (_, tagRange) in preserveTags {
            all.append((tagRange, Self.tagWithPreserve(doc.documentXML[tagRange])))
        }

        let newXML = try Self.apply(all, to: doc.documentXML)
        let newData = try Self.rebuild(archive: archive, documentXML: newXML)
        return EditResult(data: newData, applied: applied)
    }

    // MARK: - Apply replacements

    /// Rebuilds `xml` with the given disjoint replacements applied. Replacements
    /// are sorted by position; any that overlap another signal two edits competing
    /// for the same text and throw `editsOverlap`.
    static func apply(_ replacements: [(range: Range<String.Index>, text: String)], to xml: String) throws -> String {
        let sorted = replacements.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var result = ""
        var cursor = xml.startIndex
        for replacement in sorted {
            guard replacement.range.lowerBound >= cursor else { throw PicoDocsError.editsOverlap }
            result += xml[cursor..<replacement.range.lowerBound]
            result += replacement.text
            cursor = replacement.range.upperBound
        }
        result += xml[cursor..<xml.endIndex]
        return result
    }

    /// Inserts `xml:space="preserve"` into a `<w:t …>` opening tag (no-op if present).
    static func tagWithPreserve(_ openTag: Substring) -> String {
        if openTag.contains("xml:space") { return String(openTag) }
        guard openTag.hasSuffix(">") else { return String(openTag) }
        return String(openTag.dropLast()) + " xml:space=\"preserve\">"
    }

    // MARK: - Package I/O

    static func loadDocumentXML(_ data: Data) throws -> String {
        try loadArchiveAndXML(data).1
    }

    static func loadArchiveAndXML(_ data: Data) throws -> (Archive, String) {
        guard let archive = Archive(data: data, accessMode: .read) else { throw PicoDocsError.fileCorrupted }
        guard let documentData = WordConverter.readEntry(archive, path: "word/document.xml"),
              let xml = WordConverter.decodeText(documentData) else {
            throw PicoDocsError.fileCorrupted
        }
        return (archive, xml)
    }

    /// Rebuilds the package, substituting the edited `word/document.xml` and copying
    /// every other part's bytes unchanged.
    static func rebuild(archive: Archive, documentXML newXML: String) throws -> Data {
        var writer = try OOXMLPackageWriter()
        var replaced = false
        for entry in archive {
            try Task.checkCancellation()
            guard entry.type == .file else { continue }     // dirs are implied by paths
            if entry.path == "word/document.xml" {
                try writer.addXML(entry.path, newXML)
                replaced = true
            } else {
                guard let bytes = WordConverter.readEntry(archive, path: entry.path) else {
                    throw PicoDocsError.fileCorrupted
                }
                try writer.addData(entry.path, bytes)
            }
        }
        guard replaced else { throw PicoDocsError.fileCorrupted }
        return try writer.data()
    }
}

// MARK: - Splicing

extension DocxEditableText {

    /// Computes the raw-byte replacements for one match: the full (escaped)
    /// replacement goes into the first covered run; the covered portion of any
    /// further covered runs is deleted. Rejects a match that touches non-editable
    /// text or joins runs across an unsafe boundary.
    ///
    /// Returns the inner-text replacements plus, when the first run needs it, the
    /// opening-tag range to gain `xml:space="preserve"`.
    func splice(match: Range<String.Index>, replace: String)
        throws -> (replacements: [(range: Range<String.Index>, text: String)], preserveOpenTag: Range<String.Index>?)
    {
        let covered = segments.filter { $0.range.lowerBound < match.upperBound && match.lowerBound < $0.range.upperBound }
        guard let firstRun = covered.first?.run else {
            // The only way `covered` is empty or starts non-editable.
            let nonEditable = covered.map { String(snapshot[$0.range]) }.joined()
            throw PicoDocsError.editCrossesBoundary(kind: Self.boundaryKind(nonEditable))
        }
        if let nonEditable = covered.first(where: { !$0.isEditable }) {
            throw PicoDocsError.editCrossesBoundary(kind: Self.boundaryKind(String(snapshot[nonEditable.range])))
        }
        for segment in covered.dropFirst() {
            guard let run = segment.run, run.safeJoinWithPrevious, run.paragraph == firstRun.paragraph else {
                throw PicoDocsError.editCrossesBoundary(kind: "inline object or paragraph")
            }
        }

        var replacements: [(range: Range<String.Index>, text: String)] = []
        var preserve: Range<String.Index>?
        let escaped = OOXMLPackageWriter.escape(replace)

        for (index, segment) in covered.enumerated() {
            guard let run = segment.run else { continue }
            let lower = Swift.max(segment.range.lowerBound, match.lowerBound)
            let upper = Swift.min(segment.range.upperBound, match.upperBound)
            let d0 = snapshot.utf16.distance(from: segment.range.lowerBound, to: lower)
            let d1 = snapshot.utf16.distance(from: segment.range.lowerBound, to: upper)
            let rawLow = run.rawIndex(atDecodedUTF16Offset: d0, in: documentXML)
            let rawHigh = run.rawIndex(atDecodedUTF16Offset: d1, in: documentXML)
            if index == 0 {
                replacements.append((rawLow..<rawHigh, escaped))
                if !run.hasXmlSpacePreserve, Self.needsPreserve(replace) {
                    preserve = run.openTagRange
                }
            } else {
                replacements.append((rawLow..<rawHigh, ""))
            }
        }
        return (replacements, preserve)
    }

    private static func boundaryKind(_ text: String) -> String {
        if text.contains(where: { $0 == "\n" }) { return "line or paragraph break" }
        if text.contains(where: { $0 == "\t" }) { return "tab" }
        return "hyperlink, field, or content control"
    }

    /// Word needs `xml:space="preserve"` to keep edge whitespace in a run.
    private static func needsPreserve(_ replace: String) -> Bool {
        guard let first = replace.first, let last = replace.last else { return false }
        return first.isWhitespace || last.isWhitespace
    }
}
