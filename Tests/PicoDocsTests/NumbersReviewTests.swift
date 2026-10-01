import Foundation
import Testing
import UniformTypeIdentifiers
import ZIPFoundation
@testable import PicoDocs

@Suite struct NumbersReviewTests {
    static func workbook(name: String = "Sheet", orphan: Bool = false, cellValue: String = "Same") -> Data {
        typealias B = PagesConverterTests
        func table(_ id: UInt64) -> [(id: UInt64, type: UInt64, payload: [UInt8], references: [UInt64])] {
            // Two identical tables must remain distinct even when one is unclaimed.
            let cell: [UInt8] = [5, 3] + Array(repeating: 0, count: 10) + [1, 0, 0, 0]
            let tile = B.lengthField(5, B.lengthField(6, cell) + B.lengthField(7, [0, 0]))
            let strings = B.varintField(1, 1) + B.lengthField(3, B.varintField(1, 1) + B.lengthField(3, Array(cellValue.utf8)))
            return [(id, 6001, [], [id + 1, id + 2]), (id + 1, 6002, tile, []), (id + 2, 6005, strings, [])]
        }
        let document = B.lengthField(1, B.varintField(1, 10))
        var objects: [(id: UInt64, type: UInt64, payload: [UInt8], references: [UInt64])] = [
            (1, 1, document, [10]), (10, 2, B.lengthField(1, Array(name.utf8)), [20])
        ]
        objects += table(20)
        if orphan { objects += table(30) }
        return B.makeZip([(name: "Index/Document.iwa", data: B.snappyFrame(B.makeIWAStream(objects: objects)))])
    }

    @Test func unclaimedIdenticalTableSurvivesPartialAttribution() async throws {
        let result = try await NumbersConverter().convert(Self.workbook(orphan: true), info: StreamInfo(detectedFormat: .numbers))
        #expect(result.sections.count == 2)
        #expect(result.sections.allSatisfy { $0.markdown.contains("Same") })
        #expect(result.sections.first?.sheetName == "Sheet")
        #expect(result.sections.last?.sheetName == nil)
    }

    @Test func sheetNameIsLiteralInRenderedHeading() async throws {
        let name = "*Draft* `code` [a](https://example.com) <tag>"
        let result = try await NumbersConverter().convert(Self.workbook(name: name), info: StreamInfo(detectedFormat: .numbers))
        #expect(result.sections.first?.sheetName == name)
        #expect(result.sections.first?.title == name)
        #expect(try DocumentRenderer.render(result, to: .plaintext).hasPrefix(name + "\n\n"))
    }

    @Test(arguments: ["#", "Plan #", "Plan ###", "Plan #\u{0301}"])
    func sheetHeadingClosingHashesRemainLiteral(_ name: String) async throws {
        let result = try await NumbersConverter().convert(Self.workbook(name: name), info: StreamInfo(detectedFormat: .numbers))
        #expect(result.sections.first?.sheetName == name)
        #expect(result.sections.first?.title == name)
        let parsed = try AttributedString(markdown: result.markdown())
        #expect(String(parsed.characters).hasPrefix(name))
        #expect(try DocumentRenderer.render(result, to: .plaintext).hasPrefix(name + "\n\n"))
    }

    @Test(arguments: ["AT&amp;T", "&#35;", "&copy;"])
    func entityLikeSheetNamesRemainLiteral(_ name: String) async throws {
        let result = try await NumbersConverter().convert(Self.workbook(name: name), info: StreamInfo(detectedFormat: .numbers))
        let parsed = try AttributedString(markdown: result.markdown())
        #expect(String(parsed.characters).hasPrefix(name))
    }

    @Test func emptyAndUnsupportedOnlySheetsRetainNamesAndOrder() async throws {
        typealias B = PagesConverterTests
        let document = B.lengthField(1, B.varintField(1, 10)) + B.lengthField(1, B.varintField(1, 11))
        let objects: [(id: UInt64, type: UInt64, payload: [UInt8], references: [UInt64])] = [
            (1, 1, document, [10, 11]), (11, 2, B.lengthField(1, Array("Charts".utf8)), [20]),
            (10, 2, B.lengthField(1, Array("Empty".utf8)), []), (20, 5000, [], [])
        ]
        let data = B.makeZip([(name: "Index/Document.iwa", data: B.snappyFrame(B.makeIWAStream(objects: objects)))])
        let result = try await NumbersConverter().convert(data, info: StreamInfo(detectedFormat: .numbers))
        #expect(result.sections.map(\.sheetName) == ["Empty", "Charts"])
        #expect(result.sections.map(\.markdown) == ["## Empty\n\n", "## Charts\n\n"])
    }

    @Test func directoryWorkbookIsNotAdvertisedAsConvertible() {
        #expect(!UTType.numbers.isSupported)
        #expect(UTType.numbersSingleFile.isSupported)
    }

