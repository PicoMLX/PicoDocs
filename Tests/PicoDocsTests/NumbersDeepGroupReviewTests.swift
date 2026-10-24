import Foundation
import Testing
@testable import PicoDocs

struct NumbersDeepGroupReviewTests {
    @Test func deepDrawableGroupsKeepTableAttributionAndOrder() async throws {
        typealias T = NumbersTraversalReviewTests
        typealias B = PagesConverterTests
        var objects: [T.O] = [
            (19, 6000, B.lengthField(2, T.reference(20)), [20]),
            (20, 6001, [], [21, 23]), (21, 6002, T.tile([(0, 1)]), []),
            (23, 6005, T.strings(["First"]), []),
            (29, 6000, B.lengthField(2, T.reference(30)), [30]),
            (30, 6001, [], [31, 33]), (31, 6002, T.tile([(0, 1)]), []),
            (33, 6005, T.strings(["Second"]), [])
        ]
        for id in UInt64(100)..<120 {
            let child: UInt64 = id == 119 ? 19 : id + 1
            objects.append((id, 3008, B.lengthField(2, T.reference(child)), [child]))
        }
        let result = try await NumbersConverter().convert(T.workbook(objects, drawables: [100, 29]), info: StreamInfo(detectedFormat: .numbers))
        let markdown = try #require(result.sections.first?.markdown)
        let first = try #require(markdown.range(of: "First")?.lowerBound)
        let second = try #require(markdown.range(of: "Second")?.lowerBound)
        #expect(first < second)
        #expect(result.sections.first?.sheetName == "Sheet")
    }
    @Test func cyclicDrawableGraphsUseTheCumulativeVisitAllowance() throws {
        let objects: [UInt64: IWAArchive.Object] = [
            1: .init(identifier: 1, type: 6000, payload: [], references: [2]),
            2: .init(identifier: 2, type: 6001, payload: [], references: [1, 99])
        ]
        let exact = IWAObjectBudget(visits: 7)
        #expect(IWATable.reachableTiles(from: 1, objects: objects, tiles: [99], blocked: [], objectBudget: exact, drawableOrder: true) == [99])
        try exact.check()
        let tight = IWAObjectBudget(visits: 6)
        #expect(IWATable.reachableTiles(from: 1, objects: objects, tiles: [99], blocked: [], objectBudget: tight, drawableOrder: true).isEmpty)
        #expect(throws: PicoDocsError.fileCorrupted) { try tight.check() }
    }
}
