import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

struct PowerPointSixteenthStackReviewTests {
    @Test func literalTildeEscapesRoundTripThroughSharedRenderers() throws {
        let result = ConverterResult(sections: [.init(markdown: "\\~\\~literal\\~\\~")])
        #expect(try DocumentRenderer.render(result, to: .plaintext) == "~~literal~~")
        #expect(try DocumentRenderer.render(result, to: .html).contains(">~~literal~~</p>"))
        #expect(try DocumentRenderer.boundedProtectEscapes("\\~", maximumBytes: 6).utf8.count == 6)
        #expect(throws: PicoDocsError.fileCorrupted) { _ = try DocumentRenderer.boundedProtectEscapes("\\~", maximumBytes: 5) }
    }
    @Test func scalarEscapingRecordsCancellationBeforeCopying() async throws {
        let data = PowerPointConverterTests.deck(slides: [.init(file: "s.xml", shapes: PowerPointConverterTests.titleShape("Slide"))])
        let task = Task.detached {
            let archive = try Archive(data: data, accessMode: .read)
            let package = PowerPointPackage(archive: archive)
            let budget = PowerPointConverter.RenderBudget(maximumBytes: 1024, archive: package)
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(PowerPointConverter.escapeMarkdown("text & escaped", budget: budget).isEmpty)
            try package.check()
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
    @Test func footnoteIDsRestoreLiteralWhitespaceDelimiters() throws {
        for id in ["literal\u{E008}", "literal\u{E009}", "\u{E008}32\u{E009}"] {
            let markdown = "Reference[^" + id + "]\n\n[^" + id + "]: Definition"
            let result = ConverterResult(sections: [.init(markdown: markdown)])
            let html = try DocumentRenderer.render(result, to: .html)
            #expect(html.contains("href=\"#fn-" + id + "\""))
            #expect(html.contains("<li id=\"fn-" + id + "\">Definition</li>"))
        }
    }

    @Test func relativeHyperlinksReserveTheirMaterializedIdentity() async throws {
        typealias B = PowerPointConverterTests
        typealias R = PowerPointThirdStackReviewTests
        let paragraph = "<a:p><a:r><a:rPr><a:hlinkClick r:id='outside'/></a:rPr><a:t>External photo</a:t></a:r></a:p>"
        let shapes = B.shape(placeholder: nil, paragraphs: [paragraph]) + R.picture("image")
        let relationships = [("outside", R.rel + "hyperlink", "photo.png#view\" TargetMode=\"External"), ("image", R.rel + "image", "../media/photo.png")]
        let data = B.deck(slides: [.init(file: "s.xml", shapes: shapes, relationships: relationships)], extraParts: [("ppt/media/photo.png", [1,2,3])])
        let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
        let reference = try #require(result.sections.first { $0.kind == .image }?.metadata["markdownReference"])
        #expect(reference.hasPrefix("picodocs-embedded/"))
        #expect(result.markdown().contains("[External photo](photo.png#view)"))
    }
}
