import Foundation
import Testing
import UniformTypeIdentifiers
@testable import PicoDocs

struct NumbersRoutingDateReviewTests {
    @Test @MainActor func normalNumbersUTICanReachFlatFileImport() {
        let url = URL(string: "https://example.test/workbook.numbers")!
        #expect(UTType.numbers.isSupported)
        #expect(PicoDocument(url: url, utType: .numbers).status == .awaitingFetch)
    }
    @Test func modernFractionalTimesDoNotInventNanoseconds() async throws {
        typealias T = NumbersTypedCellReviewTests
        let base: Double = 803_433_600
        let cells = [base + 34200.1, base + 34200.123, -0.125].map { T.cell(5, T.double($0), fields: 4) }
        let result = try await NumbersConverter().convert(T.workbook(cells), info: StreamInfo(detectedFormat: .numbers))
        #expect(result.markdown().contains("2026-06-18T09:30:00.1 |"))
        #expect(result.markdown().contains("2026-06-18T09:30:00.123 |"))
        #expect(result.markdown().contains("2000-12-31T23:59:59.875"))
    }
}

extension NumbersRoutingDateReviewTests {
    @Test func PagesFallbackDoesNotReparseAnAlreadyAdmittedGraph() throws {
        let source = "Start " + String(repeating: "x", count: 1024 * 1024) + "\u{FFFC} End"
        let stream = PagesConverterTests.makeIWAStream(runs: [source])
        let budget = IWAObjectBudget(bytes: 3 * 1024 * 1024)
        let prepared = try IWATable.PreparedDocument(documentStream: stream, streams: [stream], objectBudget: budget)
        let blocks = try IWATable.inlineBlocks(documentStream: stream, in: [stream], objectBudget: budget, prepared: prepared)
        #expect(blocks == nil)
        let fallback = try IWATable.bodyMarkdown(documentStream: stream, in: [stream], objectBudget: budget, prepared: prepared)
        #expect(fallback.contains("Start "))
        _ = IWATable.markdownTables(from: [stream], objectBudget: budget, prepared: prepared)
        try budget.check()
    }
}

extension NumbersRoutingDateReviewTests {
    @Test @MainActor func packageDirectoriesStillUseDirectoryTraversal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".numbers", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = PicoDocument(url: root, utType: .numbers)
        #expect(document.utType == .folder)
        let fetched = try await FileFetcher(url: root).fetch()
        #expect(fetched.0 == nil)
        #expect(fetched.2 != nil)
    }
    @Test func fractionalRoundingCarriesWithoutProducingSixtySeconds() async throws {
        typealias T = NumbersTypedCellReviewTests
        let base: Double = 803_433_600
        let cells = [base + 59.9999996, base + 86_399.9999996].map { T.cell(5, T.double($0), fields: 4) }
        let result = try await NumbersConverter().convert(T.workbook(cells), info: StreamInfo(detectedFormat: .numbers))
        #expect(result.markdown().contains("2026-06-18T00:01:00"))
        #expect(result.markdown().contains("2026-06-19 |"))
    }
}
