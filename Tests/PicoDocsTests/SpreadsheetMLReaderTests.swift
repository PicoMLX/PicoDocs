//
//  SpreadsheetMLReaderTests.swift
//  PicoDocsTests
//
//  The streaming SpreadsheetML reader behind `SpreadsheetConverter`: sheet and
//  part-name resolution, optional cell references, rich text, hostile input
//  and parse-time limits. Real-world files are in CorpusTests.
//

import Foundation
import Testing
@testable import PicoDocs

@Suite("SpreadsheetML reader")
struct SpreadsheetMLReaderTests {

    private static let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let transitional = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    private static let strict = "http://purl.oclc.org/ooxml/officeDocument/relationships/"

    private static func rels(_ items: [(id: String, type: String, target: String)]) -> String {
        #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
            + items.map { #"<Relationship Id="\#($0.id)" Type="\#($0.type)" Target="\#($0.target)"/>"# }.joined()
            + "</Relationships>"
    }

    private static func workbook(_ sheets: [(name: String, id: String)], relationships: String = SpreadsheetMLReaderTests.transitional) -> String {
        let namespace = relationships.dropLast()
        return #"<workbook xmlns="\#(main)" xmlns:r="\#(namespace)"><sheets>"#
            + sheets.enumerated().map { #"<sheet name="\#($1.name)" sheetId="\#($0 + 1)" r:id="\#($1.id)"/>"# }.joined()
            + "</sheets></workbook>"
    }

    private static func worksheet(_ sheetData: String) -> String {
        #"<worksheet xmlns="\#(main)"><sheetData>\#(sheetData)</sheetData></worksheet>"#
    }

    private static func inline(_ reference: String, _ text: String) -> String {
        #"<c r="\#(reference)" t="inlineStr"><is><t>\#(text)</t></is></c>"#
    }

    private static func zip(_ parts: [(String, String)]) -> Data {
        PagesConverterTests.makeZip(parts.map { (name: $0.0, data: Array($0.1.utf8)) })
    }

    /// One worksheet at `xl/worksheets/sheet1.xml`, plus any extra parts.
    private static func singleSheet(_ sheetData: String, sharedStrings: String? = nil) -> Data {
        var workbookRelationships = [("rId1", transitional + "worksheet", "worksheets/sheet1.xml")]
        var parts = [
            ("_rels/.rels", rels([("rId1", transitional + "officeDocument", "xl/workbook.xml")])),
            ("xl/workbook.xml", workbook([("Sheet1", "rId1")])),
            ("xl/worksheets/sheet1.xml", worksheet(sheetData)),
        ]
        if let sharedStrings {
            workbookRelationships.append(("rId2", transitional + "sharedStrings", "sharedStrings.xml"))
            parts.append(("xl/sharedStrings.xml", sharedStrings))
        }
        parts.append(("xl/_rels/workbook.xml.rels", rels(workbookRelationships)))
        return zip(parts)
    }

    private static func convert(_ data: Data) async throws -> ConverterResult {
        try await SpreadsheetConverter().convert(data, info: StreamInfo(filename: "test.xlsx", detectedFormat: .xlsx))
    }

    private static func rows(_ sheetData: String) throws -> [SpreadsheetRow] {
        try SpreadsheetMLPackage.worksheetRows(Data(worksheet(sheetData).utf8))
    }

    // MARK: - Workbook structure

    @Test("Worksheets follow the workbook's tab order; other sheet kinds and relationship types are skipped")
    func tabOrder() async throws {
        let data = Self.zip([
            ("_rels/.rels", Self.rels([("rId1", Self.transitional + "officeDocument", "xl/workbook.xml")])),
            ("xl/workbook.xml", Self.workbook([("First", "rId3"), ("Chart", "rId9"), ("Macro", "rId8"), ("Second", "rId1")])),
            // Excel writes relationships in no particular order.
            ("xl/_rels/workbook.xml.rels", Self.rels([
                ("rId1", Self.transitional + "worksheet", "worksheets/b.xml"),
                ("rId9", Self.transitional + "chartsheet", "chartsheets/sheet1.xml"),
                ("rId8", "http://schemas.microsoft.com/office/2006/relationships/xlMacrosheet", "macrosheets/sheet1.xml"),
                ("rId7", "http://schemas.microsoft.com/office/2006/relationships/vbaProject", "vbaProject.bin"),
                ("rId6", "urn:example:unknown", "unknown.xml"),
                ("rId3", Self.transitional + "worksheet", "worksheets/a.xml"),
            ])),
            ("xl/worksheets/a.xml", Self.worksheet(#"<row r="1">\#(Self.inline("A1", "a"))</row>"#)),
            ("xl/worksheets/b.xml", Self.worksheet(#"<row r="1">\#(Self.inline("A1", "b"))</row>"#)),
        ])
        let result = try await Self.convert(data)
        #expect(result.sections.compactMap(\.sheetName) == ["First", "Second"])
        #expect(result.sections.map(\.markdown) == ["## First\n\n| a |\n| --- |\n", "## Second\n\n| b |\n| --- |\n"])
    }

    @Test("Part names resolve across Strict types, absolute and relative targets, backslashes, case and percent-encoding")
    func lenientPartNames() async throws {
        let data = Self.zip([
            ("_rels/.rels", Self.rels([("rId1", Self.strict + "officeDocument", "/xl/workbook.xml")])),
            ("xl/workbook.xml", Self.workbook([("One", "rId1"), ("Two", "rId2"), ("Three", "rId3")], relationships: Self.strict)),
            ("xl/_rels/workbook.xml.rels", Self.rels([
                ("rId1", Self.strict + "worksheet", "/xl/worksheets/Sheet1.xml"),
                ("rId2", Self.strict + "worksheet", #"worksheets\two.xml"#),
                ("rId3", Self.strict + "worksheet", "../xl/./worksheets/sheet%203.xml"),
                ("rId4", Self.strict + "sharedStrings", "/xl/sharedStrings.xml"),
            ])),
            ("xl/worksheets/sheet1.xml", Self.worksheet(#"<row r="1"><c r="A1" t="s"><v>0</v></c></row>"#)),
            (#"xl\worksheets\two.xml"#, Self.worksheet(#"<row r="1">\#(Self.inline("A1", "two"))</row>"#)),
            ("xl/worksheets/sheet 3.xml", Self.worksheet(#"<row r="1">\#(Self.inline("A1", "three"))</row>"#)),
            ("xl/sharedStrings.xml", #"<sst xmlns="http://purl.oclc.org/ooxml/spreadsheetml/main"><si><t>one</t></si></sst>"#),
        ])
        let result = try await Self.convert(data)
        #expect(result.sections.map(\.markdown) == ["## One\n\n| one |\n| --- |\n", "## Two\n\n| two |\n| --- |\n", "## Three\n\n| three |\n| --- |\n"])
    }

    @Test("A package without its root relationship falls back to xl/workbook.xml")
    func missingRootRelationship() async throws {
        let data = Self.zip([
            ("xl/workbook.xml", Self.workbook([("Sheet1", "rId1")])),
            ("xl/_rels/workbook.xml.rels", Self.rels([("rId1", Self.transitional + "worksheet", "worksheets/sheet1.xml")])),
            ("xl/worksheets/sheet1.xml", Self.worksheet(#"<row r="1">\#(Self.inline("A1", "found"))</row>"#)),
        ])
        #expect(try await Self.convert(data).markdown().contains("| found |"))
    }

    @Test("A missing worksheet part, or two ZIP entries for one part, is corruption")
    func corruptPackages() async throws {
        let missing = Self.zip([
            ("_rels/.rels", Self.rels([("rId1", Self.transitional + "officeDocument", "xl/workbook.xml")])),
            ("xl/workbook.xml", Self.workbook([("Sheet1", "rId1")])),
            ("xl/_rels/workbook.xml.rels", Self.rels([("rId1", Self.transitional + "worksheet", "worksheets/sheet1.xml")])),
        ])
        await #expect(throws: PicoDocsError.fileCorrupted) { _ = try await Self.convert(missing) }

        let sheet = Self.worksheet(#"<row r="1">\#(Self.inline("A1", "x"))</row>"#)
        let duplicated = Self.zip([
            ("_rels/.rels", Self.rels([("rId1", Self.transitional + "officeDocument", "xl/workbook.xml")])),
            ("xl/workbook.xml", Self.workbook([("Sheet1", "rId1")])),
            ("xl/_rels/workbook.xml.rels", Self.rels([("rId1", Self.transitional + "worksheet", "worksheets/sheet1.xml")])),
            ("xl/worksheets/sheet1.xml", sheet),
            ("xl/worksheets/sheet1.xml", sheet),
        ])
        await #expect(throws: PicoDocsError.fileCorrupted) { _ = try await Self.convert(duplicated) }
    }

    // MARK: - Cells

    @Test("Rows and cells without `r` follow the previous one; a row takes its index from a referenced cell")
    func optionalReferences() throws {
        let rows = try Self.rows(
            #"<row><c><v>1</v></c><c r="C1"><v>2</v></c><c><v>3</v></c></row>"#   // A1, C1, D1
            + #"<row r="4"><c><v>4</v></c></row>"#                                 // A4
            + #"<row><c r="B6"><v>5</v></c><c><v>6</v></c></row>"#                 // B6, C6
            + #"<row><c s="1"/></row>"#                                            // A7, formatting only
        )
        #expect(rows.map(\.index) == [1, 4, 6, 7])
        #expect(rows.map { $0.cells.map(\.column) } == [[0, 2, 3], [0], [1, 2], [0]])
        #expect(rows[3].cells[0].content == .empty)
    }

    @Test("A cell naming another row, or a reference without a row, is corruption", arguments: [
        #"<row r="2"><c r="A3"><v>1</v></c></row>"#,
        #"<row r="1"><c r="B"><v>1</v></c></row>"#,
        #"<row r="x"><c><v>1</v></c></row>"#,
    ])
    func malformedReferences(_ sheetData: String) {
        #expect(throws: PicoDocsError.fileCorrupted) { _ = try Self.rows(sheetData) }
    }

    @Test("Prefixed markup reads by position; extension content isn't mistaken for cells")
    func prefixedMarkupAndExtensions() throws {
        let xml = #"<x:worksheet xmlns:x="\#(Self.main)" xmlns:e="urn:example:ext"><x:sheetData>"#
            + #"<x:row r="1"><x:c r="A1"><x:v>1</x:v><x:extLst><e:c r="B1"><e:v>9</e:v></e:c></x:extLst></x:c></x:row>"#
            + #"</x:sheetData><x:extLst><x:ext><e:row r="5"><e:c r="A5"><e:v>5</e:v></e:c></e:row></x:ext></x:extLst></x:worksheet>"#
        let rows = try SpreadsheetMLPackage.worksheetRows(Data(xml.utf8))
        #expect(rows == [SpreadsheetRow(index: 1, cells: [SpreadsheetCell(column: 0, content: .text("1"))])])
    }

    @Test("Rich shared and inline strings join their runs and drop phonetic guides; escapes and stray indexes resolve")
    func richText() async throws {
        let sharedStrings = #"<sst xmlns="\#(Self.main)">"#
            + "<si><t>plain</t></si>"
            + #"<si><r><rPr><b/></rPr><t>bo</t></r><r><t xml:space="preserve">ld</t></r></si>"#
            + #"<si><t>東京</t><rPh sb="0" eb="2"><t>トウキョウ</t></rPh></si>"#
            + "<si><t>_x0041_BC</t></si>"
            + "</sst>"
        let cells = #"<c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c>"#
            + #"<c r="D1" t="s"><v> 3 </v></c><c r="E1" t="s"><v>99</v></c>"#
            + #"<c r="F1" t="inlineStr"><is><r><t>in</t></r><r><rPr><i/></rPr><t>line</t></r><rPh><t>x</t></rPh></is></c>"#
            + #"<c r="G1" t="inlineStr"><is><t>_x0044_E</t></is></c>"#
        let result = try await Self.convert(Self.singleSheet(#"<row r="1">\#(cells)</row>"#, sharedStrings: sharedStrings))
        #expect(result.sections.first?.markdown.contains("| plain | bold | 東京 | ABC |  | inline | DE |") == true)
    }

    @Test("A damaged shared-string table keeps the items before the damage")
    func damagedSharedStrings() async throws {
        let sharedStrings = #"<sst xmlns="\#(Self.main)"><si><t>one</t></si><si><t>two</t></si><si><t>thr"#
        let cells = #"<c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c>"#
        let result = try await Self.convert(Self.singleSheet(#"<row r="1">\#(cells)</row>"#, sharedStrings: sharedStrings))
        #expect(result.markdown().contains("| one | two |  |"))
    }

    // MARK: - Hostile input and limits

    @Test("Document type declarations are rejected, whichever part and encoding carries them")
    func documentTypeDeclarations() async throws {
        let doctype = #"<?xml version="1.0"?><!-- c --><!DOCTYPE x [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;">]>"#
        let sheet = doctype + Self.worksheet(#"<row r="1"><c r="A1" t="inlineStr"><is><t>&b;</t></is></c></row>"#)
        #expect(throws: PicoDocsError.fileCorrupted) { _ = try SpreadsheetMLPackage.worksheetRows(Data(sheet.utf8)) }
        var utf16 = Data([0xFF, 0xFE])
        utf16.append(sheet.data(using: .utf16LittleEndian)!)
        #expect(throws: PicoDocsError.fileCorrupted) { _ = try SpreadsheetMLPackage.worksheetRows(utf16) }

        // Unlike other damage to the shared-string table, a DTD fails the workbook.
        let sharedStrings = doctype + #"<sst xmlns="\#(Self.main)"><si><t>&b;</t></si></sst>"#
        let data = Self.singleSheet(#"<row r="1"><c r="A1" t="s"><v>0</v></c></row>"#, sharedStrings: sharedStrings)
        await #expect(throws: PicoDocsError.fileCorrupted) { _ = try await Self.convert(data) }
    }

    @Test("Parse-time limits bound rows, cells, shared strings and part sizes")
    func parseTimeLimits() throws {
        var limits = SpreadsheetMLPackage.Limits()
        limits.rows = 2
        #expect(throws: PicoDocsError.parsingError) {
            _ = try SpreadsheetMLPackage.worksheetRows(Data(Self.worksheet("<row/><row/><row/>").utf8), limits: limits)
        }
        limits = SpreadsheetMLPackage.Limits()
        limits.cellsPerSheet = 3
        #expect(throws: PicoDocsError.parsingError) {
            _ = try SpreadsheetMLPackage.worksheetRows(Data(Self.worksheet("<row><c/><c/></row><row><c/><c/></row>").utf8), limits: limits)
        }

        let sharedStrings = #"<sst xmlns="\#(Self.main)"><si><t>a</t></si><si><t>b</t></si></sst>"#
        let data = Self.singleSheet(#"<row r="1"><c r="A1" t="s"><v>0</v></c></row>"#, sharedStrings: sharedStrings)
        limits = SpreadsheetMLPackage.Limits()
        limits.sharedStrings = 1
        let package = try SpreadsheetMLPackage(archive: #require(ZIPEntryReader.archive(data)), limits: limits)
        let workbook = try package.workbook()
        #expect(throws: PicoDocsError.parsingError) { _ = try package.sharedStrings(at: workbook.sharedStringsPath) }

        limits = SpreadsheetMLPackage.Limits()
        limits.partBytes = 64
        let small = try SpreadsheetMLPackage(archive: #require(ZIPEntryReader.archive(data)), limits: limits)
        #expect(throws: PicoDocsError.parsingError) { _ = try small.workbook() }
    }

    @Test("A cancelled task stops parsing a worksheet")
    func cancellation() async throws {
        let rows = (1...5_000).map { #"<row r="\#($0)"><c r="A\#($0)"><v>\#($0)</v></c></row>"# }.joined()
        let data = Data(Self.worksheet(rows).utf8)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SpreadsheetMLPackage.worksheetRows(data)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test("A 40,000-row worksheet over 10 MB converts in linear time", .timeLimit(.minutes(1)))
    func largeWorksheet() async throws {
        // ~13 MB of XML: past the 10 MB libxml2 accepts in one pushed chunk, and
        // about a minute through CoreXLSX's quadratic decoding.
        let columns = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J"]
        var sheetData = ""
        sheetData.reserveCapacity(14_000_000)
        for row in 1...40_000 {
            sheetData += #"<row r="\#(row)">"#
            for (index, column) in columns.enumerated() {
                sheetData += #"<c r="\#(column)\#(row)" t="n"><v>\#(row * 10 + index)</v></c>"#
            }
            sheetData += "</row>"
        }
        let xml = Self.worksheet(sheetData)
        #expect(xml.utf8.count > 10_000_000)
        let result = try await Self.convert(ConverterTests.xlsx(sheetXML: xml))
        let markdown = try #require(result.sections.first?.markdown)
        #expect(markdown.hasPrefix("## Sheet1\n\n| 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 19 |\n| --- |"))
        #expect(markdown.hasSuffix("| 400000 | 400001 | 400002 | 400003 | 400004 | 400005 | 400006 | 400007 | 400008 | 400009 |\n"))
        #expect(markdown.split(separator: "\n").count == 1 + 40_000 + 1)   // heading, rows, delimiter row
    }
}
