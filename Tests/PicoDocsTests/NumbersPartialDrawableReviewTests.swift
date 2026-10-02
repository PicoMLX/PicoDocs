import Foundation
import Testing
@testable import PicoDocs

struct NumbersPartialDrawableReviewTests {
    @Test(arguments: [false, true])
    func partiallyDecodedGroupRetainsEnvelopeTableReferences(_ truncatedField: Bool) async throws {
        typealias T = NumbersTraversalReviewTests
        typealias B = PagesConverterTests
        let malformed: [UInt8] = truncatedField ? [0x12, 4, 0x08] : B.lengthField(2, [0x08])
        let group = B.lengthField(2, T.reference(19)) + malformed
        let objects: [T.O] = [
            (50, 3008, group, [19,29]),
            (19, 6000, B.lengthField(2, T.reference(20)), [20]),
            (20, 6001, [], [21,23]), (21,6002,T.tile([(0,1)]),[]), (23,6005,T.strings(["First"]),[]),
            (29,6000,B.lengthField(2,T.reference(30)),[30]),
            (30,6001,[],[31,33]), (31,6002,T.tile([(0,1)]),[]), (33,6005,T.strings(["Second"]),[])
        ]
        let result = try await NumbersConverter().convert(T.workbook(objects, drawables: [50]), info: StreamInfo(detectedFormat: .numbers))
        let markdown = try #require(result.sections.first?.markdown)
        #expect(markdown.contains("First"))
        #expect(markdown.contains("Second"))
        #expect(result.sections.count == 1)
        #expect(result.sections.first?.sheetName == "Sheet")
    }
}
