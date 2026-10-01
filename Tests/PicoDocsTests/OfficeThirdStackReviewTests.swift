import Foundation
import Testing
@testable import PicoDocs

struct OfficeThirdStackReviewTests {
    typealias O = OfficeStackReviewTests

    @Test func tildeSentinelsUseTheirExactExpandedByteCount() throws {
        let protected = try DocumentRenderer.boundedProtectEscapes("\\~", maximumBytes: 6)
        #expect(protected.utf8.count == 6)
        #expect(throws: PicoDocsError.fileCorrupted) { _ = try DocumentRenderer.boundedProtectEscapes("\\~", maximumBytes: 5) }
    }

    @Test func reservedHistoryNamesAreRenamedBeforeUniqueness() throws {
        let source = ConverterResult(sections: ["History", "history", "HISTORY"].map { .init(title: $0, kind: .sheet, markdown: "Value") })
        let xml = try O.xml(PicoDocsEngine.write(source, to: .xlsx), "xl/workbook.xml")
        #expect(!xml.contains("name=\"History\""))
        #expect(!xml.contains("name=\"history\""))
        #expect(!xml.contains("name=\"HISTORY\""))
        #expect(xml.contains("name=\"History (2)\""))
    }

    @Test func multilineWorksheetProseParsesBeforeRowProjection() async throws {
        for (source, rows) in [("first\\\nsecond", [["first"], ["second"]]), ("first  \nsecond", [["first"], ["second"]]), ("`first\nsecond`", [["first second"]])] {
            for markdown in [source, source.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")] {
                let data = try PicoDocsEngine.write(markdown: markdown, to: .xlsx)
                let result = try await PicoDocsEngine.convert(data: data, filename: "multiline.xlsx")
                let csv = try #require(result.sections.first?.metadata["csv"])
                #expect(CSVConverter.parseCSV(csv) == rows)
            }
        }
    }

    @Test func explicitSlideTitleRetainsItsInlineFormatting() throws {
        let source = ConverterResult(sections: [.init(title: "Bold Italic Code Link", kind: .slide, markdown: "## **Bold** *Italic* `Code` [Link](https://example.com)\n\nBody", slideNumber: 1)])
        let data = try PicoDocsEngine.write(source, to: .pptx)
        let xml = try O.xml(data, "ppt/slides/slide1.xml")
        #expect(xml.contains("b=\"1\""))
        #expect(xml.contains("i=\"1\""))
        #expect(xml.contains("Courier New"))
        #expect(xml.contains("a:hlinkClick"))
    }

    @Test func headingBookmarkMappingExcludesNestedTextboxFlow() async throws {
        let inner = "<w:txbxContent><w:p><w:bookmarkStart w:id='2' w:name='Box'/><w:r><w:t>Textbox</w:t></w:r></w:p></w:txbxContent>"
        let heading = "<w:p><w:pPr><w:pStyle w:val='Heading1'/></w:pPr><w:bookmarkStart w:id='1' w:name='Own'/><w:r><w:t>Outer</w:t></w:r><w:r><w:drawing>" + inner + "</w:drawing></w:r></w:p>"
        let links = "<w:p><w:hyperlink w:anchor='Own'><w:r><w:t>Heading link</w:t></w:r></w:hyperlink><w:hyperlink w:anchor='Box'><w:r><w:t>Textbox link</w:t></w:r></w:hyperlink></w:p>"
        let xml = "<w:document " + OfficeSecondStackReviewTests.ns + "><w:body>" + heading + links + "</w:body></w:document>"
        let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([("word/document.xml", Array(xml.utf8))]), filename: "anchors.docx")
        #expect(result.markdown().contains("[Heading link](#outer)"))
        #expect(result.markdown().contains("[Textbox link](#Box)"))
    }

    @Test func multiSheetCSVRetainsEmptyNamedCarriers() throws {
        let source = ConverterResult(sections: [.init(title: "Empty", kind: .sheet, markdown: "", metadata: ["csv": ""]), .init(title: "Data", kind: .sheet, markdown: "", metadata: ["csv": "Value"])])
        #expect(try DocumentRenderer.render(source, to: .csv) == "Empty\nData\nValue")
    }

    @Test func trailingAndBlankOnlySlidesKeepTheirProvenance() async throws {
        for sections in [[DocumentSection(kind: .slide, markdown: "Content", slideNumber: 1), .init(kind: .slide, markdown: "", slideNumber: 2)], [.init(kind: .slide, markdown: "", slideNumber: 1)]] {
            let first = try PicoDocsEngine.write(ConverterResult(sections: sections), to: .pptx)
            let result = try await PicoDocsEngine.convert(data: first, filename: "blank.pptx")
            #expect(result.sections.filter { $0.kind == .slide }.map(\.slideNumber) == sections.map(\.slideNumber))
            let second = try PicoDocsEngine.write(result, to: .pptx)
            let count = try O.xml(second, "ppt/presentation.xml").components(separatedBy: "<p:sldId ").count - 1
            #expect(count == sections.count)
        }
    }

    @Test func rawProjectionIsBoundedBeforeXMLCleanupCopiesIt() throws {
        let source = ConverterResult(sections: [.init(markdown: String(repeating: "\u{0}", count: 10 * 1024 * 1024))])
        #expect(throws: ExporterError.self) { _ = try WordprocessingMLExporter().write(source, format: .docx) }
        #expect(throws: ExporterError.self) { _ = try PPTXExporter().write(source, format: .pptx) }
    }
}
