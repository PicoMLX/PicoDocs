import Foundation
import Testing
@testable import PicoDocs

struct NumbersTraversalReviewTests {
    typealias B = PagesConverterTests
    typealias O = (id: UInt64, type: UInt64, payload: [UInt8], references: [UInt64])
    static func reference(_ id: UInt64) -> [UInt8] { B.varintField(1, id) }
    static func tile(_ rows: [(UInt64, UInt8)]) -> [UInt8] {
        var payload: [UInt8] = []
        for (index, key) in rows {
            let cell: [UInt8] = [5, 3] + Array(repeating: 0, count: 10) + [key, 0, 0, 0]
            let row = B.varintField(1, index) + B.lengthField(6, cell) + B.lengthField(7, [0, 0])
            payload += B.lengthField(5, row)
        }
        return payload
    }
    static func strings(_ names: [String]) -> [UInt8] {
        var payload = B.varintField(1, 1)
        for (index, value) in names.enumerated() {
            let entry = B.varintField(1, UInt64(index + 1)) + B.lengthField(3, Array(value.utf8))
            payload += B.lengthField(3, entry)
        }
        return payload
    }
    static func workbook(_ objects: [O], drawables: [UInt64]) -> Data {
        let document = B.lengthField(1, reference(10))
        var sheet = B.lengthField(1, Array("Sheet".utf8))
        for id in drawables { sheet += B.lengthField(2, reference(id)) }
        let all: [O] = [(1, 1, document, [10]), (10, 2, sheet, drawables.reversed())] + objects
        return B.makeZip([("Index/Document.iwa", B.snappyFrame(B.makeIWAStream(objects: all)))])
    }

    @Test func onePhysicalTableMergesAllTilesByTheirNativeRowRanges() async throws {
        let tile0 = B.varintField(1, 0) + B.lengthField(2, Self.reference(21))
        let tile1 = B.varintField(1, 1) + B.lengthField(2, Self.reference(22))
        let storage = B.lengthField(1, tile1) + B.lengthField(1, tile0) + B.varintField(2, 2)
        let model = B.lengthField(4, B.lengthField(3, storage))
        let objects: [O] = [
            (19, 6000, B.lengthField(2, Self.reference(20)), [20]),
            (20, 6001, model, [22, 21, 23]),
            (21, 6002, Self.tile([(0, 1), (1, 2)]), []),
            (22, 6002, Self.tile([(0, 3), (1, 4)]), []),
            (23, 6005, Self.strings(["A", "A2", "B", "B2"]), [])
        ]
        let result = try await NumbersConverter().convert(Self.workbook(objects, drawables: [19]), info: StreamInfo(detectedFormat: .numbers))
        #expect(result.sections.count == 1)
        #expect(result.sections[0].markdown.contains("| A |\n| --- |\n| A2 |\n| B |\n| B2 |"))
    }

    @Test func groupedTablePrecedesTheNextSheetDrawable() async throws {
        let objects: [O] = [
            (50, 3008, B.lengthField(2, Self.reference(19)), [10, 19]),
            (19, 6000, B.lengthField(2, Self.reference(20)), [20]),
            (20, 6001, [], [21, 23]), (21, 6002, Self.tile([(0, 1)]), []),
            (23, 6005, Self.strings(["First"]), []),
            (29, 6000, B.lengthField(2, Self.reference(30)), [30]),
            (30, 6001, [], [31, 33]), (31, 6002, Self.tile([(0, 1)]), []),
            (33, 6005, Self.strings(["Second"]), [])
        ]
        let result = try await NumbersConverter().convert(Self.workbook(objects, drawables: [50, 29]), info: StreamInfo(detectedFormat: .numbers))
        let markdown = try #require(result.sections.first?.markdown)
        let first = try #require(markdown.range(of: "First")?.lowerBound)
        let second = try #require(markdown.range(of: "Second")?.lowerBound)
        #expect(first < second)
    }

