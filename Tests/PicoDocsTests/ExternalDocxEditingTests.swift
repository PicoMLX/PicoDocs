//
//  ExternalDocxEditingTests.swift
//  PicoDocsTests
//
//  The DOCX fidelity guarantee on files PicoDocs didn't write: lists.docx
//  (LibreOffice 24.2) and two files from Apple's Office Open XML writer (see
//  ExternalDocxFixtures). Each edit is checked against the exact expected
//  document.xml, every other part must keep its bytes, and the result must
//  still be well-formed XML that WordConverter can open.
//

import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

@Suite("Editing externally authored DOCX")
struct ExternalDocxEditingTests {

    // MARK: - Helpers

    private func entries(_ data: Data) throws -> [(path: String, data: Data)] {
        let archive = try #require(Archive(data: data, accessMode: .read))
        return try archive.map { entry in
            var contents = Data()
            _ = try archive.extract(entry) { contents.append($0) }
            return (entry.path, contents)
        }
    }

    private func documentXML(_ data: Data) throws -> String {
        let contents = try #require(try entries(data).first { $0.path == "word/document.xml" }?.data)
        return String(decoding: contents, as: UTF8.self)
    }

    /// `xml` with each `(old, new)` applied literally (no canonical
    /// equivalence, so `e` + U+0301 never matches a precomposed `é`), where
    /// every `old` must occur exactly `count` times — so the expectation can't
    /// silently match nothing.
    private func replacing(_ xml: String, _ replacements: [(old: String, new: String, count: Int)]) -> String {
        var result = xml
        for replacement in replacements {
            #expect(literalCount(of: replacement.old, in: result) == replacement.count, "\(replacement.old)")
            result = result.replacingOccurrences(of: replacement.old, with: replacement.new, options: .literal)
        }
        return result
    }

