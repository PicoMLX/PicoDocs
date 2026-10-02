import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

struct OfficeNinthStackReviewTests {
    @Test(arguments: ["````", "~~~~"])
    func listCodeKeepsLiteralShorterBacktickRuns(_ fence: String) throws {
        let markdown = "- " + fence + "\n  before\n  ```\n  after\n  " + fence
        let list = try #require(MarkdownBlockParser.parse(markdown).first)
        guard case .list(let value) = list else { Issue.record("Expected list"); return }
        let text = try #require(value.paragraphs().first?.text)
        let inlines = MarkdownInlineParser.parse(text)
        #expect(inlines == [.code("before ``` after")])
    }
    @Test(arguments: ["\"title\"", "'title'", "(title)"])
    func titleLikeDestinationsRetainCommonMarkPrecedence(_ destination: String) throws {
        let markdown = "[foo]( " + destination + ")"
        #expect(MarkdownInlineParser.parse(markdown) == [.link(label: [.text("foo")], destination: destination)])
        let independent = try AttributedString(markdown: markdown)
        #expect(independent.runs.first?.link?.relativeString.removingPercentEncoding == destination)
        for format in [ExportableFileType.docx, .pptx] {
            let data = try PicoDocsEngine.write(markdown: markdown, to: format)
            let archive = try #require(Archive(data: data, accessMode: .read))
            for entry in archive where entry.path.hasSuffix(".rels") {
                var bytes = Data()
                _ = try archive.extract(entry) { bytes.append($0) }
                if entry.path.contains("word/_rels/document.xml") || entry.path.contains("ppt/slides/_rels/") {
                    #expect(String(decoding: bytes, as: UTF8.self).contains("/hyperlink"))
                }
            }
        }
    }
    @Test func DOCXCoreMetadataSurvivesTwoRoundTrips() async throws {
        var result = ConverterResult(title: "A title & meaning", author: "An Author", sections: [.init(markdown: "Body")])
        for _ in 0..<2 {
            let bytes = try PicoDocsEngine.write(result, to: .docx)
            result = try await PicoDocsEngine.convert(data: bytes, filename: "fallback.docx")
            #expect(result.title == "A title & meaning")
            #expect(result.author == "An Author")
        }
    }
    @Test func relocatedAndAliasedDOCXMetadataUsesPackageRelationship() async throws {
        let document = "<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body><w:p><w:r><w:t>Body</w:t></w:r></w:p></w:body></w:document>"
        let relationship = "<Relationships xmlns='http://schemas.openxmlformats.org/package/2006/relationships'><Relationship Id='core' Type='http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties' Target='metadata/props.xml'/></Relationships>"
        let properties = "<c:coreProperties xmlns:c='http://purl.oclc.org/ooxml/package/metadata/core-properties' xmlns:d='http://purl.org/dc/elements/1.1/'><d:title>Relocated</d:title><d:creator>Writer</d:creator></c:coreProperties>"
        let data = PagesConverterTests.makeZip([("word/document.xml", Array(document.utf8)), ("_rels/.rels", Array(relationship.utf8)), ("metadata/props.xml", Array(properties.utf8))])
        let result = try await WordConverter().convert(data, info: StreamInfo(filename: "fallback.docx", detectedFormat: .docx))
        #expect(result.title == "Relocated")
        #expect(result.author == "Writer")
        let fallback = try await WordConverter().convert(PagesConverterTests.makeZip([("word/document.xml", Array(document.utf8))]), info: StreamInfo(filename: "fallback.docx", detectedFormat: .docx))
        #expect(fallback.title == "fallback.docx")
    }
    @Test func metadataAboveOneMiBRetainsTheWordEntryPolicy() async throws {
        let title = String(repeating: "A", count: 1024 * 1024 + 1)
        let result = ConverterResult(title: title, sections: [.init(markdown: "Body")])
        let bytes = try PicoDocsEngine.write(result, to: .docx)
        let imported = try await PicoDocsEngine.convert(data: bytes, filename: "fallback.docx")
        #expect(imported.title == title)
    }
}