    @Test func nestedReferencesHaveDepthAndCumulativeCopyAdmission() throws {
        var bytes = Self.reference(99)
        for _ in 0..<63 { bytes = B.lengthField(1, bytes) }
        let depth = IWAObjectBudget()
        #expect(IWATable.referencedID(in: bytes, objectBudget: depth) == 99)
        try depth.check()
        let exceeded = IWAObjectBudget()
        #expect(IWATable.referencedID(in: B.lengthField(1, bytes), objectBudget: exceeded) == nil)
        #expect(throws: PicoDocsError.fileCorrupted) { try exceeded.check() }
        let enough = IWAObjectBudget(bytes: 64 * 1024)
        #expect(IWATable.referencedID(in: bytes, objectBudget: enough) == 99)
        let used = 64 * 1024 - enough.remainingBytes
        let exact = IWAObjectBudget(bytes: used)
        #expect(IWATable.referencedID(in: bytes, objectBudget: exact) == 99)
        try exact.check()
        let tight = IWAObjectBudget(bytes: used - 1)
        #expect(IWATable.referencedID(in: bytes, objectBudget: tight) == nil)
        #expect(throws: PicoDocsError.fileCorrupted) { try tight.check() }
    }

    @Test func richDataListReconstructionPropagatesWrapperExhaustion() async throws {
        var wrapped = Self.reference(25)
        for _ in 0..<96 { wrapped = B.lengthField(1, wrapped) }
        let entry = B.varintField(1, 1) + B.lengthField(9, wrapped)
        let rich = B.varintField(1, 8) + B.lengthField(3, entry)
        let objects: [O] = [(20, 6001, [], [21, 23]), (21, 6002, Self.tile([(0, 1)]), []),
                            (23, 6005, rich, [25]), (25, 6218, Self.reference(26), [26]),
                            (26, 2001, B.lengthField(3, Array("Text".utf8)), [])]
        await #expect(throws: PicoDocsError.fileCorrupted) {
            _ = try await NumbersConverter().convert(Self.workbook(objects, drawables: [20]), info: StreamInfo(detectedFormat: .numbers))
        }
    }

    @Test func graphWorkIsCumulativeAcrossRoots() throws {
        let objects: [UInt64: IWAArchive.Object] = [1: .init(identifier: 1, type: 2, payload: [], references: [99])]
        let exact = IWAObjectBudget(visits: 3)
        #expect(IWATable.reachableTiles(from: 1, objects: objects, tiles: [99], blocked: [], objectBudget: exact) == [99])
        try exact.check()
        #expect(IWATable.reachableTiles(from: 1, objects: objects, tiles: [99], blocked: [], objectBudget: exact).isEmpty)
        #expect(throws: PicoDocsError.fileCorrupted) { try exact.check() }
    }

    @Test func attributionStopsAfterAllPhysicalTablesAreClaimed() throws {
        var objects: [O] = [(20, 6001, [], [21, 23]), (21, 6002, Self.tile([(0, 1)]), []),
                            (23, 6005, Self.strings(["Once"]), [])]
        let roots = Array(UInt64(100)..<UInt64(1_100))
        for id in roots { objects.append((id, 2, [], [21])) }
        let work = IWAObjectBudget(visits: 3)
        let result = IWATable.attributedTables(rootIDs: roots, in: [B.makeIWAStream(objects: objects)], excludingSubgraphs: [], objectBudget: work)
        try work.check()
        #expect(result.byRoot.count == 1)
        #expect(result.byRoot[100]?.first?.contains("Once") == true)
        #expect(result.unclaimed.isEmpty)
    }

    @Test func sparseNativeTileRowsAreAdmittedBeforePadding() async throws {
        let objects: [O] = [(20, 6001, [], [21, 23]), (21, 6002, Self.tile([(1_000_000, 1)]), []),
                            (23, 6005, Self.strings(["Too far"]), [])]
        await #expect(throws: PicoDocsError.fileCorrupted) {
            _ = try await NumbersConverter().convert(Self.workbook(objects, drawables: [20]), info: StreamInfo(detectedFormat: .numbers))
        }
    }
}
