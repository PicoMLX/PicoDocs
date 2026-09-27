import Foundation
import Testing
import ZIPFoundation
import SwiftSoup
#if canImport(AppKit)
import AppKit
#endif
@testable import PicoDocs

struct ExporterFollowupTests {

    @Test func OfficePreflightChargesParenthesisIndexesAndFullTableCells() throws {
        let parentheses = ConverterResult(sections: [.init(markdown: String(repeating: "()", count: 600_000) + "[")])
        #expect(throws: ExporterError.self) { try OfficeDocumentBlocks.validateInput(parentheses) }
        let table = ConverterResult(sections: [.init(markdown: String(repeating: "|", count: 800_000))])
        #expect(throws: ExporterError.self) { try OfficeDocumentBlocks.validateInput(table) }
        let csv = ConverterResult(sections: [.init(kind: .sheet, markdown: "", metadata: ["csv": String(repeating: String(repeating: ",", count: 999) + "\n", count: 300)])])
        #expect(throws: ExporterError.self) { try OfficeDocumentBlocks.validateInput(csv) }
        try OfficeDocumentBlocks.validateInput(ConverterResult(sections: [.init(markdown: "Literal () and [x](a(b)c)\n\n| A | B |\n| --- | --- |\n| x | y |")]))
    }

    @Test func DOCXTableBudgetIncludesSynthesizedPadding() throws {
        // About 5 KB of source expands to a million cells when rows are padded.
        let ragged = String(repeating: "|", count: 1_001) + "\n" + String(repeating: "|x|\n", count: 1_000)
        #expect(throws: ExporterError.self) { try PicoDocsEngine.write(markdown: ragged, to: .docx) }
    }

    @Test func RTFFontFallbackNamesDoNotChangePrimaryClassification() {
        for (primary, alternate, label) in [("Arial", "Courier New", "Label"), ("Courier New", "Arial", "`Label`")] {
            let rtf = #"{\rtf1\deff0{\fonttbl{\f0 "# + primary + #"{\*\falt "# + alternate + #";};}}{\field{\*\fldinst HYPERLINK "https://example.test"}{\fldrslt \f0 Label}}}"#
            #expect(RTFConverter.markdown(fromRTF: rtf) == "[" + label + "](https://example.test)")
        }
    }

    @Test func RTFHyperlinkSwitchCasePreservesOperandCase() {
        for instruction in [#"HYPERLINK \\L "MixedCase""#, #"hyperlink \\O "Tooltip" \\t "_Blank" \\L "MixedCase""#] {
            let rtf = #"{\rtf1{\field{\*\fldinst "# + instruction + #"}{\fldrslt Label}}}"#
            #expect(RTFConverter.markdown(fromRTF: rtf) == "[Label](#MixedCase)")
        }
    }

    @Test func angleLinkDestinationsCannotCrossPhysicalLines() throws {
        for newline in ["\n", "\r", "\r\n"] {
            let source = "[x](<https://example.test/a" + newline + "b>)"
            #expect(!MarkdownInlineParser.parse(source).contains { if case .link = $0 { return true }; return false })
            let relationships = try xml(PicoDocsEngine.write(markdown: source, to: .docx), "word/_rels/document.xml.rels")
            #expect(!relationships.contains("/hyperlink"))
        }
        #expect(MarkdownInlineParser.parse("[x](<https://example.test/a b>)") == [.link(label: [.text("x")], destination: "https://example.test/a b")])
    }

    @Test func OfficePreflightCountsCRLFAsOnePhysicalLine() throws {
        for newline in ["\n", "\r", "\r\n"] {
            try OfficeDocumentBlocks.validateInput(ConverterResult(sections: [.init(markdown: String(repeating: "x" + newline, count: 250_000))]))
            try OfficeDocumentBlocks.validateInput(ConverterResult(sections: [.init(markdown: "```" + newline + String(repeating: newline, count: 250_000) + "```")]))
            let tooMany = ConverterResult(sections: [.init(markdown: "```" + newline + String(repeating: newline, count: 1_000_000) + "```")])
            #expect(throws: ExporterError.self) { try OfficeDocumentBlocks.validateInput(tooMany) }
        }
    }

    @Test func DOCXGeneratedLeadingEmphasisAlreadySurvivesRoundTrips() async throws {
        for source in ["**Bold**", "*Italic*", "***Both***", "first  \n**Bold**", "first  \n*Italic*", "- **Bold**", #"\* literal"#, ##"\# literal"##] {
            var result = ConverterResult(sections: [.init(markdown: source)])
            for _ in 0..<3 {
                result = try await PicoDocsEngine.convert(data: PicoDocsEngine.write(result, to: .docx), filename: "leading.docx")
                #expect(result.markdown() == source)
            }
        }
    }

    @Test func DenseIrrelevantBackslashesDoNotNeedAnEscapeIndex() {
        for follower in ["a", ".", "*"] {
            let source = String(repeating: "\\" + follower, count: 100_000) + "["
            let visible = String(repeating: follower == "a" ? "\\a" : follower, count: 100_000) + "["
            #expect(MarkdownInlineParser.parse(source) == [.text(visible)])
        }
        #expect(MarkdownInlineParser.parse(#"[x](a\)b)"#) == [.link(label: [.text("x")], destination: "a)b")])
        #expect(MarkdownInlineParser.parse(#"[x](<a\>b>)"#) == [.link(label: [.text("x")], destination: "a>b")])
        #expect(MarkdownInlineParser.parse(#"[x](a\\)"#) == [.link(label: [.text("x")], destination: #"a\"#)])
    }

    @Test func SpreadsheetMLEscapesDecodeIncrementallyWithUTF16Semantics() {
        let dense = SpreadsheetMLText.decode(String(repeating: "_x0000_", count: 100_000))
        #expect(dense.utf8.count == 100_000)
        #expect(dense.utf8.allSatisfy { $0 == 0 })
        for (encoded, expected) in [("_xD83D__xDE00_", "😀"), ("_xD800__x0041_", "�A"), ("_xDC00_", "�"), ("_xD800_", "�"), ("_x005F_x0041_", "_x0041_"), ("_x00e9_😀", "é😀"), ("_xZZZZ_ _x123", "_xZZZZ_ _x123")] {
            #expect(SpreadsheetMLText.decode(encoded) == expected)
        }
    }

    @Test func blankCodeLinesAreChargedBeforeOfficeParsing() throws {
        let input = ConverterResult(sections: [.init(markdown: "```\n" + String(repeating: "\n", count: 1_000_000) + "```")])
        #expect(throws: ExporterError.self) { try OfficeDocumentBlocks.validateInput(input) }
        try OfficeDocumentBlocks.validateInput(ConverterResult(sections: [.init(markdown: "```\nfirst\n\nlast\n```")]))
    }

    @Test func oversizedRTFFieldInstructionsKeepOnlyTheirLabel() {
        for count in [3, 30_000] {
            let rtf = #"{\rtf1{\field{\*\fldinst HYPERLINK "https://example.test" "# + String(repeating: #"\\z "#, count: count) + #"}{\fldrslt Label}}}"#
            let result = RTFConverter.markdown(fromRTF: rtf)
            #expect(result == (count == 3 ? "[Label](https://example.test)" : "Label"))
        }
    }

    @Test func worksheetNamesPreserveOrdinaryEdgeSpaces() async throws {
        let names = [" Data ", "Data", "   "]
        var result = ConverterResult(sections: names.map { .init(kind: .sheet, markdown: "", sheetName: $0, metadata: ["csv": "x"]) })
        for _ in 0..<3 {
            result = try await PicoDocsEngine.convert(data: PicoDocsEngine.write(result, to: .xlsx), filename: "names.xlsx")
            #expect(result.sections.map(\.sheetName) == [" Data ", "Data", "Sheet3"])
        }
    }

    @Test func RTFUnicodeFallbackIgnoresRawLineWrapping() {
        for wrapping in ["\r", "\n", "\r\n", "\n\r\n"] {
            let rtf = #"{\rtf1\ansi\uc1\u233"# + wrapping + #"\'e9}"#
            #expect(RTFConverter.markdown(fromRTF: rtf) == "é")
            let two = #"{\rtf1\ansi\uc2\u233"# + wrapping + #"\'e9"# + wrapping + "?}"
            #expect(RTFConverter.markdown(fromRTF: two) == "é")
        }
    }

    @Test func denseInlineSyntaxIsChargedBeforeOfficeParsing() throws {
        let input = ConverterResult(sections: [.init(markdown: String(repeating: "**x** ", count: 1_000_000))])
        #expect(throws: ExporterError.self) { try OfficeDocumentBlocks.validateInput(input) }
        let plain = ConverterResult(sections: [.init(markdown: String(repeating: "text ", count: 1_000_000))])
        try OfficeDocumentBlocks.validateInput(plain)
        for format in [ExportableFileType.docx, .pptx, .rtf, .xlsx] {
            #expect(throws: ExporterError.self) { try PicoDocsEngine.write(input, to: format) }
        }
    }

