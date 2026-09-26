import Foundation
import Testing
import ZIPFoundation
import SwiftSoup
@testable import PicoDocs

struct WordNumberingReviewTests {
    private let ns = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""

    @Test func concreteCountersOverridesDefaultsAndRestarts() throws {
        let levels = """
        <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl>
        <w:lvl w:ilvl="1"><w:numFmt w:val="decimal"/><w:lvlRestart w:val="0"/></w:lvl>
        <w:lvl w:ilvl="2"><w:numFmt w:val="decimal"/><w:lvlRestart w:val="1"/></w:lvl>
        """
        let numbering = """
        <w:numbering \(ns)><w:abstractNum w:abstractNumId="1">\(levels)</w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="1"/></w:num>
        <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
        <w:num w:numId="3"><w:abstractNumId w:val="1"/><w:lvlOverride w:ilvl="1"><w:startOverride w:val="5"/></w:lvlOverride></w:num>
        <w:num w:numId="4"><w:abstractNumId w:val="1"/><w:lvlOverride w:ilvl="0"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl></w:lvlOverride></w:num>
        <w:num w:numId="5"><w:abstractNumId w:val="1"/><w:lvlOverride w:ilvl="0"><w:lvl w:ilvl="0"><w:start w:val="7"/></w:lvl></w:lvlOverride></w:num>
        </w:numbering>
        """
        let styles = "<w:styles \(ns)><w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:pPr><w:numPr><w:numId w:val=\"2\"/></w:numPr></w:pPr></w:style></w:styles>"
        let data = PagesConverterTests.makeZip([
            (name: "word/numbering.xml", data: Array(numbering.utf8)),
            (name: "word/styles.xml", data: Array(styles.utf8))
        ])
        let resolver = WordListNumbering(archive: try #require(Archive(data: data, accessMode: .read)))
        func prefix(_ id: Int, _ level: Int = 0) throws -> String? {
            let xml = try SwiftSoup.parse("<w:numPr \(ns)><w:numId w:val=\"\(id)\"/><w:ilvl w:val=\"\(level)\"/></w:numPr>", "", SwiftSoup.Parser.xmlParser())
            return resolver.prefix(numPr: try xml.getElementsByTag("w:numPr").first(), style: nil)
        }
        #expect(try prefix(1) == "1. ")
        #expect(try prefix(2) == "1. ")
        #expect(resolver.prefix(numPr: nil, style: nil) == "2. ")
        #expect(try prefix(3) == "1. ")
        #expect(try prefix(3, 1) == "   5. ")
        #expect(try prefix(4) == "- ")
        #expect(try prefix(5) == "7. ")
        #expect(try prefix(1, 1) == "   1. ")
        #expect(try prefix(1, 2) == "      1. ")
        #expect(try prefix(1, 1) == "   2. ")
        #expect(try prefix(1, 2) == "      2. ")
        #expect(try prefix(1) == "2. ")
        #expect(try prefix(1, 1) == "   3. ")
        #expect(try prefix(1, 2) == "      1. ")
    }

    @Test func emptyItemsAndHeadingsConsumeNumbers() async throws {
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:numFmt w:val=\"decimal\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        func paragraph(_ text: String, style: String = "") -> String {
            "<w:p><w:pPr>\(style)<w:numPr><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>"
        }
        let document = "<w:document \(ns)><w:body>" + paragraph("a") + paragraph("") + paragraph("c") + paragraph("heading", style: "<w:pStyle w:val=\"Heading1\"/>") + paragraph("e") + "</w:body></w:document>"
        let file = PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8))])
        let result = try await PicoDocsEngine.convert(data: file, filename: "list.docx")
        #expect(result.markdown().contains("3. c"))
        #expect(result.markdown().contains("5. e"))
    }

    @Test func followupNumberingRegressions() async throws {
        let numbering = """
        <w:numbering \(ns)>
        <w:abstractNum w:abstractNumId="1"><w:numStyleLink w:val="NumberingStyle"/></w:abstractNum>
        <w:abstractNum w:abstractNumId="2"><w:lvl w:ilvl="-1"><w:lvlRestart w:val="1"/></w:lvl><w:lvl w:ilvl="0"><w:start w:val="5"/><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="1"/></w:num>
        <w:num w:numId="2"><w:abstractNumId w:val="2"/></w:num>
        </w:numbering>
        """
        let styles = "<w:styles \(ns)><w:style w:type=\"numbering\" w:styleId=\"NumberingStyle\"><w:pPr><w:numPr><w:numId w:val=\"2\"/></w:numPr></w:pPr></w:style></w:styles>"
        func item(_ text: String) -> String {
            "<w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>"
        }
        let body = item("Before") + "<w:tbl><w:tr><w:tc>" + item("Inside") + "</w:tc></w:tr></w:tbl>" + item("After")
        let document = "<w:document \(ns)><w:body>\(body)</w:body></w:document>"
        let data = PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8)), (name: "word/styles.xml", data: Array(styles.utf8))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "linked.docx")
        #expect(result.markdown().contains("5. Before"))
        #expect(result.markdown().contains("7. After"))
        for markdown in ["\t- item", "999999999999999999999999999999. item"] {
            let content = ConverterResult(sections: [DocumentSection(markdown: markdown)])
            #expect(try DocumentRenderer.render(content, to: .html).contains("item"))
            #expect(try DocumentRenderer.render(content, to: .plaintext).contains("item"))
        }
    }

    @Test func linkedOverridesAliasesAndRelocatedParts() throws {
        let numbering = """
        <w:numbering \(ns)>
        <w:abstractNum w:abstractNumId="001"><w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl><w:lvl w:ilvl="1"><w:numFmt w:val="decimal"/><w:lvlRestart w:val="0"/></w:lvl></w:abstractNum>
        <w:abstractNum w:abstractNumId="2"><w:numStyleLink w:val="Linked"/></w:abstractNum>
        <w:abstractNum w:abstractNumId="3"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl></w:abstractNum>
        <w:num w:numId="001"><w:abstractNumId w:val="1"/></w:num>
        <w:num w:numId="2"><w:abstractNumId w:val="1"/><w:lvlOverride w:ilvl="0"><w:startOverride w:val="1"/></w:lvlOverride></w:num>
        <w:num w:numId="3"><w:abstractNumId w:val="2"/><w:lvlOverride w:ilvl="0"><w:lvl w:ilvl="0"><w:lvlRestart w:val="0"/></w:lvl></w:lvlOverride></w:num>
        <w:num w:numId="4"><w:abstractNumId w:val="3"/></w:num>
        </w:numbering>
        """
        let styles = "<w:styles \(ns)><w:style w:styleId=\"Linked\"><w:pPr><w:numPr><w:numId w:val=\"004\"/></w:numPr></w:pPr></w:style></w:styles>"
        let relationships = #"<Relationships><Relationship Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="lists/n.xml"/><Relationship Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="lists/s.xml"/></Relationships>"#
        let data = PagesConverterTests.makeZip([(name: "word/lists/n.xml", data: Array(numbering.utf8)), (name: "word/lists/s.xml", data: Array(styles.utf8)), (name: "word/_rels/document.xml.rels", data: Array(relationships.utf8)), (name: "docProps/app.xml", data: Array("<Properties><Application>LibreOffice</Application></Properties>".utf8))])
        let resolver = WordListNumbering(archive: try #require(Archive(data: data, accessMode: .read)))
        func prefix(_ id: String, _ level: Int = 0) throws -> String? {
            let doc = try SwiftSoup.parse("<w:numPr \(ns)><w:numId w:val=\"\(id)\"/><w:ilvl w:val=\"\(level)\"/></w:numPr>", "", SwiftSoup.Parser.xmlParser())
            return resolver.prefix(numPr: try doc.getElementsByTag("w:numPr").first(), style: nil)
        }
        #expect(try prefix("00") == nil)
        #expect(try prefix("+01") == "1. ")
        #expect(try prefix("1", 1) == "   1. ")
        #expect(try prefix("02") == "1. ")
        #expect(try prefix("1") == "2. ")
        #expect(try prefix("1", 1) == "   2. ")
        #expect(try prefix("3") == "- ")
    }

    @Test func looseNestedListsRenderWithSourceNumbers() throws {
        let result = ConverterResult(sections: [DocumentSection(markdown: "5. First\n\n   1. Child\n\n   2. Child two\n\n6. Second")])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("<ol start=\"5\">"))
        #expect(html.components(separatedBy: "<ol").count == 3)
        #expect(html.contains("Child two</li>\n</ol></li>"))
        let plain = try DocumentRenderer.render(result, to: .plaintext)
        #expect(plain == "5. First\n   1. Child\n   2. Child two\n6. Second")
    }
}
