//
//  WordEditorTests.swift
//  PicoDocsTests
//
//  The DOCX fidelity guarantee, asserted directly rather than through a
//  converter round trip: every part except word/document.xml keeps its exact
//  uncompressed bytes, and within document.xml only the matched run text
//  changes. Plus the edit contract as the editor enforces it: boundaries,
//  structure in replacements, replaceAll, Unicode and entity mapping.
//

import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

@Suite("WordEditor (surgical DOCX editing)")
struct WordEditorTests {

    // MARK: - Package helpers

    private static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
    <Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/>\
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
    <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>
    """

    private static let packageRelationships = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
    """

    private static let documentRelationships = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://example.com/" TargetMode="External"/></Relationships>
    """

    private static let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">  <w:style w:type="paragraph" w:styleId="Normal">\
    <w:name w:val="Normal"/><w:rPr><w:rFonts w:ascii="Avenir"/><w:color w:val="1F3864"/></w:rPr></w:style></w:styles>
    """

    private static let media = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + (0..<512).map { UInt8($0 % 251) })

    private func documentXML(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>\(body)\
        <w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr></w:body></w:document>
        """
    }

    /// A package whose parts use mixed compression, so preservation is checked
    /// on uncompressed contents rather than on container bytes.
    private func docx(_ body: String) throws -> Data {
        try package([
            ("[Content_Types].xml", Data(Self.contentTypes.utf8), .deflate),
            ("_rels/.rels", Data(Self.packageRelationships.utf8), .none),
            ("word/document.xml", Data(documentXML(body).utf8), .deflate),
            ("word/_rels/document.xml.rels", Data(Self.documentRelationships.utf8), .deflate),
            ("word/styles.xml", Data(Self.styles.utf8), .none),
            ("word/media/image1.png", Self.media, .none),
        ])
    }

    private func package(_ entries: [(String, Data, CompressionMethod)]) throws -> Data {
        let archive = try #require(Archive(data: Data(), accessMode: .create))
        for (path, data, method) in entries {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: method) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        return try #require(archive.data)
    }

    private func entries(_ data: Data) throws -> [(path: String, data: Data)] {
        let archive = try #require(Archive(data: data, accessMode: .read))
        return try archive.map { entry in
            var contents = Data()
            _ = try archive.extract(entry) { contents.append($0) }
            return (entry.path, contents)
        }
    }

    private func part(_ data: Data, _ path: String) throws -> String {
        let contents = try #require(try entries(data).first { $0.path == path }?.data)
        return String(decoding: contents, as: UTF8.self)
    }

    private func edit(_ body: String, _ edits: [TextEdit]) throws -> (input: Data, result: EditResult) {
        let input = try docx(body)
        return (input, try WordEditor().applyEdits(edits, to: input))
    }

    // MARK: - Fidelity

    @Test("Only the matched bytes of document.xml change; every other part is byte-identical")
    func preservation() throws {
        let body = """
        <w:p><w:pPr><w:pStyle w:val="Normal"/></w:pPr><w:r><w:rPr><w:color w:val="C00000"/><w:sz w:val="28"/></w:rPr>\
        <w:t xml:space="preserve">The quick brown fox </w:t></w:r><w:r><w:t>jumps.</w:t></w:r></w:p>
        """
        let (input, result) = try edit(body, [TextEdit(find: "quick", replace: "slow")])
        #expect(result.applied == [1])

        let before = try entries(input)
        let after = try entries(result.data)
        #expect(after.map(\.path) == before.map(\.path))
        for (original, edited) in zip(before, after) where original.path != WordEditor.documentPath {
            #expect(edited.data == original.data, "\(original.path) changed")
        }
        let expected = documentXML(body).replacingOccurrences(of: "The quick brown", with: "The slow brown")
        #expect(try part(result.data, WordEditor.documentPath) == expected)
    }

    @Test("A match across runs goes into the first run's formatting; later runs lose only the matched part")
    func multiRun() throws {
        let body = """
        <w:p><w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">The qu</w:t></w:r>\
        <w:r><w:rPr><w:i/></w:rPr><w:t>ick bro</w:t></w:r><w:r><w:t>wn fox</w:t></w:r></w:p>
        """
        let (_, result) = try edit(body, [TextEdit(find: "quick brown", replace: "slow red")])
        let expected = documentXML("""
        <w:p><w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">The slow red</w:t></w:r>\
        <w:r><w:rPr><w:i/></w:rPr><w:t></w:t></w:r><w:r><w:t xml:space="preserve"> fox</w:t></w:r></w:p>
        """)
        #expect(try part(result.data, WordEditor.documentPath) == expected)
        #expect(try WordEditor().editableText(result.data) == "The slow red fox")
    }

    @Test("Any line of the editable text, quoted verbatim, matches and is replaced")
    func snapshotParity() throws {
        let input = try docx("""
        <w:p><w:r><w:t>Tom &amp; Jerry &lt;3</w:t></w:r></w:p>\
        <w:p><w:r><w:t xml:space="preserve">na\u{EF}ve </w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>日本語</w:t></w:r></w:p>\
        <w:p><w:r><w:t xml:space="preserve">  spaced  </w:t></w:r></w:p>\
        <w:p><w:r><w:t>cafe</w:t></w:r><w:r><w:t>\u{301}</w:t></w:r><w:proofErr w:type="spellEnd"/><w:r><w:t xml:space="preserve"> crème</w:t></w:r></w:p>\
        <w:p><w:r><w:t>emoji &#x1F600; ref</w:t></w:r></w:p>
        """)
        let editor = WordEditor()
        let lines = try editor.editableText(input).components(separatedBy: "\n")
        #expect(lines.count == 5)
        for line in lines {
            let result = try editor.applyEdits([TextEdit(find: line, replace: line + "!")], to: input)
            #expect(try editor.editableText(result.data).components(separatedBy: "\n").contains(line + "!"))
        }
    }

    @Test("Edited bytes still open with WordConverter")
    func reopenable() async throws {
        let (_, result) = try edit("<w:p><w:r><w:t>Quarterly revenue was $4.2M.</w:t></w:r></w:p>",
                                   [TextEdit(find: "$4.2M", replace: "$4.8M")])
        let converted = try await PicoDocsEngine.convert(data: result.data, filename: "edited.docx")
        #expect(converted.markdown().contains("$4.8M"))
        #expect(!converted.markdown().contains("$4.2M"))
    }

    @Test("An empty batch returns the input untouched")
    func emptyBatch() throws {
        let input = try docx("<w:p><w:r><w:t>Unchanged</w:t></w:r></w:p>")
        #expect(try WordEditor().applyEdits([], to: input) == EditResult(data: input, applied: []))
    }

    // MARK: - Contract

    private static let boundaryBody = """
    <w:p><w:r><w:t xml:space="preserve">Intro </w:t></w:r><w:hyperlink r:id="rId5"><w:r><w:t>link</w:t></w:r></w:hyperlink>\
    <w:r><w:t xml:space="preserve"> after</w:t></w:r></w:p><w:p><w:r><w:t>Next</w:t></w:r></w:p>\
    <w:p><w:r><w:t xml:space="preserve">Page </w:t></w:r><w:r><w:fldChar w:fldCharType="begin"/></w:r>\
    <w:r><w:instrText>PAGE</w:instrText></w:r><w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>7</w:t></w:r>\
    <w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>\
    <w:p><w:r><w:t xml:space="preserve">Name: </w:t></w:r><w:sdt><w:sdtContent><w:r><w:t>Jane</w:t></w:r></w:sdtContent></w:sdt></w:p>\
    <w:p><w:r><w:t xml:space="preserve">Old </w:t></w:r><w:ins w:id="1" w:author="A"><w:r><w:t>inserted</w:t></w:r></w:ins></w:p>\
    <w:p><w:r><w:t>Keep</w:t></w:r><w:del w:id="2" w:author="A"><w:r><w:delText>gone</w:delText></w:r></w:del><w:r><w:t>this</w:t></w:r></w:p>\
    <w:p><w:r><w:t>See</w:t></w:r><w:r><w:rPr><w:vanish/></w:rPr><w:t>hidden</w:t></w:r><w:r><w:t>it</w:t></w:r></w:p>\
    <w:p><w:r><w:t>Tab</w:t><w:tab/><w:t>bed</w:t><w:br/><w:t>Broken</w:t></w:r></w:p>\
    <w:p><w:r><w:t>Pic</w:t></w:r><w:r><w:drawing><wp:inline/></w:drawing></w:r><w:r><w:t>ture</w:t></w:r></w:p>
    """

    @Test("A match touching structure is rejected with the boundary it hit", arguments: [
        ("Intro link", PicoDocsError.EditBoundary.hyperlink), ("link", .hyperlink),
        ("after\nNext", .paragraph), ("Page 7", .field), ("7", .field),
        ("Name: Jane", .contentControl), ("Old inserted", .trackedChange), ("Keepthis", .trackedChange),
        ("Seeit", .hiddenText), ("Tab\tbed", .tab), ("bed\nBroken", .lineBreak), ("Picture", .object),
    ])
    func boundaries(find: String, kind: PicoDocsError.EditBoundary) throws {
        let input = try docx(Self.boundaryBody)
        #expect(throws: PicoDocsError.editCrossesBoundary(kind: kind)) {
            try WordEditor().applyEdits([TextEdit(find: find, replace: "x")], to: input)
        }
    }

    @Test("Text right next to a boundary is still editable", arguments: ["Intro", "after", "Page", "Keep", "this", "See", "it", "Tab", "bed", "Pic", "ture"])
    func besideBoundaries(find: String) throws {
        let input = try docx(Self.boundaryBody)
        let result = try WordEditor().applyEdits([TextEdit(find: find, replace: "X")], to: input)
        #expect(result.applied == [1])
    }

    @Test("A replacement can't add a tab or line break")
    func structureInReplacement() throws {
        let input = try docx("<w:p><w:r><w:t>one two</w:t></w:r></w:p>")
        #expect(throws: PicoDocsError.editCrossesBoundary(kind: .tab)) {
            try WordEditor().applyEdits([TextEdit(find: "one", replace: "a\tb")], to: input)
        }
        #expect(throws: PicoDocsError.editCrossesBoundary(kind: .paragraph)) {
            try WordEditor().applyEdits([TextEdit(find: "one", replace: "a\nb")], to: input)
        }
        #expect(throws: PicoDocsError.editCrossesBoundary(kind: .paragraph)) {
            try WordEditor().applyEdits([TextEdit(find: "one", replace: "a\r")], to: input)
        }
    }

    @Test("The matcher's rules hold, and a failing edit anywhere in a batch fails the batch")
    func contractAndAtomicity() throws {
        let input = try docx("<w:p><w:r><w:t>alpha beta alpha</w:t></w:r></w:p>" + Self.boundaryBody)
        let editor = WordEditor()
        #expect(throws: PicoDocsError.editEmptyFind) { try editor.applyEdits([TextEdit(find: "", replace: "x")], to: input) }
        #expect(throws: PicoDocsError.editTextNotFound(find: "gamma")) { try editor.applyEdits([TextEdit(find: "gamma", replace: "x")], to: input) }
        #expect(throws: PicoDocsError.editTextAmbiguous(find: "alpha", occurrences: 2)) {
            try editor.applyEdits([TextEdit(find: "alpha", replace: "x")], to: input)
        }
        #expect(throws: PicoDocsError.editsOverlap) {
            try editor.applyEdits([TextEdit(find: "alpha beta", replace: "x"), TextEdit(find: "beta alpha", replace: "y")], to: input)
        }
        #expect(throws: PicoDocsError.editCrossesBoundary(kind: .hyperlink)) {
            try editor.applyEdits([TextEdit(find: "beta", replace: "B"), TextEdit(find: "Intro link", replace: "x")], to: input)
        }
    }

    @Test("replaceAll replaces every occurrence, and applied counts each edit")
    func replaceAll() throws {
        let (_, result) = try edit("""
        <w:p><w:r><w:t xml:space="preserve">DRAFT notes, DRAFT</w:t></w:r></w:p><w:p><w:r><w:t>DR</w:t></w:r><w:r><w:t>AFT plan</w:t></w:r></w:p>
        """, [TextEdit(find: "DRAFT", replace: "FINAL", replaceAll: true), TextEdit(find: "plan", replace: "roadmap")])
        #expect(result.applied == [3, 1])
        #expect(try WordEditor().editableText(result.data) == "FINAL notes, FINAL\nFINAL roadmap")
    }

    // MARK: - Unicode, entities and whitespace

    @Test("A combining sequence split across runs is spliced whole")
    func combiningAcrossRuns() throws {
        let (_, result) = try edit("<w:p><w:r><w:t>cafe</w:t></w:r><w:r><w:t xml:space=\"preserve\">\u{301} au lait</w:t></w:r></w:p>",
                                   [TextEdit(find: "cafe\u{301}", replace: "tea")])
        let expected = documentXML("<w:p><w:r><w:t>tea</w:t></w:r><w:r><w:t xml:space=\"preserve\"> au lait</w:t></w:r></w:p>")
        #expect(try part(result.data, WordEditor.documentPath) == expected)
    }

    @Test("References map to their exact raw bytes, and replacements are escaped")
    func entities() throws {
        let (_, result) = try edit("<w:p><w:r><w:t>Tom &amp; Jerry, &#x1F600; smile, a&lt;b</w:t></w:r></w:p>", [
            TextEdit(find: "& Jerry", replace: "& Spike"),
            TextEdit(find: "😀", replace: ":)"),
            TextEdit(find: "a<b", replace: "<b>]]>"),
        ])
        let expected = documentXML("<w:p><w:r><w:t>Tom &amp; Spike, :) smile, &lt;b&gt;]]&gt;</w:t></w:r></w:p>")
        #expect(try part(result.data, WordEditor.documentPath) == expected)
    }

    @Test("An edit that leaves edge whitespace marks the run xml:space=preserve", arguments: [
        ("<w:t>Hello world</w:t>", "world", "<w:t xml:space=\"preserve\">Hello </w:t>"),
        ("<w:t> Hello world </w:t>", "world", "<w:t xml:space=\"preserve\">Hello </w:t>"),
        ("<w:t xml:space=\"default\">Hi there</w:t>", "there", "<w:t xml:space=\"preserve\">Hi </w:t>"),
        ("<w:t> Hello world</w:t>", "Hello", "<w:t> X world</w:t>"),
    ])
    func preservedSpace(run: String, find: String, expected: String) throws {
        let replacement = find == "Hello" ? "X" : ""
        let (_, result) = try edit("<w:p><w:r>\(run)</w:r></w:p>", [TextEdit(find: find, replace: replacement)])
        #expect(try part(result.data, WordEditor.documentPath) == documentXML("<w:p><w:r>\(expected)</w:r></w:p>"))
    }

    // MARK: - Rejected packages

    @Test("Input that isn't a usable DOCX package is rejected")
    func rejectedPackages() throws {
        let editor = WordEditor()
        #expect(throws: PicoDocsError.fileCorrupted) { try editor.editableText(Data("not a zip".utf8)) }
        let noDocument = try package([("word/styles.xml", Data(Self.styles.utf8), .deflate)])
        #expect(throws: PicoDocsError.fileCorrupted) { try editor.editableText(noDocument) }
        let document = Data(documentXML("<w:p><w:r><w:t>a</w:t></w:r></w:p>").utf8)
        let duplicated = try package([("word/document.xml", document, .deflate), ("Word/Document.xml", document, .deflate)])
        #expect(throws: PicoDocsError.fileCorrupted) { try editor.applyEdits([TextEdit(find: "a", replace: "b")], to: duplicated) }
    }
}