    @Test func repeatedImageResolutionHandlesInvalidAndUniqueCandidates() throws {
        let invalid = DocumentSection(kind: .image, markdown: "", sourcePath: "local/logo.png", metadata: ["base64": "invalid", "mimeType": "image/png"])
        let valid = DocumentSection(kind: .image, markdown: "", sourcePath: "local/logo.png", metadata: ["base64": "AQID", "mimeType": "image/png"])
        for includeValid in [false, true] {
            for source in ["local/logo.png", "logo.png"] {
                let markdown = String(repeating: "![Alt](" + source + ") ", count: 200)
                let result = ConverterResult(sections: [.init(markdown: markdown)] + Array(repeating: invalid, count: 1000) + (includeValid ? [valid] : []))
                let document = try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml")
                #expect(document.components(separatedBy: "<w:drawing>").count - 1 == (includeValid ? 200 : 0))
                if !includeValid { #expect(document.contains(">Alt</w:t>")) }
            }
        }
    }

    @Test func WordTablesShareGridAndTextBudgets() async throws {
        let tableXML = #"<w:tbl><w:tr><w:tc><w:tcPr><w:gridSpan w:val="3"/></w:tcPr><w:p><w:r><w:t>x</w:t></w:r></w:p></w:tc></w:tr></w:tbl>"#
        let table = try #require(SwiftSoup.parse(tableXML, "", SwiftSoup.Parser.xmlParser()).children().first())
        let budget = WordConverter.TableBudget(maximumCells: 5)
        #expect(!(try WordConverter.renderTable(table, relationships: [:], budget: budget)).isEmpty)
        #expect(throws: PicoDocsError.fileCorrupted) { try WordConverter.renderTable(table, relationships: [:], budget: budget) }
        let textBudget = WordConverter.TableBudget(maximumBytes: 16)
        try textBudget.reserveText("x")
        #expect(throws: PicoDocsError.fileCorrupted) { try textBudget.reserveText("x") }
        let row = #"<w:tr><w:tc><w:tcPr><w:gridSpan w:val="16384"/></w:tcPr><w:p/></w:tc></w:tr>"#
        let largeTable = "<w:tbl>" + String(repeating: row, count: 31) + "</w:tbl>"
        for second in [largeTable, "<w:p><w:r><w:txbxContent>" + largeTable + "</w:txbxContent></w:r></w:p>"] {
            let doc = "<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body>" + largeTable + second + "</w:body></w:document>"
            let data = PagesConverterTests.makeZip([("word/document.xml", Array(doc.utf8))])
            await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: data, filename: "tables.docx") }
        }
    }

    @Test func headingDiscoverySkipsTableProjection() throws {
        let input = #"<w:body><w:p><w:r><w:t>ordinary</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:tcPr><w:gridSpan w:val="1000000000"/></w:tcPr><w:p><w:r><w:t>ignored</w:t></w:r></w:p></w:tc></w:tr></w:tbl><w:sdt><w:sdtContent><w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Title</w:t></w:r></w:p></w:sdtContent></w:sdt></w:body>"#
        let body = try #require(SwiftSoup.parse(input, "", SwiftSoup.Parser.xmlParser()).getElementsByTag("w:body").first())
        var titles: [String] = []
        try WordConverter.collectHeadings(in: body, relationships: [:], numbering: nil) { _, title in titles.append(title) }
        #expect(titles == ["Title"])
        #expect(throws: PicoDocsError.fileCorrupted) { try WordConverter.renderBlocks(in: body, relationships: [:]) }
    }

    @Test func quotedRTFNetworkTargetsRemainLinks() {
        let rtf = #"{\rtf1{\field{\*\fldinst HYPERLINK "\\\\server\\share"}{\fldrslt Files}}}"#
        let markdown = RTFConverter.markdown(fromRTF: rtf)
        #expect(MarkdownInlineParser.parse(markdown) == [.link(label: [.text("Files")], destination: #"\\server\share"#)])
    }

    @Test func worksheetCellCoordinatesMustMatchTheirRow() async throws {
        let seed = try PicoDocsEngine.write(markdown: "x", to: .xlsx)
        for coordinate in ["A1", "A2", "A1048577"] {
            let archive = try #require(Archive(data: seed, accessMode: .read))
            var files: [(name: String, data: [UInt8])] = []
            for entry in archive {
                var bytes = Data(); _ = try archive.extract(entry) { bytes.append($0) }
                if entry.path == "xl/worksheets/sheet1.xml" { bytes = Data((#"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r=""# + coordinate + #"" t="inlineStr"><is><t>value</t></is></c></row></sheetData></worksheet>"#).utf8) }
                files.append((entry.path, Array(bytes)))
            }
            let data = PagesConverterTests.makeZip(files)
            if coordinate != "A1" { await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: data, filename: "mismatch.xlsx") } }
            else { #expect(try await PicoDocsEngine.convert(data: data, filename: "valid.xlsx").markdown().contains("value")) }
        }
    }

    @Test func externalImagesDoNotAliasLocalBasenames() throws {
        let image = DocumentSection(kind: .image, markdown: "", sourcePath: "local/logo.png", metadata: ["base64": "AQID", "mimeType": "image/png"])
        for source in ["https://example.test/assets/logo.png", "http://example.test/logo.png", "//example.test/logo.png", "data:image/png;base64,logo.png", "custom:logo.png", "logo.png", "folder/logo.png", #"C:\assets\logo.png"#] {
            let local = ["logo.png", "folder/logo.png", #"C:\assets\logo.png"#].contains(source)
            let escaped = source.replacingOccurrences(of: "\\", with: "\\\\")
            let data = try PicoDocsEngine.write(ConverterResult(sections: [.init(markdown: "![Remote](" + escaped + ")"), image]), to: .docx)
            let document = try xml(data, "word/document.xml")
            #expect(document.contains("<w:drawing>") == local)
            if !local { #expect(document.contains(">Remote</w:t>")) }
        }
        let exact = DocumentSection(kind: .image, markdown: "", sourcePath: "https://example.test/logo.png", metadata: ["base64": "AQID", "mimeType": "image/png"])
        #expect(try xml(PicoDocsEngine.write(ConverterResult(sections: [.init(markdown: "![Explicit](https://example.test/logo.png)"), exact]), to: .docx), "word/document.xml").contains("<w:drawing>"))
    }

    @Test func physicalWorksheetRowsShareTheWorkbookBudget() throws {
        var budget = SpreadsheetProjectionBudget(maximumBytes: 256)
        try budget.reservePhysicalRows(1)
        try budget.reservePhysicalRows(1)
        #expect(throws: PicoDocsError.parsingError) { try budget.reservePhysicalRows(1) }
        var defaultBudget = SpreadsheetProjectionBudget()
        #expect(throws: PicoDocsError.parsingError) { try defaultBudget.reservePhysicalRows(1_048_576) }
    }

    @Test func footnoteLookupHandlesDenseLiteralAndActualOpeners() {
        let literal = String(repeating: "[", count: 100_000) + "]"
        #expect(MarkdownInlineParser.parse(literal) == [.text(literal)])
        let missing = String(repeating: "[^", count: 20_000)
        #expect(MarkdownInlineParser.parse(missing) == [.text(missing)])
        #expect(MarkdownInlineParser.parse("[^one] [^two]") == [.footnoteReference("one"), .text(" "), .footnoteReference("two")])
        #expect(MarkdownInlineParser.parse(#"[^a\]b]"#) == [.footnoteReference(#"a\]b"#)])
        #expect(MarkdownInlineParser.parse("[^] [^x]").plainText == "[^] [^x]")
    }

    @Test func repeatedDOCXDrawingsStopBeforeMarkupExpansion() throws {
        var budget = WordprocessingMLExporter.DrawingBudget(maximumBytes: 1024 + 12 + 6)
        #expect(throws: ExporterError.self) { try budget.reserve(filename: "a", alt: "&&") }
        try budget.reserve(filename: "a", alt: "&")
        #expect(throws: ExporterError.self) { try budget.reserve(filename: "", alt: "") }
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        let image = DocumentSection(kind: .image, markdown: "", sourcePath: "one.png", metadata: ["base64": png, "mimeType": "image/png"])
        let input = ConverterResult(sections: [.init(markdown: String(repeating: "![x](one.png) ", count: 20_000)), image])
        try OfficeDocumentBlocks.validateInput(input)
        #expect(throws: ExporterError.self) { try PicoDocsEngine.write(input, to: .docx) }
        let small = ConverterResult(sections: [.init(markdown: "![a](one.png) ![b](one.png)"), image])
        let data = try PicoDocsEngine.write(small, to: .docx)
        let document = try xml(data, "word/document.xml")
        #expect(document.components(separatedBy: "<w:drawing>").count - 1 == 2)
        #expect(try xml(data, "word/_rels/document.xml.rels").components(separatedBy: "/image").count - 1 == 1)
    }

    @Test func invisibleLinkLabelsHaveVisibleFallbackAcrossExporters() async throws {
        for (source, expected) in [("[](https://example.test)", "https://example.test"), ("[ ](https://example.test)", "https://example.test"), ("[\t](https://example.test)", "https://example.test"), ("[]()", "Link")] {
            #expect(MarkdownInlineParser.parse(source).plainText == expected)
            let input = ConverterResult(sections: [.init(markdown: source)])
            #expect(try xml(PicoDocsEngine.write(input, to: .xlsx), "xl/worksheets/sheet1.xml").contains(">" + expected + "</"))
            #expect(try xml(PicoDocsEngine.write(input, to: .pptx), "ppt/slides/slide1.xml").contains(">" + expected + "</"))
            for format in [ExportableFileType.docx, .rtf] {
                let imported = try await PicoDocsEngine.convert(data: PicoDocsEngine.write(input, to: format), filename: "link." + format.rawValue)
                #expect(try DocumentRenderer.render(imported, to: .plaintext) == expected)
            }
        }
        #expect(MarkdownInlineParser.parse("[  meaningful  ](url)").plainText == "  meaningful  ")
    }

    @Test func RTFListHardBreaksStayAtTheContentColumn() async throws {
        for source in ["- first  \n  second", "100. first  \n     second", "100. Parent\n     - first  \n       second", "- Parent\n\n  first  \n  second"] {
            var result = ConverterResult(sections: [.init(markdown: source)])
            for _ in 0..<3 {
                result = try await PicoDocsEngine.convert(data: PicoDocsEngine.write(result, to: .rtf), filename: "list.rtf")
                let html = try DocumentRenderer.render(result, to: .html)
                #expect(try SwiftSoup.parse(html).select("li").array().contains { try $0.text().contains("second") })
                #expect(!html.contains("</ul>\n<p>second") && !html.contains("</ol>\n<p>second"))
                #expect(result.markdown().contains("first  \n"))
            }
        }
    }

    @Test func emptyWorksheetRowsStillValidateExcelCoordinates() async throws {
        let seed = try PicoDocsEngine.write(markdown: "x", to: .xlsx)
        for row in [1, 1_048_576, 1_048_577] {
            let archive = try #require(Archive(data: seed, accessMode: .read))
            var files: [(name: String, data: [UInt8])] = []
            for entry in archive {
                var bytes = Data(); _ = try archive.extract(entry) { bytes.append($0) }
                if entry.path == "xl/worksheets/sheet1.xml" { bytes = Data((#"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r=""# + String(row) + #""/></sheetData></worksheet>"#).utf8) }
                files.append((entry.path, Array(bytes)))
            }
            let data = PagesConverterTests.makeZip(files)
            if row > 1_048_576 { await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: data, filename: "empty.xlsx") } }
            else { #expect(try await PicoDocsEngine.convert(data: data, filename: "empty.xlsx").sections.count == 1) }
        }
    }

    @Test func identitylessImagesHaveVisibleFallbackAcrossExporters() async throws {
        for source in ["![]()", "![ ]()", "![](< >)"] {
            #expect(MarkdownInlineParser.parse(source).plainText == "Image")
            let input = ConverterResult(sections: [.init(markdown: source)])
            #expect(try xml(PicoDocsEngine.write(input, to: .xlsx), "xl/worksheets/sheet1.xml").contains(">Image</"))
            #expect(try xml(PicoDocsEngine.write(input, to: .pptx), "ppt/slides/slide1.xml").contains(">Image</"))
            for format in [ExportableFileType.docx, .rtf] {
                let imported = try await PicoDocsEngine.convert(data: PicoDocsEngine.write(input, to: format), filename: "image." + format.rawValue)
                #expect(try DocumentRenderer.render(imported, to: .plaintext) == "Image")
            }
        }
        #expect(MarkdownInline.image(alt: "", source: "\t\u{00A0}").plainText == "Image")
        #expect(MarkdownInline.image(alt: "caption", source: "").plainText == "caption")
    }

    @Test func DOCXListHardBreaksKeepContentColumnAcrossRoundTrips() async throws {
        for source in [
            "- first  \n  second",
            "100. first  \n     second",
            "100. Parent\n     - first  \n       second",
            "- Parent\n\n  first  \n  second",
            "100. Parent\n\n     first  \n     second",
            "- first  \n  1\\. literal marker"
        ] {
            var result = ConverterResult(sections: [.init(markdown: source)])
            for _ in 0..<3 {
                result = try await PicoDocsEngine.convert(data: PicoDocsEngine.write(result, to: .docx), filename: "list.docx")
                #expect(result.markdown() == source)
            }
        }
    }

    @Test func whitespaceAltImagesUseVisibleFallbackAcrossExporters() async throws {
        for alt in [" ", "\t", "\u{00A0}"] {
            let source = "![" + alt + "](folder/missing.png)"
            #expect(MarkdownInlineParser.parse(source).plainText == "missing.png")
            let input = ConverterResult(sections: [.init(markdown: source)])
            #expect(try xml(PicoDocsEngine.write(input, to: .xlsx), "xl/worksheets/sheet1.xml").contains("missing.png"))
            #expect(try xml(PicoDocsEngine.write(input, to: .pptx), "ppt/slides/slide1.xml").contains("missing.png"))
            for format in [ExportableFileType.docx, .rtf] {
                let imported = try await PicoDocsEngine.convert(data: PicoDocsEngine.write(input, to: format), filename: "image." + format.rawValue)
                #expect(try DocumentRenderer.render(imported, to: .plaintext) == "missing.png")
            }
        }
        #expect(MarkdownInline.image(alt: "  Meaningful alt  ", source: "folder/missing.png").plainText == "  Meaningful alt  ")
    }

    @Test func duplicateSpreadsheetCellsAreRejectedBeforeProjection() async throws {
        let seed = try PicoDocsEngine.write(markdown: "x", to: .xlsx)
        for duplicate in [true, false] {
            let archive = try #require(Archive(data: seed, accessMode: .read))
            var files: [(name: String, data: [UInt8])] = []
            let cells = duplicate ? #"<c r="A1"/><c r="A1"/>"# : #"<c r="A1"/><c r="B1"/>"#
            let sheet = #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1">"# + cells + #"</row><row r="2"><c r="A2" t="inlineStr"><is><t>value</t></is></c></row></sheetData></worksheet>"#
            for entry in archive {
                var bytes = Data(); _ = try archive.extract(entry) { bytes.append($0) }
                if entry.path == "xl/worksheets/sheet1.xml" { bytes = Data(sheet.utf8) }
                files.append((entry.path, Array(bytes)))
            }
            let data = PagesConverterTests.makeZip(files)
            if duplicate {
                await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: data, filename: "duplicates.xlsx") }
            } else {
                #expect(try await PicoDocsEngine.convert(data: data, filename: "valid.xlsx").markdown().contains("value"))
            }
        }
    }
    @Test func orderedListRestartsAreBoundedBeforeNumberingSerialization() throws {
        let tooMany = ConverterResult(sections: [.init(markdown: String(repeating: "1. item\n", count: 16_385))])
        try OfficeDocumentBlocks.validateInput(tooMany)
        #expect(throws: ExporterError.self) { try PicoDocsEngine.write(tooMany, to: .docx) }
        let ordinary = ConverterResult(sections: [.init(markdown: "1. First\n1. Restart\n2. Continue")])
        let numbering = try xml(PicoDocsEngine.write(ordinary, to: .docx), "word/numbering.xml")
        #expect(numbering.components(separatedBy: "<w:num w:numId=").count == 3)
    }

    @Test func XLSXPreservesControlCharactersBeforeXMLEscaping() async throws {
        for text in ["\0", "\u{000B}"] {
            if text == "\u{000B}" {
                #expect(throws: PicoDocsError.emptyDocument) { try PicoDocsEngine.write(markdown: text, to: .xlsx) }
            }
            var sections = [DocumentSection(kind: .table, markdown: "", metadata: ["csv": text]), DocumentSection(kind: .table, markdown: "", metadata: ["csv": "\"" + text + "\""])]
            if text == "\0" { sections.append(DocumentSection(markdown: text)) }
            for section in sections {
                let data = try PicoDocsEngine.write(ConverterResult(sections: [section]), to: .xlsx)
                let worksheet = try xml(data, "xl/worksheets/sheet1.xml")
                #expect(worksheet.contains(text == "\0" ? "_x0000_" : "_x000B_"))
                let imported = try await PicoDocsEngine.convert(data: data, filename: "controls.xlsx")
                let csv = try #require(imported.sections.first?.metadata["csv"])
                #expect(CSVConverter.parseCSV(csv).first?.first == text)
            }
        }
    }

    @Test func DOCXMediaDeclarationOverridesConflictingPathExtension() throws {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        let image = DocumentSection(kind: .image, markdown: "", sourcePath: "photo.jpg", metadata: ["base64": png, "mimeType": "image/png"])
        let result = ConverterResult(sections: [.init(markdown: "![Photo](photo.jpg)"), image])
        let data = try PicoDocsEngine.write(result, to: .docx)
        let archive = try #require(Archive(data: data, accessMode: .read))
        #expect(archive["word/media/photo.png"] != nil)
        #expect(archive["word/media/photo.jpg"] == nil)
        #expect(try xml(data, "[Content_Types].xml").contains("ContentType=\"image/png\""))
    }

    @Test func DOCXRelationshipStoreBoundsCountBytesAndFailedInsertions() throws {
        var countLimited = WordprocessingMLExporter.RelationshipStore(maximumCount: 2)
        try countLimited.add(id: "one", type: "hyperlink", target: "https://example.com/1", external: true)
        try countLimited.add(id: "two", type: "image", target: "media/image.png", external: false)
        let accepted = countLimited.xml
        #expect(throws: ExporterError.self) { try countLimited.add(id: "three", type: "styles", target: "styles.xml", external: false) }
        #expect(countLimited.count == 2); #expect(countLimited.xml == accepted)
        var bytesLimited = WordprocessingMLExporter.RelationshipStore(maximumBytes: 2048)
        try bytesLimited.add(id: "r1", type: "link", target: "a&b", external: true)
        #expect(bytesLimited.xml.contains("a&amp;b"))
        let beforeFailure = bytesLimited.xml
        #expect(throws: ExporterError.self) { try bytesLimited.add(id: "r2", type: "link", target: String(repeating: "&", count: 1024), external: true) }
        #expect(bytesLimited.count == 1); #expect(bytesLimited.xml == beforeFailure)
    }

    @Test func manyDistinctDOCXLinksStopInsideRelationshipConstruction() throws {
        let markdown = (0..<65_537).map { "[x](https://example.com/\($0))" }.joined(separator: " ")
        let result = ConverterResult(sections: [.init(markdown: markdown)])
        try OfficeDocumentBlocks.validateInput(result)
        #expect(throws: ExporterError.self) { try PicoDocsEngine.write(result, to: .docx) }
        let repeated = ConverterResult(sections: [.init(markdown: String(repeating: "[x](https://example.com) ", count: 1000))])
        let relationships = try xml(PicoDocsEngine.write(repeated, to: .docx), "word/_rels/document.xml.rels")
        #expect(relationships.components(separatedBy: "relationships/hyperlink").count == 2)
    }

    @Test func forbiddenImageIdentitiesHaveVisibleOfficeFallbacks() async throws {
        for identity in ["\0", "\u{000B}", "\u{FFFE}", " ", "\t", "\u{00A0}"] {
            for useTitle in [false, true] {
                let image = DocumentSection(title: useTitle ? identity : nil, kind: .image, markdown: "", sourcePath: useTitle ? nil : identity, metadata: ["base64": "AQID", "mimeType": "image/png"])
                let result = ConverterResult(sections: [image])
                for (format, path) in [(ExportableFileType.pptx, "ppt/slides/slide1.xml"), (.xlsx, "xl/worksheets/sheet1.xml")] {
                    let output = try xml(PicoDocsEngine.write(result, to: format), path)
                    #expect(output.contains("image-1.png"))
                    if ["\0", "\u{000B}", "\u{FFFE}"].contains(identity) { #expect(!output.contains(identity)) }
                }
                let imported = try await PicoDocsEngine.convert(data: PicoDocsEngine.write(result, to: .rtf), filename: "image.rtf")
                #expect(try DocumentRenderer.render(imported, to: .plaintext) == "image-1.png")
            }
        }
    }

    @Test func sparseSyntaxUsesSparseCharacterStorage() {
        let prefix = String(repeating: "a", count: 8 * 1024 * 1024 - 1)
        let source = prefix + "["
        let indexed = MarkdownInlineParser.IndexedText(source)
        #expect(indexed.checkpointCount == 32_768)
        #expect(indexed[0] == "a"); #expect(indexed[source.count - 1] == "[")
        #expect(MarkdownInlineParser.parse(source) == [.text(source)])
        let mixed = String(repeating: "café 👨‍👩‍👧‍👦 ", count: 1024)
        #expect(MarkdownInlineParser.parse(mixed + "[label](url)") == [.text(mixed), .link(label: [.text("label")], destination: "url")])
        #expect(MarkdownInlineParser.parse(mixed + "**bold**") == [.text(mixed), .strong([.text("bold")])])
    }

    @Test func emptyAltImagesStayVisibleInRTF() async throws {
        let input = ConverterResult(sections: [.init(markdown: "![](folder/missing.png)")])
        let result = try await PicoDocsEngine.convert(data: PicoDocsEngine.write(input, to: .rtf), filename: "image.rtf")
        #expect(try DocumentRenderer.render(result, to: .plaintext) == "missing.png")
    }
    @Test func completeCodeDelimiterRunsSurviveOfficeAndTextProjection() async throws {
        for (source, plain) in [("``a`b``", "a`b"), ("`` `x` ``", "`x`"), ("``a\nb``", "a b"), (#"`a\`"#, #"a\"#)] {
            let result = ConverterResult(sections: [.init(markdown: source)])
            #expect(try DocumentRenderer.render(result, to: .plaintext) == plain)
            #expect(try DocumentRenderer.render(result, to: .html).contains("<code>" + plain + "</code>"))
            for format in [ExportableFileType.docx, .rtf] {
                let imported = try await PicoDocsEngine.convert(data: PicoDocsEngine.write(result, to: format), filename: "code." + format.rawValue)
                #expect(try DocumentRenderer.render(imported, to: .plaintext) == plain)
            }
        }
    }

    @Test func docxRulesAndTableBreaksRoundTripWithoutLossOrPadding() async throws {
        for source in ["---", "Before\n\n---\n\nAfter", "| Header |\n| --- |\n| first<br>second |"] {
            var result = ConverterResult(sections: [.init(markdown: source)])
            for _ in 0..<3 {
                result = try await PicoDocsEngine.convert(data: PicoDocsEngine.write(result, to: .docx), filename: "round.docx")
                #expect(result.sections[0].markdown == source)
            }
            if source.contains("<br>") {
                let sheet = try xml(PicoDocsEngine.write(result, to: .xlsx), "xl/worksheets/sheet1.xml")
                #expect(sheet.contains("first\nsecond"))
                #expect(!sheet.contains("first  "))
            }
        }
    }

    @Test func textProjectionsKeepEmptyAltImagesAndLegacySheetNames() throws {
        let result = ConverterResult(sections: [.init(markdown: "![](folder/missing.png)")])
        #expect(try xml(PicoDocsEngine.write(result, to: .xlsx), "xl/worksheets/sheet1.xml").contains("missing.png"))
        #expect(try xml(PicoDocsEngine.write(result, to: .pptx), "ppt/slides/slide1.xml").contains("missing.png"))
        for preferred in [false, true] {
            let section = DocumentSection(title: "Old", kind: .sheet, markdown: "Value", sheetName: preferred ? "Primary" : nil, metadata: ["sheetName": "Legacy"])
            let workbook = try xml(PicoDocsEngine.write(ConverterResult(sections: [section]), to: .xlsx), "xl/workbook.xml")
            #expect(workbook.contains("name=\"" + (preferred ? "Primary" : "Legacy") + "\""))
        }
    }

    @Test func RTFFencesPreserveIntentionalTrailingCodeLines() async throws {
        for code in ["first", "first\n", "first\n\n"] {
            let source = "```\n" + code + "\n```"
            var result = ConverterResult(sections: [.init(markdown: source)])
            for _ in 0..<3 {
                result = try await PicoDocsEngine.convert(data: PicoDocsEngine.write(result, to: .rtf), filename: "round.rtf")
                #expect(result.sections[0].markdown == source)
            }
        }
    }

    @Test func docxTableSpansAreBoundedBeforeAllocating() throws {
        for span in ["1000000000", "999999999999999999999999", "0", "-1", "16385"] {
            let table = try SwiftSoup.parse("<w:tbl><w:tr><w:tc><w:tcPr><w:gridSpan w:val=\"\(span)\"/></w:tcPr><w:p><w:r><w:t>x</w:t></w:r></w:p></w:tc></w:tr></w:tbl>", "", SwiftSoup.Parser.xmlParser())
            #expect(throws: PicoDocsError.fileCorrupted) { try WordConverter.renderTable(table.children().first()!, relationships: [:]) }
        }
        let row = "<w:tr><w:tc><w:tcPr><w:gridSpan w:val=\"16384\"/></w:tcPr><w:p/></w:tc></w:tr>"
        let table = try SwiftSoup.parse("<w:tbl>" + String(repeating: row, count: 62) + "</w:tbl>", "", SwiftSoup.Parser.xmlParser())
        #expect(throws: PicoDocsError.fileCorrupted) { try WordConverter.renderTable(table.children().first()!, relationships: [:]) }
    }

    @Test func RTFBinaryLengthsCountLatin1BytesIncludingCRLF() async throws {
        for payload: [UInt8] in [[13, 10], [13, 10, 123, 92], [255, 13, 10, 125]] {
            var data = Data("{\\rtf1 Before{\\pict\\bin\(payload.count) ".utf8)
            data.append(contentsOf: payload)
            data.append(Data("}After}".utf8))
            let result = try await PicoDocsEngine.convert(data: data, filename: "binary.rtf")
            #expect(result.markdown() == "BeforeAfter")
        }
    }

    @Test func repeatedAmbiguousImageKeysKeepAltTextAndAllowExactMatches() throws {
        let bytes = Data(repeating: 1, count: 8 * 1024 * 1024).base64EncodedString()
        let carriers = ["a/logo.png", "b/logo.png"].map { DocumentSection(kind: .image, markdown: "", sourcePath: $0, metadata: ["base64": bytes, "mimeType": "image/png"]) }
        let ambiguous = (0..<32).map { "![Missing \($0)](unknown\($0)/logo.png)" }.joined(separator: " ")
        let result = ConverterResult(sections: [.init(markdown: ambiguous + " ![Exact](a/logo.png) ![Again](logo.png)")] + carriers)
        let data = try PicoDocsEngine.write(result, to: .docx)
        let archive = try #require(Archive(data: data, accessMode: .read))
        #expect(archive.filter { $0.path.hasPrefix("word/media/") }.count == 1)
        let document = try xml(data, "word/document.xml")
        #expect(document.contains("Missing 31")); #expect(document.contains("Again"))
    }

    @Test func escapeOnlyInlineParagraphAvoidsDenseDelimiterIndexes() {
        let input = String(repeating: #"\*"#, count: 4 * 1024 * 1024)
        #expect(MarkdownInlineParser.parse(input) == [.text(String(repeating: "*", count: 4 * 1024 * 1024))])
        #expect(MarkdownInlineParser.parse(#"\[literal\] \`code\`"#) == [.text("[literal] `code`")])
        #expect(MarkdownInlineParser.parse(#"\\*bold*"#) == [.text("\\"), .emphasis([.text("bold")])])
        #expect(MarkdownInlineParser.parse(#"\* literal **bold**"#) == [.text("* literal "), .strong([.text("bold")])])
    }

    @Test func effectiveWorksheetTitlesAreSanitizedBeforeProjection() throws {
        for legacy in [false, true] {
            for title in ["\0", "A\0B"] {
                let section = DocumentSection(kind: .sheet, markdown: "", sheetName: legacy ? nil : title, metadata: legacy ? ["sheetName": title] : [:])
                let result = ConverterResult(sections: [section])
                for (format, path) in [(ExportableFileType.docx, "word/document.xml"), (.pptx, "ppt/slides/slide1.xml")] {
                    if title == "\0" { #expect(throws: PicoDocsError.emptyDocument) { try PicoDocsEngine.write(result, to: format) } }
                    else { #expect(try xml(PicoDocsEngine.write(result, to: format), path).contains("AB")) }
                }
            }
        }
    }

    @Test func oversizedImageIdentitiesAreRejectedBeforeSynthesis() throws {
        let huge = String(repeating: "x", count: 5 * 1024 * 1024)
        for image in [DocumentSection(title: huge, kind: .image, markdown: "", sourcePath: "photo.png", metadata: ["base64": "AQID"]), DocumentSection(kind: .image, markdown: "", sourcePath: huge, metadata: ["base64": "AQID"])] {
            for format in [ExportableFileType.docx, .xlsx, .pptx, .rtf] {
                #expect(throws: ExporterError.self) { try PicoDocsEngine.write(ConverterResult(sections: [image]), to: format) }
            }
        }
    }


    @Test func effectiveWorksheetTitlesArePreflightedBeforeHeadingProjection() throws {
        let large = String(repeating: "&", count: 10 * 1024 * 1024)
        for section in [DocumentSection(kind: .sheet, markdown: "", sheetName: large), DocumentSection(kind: .sheet, markdown: "", metadata: ["sheetName": large])] {
            for format in [ExportableFileType.docx, .rtf, .pptx] {
                #expect(throws: ExporterError.self) { try PicoDocsEngine.write(ConverterResult(sections: [section]), to: format) }
            }
        }
        let section = DocumentSection(title: "Old", kind: .sheet, markdown: "", sheetName: "Effective & title")
        let word = try xml(PicoDocsEngine.write(ConverterResult(sections: [section]), to: .docx), "word/document.xml")
        #expect(word.contains("Effective &amp; title")); #expect(!word.contains(">Old<"))
    }

    @Test func largePlainInlineParagraphUsesOneTextNode() {
        let text = String(repeating: "plain words 123 ", count: 600_000)
        #expect(MarkdownInlineParser.parse(text) == [.text(text)])
        #expect(MarkdownInlineParser.parse("café 😀") == [.text("café 😀")])
        #expect(MarkdownInlineParser.parse("<br>", tableCell: true) == [.lineBreak(hard: true)])
        #expect(MarkdownInlineParser.parse("**bold**") == [.strong([.text("bold")])])
    }

    @Test func repeatedPPTXLinksReuseBoundedSlideRelationships() throws {
        let source = Array(repeating: "[x](https://example.test)", count: 10_000).joined(separator: " ")
        let data = try PicoDocsEngine.write(markdown: source, to: .pptx)
        let relationships = try xml(data, "ppt/slides/_rels/slide1.xml.rels")
        #expect(relationships.components(separatedBy: "/hyperlink").count - 1 == 1)
        let slide = try xml(data, "ppt/slides/slide1.xml")
        #expect(slide.components(separatedBy: "r:id=\"hyperlink1\"").count - 1 == 10_000)
        var budget = PPTXExporter.SlideRelationships(maximumBytes: 1300)
        let first = try budget.add(target: "a", jump: false)
        #expect(try budget.add(target: "a", jump: false) == first)
        #expect(throws: ExporterError.self) { try budget.add(target: String(repeating: "&", count: 1000), jump: false) }
    }

    @Test func PPTXHorizontalRulesHaveVisibleText() throws {
        for source in ["---", "Before\n\n---\n\nAfter"] {
            let slide = try xml(PicoDocsEngine.write(markdown: source, to: .pptx), "ppt/slides/slide1.xml")
            #expect(slide.contains(">---</a:t>"))
            if source != "---" { #expect(slide.contains("Before")); #expect(slide.contains("After")) }
        }
    }

    @Test func unresolvedEmptyAltDOCXImagesUseTheirBasename() async throws {
        for source in ["missing.png", "assets/missing.png"] {
            let data = try PicoDocsEngine.write(markdown: "![](" + source + ")", to: .docx)
            let result = try await PicoDocsEngine.convert(data: data, filename: "missing.docx")
            #expect(result.markdown() == "missing.png")
        }
    }

    #if canImport(AppKit)
    @Test func RTFHeadingsKeepOnlyExplicitSourceEmphasis() async throws {
        for source in ["# Heading", "# **Heading**", "## Plain **bold** tail"] {
            let data = try PicoDocsEngine.write(markdown: source, to: .rtf)
            let result = try await PicoDocsEngine.convert(data: data, filename: "heading.rtf")
            #expect(result.markdown() == source)
        }
    }
    #endif

    @Test func duplicateSpreadsheetRowsAreRejectedBeforeMerging() async throws {
        let seed = try PicoDocsEngine.write(markdown: "x", to: .xlsx)
        let archive = try #require(Archive(data: seed, accessMode: .read))
        var files: [(name: String, data: [UInt8])] = []
        for entry in archive {
            var bytes = Data(); _ = try archive.extract(entry) { bytes.append($0) }
            if entry.path == "xl/worksheets/sheet1.xml" {
                bytes = Data(#"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="XFD1" t="inlineStr"><is><t></t></is></c></row><row r="1"><c r="A1" t="inlineStr"><is><t></t></is></c></row></sheetData></worksheet>"#.utf8)
            }
            files.append((entry.path, Array(bytes)))
        }
        let data = PagesConverterTests.makeZip(files)
        await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: data, filename: "duplicates.xlsx") }
    }

    @Test func emptyDOCXCodeRunsDoNotGenerateBackticks() async throws {
        let empty = #"<w:p><w:r><w:rPr><w:rStyle w:val="PicoCode"/></w:rPr><w:t></w:t></w:r></w:p>"#
        for body in [empty, empty + "<w:p><w:r><w:t>Body</w:t></w:r></w:p>"] {
            let doc = "<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body>\(body)</w:body></w:document>"
            let data = PagesConverterTests.makeZip([("word/document.xml", Array(doc.utf8))])
            if body == empty {
                await #expect(throws: PicoDocsError.emptyDocument) { try await PicoDocsEngine.convert(data: data, filename: "empty-code.docx") }
            } else { #expect(try await PicoDocsEngine.convert(data: data, filename: "code.docx").markdown() == "Body") }
        }
    }

    @Test func independentWordListsDoNotReuseActiveMarkerWidths() throws {
        let numbering = #"<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="100"/><w:numFmt w:val="decimal"/></w:lvl><w:lvl w:ilvl="1"><w:numFmt w:val="bullet"/></w:lvl></w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num><w:num w:numId="2"><w:abstractNumId w:val="0"/></w:num></w:numbering>"#
        let data = PagesConverterTests.makeZip([("word/numbering.xml", Array(numbering.utf8))])
        let archive = try #require(Archive(data: data, accessMode: .read))
        func properties(_ id: Int, _ level: Int) throws -> Element {
            let doc = try SwiftSoup.parse("<w:numPr><w:ilvl w:val='\(level)'/><w:numId w:val='\(id)'/></w:numPr>", "", SwiftSoup.Parser.xmlParser())
            return try #require(doc.getElementsByTag("w:numPr").first())
        }
        for interrupted in [false, true] {
            let reader = WordListNumbering(archive: archive)
            #expect(reader.prefix(numPr: try properties(1, 0), style: nil) == "100. ")
            if interrupted { #expect(reader.prefix(numPr: nil, style: nil) == nil) }
            #expect(reader.prefix(numPr: try properties(2, 1), style: nil) == "  - ")
        }
    }

    @Test func exportedMixedListsRetainParentMarkerWidths() async throws {
        let source = "100. Parent\n     - Child\n       5. Grandchild\n\n          Continuation"
        let data = try PicoDocsEngine.write(markdown: source, to: .docx)
        let result = try await PicoDocsEngine.convert(data: data, filename: "mixed.docx")
        #expect(result.markdown() == source)
    }

    @Test func nativeOfficeListDepthHasAnExplicitBoundary() throws {
        for count in [9, 10] {
            let source = (0..<count).map { String(repeating: "  ", count: $0) + "- Level \($0)" }.joined(separator: "\n")
            for format in [ExportableFileType.docx, .pptx] {
                if count == 9 { #expect(!(try PicoDocsEngine.write(markdown: source, to: format)).isEmpty) }
                else { #expect(throws: ExporterError.self) { try PicoDocsEngine.write(markdown: source, to: format) } }
            }
        }
    }


    @Test func invalidExactImageDoesNotFallBackToOtherDirectory() throws {
        let images: [DocumentSection] = [
            .init(kind: .image, markdown: "", sourcePath: "a/logo.png", metadata: ["base64": "invalid", "mimeType": "image/png"]),
            .init(kind: .image, markdown: "", sourcePath: "b/logo.png", metadata: ["base64": "AQID", "mimeType": "image/png"])
        ]
        let exact = try PicoDocsEngine.write(ConverterResult(sections: [.init(markdown: "![Missing](a/logo.png)")] + images), to: .docx)
        let archive = try #require(Archive(data: exact, accessMode: .read))
        #expect(!archive.contains { $0.path.hasPrefix("word/media/") })
        #expect(try xml(exact, "word/document.xml").contains("Missing"))
        let bare = try PicoDocsEngine.write(ConverterResult(sections: [.init(markdown: "![Found](logo.png)")] + images), to: .docx)
        #expect(try #require(Archive(data: bare, accessMode: .read)).contains { $0.path.hasPrefix("word/media/") })
    }

    @Test func emptyImageTitleUsesFilenameInTextOnlyOfficeProjections() throws {
        let result = ConverterResult(sections: [.init(title: "", kind: .image, markdown: "", sourcePath: "photo.png", metadata: ["base64": "AQID", "mimeType": "image/png"])])
        for (format, path) in [(ExportableFileType.xlsx, "xl/worksheets/sheet1.xml"), (.pptx, "ppt/slides/slide1.xml")] {
            #expect(try xml(PicoDocsEngine.write(result, to: format), path).contains("photo.png"))
        }
    }

    @Test func XLSXPreservesHorizontalRuleRows() async throws {
        for source in ["---", "Before\n\n---\n\nAfter"] {
            let data = try PicoDocsEngine.write(markdown: source, to: .xlsx)
            let read = try await PicoDocsEngine.convert(data: data, filename: "rules.xlsx")
            let csv = try #require(read.sections.first?.metadata["csv"])
            #expect(CSVConverter.parseCSV(csv) == (source == "---" ? [["---"]] : [["Before"], ["---"], ["After"]]))
        }
    }

    @Test func emptySheetsHaveACumulativeCountLimit() throws {
        var budget = SpreadsheetProjectionBudget(maximumSheets: 2)
        try budget.reserveGrid(rows: 0, columns: 0, name: "A")
        try budget.reserveGrid(rows: 0, columns: 0, name: "B")
        #expect(throws: PicoDocsError.parsingError) { try budget.reserveGrid(rows: 0, columns: 0, name: "C") }
        let result = ConverterResult(sections: Array(repeating: .init(kind: .sheet, markdown: ""), count: 4097))
        #expect(throws: ExporterError.self) { try PicoDocsEngine.write(result, to: .xlsx) }
    }

    @Test func linkedDOCXCodePreservesLiteralBracketsAndBackslashes() async throws {
        for source in ["[`[x]`](https://example.test)", #"[before `[\x]` after](https://example.test)"#, #"[**`[x]`**](https://example.test)"#] {
            var result = ConverterResult(sections: [.init(markdown: source)])
            for _ in 0..<2 {
                result = try await PicoDocsEngine.convert(data: PicoDocsEngine.write(result, to: .docx), filename: "code.docx")
                #expect(result.markdown() == source)
            }
        }
    }

    @Test func OfficeMetadataIsBudgetedBeforeEscaping() throws {
        let large = String(repeating: "&", count: 10 * 1024 * 1024)
        for result in [ConverterResult(title: large, sections: [.init(markdown: "Body")]), ConverterResult(author: large, sections: [.init(markdown: "Body")])] {
            for format in [ExportableFileType.docx, .xlsx, .pptx, .rtf] {
                #expect(throws: ExporterError.self) { try PicoDocsEngine.write(result, to: format) }
            }
        }
        let small = ConverterResult(title: "A & B", author: "C < D", sections: [.init(markdown: "Body")])
        for format in [ExportableFileType.docx, .xlsx, .pptx] {
            let properties = try xml(PicoDocsEngine.write(small, to: format), "docProps/core.xml")
            #expect(properties.contains("A &amp; B")); #expect(properties.contains("C &lt; D"))
        }
    }

    @Test func manyPPTXSoftBreaksNormalizeWithoutRepeatedPrefixCopies() throws {
        let count = 100_000
        let source = Array(repeating: "x", count: count).joined(separator: "\n")
        let slide = try xml(PicoDocsEngine.write(markdown: source, to: .pptx), "ppt/slides/slide1.xml")
        #expect(slide.contains(Array(repeating: "x", count: count).joined(separator: " ")))
    }

    @Test func importedDenseEmptyGridsFitTheWriterStorageBudget() async throws {
        let seed = try PicoDocsEngine.write(markdown: "x", to: .xlsx)
        let archive = try #require(Archive(data: seed, accessMode: .read))
        var files: [String: Data] = [:]
        for entry in archive {
            var bytes = Data()
            _ = try archive.extract(entry) { bytes.append($0) }
            files[entry.path] = bytes
        }
        // One sparse coordinate still requires a 1,000 by 1,000 dense projection.
        files["xl/worksheets/sheet1.xml"] = Data(#"<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1000"><c r="ALL1000" t="inlineStr"><is><t></t></is></c></row></sheetData></worksheet>"#.utf8)
        let data = try PagesConverterTests.makeZip(files.map { (name: $0.key, data: Array($0.value)) })
        await #expect(throws: PicoDocsError.parsingError) { try await PicoDocsEngine.convert(data: data, filename: "dense.xlsx") }
    }


    @Test func generatedWordPartsEnforceReaderCompatibleLimits() throws {
        var package = try OOXMLPackageWriter()
        for (path, limit) in [("word/document.xml", 32 * 1024 * 1024), ("word/numbering.xml", 8 * 1024 * 1024), ("word/_rels/document.xml.rels", 32 * 1024 * 1024)] {
            #expect(throws: ExporterError.self) { try package.addXML(path, String(repeating: "x", count: limit + 1)) }
        }
        // Escaping must be measured after expansion, before the Data/ZIP copy.
        let expanded = OOXMLPackageWriter.escape(String(repeating: "&", count: 7 * 1024 * 1024))
        #expect(throws: ExporterError.self) { try package.addXML("word/document.xml", expanded) }
    }

    @Test func sparseMarkdownAndCSVAreRejectedBeforeOfficeProjection() throws {
        let table = ConverterResult(sections: [.init(markdown: String(repeating: "|\n", count: 1_000_000))])
        #expect(throws: ExporterError.self) { try PicoDocsEngine.write(table, to: .xlsx) }
        let csv = ConverterResult(sections: [.init(markdown: "", metadata: ["csv": String(repeating: "\n", count: 1_000_000)])])
        for format in [ExportableFileType.docx, .rtf, .pptx] {
            #expect(throws: ExporterError.self) { try PicoDocsEngine.write(csv, to: format) }
        }
    }

    @Test func ambiguousLargeCandidatesDoNotChargeEmittedMediaBudget() throws {
        let payload = Data(repeating: 1, count: 32 * 1024 * 1024).base64EncodedString()
        func image(_ path: String, bytes: String) -> DocumentSection { .init(kind: .image, markdown: "", sourcePath: path, metadata: ["base64": bytes, "mimeType": "image/png"]) }
        let result = ConverterResult(sections: [.init(markdown: "![Before](before.png) ![Ambiguous](logo.png) ![After](after.png)"), image("before.png", bytes: "AQID"), image("a/logo.png", bytes: payload), image("b/logo.png", bytes: payload), image("after.png", bytes: "BAUG")])
        let data = try PicoDocsEngine.write(result, to: .docx)
        let archive = try #require(Archive(data: data, accessMode: .read))
        #expect(archive.filter { $0.path.hasPrefix("word/media/") }.count == 2)
        #expect(try xml(data, "word/document.xml").contains("Ambiguous"))
    }

    @Test func emptyStructuresOnlyExportWhereTheyHaveARepresentation() throws {
        for kind in [SectionKind.slide, .sheet] {
            let result = ConverterResult(sections: [.init(kind: kind, markdown: "")])
            for format in [ExportableFileType.docx, .rtf] {
                #expect(throws: PicoDocsError.emptyDocument) { try PicoDocsEngine.write(result, to: format) }
            }
            #if canImport(AppKit)
            #expect(throws: PicoDocsError.emptyDocument) { try AttributedStringDOCXExporter().write(result, format: .docx) }
            #endif
        }
        let slide = try PicoDocsEngine.write(ConverterResult(sections: [.init(kind: .slide, markdown: "")]), to: .pptx)
        #expect(try xml(slide, "ppt/slides/slide1.xml").contains("p:sld"))
        let sheet = try PicoDocsEngine.write(ConverterResult(sections: [.init(kind: .sheet, markdown: "")]), to: .xlsx)
        #expect(try xml(sheet, "xl/worksheets/sheet1.xml").contains("worksheet"))
    }

    @Test func emptyPPTXLinksKeepFormattedLabelsWithoutRelationships() throws {
        let data = try PicoDocsEngine.write(markdown: "[**label**]()", to: .pptx)
        let slide = try xml(data, "ppt/slides/slide1.xml")
        #expect(slide.contains("label")); #expect(slide.contains(#"b="1""#)); #expect(!slide.contains("a:hlinkClick"))
        #expect(!(try xml(data, "ppt/slides/_rels/slide1.xml.rels")).contains("/hyperlink"))
    }

    @Test func spreadsheetBudgetCountsEncodedXMLExpansion() throws {
        for value in ["\0", "_x0000_", "\u{FFFE}", "&<>😀"] {
            #expect(SpreadsheetMLText.xmlEncodedByteCount(value) == OOXMLPackageWriter.escape(SpreadsheetMLText.encode(value)).utf8.count)
        }
        var exact = SpreadsheetProjectionBudget(maximumBytes: 7)
        try exact.reserveValue("\0")
        #expect(throws: PicoDocsError.parsingError) { try exact.reserveValue("\0") }
        var tooSmall = SpreadsheetProjectionBudget(maximumBytes: 6)
        #expect(throws: PicoDocsError.parsingError) { try tooSmall.reserveValue("\0") }
        let row = String(repeating: "\0", count: 32_767)
        let result = ConverterResult(sections: [.init(kind: .sheet, markdown: "", metadata: ["csv": Array(repeating: row, count: 390).joined(separator: "\n")])])
        #expect(throws: ExporterError.self) { try PicoDocsEngine.write(result, to: .xlsx) }
    }

    @Test func markerPreservedRTFQuotesDoNotGainSemanticEmphasis() async throws {
        for source in ["> Quote", "> *Explicit*"] {
            let result = try await PicoDocsEngine.convert(data: PicoDocsEngine.write(markdown: source, to: .rtf), filename: "quote.rtf")
            #expect(result.markdown() == source)
        }
    }

    @Test func numberedHeadingBookmarksUseVisibleHeadingSlugs() async throws {
        let ns = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main""#
        let number = #"<w:numPr><w:numId w:val="1"/></w:numPr>"#
        let document = "<w:document \(ns)><w:body><w:p><w:hyperlink w:anchor='Intro'><w:r><w:t>Forward</w:t></w:r></w:hyperlink></w:p><w:p><w:pPr><w:pStyle w:val='Heading1'/>\(number)</w:pPr><w:bookmarkStart w:id='1' w:name='Intro'/><w:r><w:t>Intro</w:t></w:r></w:p><w:p><w:pPr>\(number)</w:pPr><w:r><w:t>Item</w:t></w:r></w:p></w:body></w:document>"
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId='1'><w:lvl w:ilvl='0'><w:numFmt w:val='decimal'/></w:lvl></w:abstractNum><w:num w:numId='1'><w:abstractNumId w:val='1'/></w:num></w:numbering>"
        let input = PagesConverterTests.makeZip([("word/document.xml", Array(document.utf8)), ("word/numbering.xml", Array(numbering.utf8))])
        let result = try await PicoDocsEngine.convert(data: input, filename: "bookmarks.docx")
        #expect(result.markdown().contains("[Forward](#1-intro)")); #expect(result.markdown().contains("# 1. Intro")); #expect(result.markdown().contains("2. Item"))
        #expect(try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml").contains("<w:hyperlink w:anchor="))
    }

    @Test func forbiddenOnlyXMLContentDoesNotExportAsAnEmptyDocument() throws {
        for format in [ExportableFileType.docx, .pptx] {
            #expect(throws: PicoDocsError.emptyDocument) { try PicoDocsEngine.write(markdown: "\0", to: format) }
            #expect(throws: PicoDocsError.emptyDocument) { try PicoDocsEngine.write(ConverterResult(sections: [.init(markdown: "", metadata: ["csv": "\0"])]), to: format) }
        }
        let sheet = try PicoDocsEngine.write(ConverterResult(sections: [.init(kind: .sheet, markdown: "", metadata: ["csv": "\0"])]), to: .xlsx)
        #expect(try xml(sheet, "xl/worksheets/sheet1.xml").contains("_x0000_"))
    }

    @Test func repeatedDOCXLinkTargetsReuseOneRelationship() throws {
        let data = try PicoDocsEngine.write(markdown: String(repeating: "[x](https://example.com) ", count: 10_000), to: .docx)
        let relationships = try xml(data, "word/_rels/document.xml.rels")
        #expect(relationships.components(separatedBy: "/hyperlink").count - 1 == 1)
        #expect(try xml(data, "word/document.xml").components(separatedBy: "<w:hyperlink ").count - 1 == 10_000)
    }


    @Test func emptyCSVMetadataDoesNotHideOrdinaryBodyText() throws {
        let result = ConverterResult(sections: [.init(markdown: "Keep this body", metadata: ["csv": ""])])
        #expect(OfficeDocumentBlocks.parse(result) == [.paragraph("Keep this body")])
        #expect(try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml").contains("Keep this body"))
    }

    @Test func bodyCSVPayloadIsConsumedByEveryOfficeWriter() async throws {
        let source = ConverterResult(sections: [.init(kind: .body, markdown: "", metadata: ["csv": "UniqueValue,Second\nThird,Fourth"])])
        for format in [ExportableFileType.docx, .rtf, .pptx] {
            let data = try PicoDocsEngine.write(source, to: format)
            if format == .pptx { #expect(try xml(data, "ppt/slides/slide1.xml").contains("UniqueValue")) }
            else {
                let recovered = try await PicoDocsEngine.convert(data: data, filename: "payload." + (format == .docx ? "docx" : "rtf"))
                #expect(recovered.markdown().contains("UniqueValue")); #expect(recovered.markdown().contains("Fourth"))
            }
        }
    }

    @Test func DOCXExactImageAmbiguityUsesAltText() throws {
        let body = DocumentSection(markdown: "![Unresolved](media/a.png)")
        func carrier(_ bytes: String) -> DocumentSection { .init(kind: .image, markdown: "", sourcePath: "media/a.png", metadata: ["base64": bytes, "mimeType": "image/png"]) }
        let data = try PicoDocsEngine.write(ConverterResult(sections: [body, carrier("AQID"), carrier("BAUG")]), to: .docx)
        let document = try xml(data, "word/document.xml")
        #expect(document.contains("Unresolved")); #expect(!document.contains("<w:drawing>"))
        let unique = try PicoDocsEngine.write(ConverterResult(sections: [body, carrier("!"), carrier("AQID")]), to: .docx)
        #expect(try xml(unique, "word/document.xml").contains("<w:drawing>"))
    }

    @Test func ambiguousImageAliasesStopDecodingAtSecondValidMatch() throws {
        let base64 = Data(repeating: 1, count: 1024 * 1024).base64EncodedString()
        let carriers = (0..<65).map { DocumentSection(kind: .image, markdown: "", sourcePath: "dir\($0)/logo.png", metadata: ["base64": base64, "mimeType": "image/png"]) }
        let unique = DocumentSection(kind: .image, markdown: "", sourcePath: "unique.png", metadata: ["base64": "AQID", "mimeType": "image/png"])
        let result = ConverterResult(sections: [.init(markdown: "![Ambiguous](logo.png) ![Unique](unique.png)")] + carriers + [unique])
        let data = try PicoDocsEngine.write(result, to: .docx)
        #expect(try xml(data, "word/document.xml").contains("Ambiguous"))
        let archive = try #require(Archive(data: data, accessMode: .read))
        #expect(archive.filter { $0.path.hasPrefix("word/media/") }.count == 1)
    }

    @Test func CSVPreflightBudgetsRowsBeforeGridAllocation() throws {
        let csv = String(repeating: "\n", count: 1_000_000)
        var budget = SpreadsheetProjectionBudget()
        #expect(throws: ExporterError.self) { try XLSXExporter.preflightCSV(csv, name: "Empty", budget: &budget) }
        var small = SpreadsheetProjectionBudget(maximumBytes: 200)
        #expect(throws: ExporterError.self) { try XLSXExporter.preflightCSV("a\nb", name: "S", budget: &small) }
        var enough = SpreadsheetProjectionBudget(maximumBytes: 256)
        try XLSXExporter.preflightCSV("a\nb", name: "S", budget: &enough)
        #expect(CSVConverter.parseCSV("\"a\nb\",\"c\"\"d\"\r\n,\n") == [["a\nb", "c\"d"], ["", ""]])
    }

    @Test func numberedWordHeadingsAndNestedTableItemsKeepPrefixes() async throws {
        let ns = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main""#
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:numFmt w:val=\"decimal\"/></w:lvl><w:lvl w:ilvl=\"1\"><w:numFmt w:val=\"decimal\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        func p(_ text: String, level: Int = 0, heading: Bool = false) -> String {
            let style = heading ? "<w:pStyle w:val=\"Heading1\"/>" : ""
            return "<w:p><w:pPr>\(style)<w:numPr><w:numId w:val=\"1\"/><w:ilvl w:val=\"\(level)\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>"
        }
        for table in [false, true] {
            let content = table ? "<w:tbl><w:tr><w:tc>" + p("Parent") + p("Child", level: 1) + "</w:tc></w:tr></w:tbl>" : p("Intro", heading: true) + p("Item")
            let document = "<w:document \(ns)><w:body>\(content)</w:body></w:document>"
            let data = PagesConverterTests.makeZip([("word/document.xml", Array(document.utf8)), ("word/numbering.xml", Array(numbering.utf8))])
            let result = try await PicoDocsEngine.convert(data: data, filename: "numbered.docx")
            if table { #expect(result.markdown().contains("1. Parent<br>   1. Child")) }
            else { #expect(result.markdown().contains("# 1. Intro")); #expect(result.markdown().contains("2. Item")) }
        }
    }

    @Test func footnoteIdentifiersRemainStableAcrossRepeatedDOCXExports() async throws {
        for id in [#"a\]b"#, #"a\\b"#, #"a\\\]b"#] {
            let marker = "[^" + id + "]"
            var result = ConverterResult(sections: [.init(markdown: "Claim" + marker + "\n\n" + marker + ": Note")])
            for _ in 0..<4 {
                let data = try PicoDocsEngine.write(result, to: .docx)
                result = try await PicoDocsEngine.convert(data: data, filename: "notes.docx")
                #expect(result.markdown().contains("Claim" + marker))
                #expect(try DocumentRenderer.render(result, to: .plaintext) == "Claim[1]\n\n[1] Note")
            }
        }
    }

    @Test func emptyDOCXLinkDestinationsRemainPlainText() async throws {
        let data = try PicoDocsEngine.write(markdown: "[**label**]()", to: .docx)
        #expect(!(try xml(data, "word/_rels/document.xml.rels")).contains("/hyperlink"))
        #expect(!(try xml(data, "word/document.xml")).contains("<w:hyperlink"))
        let recovered = try await PicoDocsEngine.convert(data: data, filename: "empty-link.docx")
        #expect(recovered.markdown() == "**label**")
    }


    @Test func adjacentRTFFieldsWithTheSameTargetStaySeparate() throws {
        let first = #"{\field{\*\fldinst HYPERLINK "https://x"}{\fldrslt one}}"#
        let second = #"{\field{\*\fldinst HYPERLINK "https://x"}{\fldrslt two}}"#
        let mixed = #"{\field{\*\fldinst HYPERLINK "https://x"}{\fldrslt {\b bold} plain}}"#
        #expect(RTFConverter.markdown(fromRTF: "{\\rtf1 " + first + second + "}") == "[one](https://x)[two](https://x)")
        #expect(RTFConverter.markdown(fromRTF: "{\\rtf1 " + first + mixed + "}") == "[one](https://x)[**bold** plain](https://x)")
    }

    @Test func duplicateMediaNamesRetainUniqueSuffixesWithoutRestartingSearch() throws {
        let duplicate = (0..<10_000).map { DocumentSection(kind: .image, markdown: "", sourcePath: "dir\($0)/logo.png", metadata: ["base64": "AQID", "mimeType": "image/png"]) }
        let collision = DocumentSection(kind: .image, markdown: "", sourcePath: "explicit/logo-2.png", metadata: ["base64": "BAUG", "mimeType": "image/png"])
        let result = ConverterResult(sections: [.init(markdown: "![Last](dir9999/logo.png) ![Explicit](explicit/logo-2.png)"), collision] + duplicate)
        let data = try PicoDocsEngine.write(result, to: .docx)
        let archive = try #require(Archive(data: data, accessMode: .read))
        let names = Set(archive.filter { $0.path.hasPrefix("word/media/") }.map(\.path))
        #expect(names == ["word/media/logo-10001.png", "word/media/logo-2.png"])
    }

    @Test func worksheetBoundsScanRetainsAllCells() async throws {
        let row = Array(repeating: "x", count: 200).joined(separator: ",")
        let csv = Array(repeating: row, count: 200).joined(separator: "\n")
        let result = ConverterResult(sections: [.init(kind: .sheet, markdown: "", metadata: ["csv": csv])])
        let data = try PicoDocsEngine.write(result, to: .xlsx)
        let recovered = try await PicoDocsEngine.convert(data: data, filename: "grid.xlsx")
        let recoveredCSV = try #require(recovered.sections.first?.metadata["csv"])
        #expect(CSVConverter.parseCSV(recoveredCSV) == CSVConverter.parseCSV(csv))
    }


    @Test func emptyWorksheetsConsumeProjectionBudget() throws {
        var budget = SpreadsheetProjectionBudget(maximumBytes: 34)
        try budget.reserveGrid(rows: 0, columns: 0, name: "A")
        try budget.reserveGrid(rows: 0, columns: 0, name: "B")
        #expect(throws: PicoDocsError.parsingError) { try budget.reserveGrid(rows: 0, columns: 0, name: "C") }
    }

    @Test func duplicateHeadingAndWorksheetNamesUseStableSuffixes() throws {
        #expect(MarkdownHeadingAnchors.slugs(["A", "A-1", "A", "A", "A-2"]) == ["a", "a-1", "a-2", "a-3", "a-2-1"])
        let slugs = MarkdownHeadingAnchors.slugs(Array(repeating: "Same", count: 10_000))
        #expect(Set(slugs).count == 10_000); #expect(slugs.last == "same-9999")
        let names = ["A", "a (2)", "a", "A"] + Array(repeating: "Same", count: 1000)
        let result = ConverterResult(sections: names.map { .init(title: $0, kind: .sheet, markdown: "") })
        let workbook = try xml(XLSXExporter().write(result, format: .xlsx), "xl/workbook.xml")
        for name in ["A", "a (2)", "a (3)", "A (4)", "Same (1000)"] { #expect(workbook.contains("name=\"\(name)\"")) }
    }

    @Test func delimiterHeavyLiteralIdentifiersCoalesceOnce() {
        let source = String(repeating: "a_", count: 100_000) + "z"
        #expect(MarkdownInlineParser.parse(source) == [.text(source)])
        #expect(MarkdownInlineParser.parse("before *unclosed") == [.text("before *unclosed")])
        #expect(MarkdownInlineParser.parse("before **bold** after") == [.text("before "), .strong([.text("bold")]), .text(" after")])
    }

    @Test func DOCXFootnoteMarkerProvenanceSurvivesReimport() async throws {
        for label in ["1", #"a\]b"#, #"a\\b"#] {
            let source = "Claim[^" + label + "]\n\n[^" + label + "]: Note"
            let data = try PicoDocsEngine.write(markdown: source, to: .docx)
            #expect(try xml(data, "word/document.xml").contains("PicoFootnoteMarker"))
            let recovered = try await PicoDocsEngine.convert(data: data, filename: "footnotes.docx")
            #expect(try DocumentRenderer.render(recovered, to: .plaintext) == "Claim[1]\n\n[1] Note")
            #expect(try DocumentRenderer.render(recovered, to: .html).contains("class=\"footnote-ref\""))
        }
        let literal = try await PicoDocsEngine.convert(data: PicoDocsEngine.write(markdown: #"\[^1]"#, to: .docx), filename: "literal.docx")
        #expect(literal.markdown() == #"\[^1\]"#)
    }

    @Test func DOCXMediaDecodeBudgetEnforcesAllThreeLimits() throws {
        let image = Data([1,2,3]).base64EncodedString()
        let budget = OfficeMediaDecodeBudget(maximumImageBytes: 3, maximumBytes: 6, maximumImages: 3)
        #expect(try budget.decode(image) == Data([1,2,3]))
        #expect(try budget.decode(image) == Data([1,2,3]))
        #expect(throws: ExporterError.self) { try budget.decode(image) }
        let perImage = OfficeMediaDecodeBudget(maximumImageBytes: 2, maximumBytes: 6)
        #expect(throws: ExporterError.self) { try perImage.decode(image) }
        let count = OfficeMediaDecodeBudget(maximumImages: 1)
        _ = try count.decode(image)
        #expect(throws: ExporterError.self) { try count.decode(image) }
        let sections = (0..<1025).map { DocumentSection(kind: .image, markdown: "", sourcePath: "\($0).png", metadata: ["base64": image, "mimeType": "image/png"]) }
        #expect(throws: ExporterError.self) { try PicoDocsEngine.write(ConverterResult(sections: sections), to: .docx) }
        let repeated = ConverterResult(sections: [.init(markdown: String(repeating: "![Image](one.png) ", count: 1025)), .init(kind: .image, markdown: "", sourcePath: "one.png", metadata: ["base64": image])])
        let data = try PicoDocsEngine.write(repeated, to: .docx)
        let archive = try #require(Archive(data: data, accessMode: .read))
        #expect(archive.filter { $0.path.hasPrefix("word/media/") }.count == 1)
    }

    @Test func duplicateFullPathImagesRemainUnresolved() throws {
        let body = DocumentSection(markdown: "![Image](media/a.png)")
        let first = DocumentSection(kind: .image, markdown: "", sourcePath: "media/a.png", metadata: ["base64": "AQID", "mimeType": "image/png"])
        let second = DocumentSection(kind: .image, markdown: "", sourcePath: "media/a.png", metadata: ["base64": "BAUG", "mimeType": "image/png"])
        let html = try DocumentRenderer.render(ConverterResult(sections: [body, first, second]), to: .html)
        #expect(html.contains("src=\"media/a.png\"")); #expect(!html.contains("data:image"))
        let unique = try DocumentRenderer.render(ConverterResult(sections: [body, first]), to: .html)
        #expect(unique.contains("data:image/png;base64,AQID"))
    }

    @Test func mixedNumberedAndUnnumberedSlidesKeepTheirPositions() throws {
        let result = ConverterResult(sections: [
            .init(kind: .slide, markdown: "Cover"),
            .init(kind: .slide, markdown: "First", slideNumber: 1),
            .init(kind: .slide, markdown: "Interlude"),
            .init(kind: .slide, markdown: "Third", slideNumber: 3),
            .init(kind: .table, markdown: "| Ancillary |\n| --- |", slideNumber: 1),
            .init(kind: .slide, markdown: "Closing")])
        let data = try PicoDocsEngine.write(result, to: .pptx)
        for (index, text) in ["Cover", "First", "Interlude", "", "Third", "Closing"].enumerated() {
            let slide = try xml(data, "ppt/slides/slide\(index + 1).xml")
            #expect(slide.contains(text.isEmpty ? "<a:p/>" : text))
        }
        #expect(try xml(data, "ppt/slides/slide2.xml").contains("Ancillary"))
    }

    @Test func RTFLinkedMonospaceRunsRetainCodeSemantics() async throws {
        let rtf = #"{\rtf1\deff0{\fonttbl{\f0\fnil Helvetica;}{\f1\fmodern Courier;}}{\field{\*\fldinst HYPERLINK "https://example.test"}{\fldrslt \f1 API}}}"#
        #expect(RTFConverter.markdown(fromRTF: rtf) == "[`API`](https://example.test)")
        #if canImport(AppKit)
        for source in ["[`API`](https://example.test)", "[Docs `API` now](https://example.test)"] {
            let data = try PicoDocsEngine.write(markdown: source, to: .rtf)
            let result = try await PicoDocsEngine.convert(data: data, filename: "linked-code.rtf")
            #expect(result.markdown() == source)
            #expect(try DocumentRenderer.render(result, to: .html).contains("<code>API</code>"))
        }
        let rule = try await PicoDocsEngine.convert(data: PicoDocsEngine.write(markdown: "Before\n\n---\n\nAfter", to: .rtf), filename: "rule.rtf")
        #expect(try DocumentRenderer.render(rule, to: .html).contains("<hr>"))
        #endif
    }


    @Test func XLSXWriterSharesTheReaderWorkbookProjectionBudget() throws {
        var budget = SpreadsheetProjectionBudget()
        for _ in 0..<6 { try budget.reserveGrid(rows: 1000, columns: 1000, name: "Sheet") }
        #expect(throws: PicoDocsError.parsingError) { try budget.reserveGrid(rows: 1000, columns: 1000, name: "Sheet") }
        var exact = SpreadsheetProjectionBudget(maximumBytes: 40)
        try exact.reserveGrid(rows: 1, columns: 1, name: "S") // 35 bytes
        try exact.reserveValue("x") // 5 bytes
        #expect(throws: PicoDocsError.parsingError) { try exact.reserveValue("x") }
        // Two individually valid sections exceed the aggregate budget with values.
        let csv = Array(repeating: String(repeating: "x", count: 32_000), count: 220).joined(separator: "\n")
        let result = ConverterResult(sections: [.init(kind: .sheet, markdown: "", metadata: ["csv": csv]), .init(kind: .sheet, markdown: "", metadata: ["csv": csv])])
        #expect(throws: ExporterError.self) { try PicoDocsEngine.write(result, to: .xlsx) }
    }

    @Test func footnoteDefinitionsIgnoreEscapedLabelClosers() throws {
        for label in [#"a\]b"#, #"a\\\]b"#, #"a\\"#] {
            let result = ConverterResult(sections: [.init(markdown: "Claim[^" + label + "]\n\n[^" + label + "]: Note")])
            let html = try DocumentRenderer.render(result, to: .html)
            let text = try DocumentRenderer.render(result, to: .plaintext)
            #expect(html.contains("class=\"footnote-ref\""))
            #expect(text.contains("Claim[1]")); #expect(text.contains("[1] Note"))
            #expect(!text.contains("[^"))
        }
    }

    @Test func synthesizedImagesKeepTheirNativeSectionPositions() async throws {
        let result = ConverterResult(sections: [
            .init(title: "First", kind: .slide, markdown: "", slideNumber: 1),
            .init(title: "Image one", kind: .image, markdown: "", sourcePath: "one.png", slideNumber: 1, metadata: ["mimeType": "image/png", "base64": "AQID"]),
            .init(title: "Second", kind: .slide, markdown: "", slideNumber: 2),
            .init(title: "Image two", kind: .image, markdown: "", sourcePath: "two.png", slideNumber: 2, metadata: ["mimeType": "image/png", "base64": "BAUG"]),
        ])
        let projected = PicoDocsEngine.withSynthesizedImageReferences(result)
        #expect(projected.sections.map(\.kind) == [.slide, .image, .body, .slide, .image, .body])
        let docx = try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml")
        let firstTitle = try #require(docx.range(of: ">First<"))
        let firstImage = try #require(docx.range(of: "descr=\"Image one\""))
        let secondTitle = try #require(docx.range(of: ">Second<"))
        let secondImage = try #require(docx.range(of: "descr=\"Image two\""))
        #expect(firstTitle.lowerBound < firstImage.lowerBound && firstImage.lowerBound < secondTitle.lowerBound && secondTitle.lowerBound < secondImage.lowerBound)
        let xlsx = try PicoDocsEngine.write(result, to: .xlsx)
        #expect(try xml(xlsx, "xl/worksheets/sheet2.xml").contains("Image one"))
        #expect(try xml(xlsx, "xl/worksheets/sheet4.xml").contains("Image two"))
        #if canImport(AppKit)
        let rtf = try await PicoDocsEngine.convert(data: PicoDocsEngine.write(result, to: .rtf), filename: "images.rtf")
        let text = try DocumentRenderer.render(rtf, to: .plaintext)
        #expect(try #require(text.range(of: "Image one")).lowerBound < #require(text.range(of: "Second")).lowerBound)
        #endif
    }


    @Test func builtInExportersRejectCoverOnlyPayloads() throws {
        let result = ConverterResult(cover: Data([1, 2, 3]), sections: [])
        let exporters: [(any DocumentExporter, ExportableFileType)] = [(WordprocessingMLExporter(), .docx), (XLSXExporter(), .xlsx), (PPTXExporter(), .pptx)]
        for (exporter, format) in exporters {
            #expect(throws: PicoDocsError.emptyDocument) { try PicoDocsEngine.write(result, to: format) }
            #expect(throws: PicoDocsError.emptyDocument) { try exporter.write(result, format: format) }
        }
        #if canImport(AppKit)
        for (exporter, format) in [(AttributedStringRTFExporter() as any DocumentExporter, ExportableFileType.rtf), (AttributedStringDOCXExporter(), .docx)] {
            #expect(throws: PicoDocsError.emptyDocument) { try exporter.write(result, format: format) }
        }
        #expect(throws: PicoDocsError.emptyDocument) { try PicoDocsEngine.write(result, to: .rtf) }
        #endif
        let textAndCover = ConverterResult(cover: Data([1]), sections: [.init(markdown: "Body")])
        #expect(!(try PicoDocsEngine.write(textAndCover, to: .docx)).isEmpty)
    }

    #if canImport(AppKit)
    @Test func RTFRoundTripsLiteralInlineAndBlockPunctuation() async throws {
        for source in [#"\*literal\*"#, ##"\# literal"##, #"1\. literal"#, #"\- literal"#, #"\| literal"#, #"\[literal\] and slash\\tail"#, #"**bold \*literal\***"#, #"[\*literal\*](https://example.com)"#, #"`*literal*`"#] {
            let original = ConverterResult(sections: [.init(markdown: source)])
            let bytes = try PicoDocsEngine.write(original, to: .rtf)
            let restored = try await PicoDocsEngine.convert(data: bytes, filename: "literal.rtf")
            let expected = try DocumentRenderer.render(original, to: .plaintext)
            #expect(try DocumentRenderer.render(restored, to: .plaintext) == expected)
            let expectedHTML = try SwiftSoup.parse(DocumentRenderer.render(original, to: .html))
            let actualHTML = try SwiftSoup.parse(DocumentRenderer.render(restored, to: .html))
            for tag in ["h1", "ul", "ol", "table", "em", "strong", "a", "code"] {
                #expect(try actualHTML.getElementsByTag(tag).count == expectedHTML.getElementsByTag(tag).count)
            }
            let docx = try PicoDocsEngine.write(restored, to: .docx)
            let word = try await PicoDocsEngine.convert(data: docx, filename: "literal.docx")
            #expect(try DocumentRenderer.render(word, to: .plaintext) == expected)
        }
    }
    #endif


    @Test func PPTXDeckLimitAppliesToMarkdownAndUnnumberedSlides() throws {
        let markdown = ConverterResult(sections: [.init(markdown: String(repeating: "# Slide\n\n", count: 10_001))])
        let unnumbered = ConverterResult(sections: Array(repeating: DocumentSection(kind: .slide, markdown: "Slide"), count: 10_001))
        let mixed = ConverterResult(sections: [DocumentSection(kind: .slide, markdown: "Last", slideNumber: 10_000), DocumentSection(kind: .slide, markdown: "Unnumbered content")])
        for result in [markdown, unnumbered, mixed] {
            #expect(throws: ExporterError.self) { try PicoDocsEngine.write(result, to: .pptx) }
        }
    }

    #if canImport(AppKit)
    @Test func separateRTFQuoteBlocksStaySeparate() async throws {
        let data = try PicoDocsEngine.write(markdown: "> First\n\n> Second", to: .rtf)
        let result = try await PicoDocsEngine.convert(data: data, filename: "quotes.rtf")
        let quotes = MarkdownBlockParser.parse(result.markdown()).compactMap { block -> [String]? in
            if case .blockquote(let lines) = block { return lines }; return nil
        }
        #expect(quotes.count == 2); #expect(quotes.allSatisfy { $0.count == 1 })
    }

    @Test func RTFTablesRetainRowsCellsEscapesAndInlineFormatting() async throws {
        let source = #"| Header | Other |"# + "\n| --- | --- |\n" + #"| **Bold** | `a\|b` |"# + "\n" + #"| slash\\value | first<br>second |"#
        let original = ConverterResult(sections: [.init(markdown: source)])
        let data = try PicoDocsEngine.write(original, to: .rtf)
        let result = try await PicoDocsEngine.convert(data: data, filename: "table.rtf")
        func rows(_ value: ConverterResult) -> [[[MarkdownInline]]] {
            OfficeDocumentBlocks.parse(value).flatMap { block -> [[[MarkdownInline]]] in
                if case .table(let rows) = block { return rows.map { $0.map { MarkdownInlineParser.parse($0, tableCell: true) } } }
                return []
            }
        }
        #expect(rows(result) == rows(original))
        #expect(try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml").contains("<w:tbl>"))
        #expect(try xml(PicoDocsEngine.write(result, to: .xlsx), "xl/worksheets/sheet1.xml").contains("r=\"B3\""))
    }
    #endif

    @Test func customExporterReceivesCoverOnlyStructuredResult() throws {
        struct CoverExporter: DocumentExporter {
            func accepts(_ format: ExportableFileType) -> Bool { format == .pages }
            func write(_ result: ConverterResult, format: ExportableFileType) throws -> Data { try #require(result.cover) }
        }
        let registry = DocumentExporterRegistry().registering(CoverExporter())
        #expect(try PicoDocsEngine.write(ConverterResult(cover: Data([1,2,3]), sections: []), to: .pages, registry: registry) == Data([1,2,3]))
        #expect(throws: PicoDocsError.emptyDocument) { try PicoDocsEngine.write(ConverterResult(cover: Data(), sections: []), to: .pages, registry: registry) }
    }

    @Test func DOCXMultilineAndSeparateQuotesRetainTheirBoundaries() async throws {
        for (source, sizes) in [("> First\n> Second", [2]), ("> First\n\n> Second", [1,1])] {
            let data = try PicoDocsEngine.write(markdown: source, to: .docx)
            let result = try await PicoDocsEngine.convert(data: data, filename: "quotes.docx")
            let quotes = MarkdownBlockParser.parse(result.markdown()).compactMap { block -> Int? in
                if case .blockquote(let lines) = block { return lines.count }; return nil
            }
            #expect(quotes == sizes)
        }
    }

    @Test func explicitSlideTitlesAppearOnlyInTheTitlePlaceholder() throws {
        for markdown in ["Details", "## Agenda\n\nDetails"] {
            let result = ConverterResult(sections: [.init(title: "Agenda", kind: .slide, markdown: markdown, slideNumber: 1)])
            let slide = try xml(PicoDocsEngine.write(result, to: .pptx), "ppt/slides/slide1.xml")
            #expect(slide.components(separatedBy: ">Agenda</a:t>").count - 1 == 1)
            #expect(slide.contains(">Details</a:t>"))
            #expect(try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml").contains("Agenda"))
        }
    }

    #if canImport(AppKit)
    @Test func RTFCodeBlocksRoundTripLiteralContentAndFenceLikeLines() async throws {
        let code = "# literal\n- literal\n\n  indented \\*\n```\ntrailing  "
        let source = "````\n" + code + "\n````"
        let data = try PicoDocsEngine.write(markdown: source, to: .rtf)
        let result = try await PicoDocsEngine.convert(data: data, filename: "code.rtf")
        let blocks = MarkdownBlockParser.parse(result.markdown())
        #expect(blocks.count == 1)
        #expect(blocks.contains { if case .code(let text) = $0 { return text == code }; return false })
        #expect(try DocumentRenderer.render(result, to: .html).contains("<pre><code>"))
    }

    @Test func RTFBlockquotesRetainTheirBlockIdentity() async throws {
        let data = try PicoDocsEngine.write(markdown: "> Warning\n> Second line", to: .rtf)
        let result = try await PicoDocsEngine.convert(data: data, filename: "quote.rtf")
        #expect(MarkdownBlockParser.parse(result.markdown()).contains { if case .blockquote(let lines) = $0 { return lines.count == 2 }; return false })
        #expect(try DocumentRenderer.render(result, to: .html).contains("<blockquote>"))
        #expect(try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml").contains("w:val=\"Quote\""))
    }
    #endif

    @Test func exportedLooseListsKeepContinuationIdentityAndCounters() async throws {
        for source in ["- Parent\n\n  Continuation\n- Next", "10. Parent\n\n    Continuation\n11. Next", "- Parent\n  - Child\n\n    Child continuation\n\n  Parent continuation\n- Next"] {
            let data = try PicoDocsEngine.write(markdown: source, to: .docx)
            let result = try await PicoDocsEngine.convert(data: data, filename: "loose.docx")
            #expect(result.markdown() == source)
            #expect(try xml(data, "word/numbering.xml").contains("w:numFmt w:val=\"none\""))
        }
    }

    #if canImport(AppKit)
    @Test func RTFHeadingLevelsRemainSlideBoundariesAfterRoundTrip() async throws {
        let rtf = try PicoDocsEngine.write(markdown: "# First\n\nBody\n\n## Second\n\nMore", to: .rtf)
        let result = try await PicoDocsEngine.convert(data: rtf, filename: "headings.rtf")
        let headings = MarkdownBlockParser.parse(result.markdown()).compactMap { block -> Int? in
            if case .heading(let level, _) = block { return level }; return nil
        }
        #expect(headings == [1, 2])
        let pptx = try PicoDocsEngine.write(result, to: .pptx)
        #expect(try xml(pptx, "ppt/presentation.xml").components(separatedBy: "<p:sldId ").count - 1 == 2)
    }
    #endif

    @Test func onlyReferencedImageCarriersArePackagedAndInvalidAliasesDoNotHideValidImages() throws {
        let body = DocumentSection(markdown: "![first](used.png) ![again](used.png)")
        let used = DocumentSection(kind: .image, markdown: "", sourcePath: "valid/used.png", metadata: ["base64": "AQID", "mimeType": "image/png"])
        let invalid = DocumentSection(kind: .image, markdown: "", sourcePath: "invalid/used.png", metadata: ["base64": "invalid", "mimeType": "image/png"])
        let unused = DocumentSection(kind: .image, markdown: "", sourcePath: "unused.png", metadata: ["base64": Data(repeating: 7, count: 1024 * 1024).base64EncodedString(), "mimeType": "image/png"])
        let data = try PicoDocsEngine.write(ConverterResult(sections: [body, used, invalid, unused]), to: .docx)
        let archive = try #require(Archive(data: data, accessMode: .read))
        #expect(archive.filter { $0.path.hasPrefix("word/media/") }.count == 1)
        #expect(try xml(data, "word/document.xml").components(separatedBy: "<w:drawing>").count - 1 == 2)
    }

    @Test func repeatedSharedStringsRespectProjectedWorkbookBudget() async throws {
        let base = try PicoDocsEngine.write(markdown: "cell", to: .xlsx)
        let archive = try #require(Archive(data: base, accessMode: .read))
        var parts: [(name: String, data: [UInt8])] = []
        for entry in archive where entry.path != "xl/worksheets/sheet1.xml" {
            var data = Data(); _ = try archive.extract(entry) { data.append($0) }
            parts.append((entry.path, Array(data)))
        }
        let shared = "<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><si><t>" + String(repeating: "x", count: 32_000) + "</t></si></sst>"
        parts.append(("xl/sharedStrings.xml", Array(shared.utf8)))
        for count in [2, 1000] {
            let rows = (1...count).map { "<row r=\"\($0)\"><c r=\"A\($0)\" t=\"s\"><v>0</v></c></row>" }.joined()
            let sheet = "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>" + rows + "</sheetData></worksheet>"
            let data = PagesConverterTests.makeZip(parts + [("xl/worksheets/sheet1.xml", Array(sheet.utf8))])
            if count == 2 {
                let result = try await PicoDocsEngine.convert(data: data, filename: "small.xlsx")
                #expect(result.sections.first?.metadata["csv"]?.count == 64_005)
            } else {
                await #expect(throws: PicoDocsError.parsingError) { try await PicoDocsEngine.convert(data: data, filename: "expansion.xlsx") }
            }
        }
    }

    @Test func escapeRestorationRetainsPlainAndEscapedCells() throws {
        let result = ConverterResult(sections: [.init(markdown: #"| ordinary | \*literal\* |"# + "\n| --- | --- |")])
        #expect(try DocumentRenderer.render(result, to: .plaintext) == "ordinary\t*literal*")
        #expect(try DocumentRenderer.render(result, to: .html).contains("<th>*literal*</th>"))
    }

    @Test func imageMetadataNewlinesCannotInjectBlocks() throws {
        for separator in ["\n", "\r", "\r\n"] {
            let image = DocumentSection(title: "caption" + separator + "# Forged", kind: .image, markdown: "", sourcePath: "a" + separator + "b.png", metadata: ["mimeType": "image/png", "base64": "AQID"])
            let result = ConverterResult(sections: [image])
            let synthesized = PicoDocsEngine.withSynthesizedImageReferences(result)
            let blocks = MarkdownBlockParser.parse(synthesized.markdown())
            #expect(blocks.count == 1)
            #expect(try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml").contains("<w:drawing>"))
            #expect(!synthesized.markdown().contains(separator + "# Forged"))
        }
    }

    @Test func looseHTMLListItemsKeepSeparateParagraphs() throws {
        let source = ConverterResult(sections: [.init(markdown: "1. Parent\n\n   Continuation\n2. Next")])
        let html = try DocumentRenderer.render(source, to: .html)
        #expect(html.contains("<p>Parent</p>")); #expect(html.contains("<p>Continuation</p>"))
        #expect(html.contains("<li>Next</li>"))
    }

    @Test func customExportersCanAcceptEmptyStructuredSections() throws {
        struct StructuralExporter: DocumentExporter {
            func accepts(_ format: ExportableFileType) -> Bool { format == .pages }
            func write(_ result: ConverterResult, format: ExportableFileType) throws -> Data { Data([42]) }
        }
        let registry = DocumentExporterRegistry().registering(StructuralExporter())
        for section in [DocumentSection(kind: .slide, markdown: "", slideNumber: 1), DocumentSection(kind: .sheet, markdown: "")] {
            #expect(try PicoDocsEngine.write(ConverterResult(sections: [section]), to: .pages, registry: registry) == Data([42]))
        }
        #expect(throws: PicoDocsError.emptyDocument) { try PicoDocsEngine.write(ConverterResult(sections: []), to: .pages, registry: registry) }
    }

    @Test func slideTitlesSurviveSharedOfficeProjectionWithoutDuplication() async throws {
        for body in ["Details", "## Agenda\n\nDetails"] {
            let result = ConverterResult(sections: [.init(title: "Agenda", kind: .slide, markdown: body, slideNumber: 1)])
            let docx = try PicoDocsEngine.write(result, to: .docx)
            let restored = try await PicoDocsEngine.convert(data: docx, filename: "agenda.docx")
            #expect(restored.markdown().components(separatedBy: "Agenda").count - 1 == 1)
            #expect(restored.markdown().contains("## Agenda")); #expect(restored.markdown().contains("Details"))
            #if canImport(AppKit)
            #expect(AttributedStringDocumentBuilder.attributedString(from: result).string.components(separatedBy: "Agenda").count - 1 == 1)
            #endif
        }
    }

    @Test func noteHyperlinksUseCanonicalBodyBookmarks() async throws {
        let document = #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:bookmarkStart w:id="1" w:name="_Ref123"/><w:r><w:t>Details</w:t></w:r></w:p><w:p><w:r><w:t>See</w:t><w:footnoteReference w:id="1"/><w:endnoteReference w:id="2"/></w:r></w:p></w:body></w:document>"#
        let link = #"<w:p><w:hyperlink w:anchor="_Ref123"><w:r><w:t>Back</w:t></w:r></w:hyperlink></w:p>"#
        let footnotes = "<w:footnotes><w:footnote w:id=\"1\">" + link + "</w:footnote></w:footnotes>"
        let endnotes = "<w:endnotes><w:endnote w:id=\"2\">" + link + "</w:endnote></w:endnotes>"
        let data = PagesConverterTests.makeZip([("word/document.xml", Array(document.utf8)), ("word/footnotes.xml", Array(footnotes.utf8)), ("word/endnotes.xml", Array(endnotes.utf8))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "notes.docx")
        #expect(result.markdown().contains("[^fn1]: [Back](#details)"))
        #expect(result.markdown().contains("[^en2]: [Back](#details)"))
    }

    @Test func RTFHyperlinkSwitchesRetainBookmarkDestinations() {
        for (instruction, expected) in [(#"HYPERLINK \\l "details""#, "#details"), (#"HYPERLINK "https://example.com" \\l "details""#, "https://example.com#details"), (#"HYPERLINK \\o "tip" \\l "details" \\t "_blank""#, "#details")] {
            let rtf = #"{\rtf1 {\field{\*\fldinst "# + instruction + #"}{\fldrslt Back}}}"#
            #expect(RTFConverter.markdown(fromRTF: rtf) == "[Back](" + expected + ")")
        }
    }

    @Test func inlinePlaceholdersKeepSourceDelimiterFlanking() {
        for source in ["[x](u)_em_", "`x`_em_", "_em_[x](u)", "_em_`x`", #"\*_em_"#] {
            #expect(MarkdownInlineParser.parse(source).contains(.emphasis([.text("em")])))
        }
        #expect(MarkdownInlineParser.parse("a_em_") == [.text("a_em_")])
        #expect(!MarkdownInlineParser.parse("_a\nb_").isEmpty)
    }

    @Test func portableTIFFAndWebPHeadersKeepImageAspectRatios() throws {
        func integer(_ value: UInt32, _ count: Int, little: Bool = true) -> [UInt8] {
            let bytes = (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
            return little ? bytes : bytes.reversed()
        }
        var images: [(String, Data)] = []
        for little in [true, false] {
            for type: UInt32 in [3, 4] {
                var bytes: [UInt8] = little ? [0x49, 0x49, 42, 0] : [0x4D, 0x4D, 0, 42]
                bytes += integer(80, 4, little: little)
                bytes += Array(repeating: 0, count: 72)
                bytes += integer(2, 2, little: little)
                for (tag, value): (UInt32, UInt32) in [(256, 20), (257, 60)] {
                    bytes += integer(tag, 2, little: little) + integer(type, 2, little: little) + integer(1, 4, little: little)
                    bytes += integer(value, type == 3 ? 2 : 4, little: little)
                    if type == 3 { bytes += [0, 0] }
                }
                bytes += [0, 0, 0, 0]
                images.append(("tiff", Data(bytes)))
            }
        }
        func webp(_ kind: String, _ payload: [UInt8]) -> Data {
            let chunk = Array(kind.utf8) + integer(UInt32(payload.count), 4) + payload + (payload.count.isMultiple(of: 2) ? [] : [0])
            return Data(Array("RIFF".utf8) + integer(UInt32(chunk.count + 4), 4) + Array("WEBP".utf8) + chunk)
        }
        images.append(("webp", webp("VP8X", [0,0,0,0] + integer(19,3) + integer(59,3))))
        images.append(("webp", webp("VP8L", [0x2F] + integer(19 | (59 << 14), 4))))
        images.append(("webp", webp("VP8 ", [0,0,0,0x9D,1,0x2A] + integer(20,2) + integer(60,2))))
        for (ext, data) in images {
            let size = try #require(OfficeImageDimensions.read(data))
            #expect(size.0 == 20 && size.1 == 60)
            let result = ConverterResult(sections: [.init(kind: .image, markdown: "", sourcePath: "image." + ext, metadata: ["mimeType": "image/" + ext, "base64": data.base64EncodedString()])])
            let doc = try SwiftSoup.parse(xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml"), "", SwiftSoup.Parser.xmlParser())
            let extent = try #require(doc.getElementsByTag("wp:extent").first())
            let width = try #require(Double(extent.attr("cx"))), height = try #require(Double(extent.attr("cy")))
            #expect(abs(width / height - 1.0 / 3.0) < 0.001)
            #expect(OfficeImageDimensions.read(Data(data.prefix(12))) == nil)
        }
    }

    @Test func RTFFieldsKeepHyperlinkTargetsAndFormattedLabels() async throws {
        let rtf = #"{\rtf1 Before {\field{\*\fldinst HYPERLINK "https://example.test/a(b)"}{\fldrslt {\b Docs}}} after}"#
        let result = try await PicoDocsEngine.convert(data: Data(rtf.utf8), filename: "fields.rtf")
        #expect(result.markdown().contains("[**Docs**](<https://example.test/a(b)>)"))
        #expect(try DocumentRenderer.render(result, to: .html).contains(#"href="https://example.test/a(b)""#))
        #expect(try DocumentRenderer.render(result, to: .plaintext) == "Before Docs after")
        let ignored = #"{\rtf1 Visible {\*\unknown {\field{\*\fldinst HYPERLINK "https://hidden"}{\fldrslt Secret}}}}"#
        #expect(RTFConverter.markdown(fromRTF: ignored) == "Visible")
        #if canImport(AppKit)
        let generated = try PicoDocsEngine.write(markdown: "[Docs](https://example.test)", to: .rtf)
        let recovered = try await PicoDocsEngine.convert(data: generated, filename: "generated.rtf")
        #expect(recovered.markdown().contains("[Docs](https://example.test)"))
        #endif
    }

    #if canImport(AppKit)
    @Test func RTFUnorderedListsRoundTripWithNestedMarkers() async throws {
        let source = "- Parent\n  - Child\n- Next"
        let generated = try PicoDocsEngine.write(markdown: source, to: .rtf)
        let result = try await PicoDocsEngine.convert(data: generated, filename: "lists.rtf")
        #expect(result.markdown().contains("- Parent")); #expect(result.markdown().contains("  - Child"))
        #expect(result.markdown().contains("- Next")); #expect(!result.markdown().contains("•"))
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.components(separatedBy: "<ul>").count - 1 == 2)
        let docx = try PicoDocsEngine.write(result, to: .docx)
        #expect(try xml(docx, "word/document.xml").contains("<w:numPr>"))
    }
    #endif


    @Test func WordMediaBudgetIsSharedAcrossBodyAndNotes() throws {
        let body = try SwiftSoup.parse(#"<w:body><a:blip r:embed="body"/></w:body>"#, "", SwiftSoup.Parser.xmlParser())
        let note = #"<w:footnotes><w:footnote w:id="1"><a:blip r:embed="note"/></w:footnote></w:footnotes>"#
        for sameImage in [false, true] {
            let target = sameImage ? "media/a.png" : "media/b.png"
            let rels = "<Relationships><Relationship Id=\"note\" Type=\"rel/image\" Target=\"" + target + "\"/></Relationships>"
            let data = PagesConverterTests.makeZip([(name: "word/media/a.png", data: Array(repeating: 1, count: 6)), (name: "word/media/b.png", data: Array(repeating: 2, count: 6)), (name: "word/footnotes.xml", data: Array(note.utf8)), (name: "word/_rels/footnotes.xml.rels", data: Array(rels.utf8))])
            let archive = try #require(Archive(data: data, accessMode: .read))
            for budget in [WordConverter.MediaBudget(maxBytes: 10), WordConverter.MediaBudget(maxImages: 1)] {
                let images = try WordConverter.extractImages(from: body, relationships: ["body": "media/a.png"], archive: archive, budget: budget)
                #expect(images.count == 1)
                #expect(try WordConverter.extractNoteImages(archive, budget: budget).isEmpty)
                #expect(images.first?.metadata["base64"] == Data(repeating: 1, count: 6).base64EncodedString())
            }
        }
    }

    @Test func spreadsheetEncodeFastPathRetainsEscapesAndControls() {
        for source in ["ordinary", "_x0041_", "_xFFFF_\u{0001}", "tab\tline\n", "emoji 😀", "\u{FFFE}"] {
            #expect(SpreadsheetMLText.decode(SpreadsheetMLText.encode(source)) == source)
        }
    }

    @Test func XLSXDimensionsRespectTheReaderCellBudget() throws {
        try XLSXExporter.validateDimensions(rows: 1_000, columns: 1_000)
        #expect(throws: ExporterError.self) { try XLSXExporter.validateDimensions(rows: 1_001, columns: 1_000) }
        #expect(throws: ExporterError.self) { try XLSXExporter.validateDimensions(rows: Int.max, columns: Int.max) }
    }

    @Test func XLSXListProjectionKeepsMarkersAndContentIndentation() throws {
        let data = try PicoDocsEngine.write(markdown: "3. Third\n   - child\n4. Fourth", to: .xlsx)
        let sheet = try xml(data, "xl/worksheets/sheet1.xml")
        #expect(sheet.contains(">3. Third</t>"))
        #expect(sheet.contains(">   - child</t>"))
        #expect(sheet.contains(">4. Fourth</t>"))
    }


    @Test func emptyCSVCellSurvivesOfficeProjection() async throws {
        let converted = try await PicoDocsEngine.convert(data: Data("\"\"".utf8), filename: "empty.csv")
        let legacy = ConverterResult(sections: [.init(kind: .table, markdown: "|  |\n| --- |", metadata: ["csv": ""])])
        for result in [converted, legacy] {
            #expect(OfficeDocumentBlocks.parse(result).contains { if case .table(let rows) = $0 { return rows == [[""]] }; return false })
            #expect(try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml").contains("<w:tbl>"))
        }
        #expect(CSVConverter.parseCSV(CSVConverter.serializeCSV([[""]])) == [[""]])
        #expect(OfficeDocumentBlocks.parse(ConverterResult(sections: [.init(kind: .table, markdown: "", metadata: ["csv": ""])] )).isEmpty)
    }

    @Test func slideBodyHeadingsReceiveJumpTargets() throws {
        let source = "# Start\n[go](#details) [again](#details-1)\n# Other\n### Details\n# Last\n#### Details"
        let pptx = try PicoDocsEngine.write(markdown: source, to: .pptx)
        let rels = try xml(pptx, "ppt/slides/_rels/slide1.xml.rels")
        #expect(rels.contains("Target=\"slide2.xml\""))
        #expect(rels.contains("Target=\"slide3.xml\""))
    }

    @Test func tableLinkLabelsRetainHardBreaks() throws {
        let result = ConverterResult(sections: [.init(markdown: "| [first<br>second](https://example.com) |\n| --- |")])
        #expect(try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml").contains("<w:br/>"))
        #expect(try xml(PicoDocsEngine.write(result, to: .pptx), "ppt/slides/slide1.xml").contains("<a:br/>"))
        #expect(try xml(PicoDocsEngine.write(result, to: .xlsx), "xl/worksheets/sheet1.xml").contains("first\nsecond"))
        #if canImport(AppKit)
        #expect(AttributedStringDocumentBuilder.attributedString(from: result).string.contains("first\nsecond"))
        #endif
        #expect(MarkdownInlineParser.parse("[`<br>`](url)", tableCell: true).plainText == "<br>")
        #expect(MarkdownInlineParser.parse(#"[\<br>](url)"#, tableCell: true).plainText == "<br>")
    }

    @Test func underscoreRulesInterruptParagraphs() throws {
        let blocks = MarkdownBlockParser.parse("paragraph\n___")
        #expect(blocks.count == 2)
        #expect(blocks.contains { if case .rule = $0 { return true }; return false })
        #expect(try DocumentRenderer.render(ConverterResult(sections: [.init(markdown: "paragraph\n___")]), to: .html).contains("<hr>"))
    }

    @Test func markerlessWordParagraphRemainsListContinuation() async throws {
        let numbering = "<w:numbering xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:abstractNum w:abstractNumId=\"0\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/></w:lvl><w:lvl w:ilvl=\"1\"><w:numFmt w:val=\"none\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num></w:numbering>"
        func paragraph(_ text: String, _ level: Int) -> String { "<w:p><w:pPr><w:numPr><w:ilvl w:val=\"\(level)\"/><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>" }
        let document = "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>" + paragraph("Parent", 0) + paragraph("Continuation", 1) + paragraph("Next", 0) + "</w:body></w:document>"
        let data = PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "list.docx")
        let markdown = result.sections.map(\.markdown).joined(separator: "\n")
        #expect(markdown.contains("1. Parent\n\n   Continuation\n2. Next"))
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("Continuation")); #expect(!html.contains("</ol>\n<p>Continuation"))
        let pptx = try xml(PicoDocsEngine.write(result, to: .pptx), "ppt/slides/slide1.xml")
        #expect(pptx.contains("<a:buNone/>")); #expect(pptx.contains("Continuation"))
    }

    @Test func escapedFootnoteIDsMatchReferencesAndDefinitions() throws {
        let result = ConverterResult(sections: [.init(markdown: #"Claim[^a\*b]"# + "\n\n" + #"[^a\*b]: Note"#)])
        #expect(try DocumentRenderer.render(result, to: .plaintext) == "Claim[1]\n\n[1] Note")
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("href=\"#fn-a*b\"")); #expect(html.contains("id=\"fn-a*b\""))
        let literal = ConverterResult(sections: [.init(markdown: #"\[^a\*b] `[^a\*b]`"# + "\n\n" + #"[^a\*b]: Note"#)])
        #expect(!(try DocumentRenderer.render(literal, to: .html)).contains("<sup"))
    }


    @Test func publicWorksheetNamesProjectIntoOfficeDocuments() throws {
        for csv: String? in [nil, "value"] {
            let result = ConverterResult(sections: [.init(kind: .sheet, markdown: "", sheetName: "Template", metadata: csv.map { ["csv": $0] } ?? [:])])
            #expect(try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml").contains("Template"))
            #expect(try xml(PicoDocsEngine.write(result, to: .pptx), "ppt/slides/slide1.xml").contains("Template"))
            #if canImport(AppKit)
            #expect(AttributedStringDocumentBuilder.attributedString(from: result).string.contains("Template"))
            #endif
        }
    }

    @Test func portableJPEGDimensionsWalkMetadataAndProgressiveFrames() throws {
        for marker: UInt8 in [0xC0, 0xC2] {
            let metadata = [UInt8](repeating: 0, count: 1024)
            let bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE1, 0x04, 0x02] + metadata + [0xFF, marker, 0, 11, 8, 0, 60, 0, 20, 1, 1, 0x11, 0]
            let size = try #require(OfficeImageDimensions.read(Data(bytes)))
            #expect(size.0 == 20 && size.1 == 60)
            #expect(OfficeImageDimensions.read(Data(bytes.dropLast(5))) == nil)
        }
        #expect(OfficeImageDimensions.read(Data([0xFF, 0xD8, 0xFF, 0xE1, 0xFF, 0xFF])) == nil)
        #if canImport(AppKit)
        for (width, height) in [(20, 20), (10, 30), (40, 10)] {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [:]))
            let size = try #require(OfficeImageDimensions.read(jpeg))
            #expect(size.0 == Double(width) && size.1 == Double(height))
        }
        #endif
    }

    @Test func officeBreaksRetainBackslashParity() throws {
        for count in 1...4 {
            let source = "foo" + String(repeating: "\\", count: count) + "\nbar"
            let nodes = MarkdownInlineParser.parse(source)
            #expect(nodes.contains(.lineBreak(hard: !count.isMultiple(of: 2))))
            #expect(nodes.plainText == "foo" + String(repeating: "\\", count: count / 2) + "\nbar")
            let result = ConverterResult(sections: [.init(markdown: source)])
            let docx = try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml")
            #expect(docx.contains("<w:br/>") == !count.isMultiple(of: 2))
            #expect(docx.contains("foo" + String(repeating: "\\", count: count / 2)))
            let pptx = try xml(PicoDocsEngine.write(result, to: .pptx), "ppt/slides/slide1.xml")
            #expect(pptx.contains("<a:br/>") == !count.isMultiple(of: 2))
            #if canImport(AppKit)
            let expected = "foo" + String(repeating: "\\", count: count / 2) + (count.isMultiple(of: 2) ? " " : "\n") + "bar"
            #expect(AttributedStringDocumentBuilder.attributedString(from: result).string.contains(expected))
            #endif
        }
    }

    @Test func tableBreaksRespectCodeAndEscapesInEveryOfficeWriter() throws {
        for cell in ["`<br>`", #"\<br>"#] {
            let result = ConverterResult(sections: [.init(markdown: "| " + cell + " |\n| --- |")])
            let docx = try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml")
            #expect(docx.contains("&lt;br&gt;")); #expect(!docx.contains("<w:br/>"))
            let pptx = try xml(PicoDocsEngine.write(result, to: .pptx), "ppt/slides/slide1.xml")
            #expect(pptx.contains("&lt;br&gt;")); #expect(!pptx.contains("<a:br/>"))
            #expect(try xml(PicoDocsEngine.write(result, to: .xlsx), "xl/worksheets/sheet1.xml").contains("&lt;br&gt;"))
            #if canImport(AppKit)
            #expect(AttributedStringDocumentBuilder.attributedString(from: result).string.contains("<br>"))
            #endif
        }
    }

    @Test func rawCSVTableCarrierPreservesCellWhitespaceAndNewlines() async throws {
        let csv = "\" leading \ntrailing \""
        let converted = try await PicoDocsEngine.convert(data: Data(csv.utf8), filename: "cells.csv")
        for result in [converted, ConverterResult(sections: [.init(kind: .table, markdown: "", metadata: ["csv": csv])])] {
            let docx = try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml")
            #expect(docx.contains("> leading </w:t>")); #expect(docx.contains(">trailing </w:t>")); #expect(docx.contains("<w:br/>"))
            let pptx = try xml(PicoDocsEngine.write(result, to: .pptx), "ppt/slides/slide1.xml")
            #expect(pptx.contains("> leading </a:t>")); #expect(pptx.contains(">trailing </a:t>")); #expect(pptx.contains("<a:br/>"))
            #if canImport(AppKit)
            #expect(AttributedStringDocumentBuilder.attributedString(from: result).string.contains(" leading \ntrailing "))
            #endif
        }
    }

    @Test func optionalWordPartsHaveEnforcedExtractionLimits() throws {
        let data = PagesConverterTests.makeZip([(name: "word/numbering.xml", data: [UInt8](repeating: 32, count: 8 * 1024 * 1024 + 1))])
        let archive = try #require(Archive(data: data, accessMode: .read))
        #expect(WordListNumbering(archive: archive).failure != nil)
        let small = try #require(Archive(data: PagesConverterTests.makeZip([(name: "part", data: [1, 2, 3])]), accessMode: .read))
        #expect(WordConverter.readEntry(small, path: "part", maxBytes: 2) == nil)
        #expect(WordConverter.readEntry(small, path: "part", maxBytes: 3) == Data([1, 2, 3]))
    }

    @Test func backslashPairsKeepInlineDelimitersActive() throws {
        for count in 1...4 {
            let prefix = String(repeating: "\\", count: count)
            let result = ConverterResult(sections: [.init(markdown: prefix + "*em*")])
            let expected = String(repeating: "\\", count: count / 2) + (count.isMultiple(of: 2) ? "em" : "*em*")
            for format in [ExportFileType.plaintext, .csv] { #expect(try DocumentRenderer.render(result, to: format) == expected) }
            #expect(try DocumentRenderer.render(result, to: .html).contains("<em>em</em>") == count.isMultiple(of: 2))
        }
        let links = ConverterResult(sections: [.init(markdown: #"\\[Link](https://example.com)"#)])
        #expect(try DocumentRenderer.render(links, to: .html).contains(#"\<a href="https://example.com">Link</a>"#))
        let notes = ConverterResult(sections: [.init(markdown: #"\\[^n]"# + "\n\n[^n]: Note")])
        #expect(try DocumentRenderer.render(notes, to: .html).contains("<sup"))
    }

    @Test func csvFencesNormalizeCRLFAndCR() throws {
        for newline in ["\n", "\r\n", "\r"] {
            let source = ["```", "a|b", "```", "| c | d |", "| --- | --- |"].joined(separator: newline)
            #expect(try DocumentRenderer.render(ConverterResult(sections: [.init(markdown: source)]), to: .csv) == "a|b\nc,d")
        }
    }

    @Test func exporterErrorsExposeTheirExplanation() throws {
        let result = ConverterResult(sections: [.init(markdown: "", metadata: ["csv": String(repeating: "x", count: 32_768)])])
        do {
            _ = try PicoDocsEngine.write(result, to: .xlsx)
            Issue.record("Expected the worksheet cell limit to be enforced")
        } catch ExporterError.serializationFailed(let message) {
            #expect(!message.isEmpty)
            #expect(ExporterError.serializationFailed(message).localizedDescription == message)
        }
    }

    @Test func portableVectorAndCarrierDimensionsPreserveAspectRatio() throws {
        let vectors = [#"<svg viewBox="0 0 20 60"/>"#, #"<svg width="2in" height="1in" viewBox="0 0 10 10"/>"#, #"<svg width="100%" height="100%" viewBox="0,0,20,20"/>"#]
        for (source, ratio) in zip(vectors, [1.0 / 3, 2, 1]) {
            let data = Data(source.utf8)
            let (cx, cy) = WordprocessingMLExporter.imageExtents(data)
            #expect(abs(Double(cx) / Double(cy) - ratio) < 0.00001)
            let result = ConverterResult(sections: [.init(kind: .image, markdown: "", sourcePath: "vector.svg", metadata: ["base64": data.base64EncodedString(), "mimeType": "image/svg+xml"])])
            #expect(try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml").contains("<wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/>"))
        }
        var emf = Data(repeating: 0, count: 88)
        func put(_ value: UInt32, offset: Int, count: Int, into data: inout Data) {
            for index in 0..<count { data[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
        }
        put(1, offset: 0, count: 4, into: &emf)
        put(0x464D4520, offset: 40, count: 4, into: &emf)
        put(20, offset: 32, count: 4, into: &emf)
        put(60, offset: 36, count: 4, into: &emf)
        var wmf = Data(repeating: 0, count: 22)
        put(0x9AC6CDD7, offset: 0, count: 4, into: &wmf)
        put(20, offset: 10, count: 2, into: &wmf)
        put(60, offset: 12, count: 2, into: &wmf)
        for data in [emf, wmf] {
            let (cx, cy) = WordprocessingMLExporter.imageExtents(data)
            #expect(abs(Double(cx) / Double(cy) - 1.0 / 3) < 0.00001)
        }
        let (cx, cy) = WordprocessingMLExporter.imageExtents(Data([1, 2, 3]), metadata: ["width": "30", "height": "10"])
        #expect(cx == 3 * cy)
        #expect(OfficeImageDimensions.read(Data(#"<svg width="NaN" height="0"/>"#.utf8)) == nil)
        _ = WordprocessingMLExporter.imageExtents(Data(#"<svg width="1e-320" height="1e-320"/>"#.utf8))
    }

    @Test func imageOnlyBookmarkedHeadingsAllocateCanonicalSlugs() async throws {
        let document = #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"><w:body><w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:bookmarkStart w:id="1" w:name="rawBookmark"/><w:r><w:drawing><wp:inline><wp:docPr id="1" name="Picture" descr="Chart"/><a:blip r:embed="image"/></wp:inline></w:drawing></w:r></w:p><w:p><w:hyperlink w:anchor="rawBookmark"><w:r><w:t>Link</w:t></w:r></w:hyperlink></w:p></w:body></w:document>"#
        let relationships = #"<Relationships><Relationship Id="image" Target="media/chart.png" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"/></Relationships>"#
        let data = PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/_rels/document.xml.rels", data: Array(relationships.utf8)), (name: "word/media/chart.png", data: [1, 2, 3])])
        let result = try await PicoDocsEngine.convert(data: data, filename: "heading.docx")
        #expect(result.markdown().contains("[Link](#chart)"))
        #expect(try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml").contains(#"w:anchor="heading_1""#))
    }

    @Test func flattenedTableHeadingsDoNotAllocateFragments() async throws {
        let heading = #"<w:pPr><w:pStyle w:val="Heading1"/></w:pPr>"#
        let xml = #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>"# + "<w:tbl><w:tr><w:tc><w:p>" + heading + "<w:r><w:t>Details</w:t></w:r></w:p></w:tc></w:tr></w:tbl><w:p>" + heading + #"<w:bookmarkStart w:id="1" w:name="details"/><w:r><w:t>Details</w:t></w:r><w:bookmarkEnd w:id="1"/></w:p><w:p><w:hyperlink w:anchor="details"><w:r><w:t>Link</w:t></w:r></w:hyperlink></w:p></w:body></w:document>"#
        let result = try await PicoDocsEngine.convert(data:PagesConverterTests.makeZip([(name:"word/document.xml",data:Array(xml.utf8))]),filename:"table-heading.docx")
        #expect(result.markdown().contains("[Link](#details)"))
        #expect(!result.markdown().contains("#details-1"))
    }

    @Test func namedEmptySheetsTranscodeToOfficeHeadings() async throws {
        let workbook = try PicoDocsEngine.write(ConverterResult(sections:[.init(title:"Template",kind:.sheet,markdown:"")]),to:.xlsx)
        let recovered = try await PicoDocsEngine.convert(data:workbook,filename:"empty.xlsx")
        #expect(try xml(PicoDocsEngine.write(recovered,to:.docx),"word/document.xml").contains("Template"))
        #expect(try xml(PicoDocsEngine.write(recovered,to:.pptx),"ppt/slides/slide1.xml").contains("Template"))
        #if canImport(AppKit)
        #expect(!(try PicoDocsEngine.write(recovered,to:.rtf)).isEmpty)
        #endif
    }

    #if canImport(AppKit)
    @Test func embeddedImagesFitWithoutChangingAspectRatio() throws {
        for (width,height) in [(20,20),(10,30),(40,10)] {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
            let data = try #require(bitmap.representation(using:.png,properties:[:]))
            let (cx,cy) = WordprocessingMLExporter.imageExtents(data)
            #expect(abs(Double(cx) / Double(cy) - Double(width) / Double(height)) < 0.00001)
            #expect(cx <= 4_572_000); #expect(cy <= 3_429_000)
            let result = ConverterResult(sections:[.init(kind:.image,markdown:"",sourcePath:"image.png",metadata:["base64":data.base64EncodedString(),"mimeType":"image/png"])])
            let document = try xml(PicoDocsEngine.write(result,to:.docx),"word/document.xml")
            #expect(document.contains("<wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/>"))
            #expect(document.contains("<a:ext cx=\"\(cx)\" cy=\"\(cy)\"/>"))
        }
    }
    #endif

    @Test func exportedWordFragmentsSurviveImportAndSecondExport() async throws {
        let source = "[Details](#details) [Again](#details-1)\n\n# Details\n\n# Details"
        let first = try PicoDocsEngine.write(markdown:source,to:.docx)
        let recovered = try await PicoDocsEngine.convert(data:first,filename:"anchors.docx")
        #expect(recovered.markdown().contains("[Details](#details)"))
        #expect(recovered.markdown().contains("[Again](#details-1)"))
        let second = try xml(PicoDocsEngine.write(recovered,to:.docx),"word/document.xml")
        #expect(second.contains(#"w:anchor="heading_1""#)); #expect(second.contains(#"w:anchor="heading_2""#))
    }

    @Test func presentationFragmentsBecomeInternalSlideJumps() throws {
        let source = "# Start\n\n[Details](#details) [again](#details-1) [missing](#absent)\n\n# Details\n\nFirst\n\n# Details\n\nSecond"
        let data = try PicoDocsEngine.write(markdown:source,to:.pptx)
        let slide = try xml(data,"ppt/slides/slide1.xml")
        #expect(slide.components(separatedBy:#"action="ppaction://hlinksldjump""#).count - 1 == 2)
        let relationships = try xml(data,"ppt/slides/_rels/slide1.xml.rels")
        #expect(relationships.contains(#"/slide" Target="slide2.xml""#))
        #expect(relationships.contains(#"/slide" Target="slide3.xml""#))
        #expect(!relationships.contains("External")); #expect(!relationships.contains("#"))
    }

    @Test func mixedEmphasisClosesPastUnmatchedFrames() {
        #expect(MarkdownInlineParser.parse("*foo _bar* baz_") == [.emphasis([.text("foo _bar")]),.text(" baz_")])
        #expect(MarkdownInlineParser.parse("_foo *bar_ baz*") == [.emphasis([.text("foo *bar")]),.text(" baz*")])
        #expect(MarkdownInlineParser.parse("**foo _bar** baz_") == [.strong([.text("foo _bar")]),.text(" baz_")])
    }

    @Test func worksheetNamesSurviveOfficeProjection() throws {
        let result = ConverterResult(sections:[.init(title:"Ignored",kind:.sheet,markdown:"## A *literal*\n\nOne",metadata:["sheetName":"A *literal*","csv":"One"]),.init(title:"Second",kind:.sheet,markdown:"## Second\n\nTwo",metadata:["csv":"Two"])])
        let word = try xml(PicoDocsEngine.write(result,to:.docx),"word/document.xml")
        #expect(word.contains("A *literal*")); #expect(word.contains("Second"))
        let slides = try PicoDocsEngine.write(result,to:.pptx)
        #expect(try xml(slides,"ppt/slides/slide1.xml").contains("A *literal*"))
        #expect(try xml(slides,"ppt/slides/slide2.xml").contains("Second"))
        #if canImport(AppKit) || canImport(UIKit)
        let attributed = AttributedStringDocumentBuilder.attributedString(from:result).string
        #expect(attributed.contains("A *literal*")); #expect(attributed.contains("Second"))
        #endif
    }

    @Test func looseListParagraphsRetainTheirItemAndNesting() throws {
        let source = "- parent\n  - first\n\n    continuation"
        let blocks = MarkdownBlockParser.parse(source)
        guard case .list(let list) = try #require(blocks.first) else { Issue.record("Expected list"); return }
        let paragraphs = list.paragraphs()
        #expect(paragraphs.count == 3)
        #expect(paragraphs.last?.continuation == true); #expect(paragraphs.last?.level == 1)
        let word = try xml(PicoDocsEngine.write(markdown:source,to:.docx),"word/document.xml")
        #expect(word.contains("continuation")); #expect(word.contains(#"w:left="1440""#))
        let slide = try xml(PicoDocsEngine.write(markdown:source,to:.pptx),"ppt/slides/slide1.xml")
        #expect(slide.contains(#"<a:pPr lvl="1"><a:buNone/></a:pPr>"#))
    }

    @Test func innerLinkDeactivatesOuterLinkWithoutNestedHyperlinks() throws {
        let source = "[outer [inner](https://inner.test)](https://outer.test)"
        #expect(MarkdownInlineParser.parse(source) == [.text("[outer "),.link(label:[.text("inner")],destination:"https://inner.test"),.text("](https://outer.test)")])
        let word = try PicoDocsEngine.write(markdown:source,to:.docx)
        #expect(try xml(word,"word/document.xml").components(separatedBy:"<w:hyperlink ").count - 1 == 1)
        #expect(!(try xml(word,"word/_rels/document.xml.rels")).contains("https://outer.test"))
        #expect(MarkdownInlineParser.parse("[**text** ![alt](image.png)](url)") == [.link(label:[.strong([.text("text")]),.text(" "),.image(alt:"alt",source:"image.png")],destination:"url")])
    }

    @Test func underscoreEmphasisUsesFlankingAndPreservesIdentifiers() throws {
        #expect(MarkdownInlineParser.parse("_italic_") == [.emphasis([.text("italic")])])
        #expect(MarkdownInlineParser.parse("__bold__") == [.strong([.text("bold")])])
        #expect(MarkdownInlineParser.parse("_**both**_") == [.emphasis([.strong([.text("both")])])])
        #expect(MarkdownInlineParser.parse("foo_bar_baz foo__bar__baz").plainText == "foo_bar_baz foo__bar__baz")
        #expect(MarkdownInlineParser.parse(#"\_literal\_"#) == [.text("_literal_")])
        let document = try xml(PicoDocsEngine.write(markdown:"_italic_ __bold__",to:.docx),"word/document.xml")
        #expect(document.contains("<w:i/>")); #expect(document.contains("<w:b/>"))
        let slide = try xml(PicoDocsEngine.write(markdown:"_italic_ __bold__",to:.pptx),"ppt/slides/slide1.xml")
        #expect(slide.contains(#"i="1""#)); #expect(slide.contains(#"b="1""#))
    }

    @Test func bracketedLinkLabelsAndLiteralCodeClosers() {
        #expect(MarkdownInlineParser.parse("[API [v2]](https://example.com)") == [.link(label:[.text("API [v2]")],destination:"https://example.com")])
        #expect(MarkdownInlineParser.parse("![API [v2]](image.png)") == [.image(alt:"API [v2]",source:"image.png")])
        #expect(MarkdownInlineParser.parse("[API `]` v2](url)") == [.link(label:[.text("API "),.code("]"),.text(" v2")],destination:"url")])
        // CommonMark 0.31.2 example 338: backslashes cannot escape a code closer.
        #expect(MarkdownInlineParser.parse(#"`open\` tail"#) == [.code("open\\"),.text(" tail")])
        #expect(MarkdownInlineParser.parse(#"\`open\` tail"#) == [.text("`open` tail")])
        #expect(MarkdownInlineParser.parse("[not a `link](/foo`)") == [.text("[not a "),.code("link](/foo"),.text(")")])
    }

    @Test func blankSlidesAndNestedContinuationsRetainStructure() throws {
        let blank = ConverterResult(sections:[.init(kind:.slide,markdown:"",slideNumber:1),.init(kind:.slide,markdown:"",slideNumber:3)])
        let deck = try PicoDocsEngine.write(blank,to:.pptx)
        #expect(try xml(deck,"ppt/presentation.xml").components(separatedBy:"<p:sldId ").count - 1 == 3)
        let slide = try xml(PicoDocsEngine.write(markdown:"- parent\n  - child\n    - grandchild\n    continuation",to:.pptx),"ppt/slides/slide1.xml")
        #expect(slide.contains(#"<a:pPr lvl="1"><a:buNone/></a:pPr>"#))
        #expect(slide.contains("continuation"))
    }

    @Test func documentFragmentLinksTargetUniqueHeadingBookmarks() throws {
        let source = "[Details](#details) [second](#details-1) [unicode](#caf%C3%A9) [missing](#unknown)\n\n# Details\n\n## Details\n\n# Café"
        let data = try PicoDocsEngine.write(markdown:source,to:.docx)
        let document = try xml(data,"word/document.xml")
        for index in 1...3 {
            #expect(document.contains("<w:hyperlink w:anchor=\"heading_\(index)\">"))
            #expect(document.contains("w:name=\"heading_\(index)\""))
        }
        #expect(document.components(separatedBy:"<w:bookmarkStart ").count - 1 == 3)
        #expect(document.components(separatedBy:"<w:bookmarkEnd ").count - 1 == 3)
        #expect(!(try xml(data,"word/_rels/document.xml.rels")).contains("/hyperlink"))
        #expect(document.contains("missing"))
    }

    @Test func emptyWorksheetsSurviveTranscoding() async throws {
        for includeData in [false,true] {
            var sections = [DocumentSection(title:"Template",kind:.sheet,markdown:"")]
            if includeData { sections.append(.init(title:"Data",kind:.sheet,markdown:"Value")) }
            let first = try PicoDocsEngine.write(ConverterResult(sections:sections),to:.xlsx)
            let second = try await PicoDocsEngine.transcode(data:first,filename:"empty.xlsx",to:.xlsx,sanitizeUnicode:true)
            let workbook = try xml(second,"xl/workbook.xml")
            #expect(workbook.contains(#"name="Template""#))
            if includeData { #expect(workbook.contains(#"name="Data""#)) }
        }
    }

    @Test func spreadsheetWhitespaceSurvivesEveryOfficeProjection() async throws {
        let result = ConverterResult(sections:[.init(title:"Data",kind:.sheet,markdown:"lossy placeholder",metadata:["csv":"\"  first\nsecond  \""])])
        let xlsx = try PicoDocsEngine.write(result,to:.xlsx)
        let recovered = try await PicoDocsEngine.convert(data:xlsx,filename:"spaces.xlsx")
        let docx = try xml(PicoDocsEngine.write(recovered,to:.docx),"word/document.xml")
        #expect(docx.contains(">  first</w:t>")); #expect(docx.contains(">second  </w:t>")); #expect(docx.contains("<w:br/>"))
        let pptx = try xml(PicoDocsEngine.write(recovered,to:.pptx),"ppt/slides/slide1.xml")
        #expect(pptx.contains(#"<a:t xml:space="preserve">  first</a:t>"#))
        #expect(pptx.contains(#"<a:t xml:space="preserve">second  </a:t>"#)); #expect(pptx.contains("<a:br/>"))
        #if canImport(AppKit) || canImport(UIKit)
        #expect(AttributedStringDocumentBuilder.attributedString(from:recovered).string.contains("  first\nsecond  "))
        #endif
    }

    @Test func recoveryAndSynthesizedImagesKeepSlideOrder() throws {
        let recovery = ConverterResult(sections:[.init(kind:.body,markdown:"Recovered first"),.init(kind:.table,markdown:"| Table |\n| --- |",slideNumber:1)])
        let data = try PicoDocsEngine.write(recovery,to:.pptx)
        #expect(try xml(data,"ppt/slides/slide1.xml").contains("Recovered first"))
        #expect(try xml(data,"ppt/slides/slide2.xml").contains("Table"))
        let image = DocumentSection(title:"Image alt",kind:.image,markdown:"",sourcePath:"image.png",slideNumber:1,metadata:["mimeType":"image/png","base64":"AQID"])
        let deck = try PicoDocsEngine.write(ConverterResult(sections:[.init(kind:.slide,markdown:"",slideNumber:1),image]),to:.pptx)
        #expect(try xml(deck,"ppt/slides/slide1.xml").contains("Image alt"))
        #expect(try xml(deck,"ppt/presentation.xml").components(separatedBy:"<p:sldId ").count - 1 == 1)
    }

    @Test func numberingAndCodeRunPropertiesUseSchemaOrder() throws {
        let data = try PicoDocsEngine.write(markdown:"- Bullet\n\n1. Ordered\n\n***`code`***",to:.docx)
        let numbering = try SwiftSoup.parse(xml(data,"word/numbering.xml"),"",SwiftSoup.Parser.xmlParser())
        let names = try #require(numbering.getElementsByTag("w:numbering").first()).children().array().map { $0.tagName().lowercased() }
        #expect(names == ["w:abstractnum","w:abstractnum","w:num","w:num"])
        let document = try SwiftSoup.parse(xml(data,"word/document.xml"),"",SwiftSoup.Parser.xmlParser())
        let props = try #require(document.getElementsByTag("w:rPr").first { (try? $0.getElementsByTag("w:rStyle").isEmpty()) == false })
        #expect(props.children().array().map { $0.tagName().lowercased() } == ["w:rstyle","w:rfonts","w:b","w:i"])
    }

    @Test func tableCellsDoNotShareInlineDelimitersAndCodeKeepsSpaces() throws {
        let result = ConverterResult(sections:[.init(markdown:"| *open | close* |\n| --- | --- |")])
        let slide = try xml(PicoDocsEngine.write(result,to:.pptx),"ppt/slides/slide1.xml")
        #expect(slide.contains("*open")); #expect(slide.contains("close*")); #expect(!slide.contains(#"i="1""#))
        let code = try xml(PicoDocsEngine.write(markdown:"```\n  x  \n```",to:.pptx),"ppt/slides/slide1.xml")
        #expect(code.contains(#"<a:t xml:space="preserve">  x  </a:t>"#))
        #if canImport(AppKit) || canImport(UIKit)
        #expect(AttributedStringDocumentBuilder.attributedString(from:result).string.contains("*open\tclose*"))
        #endif
    }

    @Test func decodedAnglesInImageNamesStayBoundToCarriers() async throws {
        let document = #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body><w:p><w:r><w:drawing><a:blip r:embed="image"/></w:drawing></w:r></w:p></w:body></w:document>"#
        let rels = #"<Relationships><Relationship Id="image" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/a%3Eb%20c.png"/></Relationships>"#
        let data = PagesConverterTests.makeZip([(name:"word/document.xml",data:Array(document.utf8)),(name:"word/_rels/document.xml.rels",data:Array(rels.utf8)),(name:"word/media/a>b c.png",data:[1,2,3])])
        let result = try await PicoDocsEngine.convert(data:data,filename:"angle.docx")
        #expect(try xml(PicoDocsEngine.write(result,to:.docx),"word/document.xml").contains("<w:drawing>"))
        #expect(!((try xml(PicoDocsEngine.write(result,to:.pptx),"ppt/slides/slide1.xml")).contains("a&gt;b c.png")))
    }

    @Test func CSVUsesTheSharedFenceGrammar() throws {
        for (markdown, expected) in [("~~~\na|b\n~~~","a|b"),("````\na|b\n```\nc|d\n````","a|b\n```\nc|d")] {
            let output = try DocumentRenderer.render(ConverterResult(sections:[.init(markdown:markdown)]),to:.csv)
            #expect(output == expected)
        }
    }

    @Test func customExportersReceiveCanonicalImageSections() throws {
        struct InspectingExporter: DocumentExporter {
            func accepts(_ format: ExportableFileType) -> Bool { true }
            func write(_ result: ConverterResult, format: ExportableFileType) throws -> Data {
                #expect(result.sections.count == 3)
                #expect(result.sections.allSatisfy { $0.kind == .image && $0.markdown.isEmpty })
                #expect(result.sections.map(\.sourcePath) == ["same.png","same.png",nil])
                return Data([42])
            }
        }
        let images = ["same.png","same.png",nil].map { name in DocumentSection(kind:.image,markdown:"",sourcePath:name,metadata:["base64":"AQID"]) }
        let registry = DocumentExporterRegistry.default.registering(InspectingExporter(),priority:DocumentExporterRegistry.Priority.override)
        #expect(try PicoDocsEngine.write(ConverterResult(sections:images),to:.docx,registry:registry) == Data([42]))
    }

    @Test func mediaNamesAreUniqueIgnoringCase() throws {
        let images = ["logo.png","Logo.png"].map { name in DocumentSection(kind:.image,markdown:"",sourcePath:name,metadata:["mimeType":"image/png","base64":"AQID"]) }
        let data = try PicoDocsEngine.write(ConverterResult(sections:images),to:.docx)
        let archive = try #require(Archive(data:data,accessMode:.read))
        let names = archive.filter { $0.path.hasPrefix("word/media/") }.map { $0.path.lowercased() }
        #expect(names.count == 2); #expect(Set(names).count == 2)
    }

    @Test func percentTripletsInImageNamesAreDecodedOnce() async throws {
        for filename in ["sales%20chart.png", "literal%2Fname.png", "double%2520name.png"] {
            let image = DocumentSection(kind: .image, markdown: "", sourcePath: filename, metadata: ["mimeType": "image/png", "base64": Data([1,2,3]).base64EncodedString()])
            let first = try PicoDocsEngine.write(ConverterResult(sections: [image]), to: .docx)
            let recovered = try await PicoDocsEngine.convert(data: first, filename: "images.docx")
            let carrier = try #require(recovered.sections.first { $0.kind == .image })
            #expect(carrier.sourcePath?.hasSuffix(filename) == true)
            #expect(carrier.metadata["base64"] == Data([1,2,3]).base64EncodedString())
            let second = try PicoDocsEngine.write(recovered, to: .docx)
            #expect(try xml(second, "word/document.xml").contains("<w:drawing>"))
        }
    }

    @Test func entirelyEmptyNamedWorkbookCanBeWritten() throws {
        let result = ConverterResult(sections: [.init(title: "Template", kind: .sheet, markdown: "")])
        let data = try PicoDocsEngine.write(result, to: .xlsx)
        #expect(try xml(data, "xl/workbook.xml").contains(#"name="Template""#))
        #expect(try xml(data, "xl/worksheets/sheet1.xml").contains("<sheetData>"))
        #expect(try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml").contains("Template"))
    }

    @Test func emphasizedCodeAndFencedCodeFonts() async throws {
        let data = try PicoDocsEngine.write(markdown: "**`bold`** *`italic`* ***`both`***", to: .docx)
        let recovered = try await PicoDocsEngine.convert(data: data, filename: "code.docx")
        #expect(recovered.markdown().contains("**`bold`**"))
        #expect(recovered.markdown().contains("*`italic`*"))
        #expect(recovered.markdown().contains("***`both`***"))
        let pptx = try PicoDocsEngine.write(markdown: "```swift\nlet x = 1\nprint(x)\n```", to: .pptx)
        let slide = try xml(pptx, "ppt/slides/slide1.xml")
        #expect(slide.components(separatedBy: "Courier New").count - 1 == 2)
    }

    @Test func imageLabelsAndWhitespacePaths() throws {
        #expect(MarkdownInlineParser.parse("![**Bold** and `code`](image.png)") == [.image(alt: "Bold and code", source: "image.png")])
        let image = DocumentSection(title: "**literal**", kind: .image, markdown: "", sourcePath: "assets/company logo.png", metadata: ["mimeType": "image/png", "base64": Data([1,2,3]).base64EncodedString()])
        for format in [ExportableFileType.docx, .pptx] {
            let data = try PicoDocsEngine.write(ConverterResult(sections: [image]), to: format)
            let part = try xml(data, format == .docx ? "word/document.xml" : "ppt/slides/slide1.xml")
            if format == .docx { #expect(part.contains("<w:drawing>")) }
            if format == .pptx { #expect(!part.contains("company logo.png")) }
            #expect(part.contains("**literal**"))
        }
    }

    @Test func importedImagesKeepPackageIdentity() async throws {
        let namespaces = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main""#
        let document = "<w:document \(namespaces)><w:body><w:p>" + ["a","b"].map { "<w:r><w:drawing><a:blip r:embed=\"\($0)\"/></w:drawing></w:r>" }.joined() + "</w:p></w:body></w:document>"
        let rels = #"<Relationships><Relationship Id="a" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/charts/logo.png"/><Relationship Id="b" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/headers/logo.png"/></Relationships>"#
        let data = PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/_rels/document.xml.rels", data: Array(rels.utf8)), (name: "word/media/charts/logo.png", data: [1]), (name: "word/media/headers/logo.png", data: [2])])
        let result = try await PicoDocsEngine.convert(data: data, filename: "images.docx")
        #expect(result.markdown().contains("word/media/charts/logo.png")); #expect(result.markdown().contains("word/media/headers/logo.png"))
        let output = try PicoDocsEngine.write(result, to: .docx)
        #expect(try xml(output, "word/document.xml").components(separatedBy: "<w:drawing>").count - 1 == 2)
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("base64,AQ==")); #expect(html.contains("base64,Ag=="))
    }

    @Test func tableBlockStylesAndContentControlsRemainStructural() async throws {
        let ns = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main""#
        let cells = ["Heading1","Quote","PicoCodeBlock"].map { "<w:tc><w:p><w:pPr><w:pStyle w:val=\"\($0)\"/></w:pPr><w:r><w:t>Cell \($0)</w:t></w:r></w:p></w:tc>" }.joined()
        func item(_ text: String, level: Int) -> String { "<w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/><w:ilvl w:val=\"\(level)\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>" }
        let document = "<w:document \(ns)><w:body><w:tbl><w:tr>\(cells)</w:tr></w:tbl>" + item("Parent", level: 0) + "<w:sdt><w:sdtContent>" + item("Child", level: 1) + "</w:sdtContent></w:sdt>" + item("Next", level: 0) + "</w:body></w:document>"
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:numFmt w:val=\"decimal\"/></w:lvl><w:lvl w:ilvl=\"1\"><w:numFmt w:val=\"bullet\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8))]), filename: "structure.docx")
        #expect(result.markdown().contains("| Cell Heading1 | Cell Quote | Cell PicoCodeBlock |"))
        #expect(result.markdown().contains("1. Parent\n   - Child\n2. Next"))
        let output = try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml")
        #expect(output.contains(#"<w:ilvl w:val="1"/>"#)); #expect(!output.contains("# Cell")); #expect(!output.contains("&gt; Cell")); #expect(!output.contains("```"))
    }

    @Test func emptyListItemsRoundTrip() async throws {
        for source in ["-", "2.", "- first\n-\n- third"] {
            let result = try await PicoDocsEngine.convert(data: PicoDocsEngine.write(markdown: source, to: .docx), filename: "empty-item.docx")
            let second = try PicoDocsEngine.write(result, to: .docx)
            let count = try xml(second, "word/document.xml").components(separatedBy: "<w:numPr>").count - 1
            #expect(count == (source.contains("first") ? 3 : 1))
        }
    }

    @Test func spreadsheetTokensAndLiteralCrossFormatCells() async throws {
        let literal = "*value* [label](url) _x000A_ _x005F_"
        let source = ConverterResult(sections: [.init(kind: .sheet, markdown: "", metadata: ["csv": literal])])
        let xlsx = try PicoDocsEngine.write(source, to: .xlsx)
        let worksheet = try xml(xlsx, "xl/worksheets/sheet1.xml")
        #expect(worksheet.contains("_x005F_x000A_ _x005F_x005F_"))
        let result = try await PicoDocsEngine.convert(data: xlsx, filename: "tokens.xlsx")
        #expect(result.sections.first?.metadata["csv"] == "\"" + literal + "\"")
        for (format,path,tag) in [(ExportableFileType.docx,"word/document.xml","w:t"),(.pptx,"ppt/slides/slide1.xml","a:t")] {
            let content = try xml(PicoDocsEngine.write(result, to: format), path)
            let parsed = try SwiftSoup.parse(content, "", SwiftSoup.Parser.xmlParser())
            let visible = try parsed.getElementsByTag(tag).array().map { $0.getChildNodes().compactMap { ($0 as? TextNode)?.getWholeText() }.joined() }.joined()
            #expect(visible.contains(literal)); #expect(!content.contains("hyperlink")); #expect(!content.contains("hlinkClick"))
        }
        #expect(SpreadsheetMLText.decode(SpreadsheetMLText.encode("_x000A_\u{1}😀")) == "_x000A_\u{1}😀")
    }

    @Test func codeTypefaceSoftBreaksAndHyperlinkTargets() throws {
        let code = try xml(PicoDocsEngine.write(markdown: "Use **[`code`](https://example.com)** here", to: .pptx), "ppt/slides/slide1.xml")
        #expect(code.contains(#"<a:rPr b="1"><a:latin typeface="Courier New"/><a:hlinkClick"#))
        for (format,path,tag) in [(ExportableFileType.docx,"word/document.xml","w:t"),(.pptx,"ppt/slides/slide1.xml","a:t")] {
            let content = try xml(PicoDocsEngine.write(markdown: "one \ntwo", to: format), path)
            let parsed = try SwiftSoup.parse(content, "", SwiftSoup.Parser.xmlParser())
            let visible = try parsed.getElementsByTag(tag).array().map { $0.getChildNodes().compactMap { ($0 as? TextNode)?.getWholeText() }.joined() }.joined()
            #expect(visible == "one two")
        }
        #if canImport(AppKit)
        let attributed = AttributedStringDocumentBuilder.attributedString(from: ConverterResult(sections: [.init(markdown: "one \ntwo")]))
        #expect(attributed.string.trimmingCharacters(in: .whitespacesAndNewlines) == "one two")
        #endif
        #expect(MarkdownInlineParser.parse("[^docs](https://example.com)") == [.link(label: [.text("^docs")], destination: "https://example.com")])
        for (raw,escaped) in [("100%","100%25"),("%ZZ","%25ZZ"),("a%20b","a%20b")] {
            for (format,path) in [(ExportableFileType.docx,"word/_rels/document.xml.rels"),(.pptx,"ppt/slides/_rels/slide1.xml.rels")] {
                let rels = try xml(PicoDocsEngine.write(markdown: "[^docs](https://example.test/" + raw + ")", to: format), path)
                #expect(rels.contains("https://example.test/" + escaped))
            }
        }
    }

    @Test func sparseSpreadsheetCoordinatesSurviveOfficeRoundTrip() async throws {
        let base = try PicoDocsEngine.write(markdown: "| A | B | C |\n| --- | --- |", to: .xlsx)
        let archive = try #require(Archive(data: base, accessMode: .read))
        let worksheet = #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>First</t></is></c><c r="C1" t="inlineStr"><is><t>Third</t></is></c></row><row r="3"><c r="B3" t="inlineStr"><is><t>Middle</t></is></c></row></sheetData></worksheet>"#
        var entries: [(name: String, data: [UInt8])] = []
        for entry in archive {
            var bytes = Data(); _ = try archive.extract(entry) { bytes.append($0) }
            entries.append((entry.path, entry.path == "xl/worksheets/sheet1.xml" ? Array(worksheet.utf8) : Array(bytes)))
        }
        let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip(entries), filename: "sparse.xlsx")
        #expect(result.sections.first?.metadata["csv"] == "\"First\",\"\",\"Third\"\n\"\",\"\",\"\"\n\"\",\"Middle\",\"\"")
        let output = try xml(PicoDocsEngine.write(result, to: .xlsx), "xl/worksheets/sheet1.xml")
        #expect(output.contains(#"r="C1" t="inlineStr"><is><t xml:space="preserve">Third"#))
        #expect(output.contains(#"r="B3" t="inlineStr"><is><t xml:space="preserve">Middle"#))
    }

    @Test func inlineSentinelsAndOptionalLinkTitlesStayDistinct() throws {
        for source in ["\u{E020}0\u{E021} `code`", "\u{E010}0\u{E011} \\*"] {
            let expected = source.replacingOccurrences(of: "`code`", with: "code").replacingOccurrences(of: "\\*", with: "*")
            #expect(MarkdownInlineParser.parse(source).plainText == expected)
            let document = try SwiftSoup.parse(xml(PicoDocsEngine.write(markdown: source, to: .docx), "word/document.xml"), "", SwiftSoup.Parser.xmlParser())
            let visible = try document.getElementsByTag("w:t").array().map { $0.getChildNodes().compactMap { ($0 as? TextNode)?.getWholeText() }.joined() }.joined()
            #expect(visible == expected)
        }
        for source in [#"[Label](https://example.com "Home")"#, #"[Label](<https://example.com> "Home")"#, #"[Label](https://example.com 'Home')"#, #"[Label](https://example.com (Home))"#, #"[Label](https://example.com/a_(b) "Home (extra)")"#] {
            let nodes = MarkdownInlineParser.parse(source)
            let expected = source.contains("a_(b)") ? "https://example.com/a_(b)" : "https://example.com"
            #expect(nodes == [.link(label: [.text("Label")], destination: expected)])
            for (format, path) in [(ExportableFileType.docx, "word/_rels/document.xml.rels"), (.pptx, "ppt/slides/_rels/slide1.xml.rels")] {
                let rels = try xml(PicoDocsEngine.write(markdown: source, to: format), path)
                #expect(rels.contains(expected)); #expect(!rels.contains("Home"))
            }
        }
    }

    @Test func literalWordRunsSurviveOfficeTranscoding() async throws {
        let literals = [#"[label](https://example.com) *stars* `code` ![image](x) \*"#, "# Heading", "1. List", "- Bullet", "---"]
        let paragraphs = literals.map { "<w:p><w:r><w:t>" + $0 + "</w:t></w:r></w:p>" }.joined()
        let document = #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>"# + paragraphs + "</w:body></w:document>"
        let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8))]), filename: "literal.docx")
        let exported = try PicoDocsEngine.write(result, to: .docx)
        let output = try xml(exported, "word/document.xml")
        #expect(!output.contains("<w:hyperlink")); #expect(!output.contains("<w:numPr>")); #expect(!output.contains("<w:drawing>"))
        for literal in literals { #expect(output.contains(literal)) }
        let recovered = try await PicoDocsEngine.convert(data: exported, filename: "again.docx")
        let plain = try DocumentRenderer.render(recovered, to: .plaintext)
        for literal in literals { #expect(plain.contains(literal)) }
    }

    @Test func titleOnlySlidesAndPathQualifiedTitleImages() throws {
        let slide = ConverterResult(sections: [.init(title: "Agenda", kind: .slide, markdown: "", slideNumber: 1)])
        #expect(try xml(PicoDocsEngine.write(slide, to: .pptx), "ppt/slides/slide1.xml").contains(">Agenda</a:t>"))
        let images = ConverterResult(sections: ["charts/logo.png", "headers/logo.png"].enumerated().map { index, title in
            .init(title: title, kind: .image, markdown: "", metadata: ["base64": Data([UInt8(index + 1)]).base64EncodedString(), "mimeType": "image/png"])
        })
        let docx = try PicoDocsEngine.write(images, to: .docx)
        #expect(try xml(docx, "word/document.xml").components(separatedBy: "<w:drawing>").count - 1 == 2)
        let archive = try #require(Archive(data: docx, accessMode: .read))
        #expect(archive.filter { $0.path.hasPrefix("word/media/") }.count == 2)
    }

    @Test func listContinuationHardBreaksAndItalicCode() throws {
        let source = "- first\n  second  \n  third"
        let docx = try PicoDocsEngine.write(markdown: source, to: .docx)
        #expect(try xml(docx, "word/document.xml").contains("<w:br/>"))
        let pptx = try PicoDocsEngine.write(markdown: source, to: .pptx)
        #expect(try xml(pptx, "ppt/slides/slide1.xml").contains("first second</a:t></a:r><a:br/>"))
        #if canImport(AppKit)
        for source in ["*`code`*", "***`code`***"] {
            let string = AttributedStringDocumentBuilder.attributedString(from: ConverterResult(sections: [.init(markdown: source)]))
            let font = try #require(string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            #expect(font.fontDescriptor.symbolicTraits.contains(.italic))
            #expect(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
            if source.hasPrefix("***") { #expect(font.fontDescriptor.symbolicTraits.contains(.bold)) }
        }
        let list = AttributedStringDocumentBuilder.attributedString(from: ConverterResult(sections: [.init(markdown: source)]))
        #expect(list.string.contains("first second\nthird"))
        #endif
    }

    @Test func importedSheetValuesHaveLosslessRoundTripCarrier() async throws {
        let csv = #""*value*","`code`","[label](url)","\*literal\*"," edge ","line"# + "\r\nbreak\""
        let original = ConverterResult(sections: [.init(title: "`Code`", kind: .sheet, markdown: "", metadata: ["csv": csv])])
        let first = try PicoDocsEngine.write(original, to: .xlsx)
        let recovered = try await PicoDocsEngine.convert(data: first, filename: "literal.xlsx")
        #expect(recovered.sections.first?.metadata["csv"] == csv)
        let second = try PicoDocsEngine.write(recovered, to: .xlsx)
        #expect(try xml(second, "xl/worksheets/sheet1.xml") == xml(first, "xl/worksheets/sheet1.xml"))
        #expect(try DocumentRenderer.render(recovered, to: .csv) == csv)
        let echoed = ConverterResult(sections: [.init(title: "`Code`", kind: .sheet, markdown: "## `Code`\n\n| Value |\n| --- |\n| Actual |")])
        let sheet = try xml(PicoDocsEngine.write(echoed, to: .xlsx), "xl/worksheets/sheet1.xml")
        #expect(sheet.components(separatedBy: "<row ").count - 1 == 2)
        #expect(!sheet.contains(">Code</t>"))
    }

    @Test func canonicalLineEndingsFencesAndTabMarkers() throws {
        let expected: [MarkdownBlock] = [.heading(1, "Title"), .code("code"), .paragraph("after")]
        for newline in ["\r\n", "\r", "\n"] {
            #expect(MarkdownBlockParser.parse(["# Title", "", "```", "code", "```", "after"].joined(separator: newline)) == expected)
        }
        for source in ["~~~\n[^n]: literal\n~~~", "````\n```\n[^n]: literal\n````"] {
            for format in [ExportFileType.html, .plaintext] {
                let text = try DocumentRenderer.render(ConverterResult(sections: [.init(markdown: source)]), to: format)
                #expect(text.contains("[^n]: literal"))
            }
        }
        for marker in ["-", "*", "+", "2."] {
            let data = try PicoDocsEngine.write(markdown: marker + "\tfirst\n\tcontinued", to: .docx)
            #expect(try xml(data, "word/document.xml").contains("<w:numPr>"))
        }
        let sibling = try PicoDocsEngine.write(markdown: "- first\n - second", to: .pptx)
        #expect(try !xml(sibling, "ppt/slides/slide1.xml").contains(#"lvl="1""#))
    }

    @Test func inlineCodeNormalizesItsOwnSlideNewlines() throws {
        let data = try PicoDocsEngine.write(markdown: "`one\\\ntwo` and `one  \ntwo`\n\n- `list\\\n  continuation`", to: .pptx)
        let slide = try xml(data, "ppt/slides/slide1.xml")
        #expect(slide.contains(#">one\ two</a:t>"#))
        #expect(slide.contains(">one   two</a:t>"))
        #expect(!slide.contains("<a:br/>"))
        #expect(MarkdownInlineParser.parse(#"[x](<https://e.test/a\>b\~c>)"#) == [.link(label: [.text("x")], destination: "https://e.test/a>b~c")])
        let linked = try PicoDocsEngine.write(markdown: #"[x](<https://e.test/a\>b\~c>)"#, to: .docx)
        #expect(try xml(linked, "word/_rels/document.xml.rels").contains("https://e.test/a%3Eb~c"))
    }

    @Test func CSVCRLFRecordsAndCarriageReturnsStayLossless() throws {
        let csv = "A,B\r\n\"one\rtwo\",\"three\r\nfour\"\r\nlast,value"
        let result = ConverterResult(sections: [.init(kind: .sheet, markdown: "", metadata: ["csv": csv])])
        let sheet = try xml(PicoDocsEngine.write(result, to: .xlsx), "xl/worksheets/sheet1.xml")
        #expect(sheet.components(separatedBy: "<row ").count - 1 == 3)
        #expect(sheet.contains("one&#13;two"))
        #expect(sheet.contains("three&#13;\nfour"))
        #expect(sheet.contains(#"r="B3""#))
    }

    @Test func sheetNamesRespectUTF16BudgetAndGraphemeBoundaries() throws {
        let flag = "🇺🇸", family = "👨‍👩‍👧‍👦"
        let result = ConverterResult(sections: [flag, flag, family].map { .init(title: String(repeating: $0, count: 31), markdown: "value") })
        let workbook = try xml(PicoDocsEngine.write(result, to: .xlsx), "xl/workbook.xml")
        let document = try SwiftSoup.parse(workbook, "", SwiftSoup.Parser.xmlParser())
        let names = try document.getElementsByTag("sheet").array().map { try $0.attr("name") }
        #expect(names.count == 3)
        #expect(names.allSatisfy { $0.utf16.count <= 31 })
        #expect(names[0] == String(repeating: flag, count: 7))
        #expect(names[1] == String(repeating: flag, count: 6) + " (2)")
        #expect(names[2] == String(repeating: family, count: 2))
    }

    @Test func nestedEmphasisSharedClosersAndAllPunctuationEscapes() {
        #expect(MarkdownInlineParser.parse("**bold *italic***") == [.strong([.text("bold "), .emphasis([.text("italic")])])])
        #expect(MarkdownInlineParser.parse("*italic **bold***") == [.emphasis([.text("italic "), .strong([.text("bold")])])])
        #expect(MarkdownInlineParser.parse("**before *inside `code`* after**").plainText == "before inside code after")
        #expect(MarkdownInlineParser.parse(#"Cost: \$5, literal \~text\~ and \>"#).plainText == "Cost: $5, literal ~text~ and >")
        #expect(MarkdownInlineParser.parse(#"[\$5](https://example.com) and `\$5`"#).plainText == #"$5 and \$5"#)
    }

    @Test func slideHyperlinksNumberBoundsAndTabContinuations() throws {
        let source = "# [Title](https://example.com/title)\n\nVisit **[bold](https://example.com/a?x=1&y=2)**\n\n0. Zero\n32768. Large\n\n- first\n\tcontinued\n\t- [child](https://example.com/child)"
        let data = try PicoDocsEngine.write(markdown: source, to: .pptx)
        let slide = try xml(data, "ppt/slides/slide1.xml")
        let rels = try xml(data, "ppt/slides/_rels/slide1.xml.rels")
        #expect(slide.components(separatedBy: "<a:hlinkClick ").count - 1 == 3)
        #expect(slide.contains(#"<a:rPr b="1"><a:hlinkClick"#))
        #expect(rels.contains(#"Target="https://example.com/a?x=1&amp;y=2" TargetMode="External""#))
        #expect(rels.contains("/title")); #expect(rels.contains("/child"))
        #expect(!slide.contains(#"startAt="0""#)); #expect(!slide.contains(#"startAt="32768""#))
        #expect(slide.contains(">0. </a:t>")); #expect(slide.contains(">32768. </a:t>"))
        #expect(slide.contains(">first continued</a:t>"))
        #expect(slide.contains(#"<a:pPr lvl="1"><a:buChar"#))
        let docx = try PicoDocsEngine.write(markdown: "- first\n\tcontinued", to: .docx)
        let document = try xml(docx, "word/document.xml")
        #expect(document.components(separatedBy: "<w:p>").count - 1 == 1)
        #expect(document.contains("continued"))
    }

    @Test func unsupportedMediaExtensionUsesKnownMIME() throws {
        let image = DocumentSection(kind: .image, markdown: "", sourcePath: "avatar.dat", metadata: ["base64": "AQID", "mimeType": "image/png"])
        let data = try PicoDocsEngine.write(ConverterResult(sections: [.init(markdown: "![Avatar](avatar.dat)"), image]), to: .docx)
        let archive = try #require(Archive(data: data, accessMode: .read))
        #expect(archive["word/media/avatar.png"] != nil)
        #expect(archive["word/media/avatar.dat"] == nil)
        #expect(try xml(data, "[Content_Types].xml").contains(#"Extension="png" ContentType="image/png""#))
    }

    @Test func structuredEmphasisFlankingAndLiteralPaths() {
        #expect(MarkdownInlineParser.parse("**before `code` after**") == [.strong([.text("before "), .code("code"), .text(" after")])])
        #expect(MarkdownInlineParser.parse("*see [link](https://example.com)*") == [.emphasis([.text("see "), .link(label: [.text("link")], destination: "https://example.com")])])
        #expect(MarkdownInlineParser.parse("2 * 3 * 4").plainText == "2 * 3 * 4")
        #expect(MarkdownInlineParser.parse(#"![x](C:\images\pic.png)"#) == [.image(alt: "x", source: #"C:\images\pic.png"#)])
    }

    @Test func listStartsAndNestingSurviveOfficeRoundTrips() async throws {
        let source = "3. Parent\n   1. Child\n      - Grandchild\n4. Next"
        var result = ConverterResult(sections: [.init(markdown: source)])
        for _ in 0..<2 {
            let docx = try PicoDocsEngine.write(result, to: .docx)
            let document = try xml(docx, "word/document.xml")
            #expect(document.contains(#"w:ilvl w:val="1""#))
            #expect(document.contains(#"w:ilvl w:val="2""#))
            #expect(try xml(docx, "word/numbering.xml").contains(#"w:startOverride w:val="3""#))
            result = try await PicoDocsEngine.convert(data: docx, filename: "nested.docx")
            #expect(result.markdown().contains("3. Parent\n   1. Child\n      - Grandchild\n4. Next"))
        }
        let pptx = try PicoDocsEngine.write(result, to: .pptx)
        let slide = try xml(pptx, "ppt/slides/slide1.xml")
        #expect(slide.contains(#"<a:pPr lvl="1"><a:buAutoNum type="arabicPeriod" startAt="1""#))
        #expect(slide.contains(#"startAt="3""#))
    }

    @Test func imagePathsCSVMetadataCellLimitsAndSlideGaps() throws {
        for (path, title, reference) in [(#"C:\images\pic.png"#, "pic.png", #"C:\images\pic.png"#), ("", "logo.png", "logo.png")] {
            let image = DocumentSection(title: title, kind: .image, markdown: "", sourcePath: path, metadata: ["base64": "AQID", "mimeType": "image/png"])
            let result = ConverterResult(sections: [.init(markdown: "![Image](\(reference))"), image])
            let data = try PicoDocsEngine.write(result, to: .docx)
            #expect(try xml(data, "word/document.xml").contains("<w:drawing>"))
            let archive = try #require(Archive(data: data, accessMode: .read))
            for entry in archive where entry.path.hasPrefix("word/media/") {
                #expect(!entry.path.contains("\\"))
                #expect(!entry.path.contains(":"))
            }
        }
        let csvOnly = ConverterResult(sections: [.init(kind: .sheet, markdown: "", metadata: ["csv": "A,B\n1,2"])])
        #expect(try xml(PicoDocsEngine.write(csvOnly, to: .xlsx), "xl/worksheets/sheet1.xml").contains(">A</t>"))
        #expect(throws: ExporterError.self) { try PicoDocsEngine.write(markdown: String(repeating: "x", count: 32_768), to: .xlsx) }
        let deck = ConverterResult(sections: [.init(kind: .slide, markdown: "Third", slideNumber: 3), .init(kind: .slide, markdown: "First", slideNumber: 1)])
        let pptx = try PicoDocsEngine.write(deck, to: .pptx)
        #expect(try xml(pptx, "ppt/slides/slide1.xml").contains("First"))
        #expect(try xml(pptx, "ppt/slides/slide2.xml").contains("<a:p/>"))
        #expect(try xml(pptx, "ppt/slides/slide3.xml").contains("Third"))
    }

    @Test func slideBreaksSpaceCodeAndTableNumbering() async throws {
        let pptx = try PicoDocsEngine.write(markdown: "first\nsecond\n\nfirst\\\nsecond", to: .pptx)
        let slide = try xml(pptx, "ppt/slides/slide1.xml")
        #expect(slide.contains("first second</a:t>"))
        #expect(slide.contains("first</a:t></a:r><a:br/><a:r><a:t>second"))
        var result = ConverterResult(sections: [.init(markdown: "` `")])
        for _ in 0..<3 {
            result = try await PicoDocsEngine.convert(data: PicoDocsEngine.write(result, to: .docx), filename: "space.docx")
            #expect(MarkdownInlineParser.parse(result.markdown()) == [.code(" ")])
        }
        let ns = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main""#
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:numFmt w:val=\"decimal\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        func paragraph(_ text: String) -> String { "<w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>" }
        let document = "<w:document \(ns)><w:body>" + paragraph("Before") + "<w:tbl><w:tr><w:tc>" + paragraph("Inside") + "</w:tc></w:tr></w:tbl>" + paragraph("After") + "</w:body></w:document>"
        let data = PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8))])
        let numbered = try await PicoDocsEngine.convert(data: data, filename: "table.docx").markdown()
        #expect(numbered.contains("2. Inside"))
        #expect(numbered.contains("3. After"))
    }

    @Test func completeCodeDelimitersAndMalformedDestinations() async throws {
        #expect(MarkdownInlineParser.parse("Use ``a`b`` now") == [.text("Use "), .code("a`b"), .text(" now")])
        #expect(MarkdownInlineParser.parse("`` `x` ``") == [.code("`x`")])
        let fenced = "````\n```\ncontent\n```\n````"
        #expect(MarkdownBlockParser.parse(fenced) == [.code("```\ncontent\n```")])
        #expect(MarkdownBlockParser.parse("~~~\n```\n~~~") == [.code("```")])
        let incomplete = String(repeating: "[](", count: 20_000)
        #expect(MarkdownInlineParser.parse(incomplete).plainText == incomplete)
        let markdown = "Use ``a`b`` now\n\n" + fenced
        let docx = try PicoDocsEngine.write(markdown: markdown, to: .docx)
        let recovered = try await PicoDocsEngine.convert(data: docx, filename: "code.docx")
        #expect(recovered.markdown().contains("``a`b``"))
        #expect(recovered.markdown().contains(fenced))
    }

    @Test func quotesListsSlideMarkersAndTitleImages() async throws {
        let source = "> Quoted\n\n1. Plan\n2. Ship\n\n- Bullet"
        let data = try PicoDocsEngine.write(markdown: source, to: .docx)
        let recovered = try await PicoDocsEngine.convert(data: data, filename: "roundtrip.docx")
        #expect(recovered.markdown().contains("> Quoted"))
        #expect(recovered.markdown().contains("1. Plan"))
        #expect(recovered.markdown().contains("2. Ship"))
        #expect(recovered.markdown().contains("- Bullet"))
        let second = try PicoDocsEngine.write(recovered, to: .docx)
        let reread = try await PicoDocsEngine.convert(data: second, filename: "second.docx")
        #expect(reread.markdown().contains("2. Ship"))
        let slide = try xml(PicoDocsEngine.write(markdown: source, to: .pptx), "ppt/slides/slide1.xml")
        #expect(slide.contains(#"<a:buAutoNum type="arabicPeriod" startAt="1"/>"#))
        #expect(slide.contains(#"<a:buAutoNum type="arabicPeriod" startAt="2"/>"#))
        #expect(slide.contains("<a:buChar"))
        let image = ConverterResult(sections: [.init(title: "icons/logo.png", kind: .image, markdown: "", metadata: ["base64": Data([1,2,3]).base64EncodedString(), "mimeType": "image/png"])])
        #expect(try xml(PicoDocsEngine.write(image, to: .docx), "word/document.xml").contains("<w:drawing>"))
    }

    @Test func sheetWhitespaceAndAttributedBreaks() throws {
        let sheets = ConverterResult(sections: ["A B", "A\nB", "A\tB", "A\rB"].map { .init(title: $0, kind: .sheet, markdown: "x") })
        let workbook = try xml(PicoDocsEngine.write(sheets, to: .xlsx), "xl/workbook.xml")
        #expect(workbook.components(separatedBy: #"name="A B""#).count == 2)
        #expect(workbook.contains(#"name="A B (2)""#))
        #if canImport(AppKit) || canImport(UIKit)
        let result = ConverterResult(sections: [.init(markdown: "first\nsecond\n\nfirst\\\nsecond\n\nfirst  \nsecond")])
        let text = AttributedStringDocumentBuilder.attributedString(from: result).string
        #expect(text.contains("first second"))
        #expect(text.components(separatedBy: "first\nsecond").count == 3)
        #expect(!text.contains("\\"))
        #endif
    }

    private func xml(_ data: Data, _ path: String) throws -> String {
        let archive = try #require(Archive(data: data, accessMode: .read))
        let entry = try #require(archive[path])
        var bytes = Data()
        _ = try archive.extract(entry) { bytes.append($0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    @Test func inlineLiteralEscapesFootnotesAndUnmatchedOpeners() {
        #expect(MarkdownInlineParser.parse(#"\*literal\*"#) == [.text("*literal*")])
        #expect(MarkdownInlineParser.parse(#"*a\*b*"#) == [.emphasis([.text("a*b")])])
        #expect(MarkdownInlineParser.parse(#"\[not a link](url)"#).plainText == "[not a link](url)")
        #expect(MarkdownInlineParser.parse("Claim[^1]\n[^1]: Source").plainText == "Claim[^1]\n[^1]: Source")
        let unfinished = String(repeating: "[^", count: 20_000)
        #expect(MarkdownInlineParser.parse(unfinished).plainText == unfinished)
    }

    @Test func docxStylesCodeAndHyperlinks() async throws {
        let markdown = "# Heading\n\n> Quote\n\nUse `x` here.\n\n```\n  let x = 1\nprint(x)\n```\n\n[Link](<https://example.com/a b?q=x y&v=1>)"
        let data = try PicoDocsEngine.write(markdown: markdown, to: .docx)
        let styles = try xml(data, "word/styles.xml")
        #expect(styles.contains(#"w:styleId="Heading1""#))
        #expect(styles.contains(#"w:styleId="Quote""#))
        #expect(styles.contains(#"w:styleId="PicoCodeBlock""#))
        let rels = try xml(data, "word/_rels/document.xml.rels")
        #expect(rels.contains("/styles"))
        #expect(rels.contains("https://example.com/a%20b?q=x%20y&amp;v=1"))
        let recovered = try await PicoDocsEngine.convert(data: data, filename: "out.docx")
        #expect(recovered.markdown().contains("Use `x` here."))
        #expect(recovered.markdown().contains("```\n  let x = 1\nprint(x)\n```"))
    }

    @Test func mediaIdentitySurvivesSecondExportAndReservedExtensions() async throws {
        for name in ["chart#1.png", "chart.xml", "chart.rels"] {
            let image = DocumentSection(kind: .image, markdown: "", sourcePath: name, metadata: ["mimeType": "image/png", "base64": Data([1, 2, 3]).base64EncodedString()])
            let first = try PicoDocsEngine.write(ConverterResult(sections: [image]), to: .docx)
            let recovered = try await PicoDocsEngine.convert(data: first, filename: "one.docx")
            let second = try PicoDocsEngine.write(recovered, to: .docx)
            #expect(try xml(second, "word/document.xml").contains("<w:drawing>"))
            let types = try xml(first, "[Content_Types].xml")
            #expect(types.components(separatedBy: #"Extension="xml""#).count == 2)
            #expect(types.components(separatedBy: #"Extension="rels""#).count == 2)
        }
    }

    @Test func emptyWorksheetsAndSpreadsheetLimits() throws {
        let sheets = ConverterResult(sections: [DocumentSection(title: "Empty", kind: .sheet, markdown: ""), DocumentSection(title: "Data", kind: .sheet, markdown: "Value")])
        let data = try PicoDocsEngine.write(sheets, to: .xlsx)
        let workbook = try xml(data, "xl/workbook.xml")
        #expect(workbook.contains(#"name="Empty""#))
        #expect(workbook.contains(#"name="Data""#))
        let oversized = ConverterResult(sections: [DocumentSection(markdown: "data", metadata: ["csv": Array(repeating: "x", count: 16_385).joined(separator: ",")])])
        #expect(throws: ExporterError.self) { try PicoDocsEngine.write(oversized, to: .xlsx) }
        #expect(throws: ExporterError.self) { try XLSXExporter.validateDimensions(rows: 1_048_577, columns: 1) }
        try XLSXExporter.validateDimensions(rows: 61, columns: 16_384)
    }

    @Test func metadataAndCanonicalTableBreaks() throws {
        let result = ConverterResult(title: "Review title", author: "Review author", sections: [DocumentSection(markdown: "| first<br>second |\n| --- |")])
        for format in [ExportableFileType.docx, .xlsx, .pptx] {
            let data = try PicoDocsEngine.write(result, to: format)
            let core = try xml(data, "docProps/core.xml")
            #expect(core.contains("<dc:title>Review title</dc:title>"))
            #expect(core.contains("<dc:creator>Review author</dc:creator>"))
            #expect(try xml(data, "_rels/.rels").contains("metadata/core-properties"))
        }
        let pptx = try PicoDocsEngine.write(result, to: .pptx)
        #expect(try xml(pptx, "ppt/slides/slide1.xml").contains("first</a:t></a:r><a:br/><a:r><a:t>second"))
        #if canImport(AppKit) || canImport(UIKit)
        let rtf = try PicoDocsEngine.write(result, to: .rtf)
        let text = String(decoding: rtf, as: UTF8.self)
        #expect(text.contains("Review title"))
        #expect(text.contains("Review author"))
        #expect(!text.contains("<br>"))
        #endif
    }
}
