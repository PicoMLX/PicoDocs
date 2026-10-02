import Foundation
import Testing
import SwiftSoup
@testable import PicoDocs

struct PowerPointFourteenthStackReviewTests {
    typealias B = PowerPointConverterTests
    typealias R = PowerPointThirdStackReviewTests
    typealias T = PowerPointTwelfthStackReviewTests
    let rel = PowerPointFifthStackReviewTests.rel

    @Test func equivalentUnsignedPlaceholderIndexesShareStylesAndFills() async throws {
        for (source, inherited) in [(" 1 ", "01"), ("01", "&#9;+1&#13;")] {
            let local = B.shape(placeholder: "<p:ph type='body' idx='\(source)'/>", paragraphs: ["<a:p><a:r><a:t>Inherited</a:t></a:r></a:p>"])
            let owner = T.filledShape("<a:blipFill><a:blip r:embed='fill'/></a:blipFill>", placeholder: "<p:ph type='obj' idx='\(inherited)'/>")
                .replacingOccurrences(of: "<a:bodyPr/>", with: "<a:bodyPr/><a:lstStyle><a:lvl1pPr><a:buChar char='•'/><a:defRPr b='1'/></a:lvl1pPr></a:lstStyle>")
            let parts = T.themeParts(layoutShapes: owner)
            let data = B.deck(slides: [.init(file: "s.xml", shapes: local, relationships: [("layout", rel + "slideLayout", "../slideLayouts/l.xml")])], extraParts: parts)
            let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
            #expect(result.markdown().contains("- **Inherited**"))
            #expect(result.markdown().contains("layout.png"))
        }
    }

    @Test func autoNumberSchemeUsesCollapsedXMLToken() async throws {
        let paragraph = "<a:p><a:pPr><a:buAutoNum type='&#9;arabicPeriod&#13;' startAt='3'/></a:pPr><a:r><a:t>Third</a:t></a:r></a:p>"
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.shape(placeholder: nil, paragraphs: [paragraph]))])
        let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
        #expect(result.markdown() == "3. Third")
    }

    @Test func contentTypeOverrideCollapsesOnlyXMLURIWhitespace() async throws {
        let name = "ppt/media/caf%C3%A9"
        var data = B.deck(slides: [.init(file: "s.xml", shapes: R.picture("image"), relationships: [("image", rel + "image", "../media/caf%c3%a9")])], extraParts: [(name, [1, 2, 3])])
        data = try R.replacing(data, part: "[Content_Types].xml") { _ in
            "<Types xmlns='http://schemas.openxmlformats.org/package/2006/content-types'><Override PartName='&#9; /ppt/media/caf%c3%a9 &#13;' ContentType='image/jpeg'/></Types>"
        }
        let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
        #expect(result.sections.first { $0.kind == .image }?.metadata["mimeType"] == "image/jpeg")
    }

    @Test func placeholderIndexesRejectInvalidExplicitValues() throws {
        for raw in ["-1", "4294967296", "", "1 0"] {
            let document = try SwiftSoup.parse("<p:ph idx='\(raw)'/>", "", SwiftSoup.Parser.xmlParser())
            let ph = try #require(document.children().first())
            #expect(PowerPointConverter.placeholderIndex(ph) == nil)
        }
        for raw in ["+000", "-0", "4294967295"] {
            let document = try SwiftSoup.parse("<p:ph idx='\(raw)'/>", "", SwiftSoup.Parser.xmlParser())
            let ph = try #require(document.children().first())
            #expect(PowerPointConverter.placeholderIndex(ph) == (raw == "4294967295" ? raw : "0"))
        }
    }

    @Test func inlineRestorationAdmitsCompleteOutputAndKeepsLiteralTokens() throws {
        let open = "\u{E002}", close = "\u{E003}"
        let token = open + "0" + close
        let literal = open + token + close
        let source = token + " " + literal + " " + open + "01" + close
        let expected = "replacement " + literal + " " + open + "01" + close
        let restored = try DocumentRenderer.boundedInlineTokenReplacements(source, open: open, close: close, replacements: ["replacement"], maximumBytes: expected.utf8.count)
        #expect(restored == expected)
        #expect(throws: PicoDocsError.self) {
            try DocumentRenderer.boundedInlineTokenReplacements(source, open: open, close: close, replacements: ["replacement"], maximumBytes: expected.utf8.count - 1)
        }
        let many = (0..<20_000).map { open + String($0) + close }.joined(separator: " ")
        let values = (0..<20_000).map { "renderedvalue" + String($0) }
        let joined = values.joined(separator: " ")
        #expect(try DocumentRenderer.boundedInlineTokenReplacements(many, open: open, close: close, replacements: values, maximumBytes: joined.utf8.count) == joined)
    }

    @Test func denseLinksAndCodeSpansRetainRenderingAndSafety() throws {
        let links = (0..<2_500).map { "[label" + String($0) + "](https://example.com/" + String($0) + ")" }
        let codes = (0..<2_500).map { "`code" + String($0) + "`" }
        let literal = "\u{E002}0\u{E003} \u{E000}0\u{E001}"
        let markdown = (links + codes).joined(separator: " ") + " [literal `code`](https://example.com) [unsafe](javascript:alert) " + literal
        let result = ConverterResult(sections: [.init(markdown: markdown)])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.components(separatedBy: "<a href=").count - 1 == 2_501)
        #expect(html.components(separatedBy: "<code>").count - 1 == 2_501)
        #expect(html.contains("<a href=\"https://example.com\">literal <code>code</code></a>"))
        #expect(!html.contains("javascript:"))
        #expect(html.contains(literal))
        #expect(try DocumentRenderer.render(result, to: .plaintext).contains("label2499 code0"))
    }
}
