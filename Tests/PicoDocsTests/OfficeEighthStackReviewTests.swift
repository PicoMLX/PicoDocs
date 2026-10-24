import Foundation
import Testing
@testable import PicoDocs

struct OfficeEighthStackReviewTests {
    @Test func malformedImageCandidatesConsumeAggregateProbeBytes() throws {
        let budget = OfficeMediaDecodeBudget(maximumImageBytes: 3, maximumBytes: 6, maximumImages: 3)
        #expect(try budget.decodeCandidate("AQI!") == nil)
        #expect(try budget.decodeCandidate("AQI!") == nil)
        #expect(throws: ExporterError.self) { _ = try budget.decodeCandidate("AQI!") }
    }
    @Test func candidateProbeAndCommittedStorageHaveSeparateAllowances() throws {
        let budget = OfficeMediaDecodeBudget(maximumImageBytes: 3, maximumBytes: 6, maximumImages: 3)
        let data = try #require(try budget.decodeCandidate("AQID"))
        try budget.reserve(data)
        let second = try #require(try budget.decodeCandidate("BAUG"))
        try budget.reserve(second)
        #expect(throws: ExporterError.self) { _ = try budget.decodeCandidate("AQID") }
        let empty = OfficeMediaDecodeBudget(maximumImages: 1)
        #expect(try empty.decodeCandidate("") == Data())
        #expect(throws: ExporterError.self) { _ = try empty.decodeCandidate("") }
    }
    @Test func shiftJISHyperlinkInstructionRetainsMultibyteTarget() async throws {
        let rtf = #"{\rtf1\ansi\ansicpg932{\field{\*\fldinst HYPERLINK "https://example.test/\'82\'a0"}{\fldrslt Link}}}"#
        let result = try await PicoDocsEngine.convert(data: Data(rtf.utf8), filename: "link.rtf")
        #expect(result.markdown().contains("https://example.test/あ"))
    }
}
