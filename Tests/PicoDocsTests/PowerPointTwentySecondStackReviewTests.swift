import Foundation
import Testing
@testable import PicoDocs

struct PowerPointTwentySecondStackReviewTests {
    typealias B = PowerPointConverterTests
    typealias R = PowerPointThirdStackReviewTests

    @Test func carrierPathsDoNotAliasExternalPathsOnCaseInsensitiveVolumes() async throws {
        let embedded = B.Slide(file: "embedded.xml", shapes: R.picture("image"), relationships: [("image", R.rel + "image", "../media/photo.png")])
        let external = B.Slide(file: "external.xml", shapes: R.picture("outside", external: true), relationships: [("outside", R.rel + "image", "Photo.png?view=1#detail\" TargetMode=\"External")])
        let data = B.deck(slides: [embedded, external], extraParts: [("ppt/media/photo.png", [1, 2, 3])])
        let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
        let reference = try #require(result.sections.first { $0.kind == .image }?.metadata["markdownReference"])
        #expect(reference.hasPrefix("picodocs-embedded/"))
        #expect(result.sections.first { $0.sourcePath == "ppt/slides/external.xml" }?.markdown.contains("Photo.png?view=1#detail") == true)
        // URI identity stays case-sensitive, independently of materialized paths.
        #expect(PowerPointConverter.ImageCollector.referenceIdentity("Photo.png") != PowerPointConverter.ImageCollector.referenceIdentity("photo.png"))
    }

    @Test func differentlyCasedEmbeddedPathsKeepDistinctCarriers() async throws {
        let upper = B.Slide(file: "upper.xml", shapes: R.picture("image"), relationships: [("image", R.rel + "image", "../media/Photo.png")])
        let lower = B.Slide(file: "lower.xml", shapes: R.picture("image"), relationships: [("image", R.rel + "image", "../media/photo.png")])
        let result = try await PowerPointConverter().convert(B.deck(slides: [upper, lower], extraParts: [("ppt/media/Photo.png", [1]), ("ppt/media/photo.png", [2])]), info: StreamInfo(detectedFormat: .pptx))
        let carriers = result.sections.filter { $0.kind == .image }
        #expect(carriers.count == 2)
        #expect(Set(carriers.compactMap { $0.metadata["markdownReference"]?.lowercased() }).count == 2)
        #expect(Set(carriers.compactMap { $0.metadata["base64"] }) == ["AQ==", "Ag=="])
    }

    @Test func renderInputScanChecksCancellationBeforeTheEndOfOneSection() throws {
        let result = ConverterResult(sections: [.init(markdown: String(repeating: "x", count: 32 * 1024) + "\n")])
        for fallbackOnly in [false, true] {
            var checks = 0
            // With one allowed line, reaching the trailing newline would produce
            // fileCorrupted. Cancellation must win at an earlier byte checkpoint.
            #expect(throws: CancellationError.self) {
                try DocumentRenderer.preflightRenderInput(result, maximumLines: 1, markdownFallbackOnly: fallbackOnly, checkCancellation: {
                    checks += 1
                    if checks == 3 { throw CancellationError() }
                })
            }
            #expect(checks == 3)
        }
    }

    @Test func rawCSVStillSkipsMarkdownLineAdmission() throws {
        let result = ConverterResult(sections: [.init(markdown: "ignored\nMarkdown", metadata: ["csv": "a,b"])])
        try DocumentRenderer.preflightRenderInput(result, maximumBytes: 256, maximumLines: 1, markdownFallbackOnly: true)
        #expect(throws: PicoDocsError.fileCorrupted) {
            try DocumentRenderer.preflightRenderInput(result, maximumBytes: 256, maximumLines: 1)
        }
    }
}
