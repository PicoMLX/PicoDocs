import Foundation
import Testing
@testable import PicoDocs

struct NumbersGraphReviewTests {
    @Test func objectCountAdmissionIsCumulativeAcrossStreams() throws {
        typealias B = PagesConverterTests
        let stream = B.makeIWAStream(objects: [(1, 1, [], []), (2, 2, [], [])])
        let budget = IWAObjectBudget(objects: 2)
        #expect(IWAArchive.objects(in: stream, objectBudget: budget).count == 2)
        try budget.check()
        #expect(IWAArchive.objects(in: stream, objectBudget: budget).isEmpty)
        #expect(throws: PicoDocsError.fileCorrupted) { try budget.check() }
    }
    @Test func oneEnvelopeCannotStageUnboundedMessageInfos() throws {
        typealias B = PagesConverterTests
        let info = B.varintField(1, 1) + B.varintField(3, 0)
        var header = B.varintField(1, 1)
        for _ in 0..<3 { header += B.lengthField(2, info) }
        let stream = B.varint(UInt64(header.count)) + header
        let budget = IWAObjectBudget(objects: 2)
        #expect(IWAArchive.objects(in: stream, objectBudget: budget).isEmpty)
        #expect(throws: PicoDocsError.fileCorrupted) { try budget.check() }
    }
    @Test func objectPayloadAndReferenceCopiesAreAdmitted() throws {
        typealias B = PagesConverterTests
        let references = Array(UInt64(10)..<UInt64(110))
        let stream = B.makeIWAStream(objects: [(1, 2, [1, 2, 3], references)])
        let enough = IWAObjectBudget(bytes: 8192)
        #expect(IWAArchive.objects(in: stream, objectBudget: enough).first?.references == references)
        try enough.check()
        let tight = IWAObjectBudget(bytes: 512)
        #expect(IWAArchive.objects(in: stream, objectBudget: tight).isEmpty)
        #expect(throws: PicoDocsError.fileCorrupted) { try tight.check() }
        let exact = IWAObjectBudget(bytes: 8192 - enough.remainingBytes)
        #expect(IWAArchive.objects(in: stream, objectBudget: exact).count == 1)
        try exact.check()
        let over = IWAObjectBudget(bytes: 8192 - enough.remainingBytes - 1)
        #expect(IWAArchive.objects(in: stream, objectBudget: over).isEmpty)
        #expect(throws: PicoDocsError.fileCorrupted) { try over.check() }
    }
    @Test func NumbersReportsObjectExhaustionBeforeEmptyDocument() async throws {
        let converter = NumbersConverter(outputBudgetBytes: 64 * 1024 * 1024, objectBudgetBytes: 10)
        await #expect(throws: PicoDocsError.fileCorrupted) {
            _ = try await converter.convert(NumbersReviewTests.workbook(), info: StreamInfo(detectedFormat: .numbers))
        }
    }
    @Test func reachedTablesRetainDiscoveryOrderWithoutDuplicateWork() {
        let ids = Array(UInt64(10)..<UInt64(50_010))
        let objects: [UInt64: IWAArchive.Object] = [
            1: .init(identifier: 1, type: 2, payload: [], references: ids + ids.reversed()),
            2: .init(identifier: 2, type: 2, payload: [], references: [1])
        ]
        let found = IWATable.reachableTiles(from: 2, objects: objects, tiles: Set(ids), blocked: [10])
        #expect(found == Array(ids.dropFirst()))
    }
}
