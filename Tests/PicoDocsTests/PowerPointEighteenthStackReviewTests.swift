import Foundation
import Testing
@testable import PicoDocs

struct PowerPointEighteenthStackReviewTests {
    @Test func generatedInlineTokensSurviveAdjacentLiteralSentinels() throws {
        for (open, close, markdown, visible) in [("\u{E000}", "\u{E001}", "`code`", "code"), ("\u{E002}", "\u{E003}", "[label](https://example.com)", "label")] {
            let result = ConverterResult(sections: [.init(markdown: open + markdown + close)])
            #expect(try DocumentRenderer.render(result, to: .plaintext) == open + visible + close)
            let html = try DocumentRenderer.render(result, to: .html)
            #expect(html.contains(visible))
            #expect(!html.contains(open + "0" + close))
        }
    }
    @Test func ownedWhitespaceSurvivesAdjacentLiteralDelimiters() throws {
        let result = ConverterResult(sections: [.init(markdown: "A\u{E008}&#32;\u{E009}B", metadata: ["preservedWhitespace": "1"])])
        #expect(try DocumentRenderer.render(result, to: .plaintext) == "A\u{E008} \u{E009}B")
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("&#32;"))
        #expect(!html.contains("\u{E008}32\u{E009}"))
    }
    @Test func picturePlaceholdersSupplyInheritedImageFills() async throws {
        typealias B = PowerPointConverterTests
        typealias R = PowerPointThirdStackReviewTests
        typealias T = PowerPointTwelfthStackReviewTests
        let ph = "<p:ph type='body' idx='1'/>"
        let picture = R.picture("fill").replacingOccurrences(of: "<p:nvPr/>", with: "<p:nvPr>" + ph + "</p:nvPr>")
        for owner in ["layout", "master"] {
            let empty = B.shape(placeholder: ph, paragraphs: [])
            let parts = T.themeParts(layoutShapes: owner == "layout" ? picture : empty, masterShapes: owner == "master" ? picture : "")
            let deck = B.deck(slides: [.init(file: "s.xml", shapes: empty, relationships: [("layout", R.rel + "slideLayout", "../slideLayouts/l.xml")])], extraParts: parts)
            let result = try await PowerPointConverter().convert(deck, info: StreamInfo(detectedFormat: .pptx))
            #expect(result.sections.contains { $0.kind == .image && $0.sourcePath == "ppt/media/" + owner + ".png" })
        }
    }
    @Test func dotfileImageUsesOPCDefaultExtension() async throws {
        typealias B = PowerPointConverterTests
        typealias R = PowerPointThirdStackReviewTests
        let deck = B.deck(slides: [.init(file: "s.xml", shapes: R.picture("image"), relationships: [("image", R.rel + "image", "../media/.png")])], extraParts: [("ppt/media/.png", [1,2,3])])
        let result = try await PowerPointConverter().convert(deck, info: StreamInfo(detectedFormat: .pptx))
        #expect(result.sections.first { $0.kind == .image }?.metadata["mimeType"] == "image/png")
    }
}
