import Foundation
import Testing
@testable import PicoDocs

struct NumbersDocumentGraphReuseReviewTests {
    @Test func sheetDiscoveryAndAttributionShareOneAdmittedGraph() async throws {
        let name = String(repeating: "x", count: 1024 * 1024)
        let data = NumbersReviewTests.workbook(name: name)
        let result = try await NumbersConverter(outputBudgetBytes: 64 * 1024 * 1024, objectBudgetBytes: 2560 * 1024).convert(data, info: StreamInfo(detectedFormat: .numbers))
        #expect(result.sections.count == 1)
        #expect(result.sections.first?.sheetName == name)
        #expect(result.markdown().contains("| Same |"))
    }
}
