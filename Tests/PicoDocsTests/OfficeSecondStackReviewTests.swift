import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

struct OfficeSecondStackReviewTests {
    typealias O = OfficeStackReviewTests
    static let ns = "xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'"

    @Test func fencedCodeKeepsTabsThroughTheSharedOfficeParser() async throws {
        let source = "```make\nall:\n\techo done\n```"
        #expect(MarkdownBlockParser.parse(source) == [.code("all:\n\techo done")])
        let result = try await PicoDocsEngine.convert(data: PicoDocsEngine.write(markdown: source, to: .docx), filename: "code.docx")
        #expect(result.markdown().contains("\techo done"))
        let nested = ConverterResult(sections: [.init(markdown: "- ```make\n  all:\n  \techo done\n  ```")])
        #expect(try DocumentRenderer.render(nested, to: .plaintext).contains("\techo done"))
    }

    @Test func parameterizedMIMECarriersKeepTheirImageExtension() throws {
        #expect(OfficeMediaType.fileExtension(forMIME: " Image/PNG ;name=chart.png ") == "png")
        let result = ConverterResult(sections: [.init(kind: .image, markdown: "", metadata: ["base64": "AQID", "mimeType": "image/png;name=chart.png"])])
        let data = try PicoDocsEngine.write(result, to: .docx)
        let zip = try Archive(data: data, accessMode: .read)
        #expect(zip.contains { $0.path.hasPrefix("word/media/") && $0.path.hasSuffix(".png") })
        #expect(try O.xml(data, "[Content_Types].xml").contains("ContentType=\"image/png\""))
    }

    @Test func inheritedAndDirectHeadingBookmarksUseRenderedSlugs() async throws {
        let headings = "<w:p><w:pPr><w:pStyle w:val='Custom'/></w:pPr><w:bookmarkStart w:id='1' w:name='CustomAnchor'/><w:r><w:t>Derived</w:t></w:r></w:p><w:p><w:pPr><w:outlineLvl w:val='1'/></w:pPr><w:bookmarkStart w:id='2' w:name='OutlineAnchor'/><w:r><w:t>Outlined</w:t></w:r></w:p>"
        let links = "<w:p><w:hyperlink w:anchor='CustomAnchor'><w:r><w:t>First</w:t></w:r></w:hyperlink><w:hyperlink w:anchor='OutlineAnchor'><w:r><w:t>Second</w:t></w:r></w:hyperlink></w:p>"
        let document = "<w:document " + Self.ns + "><w:body>" + headings + links + "</w:body></w:document>"
        let styles = "<w:styles " + Self.ns + "><w:style w:styleId='Custom'><w:basedOn w:val='Heading1'/></w:style></w:styles>"
        let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([("word/document.xml", Array(document.utf8)), ("word/styles.xml", Array(styles.utf8))]), filename: "headings.docx")
        #expect(result.markdown().contains("[First](#derived)"))
        #expect(result.markdown().contains("[Second](#outlined)"))
        let exported = try PicoDocsEngine.write(result, to: .docx)
        #expect(try O.xml(exported, "word/document.xml").contains("w:hyperlink w:anchor="))
    }

    @Test func WordListLiteralParenthesizedMarkersStayText() async throws {
        let document = "<w:document " + Self.ns + "><w:body><w:p><w:pPr><w:numPr/></w:pPr><w:r><w:t>1) not nested</w:t></w:r></w:p></w:body></w:document>"
        let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([("word/document.xml", Array(document.utf8))]), filename: "list.docx")
        #expect(result.markdown().contains("1\\) not nested"))
    }

    @Test func PagesLiteralTildeContinuationsMatchFenceGrammar() throws {
        let literal = IWATable.escapingListMarker("~~~swift")
        #expect(literal.hasPrefix("\\~"))
        let result = ConverterResult(sections: [.init(markdown: "- Item\n\n  " + literal + "\n  Following")])
        #expect(try DocumentRenderer.render(result, to: .plaintext).contains("~~~swift"))
        #expect(try DocumentRenderer.render(result, to: .plaintext).contains("Following"))
    }

    @Test func exportedSlideJumpsSurviveTwoOfficeRoundTrips() async throws {
        for (first, target, fragment) in [("First", "Second", "second"), ("Same", "Same", "same-1")] {
            let source = "# " + first + "\n\n[Next](#" + fragment + ")\n\n# " + target + "\n\nTarget"
            let data = try PicoDocsEngine.write(markdown: source, to: .pptx)
            let result = try await PicoDocsEngine.convert(data: data, filename: "jump.pptx")
            #expect(result.markdown().contains("[Next](#" + fragment + ")"))
            let second = try PicoDocsEngine.write(result, to: .pptx)
            #expect(try O.xml(second, "ppt/slides/_rels/slide1.xml.rels").contains("/relationships/slide\""))
        }
    }

    @Test func exactCarrierPathsPrecedeCollidingAliases() throws {
        let result = ConverterResult(sections: [
            .init(markdown: "![First](a.png) ![Second](b.png)"),
            .init(kind: .image, markdown: "", sourcePath: "a.png", metadata: ["base64": "AQID", "mimeType": "image/png"]),
            .init(kind: .image, markdown: "", sourcePath: "b.png", metadata: ["base64": "BAUG", "mimeType": "image/png", "markdownReference": "a.png"])
        ])
        let data = try PicoDocsEngine.write(result, to: .docx)
        #expect(try O.xml(data, "word/document.xml").components(separatedBy: "<w:drawing>").count - 1 == 2)
    }

    #if canImport(AppKit) || canImport(UIKit)
    @Test func rejectedRTFLinksRetainLiteralLabels() async throws {
        let data = try PicoDocsEngine.write(markdown: "[\\*literal\\*](<javascript:alert(1)>)", to: .rtf)
        let result = try await PicoDocsEngine.convert(data: data, filename: "literal.rtf")
        #expect(result.markdown().contains("\\*literal\\*"))
        #expect(try DocumentRenderer.render(result, to: .plaintext) == "*literal*")
    }
    #endif

    @Test func slideNoteMetadataIsChargedBeforeSuffixConstruction() throws {
        let result = ConverterResult(sections: [.init(kind: .slide, markdown: "x", metadata: ["notes": "1234"])])
        // Section 256 + sanitized notes and suffix copies 36 + Markdown 7 + line 128.
        try OfficeDocumentBlocks.validateInput(result, maximumBytes: 427)
        #expect(throws: ExporterError.self) { try OfficeDocumentBlocks.validateInput(result, maximumBytes: 426) }
    }

    @Test func sanitizedCanonicalNotesNeverBecomeVisibleSlideBody() throws {
        for notes in ["Se\u{0}cret\u{0B}", "\u{0}\u{0B}", ""] {
            let source = ConverterResult(sections: [.init(title: "Talk", kind: .slide, markdown: "## Talk\n\nPublic\n\n### Notes\n\n" + notes, slideNumber: 1, metadata: ["notes": notes])])
            let xml = try O.xml(PicoDocsEngine.write(source, to: .pptx), "ppt/slides/slide1.xml")
            #expect(xml.contains("Public"))
            #expect(!xml.contains("Secret"))
            #expect(!xml.contains(">Notes<"))
        }
        let authored = ConverterResult(sections: [.init(kind: .slide, markdown: "### Notes\n\nAuthored", slideNumber: 1)])
        #expect(try O.xml(PicoDocsEngine.write(authored, to: .pptx), "ppt/slides/slide1.xml").contains("Authored"))
    }
}
