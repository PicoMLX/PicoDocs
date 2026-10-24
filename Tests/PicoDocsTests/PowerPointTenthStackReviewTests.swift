import Foundation
import Testing
@testable import PicoDocs

struct PowerPointTenthStackReviewTests {
    typealias B = PowerPointConverterTests
    typealias R = PowerPointThirdStackReviewTests

    @Test func tableCellImageFillsRetainImageOnlyTables() async throws {
        let table = "<p:graphicFrame><a:graphic><a:graphicData uri='http://schemas.openxmlformats.org/drawingml/2006/table'><a:tbl><a:tr><a:tc><a:txBody><a:p/></a:txBody><a:tcPr><a:blipFill><a:blip r:embed='image'/></a:blipFill></a:tcPr></a:tc></a:tr></a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
        let data = B.deck(slides: [.init(file: "s.xml", shapes: table, relationships: [("image", R.rel + "image", "../media/cell.png")])], extraParts: [("ppt/media/cell.png", [1, 2, 3])])
        let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
        #expect(result.markdown().contains("![image](cell.png)"))
        #expect(result.sections.filter { $0.kind == .image }.count == 1)
    }

    @Test func relationshipURIsUseXMLWhitespaceCollapse() async throws {
        let seed = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Padded"))])
        let root = try R.replacing(seed, part: "_rels/.rels") { $0.replacingOccurrences(of: "Type=\"", with: "Type=\"&#9; ").replacingOccurrences(of: " Target=\"", with: " Target=\" ").replacingOccurrences(of: "presentation.xml\"", with: "presentation.xml &#13;\"") }
        let data = try R.replacing(root, part: "ppt/_rels/presentation.xml.rels") { $0.replacingOccurrences(of: "Target=\"slides/s.xml\"", with: "Target=\"&#9; slides/s.xml &#13;\"") }
        #expect(try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx)).markdown() == "## Padded")
    }

    @Test func logicalLineAdmissionCountsLoneCRAndCRLF() throws {
        for text in ["a\nb", "a\rb", "a\r\nb"] {
            let result = ConverterResult(sections: [.init(markdown: text)])
            let exact = text.utf8.count + 512
            try DocumentRenderer.preflightRenderInput(result, maximumBytes: exact, maximumLines: 2)
            #expect(throws: PicoDocsError.fileCorrupted) { try DocumentRenderer.preflightRenderInput(result, maximumBytes: exact - 1, maximumLines: 2) }
            #expect(throws: PicoDocsError.fileCorrupted) { try DocumentRenderer.preflightRenderInput(result, maximumBytes: exact, maximumLines: 1) }
        }
    }

    @Test func CSVRejectsExcessiveMarkdownLinesBeforeSplitting() throws {
        let result = ConverterResult(sections: [.init(markdown: String(repeating: "\n", count: 100_000))])
        #expect(throws: PicoDocsError.fileCorrupted) { _ = try DocumentRenderer.render(result, to: .csv) }
    }
    @Test func XMLAdmissionIncludesExpandedTextAttributesAndWrappers() throws {
        let result = ConverterResult(title: "'&", author: "\"", sections: [.init(title: "<", markdown: "''''''''''''''''")])
        let xml = try DocumentRenderer.renderXML(result)
        let bytes = xml.utf8.count
        #expect(xml.contains(String(repeating: "&#39;", count: 16)))
        #expect(try DocumentRenderer.renderXML(result, maximumBytes: bytes) == xml)
        #expect(throws: PicoDocsError.fileCorrupted) { _ = try DocumentRenderer.renderXML(result, maximumBytes: bytes - 1) }
        #expect(throws: PicoDocsError.fileCorrupted) { _ = try DocumentRenderer.renderXML(result, maximumBytes: 16) }
    }

    @Test func URICollapsePreservesEncodedAndUnicodeSpaces() {
        #expect(PowerPointConverter.collapsedXMLURI(" \t a%20b \r\n ") == "a%20b")
        #expect(PowerPointConverter.collapsedXMLURI("a\t\n b") == "a b")
        #expect(PowerPointConverter.collapsedXMLURI("\u{00A0}a\u{00A0}") == "\u{00A0}a\u{00A0}")
    }
}