    @Test(arguments: [" Sheet ", "\tSheet\t", " \tSheet\t "])
    func sheetBoundaryWhitespaceStaysLiteral(_ name: String) async throws {
        let result = try await NumbersConverter().convert(Self.workbook(name: name), info: StreamInfo(detectedFormat: .numbers))
        #expect(String(try AttributedString(markdown: result.markdown()).characters).hasPrefix(name))
        #expect(try DocumentRenderer.render(result, to: .plaintext).hasPrefix(name + "\n\n"))
    }

    @Test func partiallyResolvedSheetOrderAppendsRecoveredSheets() async throws {
        typealias B = PagesConverterTests
        let document = B.lengthField(1, B.varintField(1, 10)) + B.lengthField(1, [0x08])
        let objects: [(id: UInt64, type: UInt64, payload: [UInt8], references: [UInt64])] = [
            (1, 1, document, [10]), (11, 2, B.lengthField(1, Array("Recovered".utf8)), []),
            (10, 2, B.lengthField(1, Array("Ordered".utf8)), [])
        ]
        let data = B.makeZip([(name: "Index/Document.iwa", data: B.snappyFrame(B.makeIWAStream(objects: objects)))])
        let result = try await NumbersConverter().convert(data, info: StreamInfo(detectedFormat: .numbers))
        #expect(result.sections.map(\.sheetName) == ["Ordered", "Recovered"])
    }
    @Test func archiveAndDecodedOutputBudgetsStopExpansion() throws {
        typealias B = PagesConverterTests
        let payload = Array(repeating: UInt8(65), count: 12)
        let archive = try Archive(data: B.makeZip([(name: "Index/Document.iwa", data: payload), (name: "Index/Aux.iwa", data: payload)]), accessMode: .read)
        #expect(throws: PicoDocsError.fileCorrupted) { try PagesConverter.iwaComponents(in: archive, maximumEntryBytes: 11, maximumTotalBytes: 24) }
        #expect(throws: PicoDocsError.fileCorrupted) { try PagesConverter.iwaComponents(in: archive, maximumEntryBytes: 12, maximumTotalBytes: 23) }
        #expect(try PagesConverter.iwaComponents(in: archive, maximumEntryBytes: 12, maximumTotalBytes: 24).count == 2)
        let nestedBytes = B.makeZip([(name: "Document.iwa", data: payload)])
        let nested = try Archive(data: B.makeZip([(name: "Index.zip", data: Array(nestedBytes))]), accessMode: .read)
        // The outer container is itself a ZIP entry and has the same entry cap.
        #expect(throws: PicoDocsError.fileCorrupted) { try PagesConverter.iwaComponents(in: nested, maximumEntryBytes: nestedBytes.count - 1, maximumTotalBytes: nestedBytes.count + 12) }
        #expect(throws: PicoDocsError.fileCorrupted) { try PagesConverter.iwaComponents(in: nested, maximumEntryBytes: nestedBytes.count, maximumTotalBytes: nestedBytes.count + 11) }
        #expect(try PagesConverter.iwaComponents(in: nested, maximumEntryBytes: nestedBytes.count, maximumTotalBytes: nestedBytes.count + 12).count == 1)
        let frames = B.snappyFrame(payload) + B.snappyFrame(payload)
        #expect(throws: Snappy.SnappyError.outputLimitExceeded) { try Snappy.decompressIWA(frames, maximumOutputBytes: 23) }
        #expect(try Snappy.decompressIWA(frames, maximumOutputBytes: 24).count == 24)
        // A tiny block with an oversized declared expansion fails before reserve/copy.
        #expect(throws: Snappy.SnappyError.outputLimitExceeded) { try Snappy.decompressBlock(B.varint(1_000_000_000), maximumOutputBytes: 32) }
    }

    @Test(arguments: ["AT&amp;T", "&copy;", "&#35;", "\\&copy;"])
    func entityLikeCellValuesRemainLiteral(_ value: String) async throws {
        let result = try await NumbersConverter().convert(Self.workbook(cellValue: value), info: StreamInfo(detectedFormat: .numbers))
        #expect(String(try AttributedString(markdown: result.markdown()).characters).contains(value))
        #expect(try DocumentRenderer.render(result, to: .plaintext).contains(value))
        #expect(try DocumentRenderer.render(result, to: .html).contains(value.replacingOccurrences(of: "&", with: "&amp;")))
    }

