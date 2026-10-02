import Foundation
import Testing
@testable import PicoDocs

struct PowerPointFifteenthStackReviewTests {
    @Test func relationshipIDsCollapseBeforeLookupAndDuplicateValidation() async throws {
        typealias B = PowerPointConverterTests
        var data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Visible"))])
        data = try PowerPointThirdStackReviewTests.replacing(data, part: "ppt/_rels/presentation.xml.rels") { $0.replacingOccurrences(of: "Id=\"rIdSlide0\"", with: "Id=\" &#9;rIdSlide0&#13; \"") }
        let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
        #expect(result.markdown() == "## Visible")
        let duplicate = try PowerPointThirdStackReviewTests.replacing(data, part: "ppt/_rels/presentation.xml.rels") {
            $0.replacingOccurrences(of: "</Relationships>", with: "<Relationship Id='rIdSlide0' Type='" + PowerPointThirdStackReviewTests.rel + "slide' Target='slides/s.xml'/></Relationships>")
        }
        await #expect(throws: PicoDocsError.fileCorrupted) {
            _ = try await PowerPointConverter().convert(duplicate, info: StreamInfo(detectedFormat: .pptx))
        }
    }

    @Test func notesFurnitureIsSkippedForPicturesAndGraphicFrames() async throws {
        typealias B = PowerPointConverterTests
        typealias R = PowerPointThirdStackReviewTests
        let picture = R.picture("thumbnail").replacingOccurrences(of: "<p:nvPr/>", with: "<p:nvPr><p:ph type='sldImg'/></p:nvPr>")
        let table = "<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id='3' name='Furniture'/><p:cNvGraphicFramePr/><p:nvPr><p:ph type='sldImg'/></p:nvPr></p:nvGraphicFramePr><a:graphic><a:graphicData uri='http://schemas.openxmlformats.org/drawingml/2006/table'><a:tbl><a:tr><a:tc><a:txBody><a:p><a:r><a:t>Thumbnail table</a:t></a:r></a:p></a:txBody></a:tc></a:tr></a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
        let shapes = B.shape(placeholder: "<p:ph type='body'/>", paragraphs: ["<a:p><a:pPr><a:buNone/></a:pPr><a:r><a:t>Notes body</a:t></a:r></a:p>"]) + picture + table
        let note = "<p:notes " + B.namespaces + "><p:cSld><p:spTree>" + shapes + "</p:spTree></p:cSld></p:notes>"
        let parts: [(name: String, data: [UInt8])] = [("ppt/notesSlides/n.xml", Array(note.utf8)), ("ppt/notesSlides/_rels/n.xml.rels", Array(B.relationshipsXML([("thumbnail", R.rel + "image", "../media/thumbnail.png")]).utf8)), ("ppt/media/thumbnail.png", [1, 2, 3])]
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Slide"), relationships: [("notes", R.rel + "notesSlide", "../notesSlides/n.xml")])], extraParts: parts)
        let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
        #expect(result.sections[0].metadata["notes"] == "Notes body")
        #expect(!result.sections.contains { $0.kind == .image })
    }
}
