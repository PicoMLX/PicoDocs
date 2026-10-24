import Foundation
import Testing
@testable import PicoDocs

struct PowerPointThirteenthStackReviewTests {
    @Test func imageFragmentsDoNotClaimEmbeddedBytes() async throws {
        typealias B = PowerPointConverterTests
        typealias R = PowerPointThirdStackReviewTests
        let rel = PowerPointFifthStackReviewTests.rel
        let embedded = B.Slide(file: "e.xml", shapes: R.picture("image"), relationships: [("image", rel + "image", "../media/image.png")])
        let external = B.Slide(file: "x.xml", shapes: R.picture("outside", external: true), relationships: [("outside", rel + "image", "image.png#remote\" TargetMode=\"External")])
        let result = try await PowerPointConverter().convert(B.deck(slides: [embedded, external], extraParts: [("ppt/media/image.png", [1, 2, 3])]), info: StreamInfo(detectedFormat: .pptx))
        let reference = try #require(result.sections.first { $0.kind == .image }?.metadata["markdownReference"])
        #expect(reference.hasPrefix("picodocs-embedded/"))
        #expect(result.sections.first { $0.slideNumber == 2 }?.markdown.contains("image.png#remote") == true)
        #expect(PowerPointConverter.ImageCollector.referenceIdentity("image.png?version=2#remote") == "image.png?version=2")
        #expect(PowerPointConverter.ImageCollector.referenceIdentity("image%23remote.png") == "image%23remote.png")
    }
    @Test func CSVFencesRestoreOnlyProtectedWhitespaceSentinels() throws {
        let text = "\u{E008}32\u{E009} \u{E008}\u{E008} \u{E000}\u{E000}"
        let source = ConverterResult(sections: [.init(markdown: "```\n" + text + "\n```")])
        #expect(try DocumentRenderer.render(source, to: .csv) == text)
        let owned = ConverterResult(sections: [.init(markdown: "```\nA&#32;B\n```", metadata: ["preservedWhitespace": "1"])])
        #expect(try DocumentRenderer.render(owned, to: .csv) == "A B")
        let raw = ConverterResult(sections: [.init(markdown: "", metadata: ["csv": text])])
        #expect(try DocumentRenderer.render(raw, to: .csv) == text)
    }
}
