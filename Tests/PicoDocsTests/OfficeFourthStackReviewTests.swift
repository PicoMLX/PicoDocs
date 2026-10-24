import Foundation
import Testing
@testable import PicoDocs

struct OfficeFourthStackReviewTests {
    @Test func speakerNotesSurviveTwoPPTXRoundTripsInNativeNotesParts() async throws {
        let notes = "Presenter **emphasis**\n\nSecond paragraph"
        let source = ConverterResult(sections: [.init(title: "Slide", kind: .slide, markdown: "## Slide\n\nBody\n\n### Notes\n\n" + notes, slideNumber: 1, metadata: ["notes": notes])])
        let first = try PicoDocsEngine.write(source, to: .pptx)
        let visible = try OfficeStackReviewTests.xml(first, "ppt/slides/slide1.xml")
        #expect(!visible.contains("Presenter"))
        let native = try OfficeStackReviewTests.xml(first, "ppt/notesSlides/notesSlide1.xml")
        #expect(native.contains("Presenter"))
        let converted = try await PicoDocsEngine.convert(data: first, filename: "notes.pptx")
        let convertedNotes = try #require(converted.sections.first?.metadata["notes"])
        #expect(OfficeDocumentBlocks.decodedPreservedWhitespace(convertedNotes) == notes)
        let second = try PicoDocsEngine.write(converted, to: .pptx)
        let again = try await PicoDocsEngine.convert(data: second, filename: "notes-again.pptx")
        #expect(again.sections.first?.metadata["notes"] == convertedNotes)
    }

    @Test func lateCanonicalRTFMarkersNeverDiscardEarlierBody() async throws {
        for text in [#"{\rtf1 Before\par{\*\picodocsmarkdown1}After}"#, #"{\rtf1 Before{\*\picodocsmarkdown1}}"#, #"{\rtf1 \par{\*\picodocsmarkdown1}After}"#] {
            let result = try await RTFConverter().convert(Data(text.utf8), info: StreamInfo(detectedFormat: .rtf))
            if text.contains("Before") { #expect(result.markdown().contains("Before")) }
            if text.contains("After") { #expect(result.markdown().contains("After")) }
        }
    }

    @Test func emptyHeadingSlugRetainsNativeJump() async throws {
        let data = try PicoDocsEngine.write(markdown: "# !!!\n\n[jump](#)", to: .pptx)
        let result = try await PicoDocsEngine.convert(data: data, filename: "empty-slug.pptx")
        #expect(result.markdown().contains("[jump](#)"))
    }
}
