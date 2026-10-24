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

    @Test("XLSX with macro, XML-map, metadata, revision and signature relationships converts", arguments: [
        ("poi/SimpleMacro.xlsm", ["Sheet1", "Sheet2", "Sheet3"], "| This is a macro workbook |"),        // vbaProject
        ("poi/CustomXMLMappings.xlsx", ["Foglio1", "Foglio2", "Foglio3"], "| jerhwkj | lkcnkln | msdnakjd |"), // xmlMaps
        ("poi/xlookup.xlsx", ["Sheet1", "Sheet2", "Sheet3"], "|  | 8389 | Dianne Pugh | Finance |"),     // sheetMetadata
        ("poi/workbookProtection_workbook_revision_protected.xlsx", ["Sheet1", "Sheet2", "Sheet3"], ""), // usernames
        ("poi/xlmmacro.xlsm", ["Sheet1", "Sheet2"], ""),                                                 // xlMacrosheet
        ("tika/testEXCEL_signed.xlsx", ["Sheet1"], "| test doc |"),                                      // digital signature
    ])
    func xlsxUnknownRelationshipTypes(_ path: String, sheets: [String], expected: String) async throws {
        // Unknown types are ignored, not fatal; the Excel 4.0 macro sheet
        // (`Macro1` in xlmmacro.xlsm) isn't a worksheet and is skipped.
        let result = try await Self.convert(path)
        #expect(result.sections.compactMap(\.sheetName) == sheets)
        if expected.isEmpty {
            // Their worksheets hold no cells.
            #expect(result.sections.allSatisfy(\.markdown.isEmpty))
        } else {
            #expect(result.markdown().contains(expected))
        }
    }

    @Test("Strict OOXML workbooks resolve their purl.oclc.org relationships")
    func xlsxStrict() async throws {
        let tika = try await Self.convert("tika/testEXCEL.strict.xlsx")
        #expect(tika.sections.compactMap(\.sheetName) == ["First Sheet", "Sheet Number 2", "Sheet3"])
        #expect(tika.markdown().contains("| 2nd row | 2nd row 2nd column |"))
        #expect(tika.markdown().contains("| cb=1 | cb=10 | cb=2 | cb=sum |\n| 1 | 10 | 2 | 13 |"))
        let poi = try await Self.markdown("poi/SimpleStrict.xlsx")
        #expect(poi.contains("| test |  | 1 |"))
        // Strict stores dates as ISO 8601 text rather than serial numbers.
        #expect(poi.contains("| 1990-01-01 |  |  |  |  |  |"))
    }

    @Test("XLSX package-absolute relationship targets resolve")
    func xlsxAbsoluteTargets() async throws {
        let md = try await Self.markdown("poi/xlsx-jdbc.xlsx")
        #expect(md.contains("| Column\\_1 | Column\\_2\\_Extended | Column\\_3 |"))
        #expect(md.contains("| A Very large string in column 1 AAAAAAAAAAAAAAAAAAAAA | foo | bar |"))
    }

    @Test("XLSX rows and cells without `r` take the next position")
    func xlsxCellsWithoutReferences() async throws {
        // Neither rows nor cells carry `r`, markup is `x:`-prefixed and targets
        // are absolute; the outline's nested rows start one column further in.
        let outline = try await Self.markdown("poi/59746_NoRowNums.xlsx")
        #expect(outline.contains("| Checked | Ion | Charge | Molecular Weight | m/z |"))
        #expect(outline.contains("\n|  | 1 | 644.24221 | 8.346 | 0.177 | 3 | 2 | 263061.998633582 | F1 |  |  |\n"))
        let rates = try await Self.convert("poi/56278.xlsx")
        #expect(rates.sections.count == 10)
        #expect(rates.markdown().contains("| Prime | 0.032500 |  |"))
    }

    @Test("XLSX rich inline strings keep every run")
    func xlsxRichInlineStrings() async throws {
        let emoji = try await Self.markdown("poi/InlineString.xlsx")
        #expect(emoji.contains("| 😜more text |"))
        let balance = try await Self.markdown("poi/52348.xlsx")
        #expect(balance.contains("|  |  | Category |  | Account | Balance |"))
        #expect(balance.contains("|  |  | Totals |  | - |  | - |  | - |  |  | 600.25 |"))
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

    @Test("HTML whitespace-only lines inside preformatted code are kept")
    func htmlPreformattedWhitespace() async throws {
        let html = "<html><body><p>Intro</p>\n  \n<pre>first\n   \nlast</pre>\n \n<p>Outro</p></body></html>"
        let md = try await PicoDocsEngine.convert(data: Data(html.utf8), filename: "pre.html", enhanceReadability: false).markdown()
        #expect(md.contains("```\nfirst\n   \nlast\n```"))
        #expect(Self.whitespaceOnlyLines(md) == 1)
    }
}