    @Test func cancellationDuringOneLargeSnappyBlockDoesNotReturnSuccess() async throws {
        let size = 32 * 1024 * 1024
        var block = PagesConverterTests.varint(UInt64(size)) + [0, UInt8(65)]
        var remaining = size - 1
        while remaining > 0 {
            let count = min(64, remaining)
            block += [UInt8((count - 1) << 2) | 2, 1, 0]
            remaining -= count
        }
        let input = block
        let task = Task.detached {
            do {
                _ = try Snappy.decompressBlock(input, maximumOutputBytes: size)
                return false
            } catch is CancellationError { return true }
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        task.cancel()
        #expect(try await task.value)
    }

    @Test func cancellationStopsAlreadyDecodedIWAAndTableReconstruction() async throws {
        typealias B = PagesConverterTests
        let stream = B.makeIWAStream(objects: [(1, 2001, B.lengthField(3, Array("Body".utf8)), [])])
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            var reader = ProtobufReader([8, 1])
            #expect(reader.next() == nil)
            #expect(IWAArchive.objects(in: stream).isEmpty)
            do {
                _ = try IWATable.inlineBlocks(documentStream: stream, in: [stream])
                return false
            } catch is CancellationError { return true }
        }
        #expect(try await task.value)
    }

    static func repeatedCellStream(rows: [Int], value: String) -> [UInt8] {
        typealias B = PagesConverterTests
        let cell: [UInt8] = [5, 3] + Array(repeating: 0, count: 10) + [1, 0, 0, 0]
        var tile: [UInt8] = []
        for columns in rows {
            let offsets = Array(repeating: UInt8(0), count: columns * 2)
            let row = B.lengthField(6, cell) + B.lengthField(7, offsets)
            tile += B.lengthField(5, row)
        }
        let entry = B.varintField(1, 1) + B.lengthField(3, Array(value.utf8))
        let strings = B.varintField(1, 1) + B.lengthField(3, entry)
        return B.makeIWAStream(objects: [(20, 6001, [], [21, 22]), (21, 6002, tile, []), (22, 6005, strings, [])])
    }

    @Test func repeatedCellStringsAndSparsePaddingAreAdmittedBeforeExpansion() throws {
        let value = String(repeating: "&", count: 100)
        let one = Self.repeatedCellStream(rows: [1], value: value)
        let smallBudget = IWAOutputBudget(bytes: 4096)
        let small = IWATable.attributedTables(rootIDs: [], in: [one], excludingSubgraphs: [], budget: smallBudget)
        try smallBudget.check()
        #expect(small.unclaimed.count == 1)
        #expect(small.unclaimed[0].contains(String(repeating: "\\&", count: 100)))
        let repeated = Self.repeatedCellStream(rows: [1000], value: value)
        let repeatedBudget = IWAOutputBudget(bytes: 4096)
        _ = IWATable.attributedTables(rootIDs: [], in: [repeated], excludingSubgraphs: [], budget: repeatedBudget)
        #expect(throws: PicoDocsError.fileCorrupted) { try repeatedBudget.check() }
        let sparse = Self.repeatedCellStream(rows: [100] + Array(repeating: 1, count: 99), value: "a")
        let sparseBudget = IWAOutputBudget(bytes: 1_000_000, cells: 1000)
        _ = IWATable.attributedTables(rootIDs: [], in: [sparse], excludingSubgraphs: [], budget: sparseBudget)
        #expect(throws: PicoDocsError.fileCorrupted) { try sparseBudget.check() }
    }

    @Test func outputAdmissionHasAnExactBoundaryAndIncludesRecoveredTables() async throws {
        let stream = Self.repeatedCellStream(rows: [3, 1], value: "a&b")
        let measured = IWAOutputBudget(bytes: 4096)
        let expected = IWATable.attributedTables(rootIDs: [], in: [stream], excludingSubgraphs: [], budget: measured)
        try measured.check()
        let used = 4096 - measured.remainingBytes
        let exact = IWAOutputBudget(bytes: used)
        let actual = IWATable.attributedTables(rootIDs: [], in: [stream], excludingSubgraphs: [], budget: exact)
        try exact.check()
        #expect(actual.unclaimed == expected.unclaimed)
        let short = IWAOutputBudget(bytes: used - 1)
        _ = IWATable.attributedTables(rootIDs: [], in: [stream], excludingSubgraphs: [], budget: short)
        #expect(throws: PicoDocsError.fileCorrupted) { try short.check() }
        _ = try await NumbersConverter(outputBudgetBytes: 1000).convert(Self.workbook(), info: StreamInfo(detectedFormat: .numbers))
        await #expect(throws: PicoDocsError.fileCorrupted) {
            try await NumbersConverter(outputBudgetBytes: 1000).convert(Self.workbook(orphan: true), info: StreamInfo(detectedFormat: .numbers))
        }
    }

    @Test func cancellationInterruptsActiveDecodedTableReconstruction() async throws {
        let stream = Self.repeatedCellStream(rows: [1000], value: String(repeating: "&", count: 2048))
        let task = Task.detached {
            let budget = IWAOutputBudget()
            _ = IWATable.attributedTables(rootIDs: [], in: [stream], excludingSubgraphs: [], budget: budget)
            do { try budget.check(); return false }
            catch is CancellationError { return true }
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        task.cancel()
        #expect(try await task.value)
    }

}
