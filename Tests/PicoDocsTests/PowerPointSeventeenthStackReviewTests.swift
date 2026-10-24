import Foundation
import Testing
@testable import PicoDocs

struct PowerPointSeventeenthStackReviewTests {
    @Test func unicodeAndEncodedImagePathsReserveTheSameIdentity() async throws {
        typealias B = PowerPointConverterTests
        typealias R = PowerPointThirdStackReviewTests
        let embedded = B.Slide(file: "e.xml", shapes: R.picture("image"), relationships: [("image", R.rel + "image", "../media/caf%C3%A9.png")])
        let external = B.Slide(file: "x.xml", shapes: R.picture("outside", external: true), relationships: [("outside", R.rel + "image", "café.png\" TargetMode=\"External")])
        let data = B.deck(slides: [embedded, external], extraParts: [("ppt/media/caf%C3%A9.png", [1,2,3])])
        let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
        let reference = try #require(result.sections.first { $0.kind == .image }?.metadata["markdownReference"])
        #expect(reference.hasPrefix("picodocs-embedded/"))
        let identity = PowerPointConverter.ImageCollector.referenceIdentity
        #expect(identity("café.png") == identity("caf%c3%a9.png"))
        #expect(identity("a/b.png") != identity("a%2Fb.png"))
        #expect(identity("a#b.png") != identity("a%23b.png"))
    }
}
