import Foundation
import Testing
import SwiftSoup
@testable import PicoDocs

struct PowerPointTwentyFirstStackReviewTests {
    @Test func encodedHexCaseCannotBypassExternalImageReservation() async throws {
        typealias B = PowerPointConverterTests
        typealias R = PowerPointThirdStackReviewTests
        let embedded = B.Slide(file: "e.xml", shapes: R.picture("image"), relationships: [("image", R.rel + "image", "../media/caf%C3%A9.png")])
        let external = B.Slide(file: "x.xml", shapes: R.picture("outside", external: true), relationships: [("outside", R.rel + "image", "caf%c3%a9.png\" TargetMode=\"External")])
        let result = try await PowerPointConverter().convert(B.deck(slides: [embedded, external], extraParts: [("ppt/media/caf%C3%A9.png", [1,2,3])]), info: StreamInfo(detectedFormat: .pptx))
        #expect(result.sections.first { $0.kind == .image }?.metadata["markdownReference"]?.hasPrefix("picodocs-embedded/") == true)
        let identity = PowerPointConverter.ImageCollector.referenceIdentity
        #expect(identity("a%2fb.png") == identity("a%2Fb.png"))
        #expect(identity("a%23b.png") != identity("a#b.png"))
    }
    @Test func whitespaceVisibilityStopsAtCancellationCheckpoints() throws {
        let document = try SwiftSoup.parse("<a:t>" + String(repeating: " ", count: 1024 * 1024) + "Visible</a:t>", "", SwiftSoup.Parser.xmlParser())
        let text = try #require(document.getElementsByTag("a:t").first())
        var checks = 0
        #expect(!PowerPointConverter.hasVisibleText(text, isCancelled: { checks += 1; return checks >= 3 }))
        #expect(checks == 3)
        #expect(PowerPointConverter.hasVisibleText(text))
    }

}