    private func literalCount(of needle: String, in haystack: String) -> Int {
        var count = 0
        var range = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, options: .literal, range: range) {
            count += 1
            range = found.upperBound..<haystack.endIndex
        }
        return count
    }

    /// Applies `edits` and checks the guarantee: the same entries in the same
    /// order, identical bytes outside document.xml, document.xml exactly as
    /// `expected` describes, well-formed, and readable by WordConverter.
    @discardableResult
    private func expectSurgicalEdit(_ input: Data, _ edits: [TextEdit], expected: (String) -> String) async throws -> EditResult {
        let result = try await PicoDocsEngine.applyEdits(edits, to: input, filename: "input.docx")
        let before = try entries(input)
        let after = try entries(result.data)
        #expect(after.map(\.path) == before.map(\.path))
        for (original, edited) in zip(before, after) where original.path != "word/document.xml" {
            #expect(edited.data == original.data, "\(original.path) changed")
        }
        let xml = try documentXML(result.data)
        #expect(xml == expected(try documentXML(input)))
        #expect(XMLParser(data: Data(xml.utf8)).parse())
        _ = try await PicoDocsEngine.convert(data: result.data, filename: "edited.docx")
        return result
    }

    // MARK: - LibreOffice

    @Test("LibreOffice: an edited list item changes only its text; numbering, styles and settings keep their bytes")
    func libreOfficeListItem() async throws {
        let result = try await expectSurgicalEdit(try Fixture.data("lists", "docx"), [TextEdit(find: "Second step", replace: "Second milestone")]) {
            replacing($0, [("<w:t>Second step</w:t>", "<w:t>Second milestone</w:t>", 1)])
        }
        let converted = try await PicoDocsEngine.convert(data: result.data, filename: "lists.docx")
        #expect(converted.markdown().contains("2.\tSecond milestone"))
    }

    @Test("LibreOffice: a run without xml:space gains it when the edit leaves trailing space")
    func libreOfficeWhitespace() async throws {
        try await expectSurgicalEdit(try Fixture.data("lists", "docx"), [TextEdit(find: "paragraph.", replace: "")]) {
            replacing($0, [("<w:t>An interlude paragraph.</w:t>", "<w:t xml:space=\"preserve\">An interlude </w:t>", 1)])
        }
    }

    // MARK: - Apple (textutil)

    @Test("Apple: the editable text of quirky writer output reads naturally")
    func appleSnapshots() async throws {
        let report = try await PicoDocsEngine.editableText(for: try ExternalDocxFixture.textutilReport(), filename: "report.docx")
        #expect(report == """
        Quarterly Report
        Revenue grew 12% to $4.2M in Q3, ahead of plan.
        Owner: Jane Doe
        Reviewer: Sam Lee
        Tom & Jerry <3 caf\u{E9} and cafe\u{301} na\u{EF}ve 日本語 😀 Ελληνικά
        The quick brown fox jumps over the lazy dog.
        \t•\tFirst item
        \t•\tSecond item
        Cell A
        Cell B
        DRAFT notes. DRAFT summary. DRAFT end.
        """)
        let tabs = try await PicoDocsEngine.editableText(for: try ExternalDocxFixture.textutilTabs(), filename: "tabs.docx")
        #expect(tabs == "Name:\tJane Doe\nRole:\tAnalyst\nTotal:\t$4.2M\tfinal\nCaf\u{E9} cr\u{E8}me br\u{FB}l\u{E9}e")
    }

    @Test("Apple: a batch across formatted runs, references and combining text splices exactly")
    func appleReportBatch() async throws {
        let result = try await expectSurgicalEdit(try ExternalDocxFixture.textutilReport(), [
            TextEdit(find: "quick brown", replace: "slow red"),
            TextEdit(find: "$4.2M", replace: "$4.8M"),
            TextEdit(find: "cafe\u{301}", replace: "tea"),
            TextEdit(find: "😀", replace: ":)"),
            TextEdit(find: "& Jerry <3", replace: "+ Jerry ♥"),
            TextEdit(find: "DRAFT", replace: "FINAL", replaceAll: true),
        ]) {
            replacing($0, [
                (">qu</w:t>", ">slow red</w:t>", 1),
                (">ick</w:t>", "></w:t>", 1),
                ("> brown fox jumps", "> fox jumps", 1),
                (">$4.2M</w:t>", ">$4.8M</w:t>", 1),
                ("cafe\u{301}", "tea", 1),
                ("😀", ":)", 1),
                ("&amp; Jerry &lt;3", "+ Jerry ♥", 1),
                ("DRAFT", "FINAL", 3),
            ])
        }
        #expect(result.applied == [1, 1, 1, 1, 1, 3])
    }

    @Test("Apple: line breaks, list tabs and table cells are boundaries", arguments: [
        ("Jane Doe\nReviewer", PicoDocsError.EditBoundary.lineBreak),
        ("•\tFirst", .tab),
        ("Cell A\nCell B", .paragraph),
    ])
    func appleReportBoundaries(find: String, kind: PicoDocsError.EditBoundary) async throws {
        let input = try ExternalDocxFixture.textutilReport()
        await #expect(throws: PicoDocsError.editCrossesBoundary(kind: kind)) {
            try await PicoDocsEngine.applyEdits([TextEdit(find: find, replace: "x")], to: input, filename: "report.docx")
        }
    }

    @Test("Apple: text between tabs edits in place, keeping its run's font and color")
    func appleTabs() async throws {
        let input = try ExternalDocxFixture.textutilTabs()
        try await expectSurgicalEdit(input, [
            TextEdit(find: "$4.2M", replace: "$4.8M"),
            TextEdit(find: "Analyst", replace: "Lead"),
            TextEdit(find: "crème", replace: "custard"),
        ]) {
            replacing($0, [
                ("<w:color w:val=\"C00000\"/></w:rPr><w:t xml:space=\"preserve\">$4.2M</w:t>",
                 "<w:color w:val=\"C00000\"/></w:rPr><w:t xml:space=\"preserve\">$4.8M</w:t>", 1),
                (">Analyst</w:t>", ">Lead</w:t>", 1),
                ("crème", "custard", 1),
            ])
        }
        await #expect(throws: PicoDocsError.editCrossesBoundary(kind: .tab)) {
            try await PicoDocsEngine.applyEdits([TextEdit(find: "Name:\tJane", replace: "x")], to: input, filename: "tabs.docx")
        }
    }

    @Test("Every line of every external fixture's editable text, quoted verbatim, is found")
    func externalParity() async throws {
        let fixtures = [try Fixture.data("lists", "docx"), try ExternalDocxFixture.textutilReport(), try ExternalDocxFixture.textutilTabs()]
        var applied = 0
        for data in fixtures {
            let text = try await PicoDocsEngine.editableText(for: data, filename: "fixture.docx")
            for line in text.components(separatedBy: "\n") where !line.isEmpty {
                do {
                    _ = try await PicoDocsEngine.applyEdits([TextEdit(find: line, replace: line + "!")], to: data, filename: "fixture.docx")
                    applied += 1
                } catch PicoDocsError.editCrossesBoundary, PicoDocsError.editTextAmbiguous {
                    // Found, but it spans fixed structure or repeats: the quote still matched.
                }
            }
        }
        #expect(applied >= 20)
    }
}
