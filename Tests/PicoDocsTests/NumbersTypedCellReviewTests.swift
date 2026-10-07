import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

struct NumbersTypedCellReviewTests {
    typealias B = PagesConverterTests
    typealias T = NumbersTraversalReviewTests
    static func cell(_ type: UInt8, _ bytes: [UInt8], fields: UInt32) -> [UInt8] {
        var prefix: [UInt8] = [5, type] + Array(repeating: 0, count: 6)
        prefix += (0..<4).map { UInt8(truncatingIfNeeded: fields >> ($0 * 8)) }
        return prefix + bytes
    }
    static func double(_ value: Double) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value.bitPattern >> ($0 * 8)) }
    }
    static func workbook(_ cells: [[UInt8]]) -> Data {
        var buffer: [UInt8] = [], offsets: [UInt8] = []
        for cell in cells {
            offsets += [UInt8(truncatingIfNeeded: buffer.count), UInt8(truncatingIfNeeded: buffer.count >> 8)]
            buffer += cell
        }
        let row = B.varintField(1, 0) + B.lengthField(6, buffer) + B.lengthField(7, offsets)
        let tile = B.lengthField(5, row)
        let objects: [T.O] = [(20,6001,[],[21]), (21,6002,tile,[])]
        return T.workbook(objects, drawables: [20])
    }
    @Test func booleanOnlyTableIsRetained() async throws {
        let data = Self.workbook([Self.cell(6, Self.double(0), fields: 2), Self.cell(6, Self.double(1), fields: 2)])
        let result = try await NumbersConverter().convert(data, info: StreamInfo(detectedFormat: .numbers))
        #expect(result.markdown().contains("| false | true |"))
    }
    @Test func nonMidnightDateTimeSurvives() async throws {
        let seconds: Double = 803_433_600 // 2026-06-18 00:00:00 UTC
        let data = Self.workbook([Self.cell(5, Self.double(seconds + 34_200), fields: 4)])
        let result = try await NumbersConverter().convert(data, info: StreamInfo(detectedFormat: .numbers))
        #expect(result.markdown().contains("2026-06-18T09:30:00"))
    }
    @Test func errorOnlyTableDoesNotBecomeAnEmptySheet() async throws {
        let data = Self.workbook([Self.cell(8, [3, 0, 0, 0], fields: 0x40), Self.cell(8, [4, 0, 0, 0], fields: 0x40)])
        let result = try await NumbersConverter().convert(data, info: StreamInfo(detectedFormat: .numbers))
        #expect(result.markdown().contains("| #ERROR! | #ERROR! |"))
    }
    @Test func preEpochAndFractionalTimeRemainDistinctFromMidnight() async throws {
        let data = Self.workbook([Self.cell(5, Self.double(-0.125), fields: 4), Self.cell(5, Self.double(0), fields: 4)])
        let result = try await NumbersConverter().convert(data, info: StreamInfo(detectedFormat: .numbers))
        #expect(result.markdown().contains("| 2000-12-31T23:59:59.875 | 2001-01-01 |"))
    }
    @Test func committedWorkbookPreservesTypedValues() async throws {
        let result = try await NumbersConverter().convert(Fixture.data("sample", "numbers"), info: StreamInfo(detectedFormat: .numbers))
        let markdown = result.markdown()
        #expect(markdown.contains("| true |"))
        #expect(markdown.contains("| false |"))
        #expect(markdown.contains("2026-06-18T09:30:00"))
        #expect(markdown.contains("2026-06-18T17:00:00"))
        #expect(markdown.contains("2026-06-18T13:45:00"))
        #expect(markdown.contains("| divide\\_by\\_zero | #ERROR! | #DIV/0! |"))
        #expect(markdown.contains("| bad\\_value | #ERROR! | #VALUE! |"))
    }
    @Test func numericValuesRemainSeparateFromDisplayFormats() async throws {
        let result = try await NumbersConverter().convert(Fixture.data("sample", "numbers"), info: StreamInfo(detectedFormat: .numbers))
        let locale = try #require(result.sections.first { $0.sheetName == "Locale_Unicode" })
        #expect(locale.markdown.contains("| currency\\_usd | 1234.56 | number | numeric value, USD format | $#,##0.00 |"))
        #expect(locale.markdown.contains("format is not value"))
        let rows = try #require(result.sections.first { $0.sheetName == "Data_Rows" })
        #expect(rows.markdown.contains("| Hourly Rate | Budget | Completion % |"))
        #expect(rows.markdown.contains("| 165 | 19800 | 0.62 | true |"))
    }
}
