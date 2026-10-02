import Foundation
import Testing
@testable import PicoDocs

struct KeynoteGraphReuseReviewTests {
    @Test func oneAdmittedSlideGraphDoesNotExhaustTheBudgetByBeingParsedTwice() async throws {
        let source = "Start " + String(repeating: "x", count: 1024 * 1024) + " End"
        let result = try await KeynoteConverter(objectBudgetBytes: 1536 * 1024).convert(KeynoteConverterTests.makeKeynoteFile(slides: [source]), info: StreamInfo(detectedFormat: .keynote))
        #expect(result.markdown().contains("Start "))
        #expect(result.markdown().contains(" End"))
    }
}
