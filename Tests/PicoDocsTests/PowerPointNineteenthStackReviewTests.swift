import Foundation
import Testing
import ZIPFoundation
import SwiftSoup
@testable import PicoDocs

struct PowerPointNineteenthStackReviewTests {
    typealias B = PowerPointConverterTests
    typealias R = PowerPointThirdStackReviewTests
    @Test func relocatedSniffRejectsHostileDeclaredSizesBeforeExtraction() throws {
        for compressed in [UInt64(Int64.max), UInt64.max] {
            let zip = ZIPEntryReaderTests.zip(name: "relocated.xml", content: [1], declaredSize: 1, declaredCompressedSize: compressed)
            let archive = try #require(Archive(data: zip, accessMode: .read))
            #expect(archive["relocated.xml"]?.compressedSize == compressed)
            #expect(!ContentTypeDetector.sniffPresentationRoot(PowerPointPackage(archive: archive), path: "relocated.xml"))
        }
        let zip = ZIPEntryReaderTests.zip(name: "relocated.xml", content: [1], declaredSize: 20 * 1024 * 1024)
        let archive = try #require(Archive(data: zip, accessMode: .read))
        #expect(!ContentTypeDetector.sniffPresentationRoot(PowerPointPackage(archive: archive), path: "relocated.xml"))
    }
    @Test func literalInlineSentinelsInFootnoteIDsFindTheirDefinitions() throws {
        for scalar in ["\u{E000}", "\u{E001}", "\u{E002}", "\u{E003}", "\u{E000}\u{E000}"] {
            let id = "note" + scalar
            let result = ConverterResult(sections: [.init(markdown: "Reference[^" + id + "]\n\n[^" + id + "]: Definition")])
            #expect(try DocumentRenderer.render(result, to: .plaintext).contains("[1] Definition"))
            let html = try DocumentRenderer.render(result, to: .html)
            #expect(html.contains("href=\"#fn-" + id + "\""))
            #expect(html.contains("<li id=\"fn-" + id + "\">Definition</li>"))
        }
    }
    @Test func queryRelativeReferenceCannotClaimACarrierPath() async throws {
        let paragraph = "<a:p><a:r><a:rPr><a:hlinkClick r:id='outside'/></a:rPr><a:t>Outside</a:t></a:r></a:p>"
        let shape = B.shape(placeholder: nil, paragraphs: [paragraph]) + R.picture("image")
        let relationships = [("outside", R.rel + "hyperlink", "photo.png?v=remote#view\" TargetMode=\"External"), ("image", R.rel + "image", "../media/photo.png")]
        let data = B.deck(slides: [.init(file: "s.xml", shapes: shape, relationships: relationships)], extraParts: [("ppt/media/photo.png", [1,2,3])])
        let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
        #expect(result.sections.first { $0.kind == .image }?.metadata["markdownReference"]?.hasPrefix("picodocs-embedded/") == true)
        #expect(result.markdown().contains("photo.png?v=remote#view"))
    }
    @Test func extensionPayloadSlideIDsAreOpaque() async throws {
        var data = B.deck(slides: [.init(file: "s.xml", shapes: B.shape(placeholder: nil, paragraphs: ["<a:p><a:r><a:t>Visible</a:t></a:r></a:p>"]))])
        data = try R.replacing(data, part: "ppt/presentation.xml") { $0.replacingOccurrences(of: "</p:presentation>", with: "<p:extLst><p:ext uri='urn:opaque'><p:sldId r:id='missing'/></p:ext></p:extLst></p:presentation>") }
        let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
        #expect(result.markdown().contains("Visible"))
    }
    @Test func paragraphDefaultLinkHasRunPrecedence() async throws {
        let paragraph = "<a:p><a:pPr><a:defRPr><a:hlinkClick r:id='default'/></a:defRPr></a:pPr><a:r><a:t>Default</a:t></a:r><a:r><a:rPr><a:hlinkClick r:id='explicit'/></a:rPr><a:t>Explicit</a:t></a:r></a:p>"
        let relationships = [("default", R.rel + "hyperlink", "https://example.com/default\" TargetMode=\"External"), ("explicit", R.rel + "hyperlink", "https://example.com/explicit\" TargetMode=\"External")]
        let result = try await PowerPointConverter().convert(B.deck(slides: [.init(file: "s.xml", shapes: B.shape(placeholder: nil, paragraphs: [paragraph]), relationships: relationships)]), info: StreamInfo(detectedFormat: .pptx))
        #expect(result.markdown().contains("[Default](https://example.com/default)"))
        #expect(result.markdown().contains("[Explicit](https://example.com/explicit)"))
    }
    @Test func inheritedDefaultLinkResolvesInItsOwningLayout() async throws {
        let ph = "<p:ph type='body' idx='1'/>"
        let local = B.shape(placeholder: ph, paragraphs: ["<a:p><a:r><a:t>Inherited</a:t></a:r></a:p>"])
        let inherited = B.shape(placeholder: ph, paragraphs: []).replacingOccurrences(of: "<a:bodyPr/>", with: "<a:bodyPr/><a:lstStyle><a:lvl1pPr><a:defRPr><a:hlinkClick r:id='link'/></a:defRPr></a:lvl1pPr></a:lstStyle>")
        var parts = PowerPointTwelfthStackReviewTests.themeParts(layoutShapes: inherited)
        parts = parts.map { entry in
            entry.name == "ppt/slideLayouts/_rels/l.xml.rels" ? (name: entry.name, data: Array(String(decoding: entry.data, as: UTF8.self).replacingOccurrences(of: "</Relationships>", with: "<Relationship Id='link' Type='" + R.rel + "hyperlink' Target='https://example.com/layout' TargetMode='External'/></Relationships>").utf8)) : entry
        }
        let data = B.deck(slides: [.init(file: "s.xml", shapes: local, relationships: [("layout", R.rel + "slideLayout", "../slideLayouts/l.xml")])], extraParts: parts)
        let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
        #expect(result.markdown().contains("[Inherited](https://example.com/layout)"))
    }
    @Test func tableAndListBreaksRemainAttributeSafe() throws {
        for markdown in ["| ![One<br>Two](image.png) |\n| --- |\n| A<br>B |", "- ![One  \n  Two](image.png)"] {
            let html = try DocumentRenderer.render(ConverterResult(sections: [.init(markdown: markdown)]), to: .html)
            let document = try SwiftSoup.parse(html)
            let image = try #require(try document.getElementsByTag("img").first())
            #expect(try image.attr("alt") == "One\nTwo")
            #expect(!html.contains("alt=\"One<br>Two\""))
        }
    }
}
