import Foundation
import Testing
@testable import PicoDocs

struct PowerPointTwentiethStackReviewTests {
    typealias B = PowerPointConverterTests
    typealias R = PowerPointThirdStackReviewTests
    @Test func presentationDefaultsReserveTheirExternalImageIdentities() async throws {
        let body = B.shape(placeholder: nil, paragraphs: ["<a:p><a:r><a:t>Outside</a:t></a:r></a:p>"]) + R.picture("image")
        var data = B.deck(slides: [.init(file: "s.xml", shapes: body, relationships: [("image", R.rel + "image", "../media/photo.png")])], extraParts: [("ppt/media/photo.png", [1,2,3])])
        data = try R.replacing(data, part: "ppt/presentation.xml") { $0.replacingOccurrences(of: "</p:presentation>", with: "<p:defaultTextStyle><a:lvl1pPr><a:defRPr><a:hlinkClick r:id='outside'/></a:defRPr></a:lvl1pPr></p:defaultTextStyle></p:presentation>") }
        data = try R.replacing(data, part: "ppt/_rels/presentation.xml.rels") { $0.replacingOccurrences(of: "</Relationships>", with: "<Relationship Id='outside' Type='" + R.rel + "hyperlink' Target='photo.png' TargetMode='External'/></Relationships>") }
        let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
        #expect(result.markdown().contains("[Outside](photo.png)"))
        #expect(result.sections.first { $0.kind == .image }?.metadata["markdownReference"]?.hasPrefix("picodocs-embedded/") == true)
    }
    @Test func hiddenMasterDoesNotHideLayoutContent() async throws {
        let layout = B.shape(placeholder: nil, paragraphs: ["<a:p><a:r><a:t>Layout content</a:t></a:r></a:p>"])
        let master = layout.replacingOccurrences(of: "Layout content", with: "Master content")
        let parts = PowerPointTwelfthStackReviewTests.themeParts(layoutShapes: layout, masterShapes: master)
        var data = B.deck(slides: [.init(file: "s.xml", shapes: "", relationships: [("layout", R.rel + "slideLayout", "../slideLayouts/l.xml")])], extraParts: parts)
        data = try R.replacing(data, part: "ppt/slides/s.xml") { $0.replacingOccurrences(of: "<p:sld ", with: "<p:sld showMasterSp='0' ") }
        let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
        #expect(result.markdown().contains("Layout content"))
        #expect(!result.markdown().contains("Master content"))
    }
    @Test func preservedWhitespaceOnlyTextRemainsAnEmptySlide() async throws {
        for placeholder in ["<p:ph type='title'/>", "<p:ph type='body'/>"] {
            let shapes = B.shape(placeholder: placeholder, paragraphs: ["<a:p><a:r><a:t xml:space='preserve'>  \t </a:t></a:r></a:p>"])
            let result = try await PowerPointConverter().convert(B.deck(slides: [.init(file: "s.xml", shapes: shapes)]), info: StreamInfo(detectedFormat: .pptx))
            // This Office integration layer keeps native blank slide slots.
            let slide = try #require(result.sections.first { $0.kind == .slide })
            #expect(slide.markdown.isEmpty)
            #expect(slide.slideNumber == 1)
            #expect(slide.title == nil || slide.title?.isEmpty == true)
        }
    }
    @Test func sanitizedDecomposedImageReferenceStillEmbedsBytes() async throws {
        let filename = "cafe%CC%81.png"
        let data = B.deck(slides: [.init(file: "s.xml", shapes: R.picture("image"), relationships: [("image", R.rel + "image", "../media/" + filename)])], extraParts: [("ppt/media/" + filename, [1,2,3])])
        let raw = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
        let result = UnicodeSanitizer.sanitize(raw)
        #expect(try DocumentRenderer.render(result, to: .html).contains("src=\"data:image/png;base64,AQID\""))
        #expect(result.sections.first { $0.kind == .image }?.metadata["base64"] == "AQID")
    }
}
