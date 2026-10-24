//
//  CorpusTests.swift
//  PicoDocsTests
//
//  Files from other projects' public test suites — Apache POI, Apache Tika,
//  numbers-parser, python-pptx, csv-spectrum and Mozilla Readability (sources
//  and licenses: Resources/Corpus/README.md). Each was converted and checked
//  against a reference extractor; these are the ones that exposed a crash, a
//  hang or lost/garbled content, plus representative complex files per format.
//

import Foundation
import Testing
@testable import PicoDocs

@Suite("Public test corpora")
struct CorpusTests {

    private static func convert(_ path: String) async throws -> ConverterResult {
        let url = try Fixture.corpusURL(path)
        return try await PicoDocsEngine.convert(data: Data(contentsOf: url), filename: url.lastPathComponent)
    }

    private static func markdown(_ path: String) async throws -> String {
        try await convert(path).markdown()
    }

    /// Lines holding only spaces/tabs — blank to Markdown, but noise in output.
    private static func whitespaceOnlyLines(_ markdown: String) -> Int {
        markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty && $0.allSatisfy { $0 == " " || $0 == "\t" } }.count
    }

    // MARK: - ZIP containers

    @Test("Fuzzed OOXML packages fail cleanly instead of trapping in ZIPFoundation", arguments: [
        "poi/clusterfuzz-testcase-minimized-POIXWPFFuzzer-4791943399604224.docx",
        "poi/clusterfuzz-testcase-minimized-POIXSLFFuzzer-5463285576892416.pptx",
        "poi/clusterfuzz-testcase-minimized-XLSX2CSVFuzzer-5025401116950528.xlsx",
    ])
    func fuzzedPackages(_ path: String) async throws {
        // Their central directories point past the end of the bytes, where
        // ZIPFoundation's in-memory reader computes a negative length and traps.
        let data = try Fixture.corpusData(path)
        #expect(!ZIPEntryReader.isSafelyTraversable(data))
        await #expect(throws: PicoDocsError.fileCorrupted) {
            _ = try await PicoDocsEngine.convert(data: data, filename: (path as NSString).lastPathComponent)
        }
    }

    @Test("A local-header offset past the end of the archive is rejected before ZIPFoundation reads it")
    func outOfRangeLocalHeaderOffset() async throws {
        var data = try Fixture.data("sample", "docx")
        #expect(ZIPEntryReader.isSafelyTraversable(data))
        // Point the first central-directory record's local header past the end.
        let end = try #require(data.range(of: Data([0x50, 0x4B, 0x05, 0x06]), options: .backwards)).lowerBound
        let directory = Int(data[end + 16]) | Int(data[end + 17]) << 8 | Int(data[end + 18]) << 16 | Int(data[end + 19]) << 24
        data.replaceSubrange((directory + 42)..<(directory + 46), with: [0xF0, 0xFF, 0xFF, 0x7F])
        #expect(!ZIPEntryReader.isSafelyTraversable(data))
        await #expect(throws: PicoDocsError.fileCorrupted) {
            _ = try await PicoDocsEngine.convert(data: data, filename: "sample.docx")
        }
    }

    // MARK: - DOCX

    @Test("DOCX ruby (furigana) keeps the base text, not the reading")
    func docxRuby() async throws {
        let md = try await Self.markdown("poi/61470.docx")
        #expect(md.contains("東京"))
        #expect(!md.contains("とうきょう"))
    }

    @Test("DOCX table rows wrapped in a content control are rendered")
    func docxRowContentControl() async throws {
        let md = try await Self.markdown("poi/Bug66263-table.docx")
        #expect(md.contains("| SDT Cell 1 | SDT Cell 2 |"))
    }

    @Test("DOCX table cells wrapped in content controls are rendered")
    func docxCellContentControls() async throws {
        let md = try await Self.markdown("poi/Bug54771b.docx")
        #expect(md.contains("| Test Subtitle |"))
        #expect(md.contains("| Test User |"))
        let dropdown = try await Self.markdown("poi/tika-3816.docx")
        #expect(dropdown.contains("| Choose an item. | Here is just a sample |"))
    }

    @Test("DOCX with 5,000 nested tables converts in linear time", .timeLimit(.minutes(1)))
    func docxDeeplyNestedTables() async throws {
        // Per-paragraph ancestor walks made this 17 KB file take ~100 s.
        let md = try await Self.markdown("poi/deep-table-cell.docx")
        #expect(md.contains("Nested level 0"))
        #expect(md.contains("Nested level 4999"))
    }

    // MARK: - XLSX

    @Test("XLSX rich-text shared strings render their text, not the string index")
    func xlsxRichTextSharedStrings() async throws {
        let md = try await Self.markdown("poi/56511.xlsx")
        #expect(md.contains("| dlgkdflgdfjkl | dlgkdflgdfjkl | dlgkdflgdfjkl | dlgkdflgdfjkl |"))
    }

    @Test("XLSX shared-string index with surrounding whitespace resolves")
    func xlsxPaddedSharedStringIndex() async throws {
        let md = try await Self.markdown("poi/bug69769.xlsx")
        #expect(md.contains("| 100 | Mustermann |"))
    }

    @Test("XLSX out-of-range shared-string indexes render empty instead of trapping")
    func xlsxOutOfRangeSharedString() async throws {
        // A pre-release Office 2007 file (`<sstItem>`): no table items decode.
        let result = try await Self.convert("poi/sample-beta.xlsx")
        #expect(result.sections.filter { $0.kind == .sheet }.count == 3)
        #expect(result.markdown().contains("|  | 4995 |"))
    }

    @Test("XLSX with an empty formatted row 1048576 (LibreOffice) sizes the grid by its values")
    func xlsxTrailingFormattedRow() async throws {
        let md = try await Self.markdown("poi/60384.xlsx")
        #expect(md.contains("| Bezeichnung | Wert | Standardwert |"))
        #expect(md.contains("| An very very long template text reaching over multiple columns |  |  |"))
        #expect(md.split(separator: "\n").count < 20)
    }

    // MARK: - RTF

    @Test("RTF `\\*` inside a group (not at its start) doesn't hide the group's text")
    func rtfMidGroupIgnorableMarker() async throws {
        let md = try await Self.markdown("tika/testRTFIgnoredControlWord.rtf")
        #expect(md.contains("The quick brown fox jumps over the lazy dog"))
    }

    @Test("RTF hex escapes decode with the font's charset, not only \\ansicpg", arguments: [
        ("tika/testFontAfterBufferedText.rtf", ["Уважаемый клиент!"]),                     // \fcharset204
        ("tika/testRTFWordPadCzechCharacters.rtf", ["Článek týdne", "Mrtvého moře"]),       // \fcharset238
        ("tika/testRTFJapanese.rtf", ["古書店で処刑記録見つかる", "ゾルゲの処刑記録"]),         // \fcharset128 (DBCS)
    ])
    func rtfFontCharsets(_ path: String, expected: [String]) async throws {
        let md = try await Self.markdown(path)
        for text in expected { #expect(md.contains(text)) }
    }

    // MARK: - PPTX

    @Test("PPTX tables with merged cells keep their grid")
    func pptxMergedCellTables() async throws {
        let md = try await Self.markdown("python-pptx/tbl-cell.pptx")
        #expect(md.contains("| having custom margins | vert anchor is inherited | vert anchor is top | vert anchor is bottom |"))
        #expect(md.contains("| unladen swallows |  |  |  |"))
        #expect(md.contains("| a | b | c |\n| --- | --- | --- |\n| d | e | f |\n| g | h | i |"))
    }

    // MARK: - Numbers

    @Test("Numbers tile rows with wide (4-byte unit) cell offsets match the reference CSV")
    func numbersWideOffsets() async throws {
        // format-1.numbers was written by numbers-parser from format-1.csv.
        let md = try await Self.markdown("numbers-parser/format-1.numbers")
        let unescaped = md.replacingOccurrences(of: #"\\([!-/:-@\[-`{-~])"#, with: "$1", options: .regularExpression)
        let csv = String(decoding: try Fixture.corpusData("numbers-parser/format-1.csv"), as: UTF8.self)
        let rows = CSVConverter.parseCSV(csv)
        #expect(rows.count == 9)
        for row in rows {
            #expect(unescaped.contains("| " + row.joined(separator: " | ") + " |"))
        }
    }

    // MARK: - CSV

    @Test("CSV parsing matches csv-spectrum's expected records", arguments: [
        "comma_in_quotes", "empty", "empty_crlf", "escaped_quotes", "json", "newlines",
        "newlines_crlf", "quotes_and_newlines", "simple", "simple_crlf", "utf8",
    ])
    func csvSpectrum(_ name: String) async throws {
        let text = String(decoding: try Fixture.corpusData("csv-spectrum/\(name).csv"), as: UTF8.self)
        let expected = try #require(try JSONSerialization.jsonObject(with: Fixture.corpusData("csv-spectrum/\(name).json")) as? [[String: String]])
        let rows = CSVConverter.parseCSV(text)
        let header = try #require(rows.first)
        let records = rows.dropFirst().map { Dictionary(uniqueKeysWithValues: zip(header, $0)) }
        #expect(records == expected)
        _ = try await Self.convert("csv-spectrum/\(name).csv")
    }

    @Test("CSV quote inside an unquoted field is literal")
    func csvBareQuote() async throws {
        let md = try await Self.markdown("csv-spectrum/location_coordinates.csv")
        #expect(md.contains(#"37.8"N 121"#))
        #expect(md.contains(#"17.9"W | Modesto | Stanislaus |"#))
    }

    // MARK: - EPUB / HTML

    @Test("EPUB spine chapters convert in order with headings and lists")
    func epubChapters() async throws {
        let md = try await Self.markdown("tika/testEPUB.epub")
        let one = try #require(md.range(of: "# Chapter 1"))
        let two = try #require(md.range(of: "# Chapter 2"))
        #expect(one.lowerBound < two.lowerBound)
        #expect(md.contains("This is the text for chapter One"))
        #expect(md.contains("- First item\n- Second item"))
        #expect(md.contains("## Subchapter 2.1"))
        #expect(Self.whitespaceOnlyLines(md) == 0)
    }

    @Test("HTML article keeps its sections without whitespace-only filler lines")
    func htmlReadabilityPage() async throws {
        let md = try await Self.markdown("readability/dev418.html")
        #expect(md.contains("# Readability Test"))
        #expect(md.contains(#"## Single \<figure\>"#))
        #expect(md.contains("Caption of the figure"))
        #expect(Self.whitespaceOnlyLines(md) == 0)
    }

    @Test("HTML image-only paragraphs and figures stay in the article, as in Readability's expected output")
    func htmlReadabilityMediaParagraphs() async throws {
        // <body> is the top candidate: Readability keeps all of its children and
        // only cleans them, rather than filtering them like a candidate's siblings.
        let md = try await Self.markdown("readability/dev418.html")
        #expect(md.components(separatedBy: "![An image](").count - 1 == 8)
        #expect(md.components(separatedBy: "Caption of the figure").count - 1 == 4)
    }

    @Test("HTML article inside an unlikely-looking panel is found by the retry that keeps unlikely nodes")
    func htmlReadabilityRetry() async throws {
        // The article sits in `panel-two-col-sidebar-right-mix` ("sidebar"), so
        // the first attempt finds only the footer; the retry finds the article.
        let md = try await Self.markdown("readability/aclu.html")
        #expect(md.contains("I don't use Facebook. I'm not technophobic"))
        #expect(md.contains("we also need to protect those of us who manage to opt out"))
        #expect(!md.contains("This is the website of the American Civil Liberties Union"))
    }

    @Test("HTML article split into one candidate per step resolves to their common ancestor")
    func htmlReadabilityCommonAncestor() async throws {
        let md = try await Self.markdown("readability/ehow-1.html")
        #expect(md.contains("Glass cloche terrariums are not only appealing"))
        #expect(md.contains("Displayed alone or in a group, these pretty arrangements"))
    }

    @Test("HTML article nested five levels deep, as an only child, keeps its opening")
    func htmlReadabilityDeepArticle() async throws {
        let md = try await Self.markdown("readability/quanta-1.html")
        #expect(md.contains("A little over half a century ago, chaos started spilling out of a famous experiment"))
        #expect(md.contains("But you’re not going to be counted that way"))
    }

    @Test("HTML MathJax equations keep their MathML text")
    func htmlReadabilityMathJax() async throws {
        // The containers' `CtxtMenu` classes contain "menu", which Readability
        // forgives for "MathJax"; the aria-hidden render tree is dropped.
        let md = try await Self.markdown("readability/mathjax.html")
        let start = try #require(md.range(of: "## The Lorenz Equations"))
        let end = try #require(md.range(of: "## The Cauchy-Schwarz Inequality"))
        let lorenz = md[start.upperBound..<end.lowerBound]
        #expect(["σ", "ρ", "β"].allSatisfy { lorenz.contains($0) })
        #expect(md.contains("is an example of an inline equation"))
    }

    @Test("HTML article outscores a video player's control labels")
    func htmlReadabilityVideoPlayerPage() async throws {
        let md = try await Self.markdown("readability/yahoo-2.html")
        #expect(md.contains("the Soyuz-FG rocket booster with the Progress MS-04 cargo ship"))
        #expect(md.contains("Marcia Dunn in Cape Canaveral"))
        #expect(!md.contains("Captions will look like this"))
        #expect(!md.contains("Style Options"))
    }

    @Test("HTML whitespace-only lines inside preformatted code are kept")
    func htmlPreformattedWhitespace() async throws {
        let html = "<html><body><p>Intro</p>\n  \n<pre>first\n   \nlast</pre>\n \n<p>Outro</p></body></html>"
        let md = try await PicoDocsEngine.convert(data: Data(html.utf8), filename: "pre.html", enhanceReadability: false).markdown()
        #expect(md.contains("```\nfirst\n   \nlast\n```"))
        #expect(Self.whitespaceOnlyLines(md) == 1)
    }
}
