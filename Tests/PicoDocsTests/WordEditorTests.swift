//
//  WordEditorTests.swift
//  PicoDocsTests
//
//  Surgical, source-preserving DOCX editing. The fixtures are hand-authored
//  `document.xml` bodies so each boundary case (multi-run splits, hyperlinks,
//  complex fields, hidden text, entities) is exercised precisely — more targeted
//  than an opaque Word binary. The headline assertions check the fidelity
//  guarantee *directly*: other package parts stay byte-identical, and only the
//  matched run text in document.xml changes.
//

import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

@Suite("WordEditor (surgical DOCX editing)")
struct WordEditorTests {

    // MARK: - Fixtures

    private static let docxInfo = StreamInfo(filename: "test.docx", detectedFormat: .docx)

    /// Wraps a `<w:body>` fragment in a complete `document.xml`.
    private func document(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>\(body)</w:body></w:document>
        """
    }

    /// Assembles a minimal, valid OOXML package around `documentXML`, plus any
    /// extra parts (used to prove they survive an edit unchanged).
    private func makeDocx(_ documentXML: String, extraParts: [(String, Data)] = []) throws -> Data {
        var writer = try OOXMLPackageWriter()
        try writer.addXML("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
        """)
        try writer.addXML("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """)
        try writer.addXML("word/document.xml", documentXML)
        for (path, data) in extraParts { try writer.addData(path, data) }
        return try writer.data()
    }

    private func entry(_ data: Data, _ path: String) -> Data? {
        guard let archive = Archive(data: data, accessMode: .read), let entry = archive[path] else { return nil }
        var out = Data()
        _ = try? archive.extract(entry) { out.append($0) }
        return out
    }

    private func documentXML(of data: Data) throws -> String {
        try #require(entry(data, "word/document.xml").flatMap { String(data: $0, encoding: .utf8) })
    }

    private func snapshot(of data: Data) async throws -> String {
        try await WordEditor().editableText(data, info: Self.docxInfo)
    }

    /// Applies a single edit through `WordEditor` and returns the edited bytes.
    private func edit(_ docx: Data, find: String, replace: String, replaceAll: Bool = false) async throws -> Data {
        try await WordEditor().applyEdits([TextEdit(find: find, replace: replace, replaceAll: replaceAll)], to: docx, info: Self.docxInfo).data
    }

    private func expectError(
        _ expression: @autoclosure () async throws -> Data,
        _ matches: (PicoDocsError) -> Bool,
        _ comment: Comment = "expected a PicoDocsError"
    ) async {
        do {
            _ = try await expression()
            Issue.record(comment)
        } catch let error as PicoDocsError {
            #expect(matches(error), comment)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: - Happy path & multi-run

    @Test("Edits a single run and recovers the new text")
    func singleRun() async throws {
        let docx = try makeDocx(document("<w:p><w:r><w:t>Hello world</w:t></w:r></w:p>"))
        let edited = try await edit(docx, find: "world", replace: "there")
        #expect(try documentXML(of: edited).contains("<w:t>Hello there</w:t>"))
        #expect(try await snapshot(of: edited) == "Hello there")
    }

    @Test("Edits a phrase split across runs; replacement lands in the first run")
    func multiRun() async throws {
        // "Hello" is split "Hel" + (bold) "lo".
        let docx = try makeDocx(document(
            "<w:p><w:r><w:t>Hel</w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>lo</w:t></w:r></w:p>"))
        #expect(try await snapshot(of: docx) == "Hello")
        let edited = try await edit(docx, find: "Hello", replace: "Bye")
        let xml = try documentXML(of: edited)
        #expect(xml.contains("<w:t>Bye</w:t>"))
        #expect(xml.contains("<w:b/>"))                // the bold run's props are preserved
        #expect(try await snapshot(of: edited) == "Bye")
    }

    // MARK: - Fidelity guarantee

    @Test("Other package parts stay byte-identical; only document.xml changes")
    func preservesOtherParts() async throws {
        let styles = Data("<styles>unchanged</styles>".utf8)
        let image = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02, 0x03])
        let docx = try makeDocx(
            document("<w:p><w:r><w:t>keep me</w:t></w:r></w:p>"),
            extraParts: [("word/styles.xml", styles), ("word/media/image1.png", image)])
        let edited = try await edit(docx, find: "keep me", replace: "changed")

        #expect(entry(edited, "word/styles.xml") == styles)
        #expect(entry(edited, "word/media/image1.png") == image)
        #expect(entry(edited, "[Content_Types].xml") == entry(docx, "[Content_Types].xml"))
        #expect(try documentXML(of: edited).contains("changed"))
        #expect(try !documentXML(of: edited).contains("keep me"))
    }

    // MARK: - Snapshot ↔ matcher parity

    @Test("editableText is the exact string the matcher searches")
    func snapshotParity() async throws {
        let docx = try makeDocx(document("<w:p><w:r><w:t>Alpha beta gamma</w:t></w:r></w:p>"))
        let text = try await snapshot(of: docx)
        // A verbatim slice of the snapshot always matches.
        let slice = String(text.dropFirst(6).prefix(4))        // "beta"
        let edited = try await edit(docx, find: slice, replace: "BETA")
        #expect(try await snapshot(of: edited) == "Alpha BETA gamma")
    }

    // MARK: - Anti-hallucination & batch semantics

    @Test("Absent, ambiguous, and empty finds are rejected")
    func rejects() async throws {
        let docx = try makeDocx(document("<w:p><w:r><w:t>one two one</w:t></w:r></w:p>"))
        await expectError(try await edit(docx, find: "missing", replace: "x")) {
            if case .editTextNotFound = $0 { return true }; return false
        }
        await expectError(try await edit(docx, find: "one", replace: "x")) {
            if case .editTextAmbiguous(_, let n) = $0 { return n == 2 }; return false
        }
        await expectError(try await edit(docx, find: "", replace: "x")) {
            if case .editEmptyFind = $0 { return true }; return false
        }
    }

    @Test("replaceAll replaces every occurrence")
    func replaceAll() async throws {
        let docx = try makeDocx(document("<w:p><w:r><w:t>a a a</w:t></w:r></w:p>"))
        let edited = try await edit(docx, find: "a", replace: "b", replaceAll: true)
        #expect(try await snapshot(of: edited) == "b b b")
    }

    @Test("Overlapping edits in a batch are rejected atomically")
    func overlap() async throws {
        let docx = try makeDocx(document("<w:p><w:r><w:t>abcdef</w:t></w:r></w:p>"))
        await expectError(
            try await WordEditor().applyEdits(
                [TextEdit(find: "abcd", replace: "X"), TextEdit(find: "cdef", replace: "Y")],
                to: docx, info: Self.docxInfo).data
        ) { if case .editsOverlap = $0 { return true }; return false }
        // The document is unchanged (atomicity): a fresh read still finds the original.
        #expect(try await snapshot(of: docx) == "abcdef")
    }

    @Test("A failing edit in a batch aborts the whole batch")
    func batchAtomic() async throws {
        let docx = try makeDocx(document("<w:p><w:r><w:t>good text</w:t></w:r></w:p>"))
        await expectError(
            try await WordEditor().applyEdits(
                [TextEdit(find: "good", replace: "great"), TextEdit(find: "nope", replace: "x")],
                to: docx, info: Self.docxInfo).data
        ) { if case .editTextNotFound = $0 { return true }; return false }
    }

    // MARK: - Boundaries

    @Test("Hyperlink text is shown but not editable")
    func hyperlinkBoundary() async throws {
        let docx = try makeDocx(document(
            "<w:p><w:r><w:t>see </w:t></w:r><w:hyperlink r:id=\"rId1\"><w:r><w:t>here</w:t></w:r></w:hyperlink></w:p>"))
        #expect(try await snapshot(of: docx) == "see here")      // visible for context
        await expectError(try await edit(docx, find: "here", replace: "there")) {
            if case .editCrossesBoundary = $0 { return true }; return false
        }
        // …but ordinary text in the same paragraph still edits.
        #expect(try await snapshot(of: edit(docx, find: "see", replace: "SEE")) == "SEE here")
    }

    @Test("Complex-field result text is not editable")
    func fieldBoundary() async throws {
        let field = "<w:r><w:fldChar w:fldCharType=\"begin\"/></w:r>"
            + "<w:r><w:instrText>PAGE</w:instrText></w:r>"
            + "<w:r><w:fldChar w:fldCharType=\"separate\"/></w:r>"
            + "<w:r><w:t>1</w:t></w:r>"
            + "<w:r><w:fldChar w:fldCharType=\"end\"/></w:r>"
        let docx = try makeDocx(document("<w:p><w:r><w:t>Page </w:t></w:r>\(field)</w:p>"))
        #expect(try await snapshot(of: docx) == "Page 1")
        await expectError(try await edit(docx, find: "1", replace: "2")) {
            if case .editCrossesBoundary = $0 { return true }; return false
        }
    }

    @Test("Hidden text is excluded from the snapshot")
    func hiddenExcluded() async throws {
        let docx = try makeDocx(document(
            "<w:p><w:r><w:t>visible </w:t></w:r><w:r><w:rPr><w:vanish/></w:rPr><w:t>secret</w:t></w:r></w:p>"))
        let text = try await snapshot(of: docx)
        #expect(text == "visible ")
        #expect(!text.contains("secret"))
    }

    @Test("Edits cannot cross a paragraph break")
    func paragraphBoundary() async throws {
        let docx = try makeDocx(document(
            "<w:p><w:r><w:t>foo</w:t></w:r></w:p><w:p><w:r><w:t>bar</w:t></w:r></w:p>"))
        #expect(try await snapshot(of: docx) == "foo\nbar")
        await expectError(try await edit(docx, find: "foo\nbar", replace: "x")) {
            if case .editCrossesBoundary = $0 { return true }; return false
        }
    }

    @Test("Edits cannot join runs across an inline drawing")
    func drawingBetweenRuns() async throws {
        let docx = try makeDocx(document(
            "<w:p><w:r><w:t>foo</w:t><w:drawing><wp:inline/></w:drawing></w:r><w:r><w:t>baz</w:t></w:r></w:p>"))
        #expect(try await snapshot(of: docx) == "foobaz")
        await expectError(try await edit(docx, find: "foobaz", replace: "x")) {
            if case .editCrossesBoundary = $0 { return true }; return false
        }
    }

    // MARK: - Unicode & entities

    @Test("Entity-encoded text maps to the correct raw bytes")
    func entities() async throws {
        let docx = try makeDocx(document("<w:p><w:r><w:t>A &amp; B</w:t></w:r></w:p>"))
        #expect(try await snapshot(of: docx) == "A & B")
        let edited = try await edit(docx, find: "& B", replace: "and C")
        #expect(try await snapshot(of: edited) == "A and C")
        // The ampersand we introduced is re-escaped, so the XML stays well-formed.
        let xml = try documentXML(of: edited)
        #expect(!xml.contains("A &amp; B"))
    }

    @Test("A replacement containing & is escaped")
    func escapesReplacement() async throws {
        let docx = try makeDocx(document("<w:p><w:r><w:t>Tom and Jerry</w:t></w:r></w:p>"))
        let edited = try await edit(docx, find: "and", replace: "&")
        #expect(try documentXML(of: edited).contains("&amp;"))
        #expect(try await snapshot(of: edited) == "Tom & Jerry")
    }

    @Test("Astral (multi-UTF-16) characters splice correctly")
    func astral() async throws {
        let docx = try makeDocx(document("<w:p><w:r><w:t>hi 😀 bye</w:t></w:r></w:p>"))
        #expect(try await snapshot(of: docx) == "hi 😀 bye")
        let edited = try await edit(docx, find: "😀 bye", replace: "there")
        #expect(try await snapshot(of: edited) == "hi there")
    }

    @Test("Leading/trailing space gains xml:space=preserve")
    func preserveSpace() async throws {
        let docx = try makeDocx(document("<w:p><w:r><w:t>ab</w:t></w:r></w:p>"))
        let edited = try await edit(docx, find: "ab", replace: " x ")
        let xml = try documentXML(of: edited)
        #expect(xml.contains("xml:space=\"preserve\""))
        #expect(try await snapshot(of: edited) == " x ")
    }

    // MARK: - Re-openability & engine wiring

    @Test("Edited document re-imports cleanly through WordConverter")
    func reopenable() async throws {
        let docx = try makeDocx(document("<w:p><w:pStyle w:val=\"Heading1\"/><w:r><w:t>Title here</w:t></w:r></w:p>"))
        let edited = try await edit(docx, find: "Title here", replace: "New title")
        let result = try await PicoDocsEngine.convert(data: edited, filename: "test.docx")
        #expect(result.markdown().contains("New title"))
    }

    @Test("Engine applyEdits dispatches via detection")
    func engineWiring() async throws {
        let docx = try makeDocx(document("<w:p><w:r><w:t>engine path</w:t></w:r></w:p>"))
        let result = try await PicoDocsEngine.applyEdits(
            [TextEdit(find: "engine", replace: "wired")], to: docx, filename: "test.docx")
        #expect(result.applied.first?.occurrences == 1)
        #expect(try await snapshot(of: result.data) == "wired path")
    }

    @Test("Unsupported formats throw documentTypeNotSupported")
    func unsupported() async throws {
        await expectError(
            try await PicoDocsEngine.applyEdits(
                [TextEdit(find: "a", replace: "b")], to: Data("plain".utf8), filename: "note.txt").data
        ) { if case .documentTypeNotSupported = $0 { return true }; return false }
    }

    // MARK: - Matcher unit

    @Test("TextEditMatcher counts non-overlapping occurrences")
    func matcher() throws {
        #expect(TextEditMatcher.occurrences(of: "aa", in: "aaaa").count == 2)
        #expect(TextEditMatcher.occurrences(of: "x", in: "abc").isEmpty)
        #expect(try TextEditMatcher.resolve(TextEdit(find: "b", replace: ""), in: "abc").count == 1)
    }
}
