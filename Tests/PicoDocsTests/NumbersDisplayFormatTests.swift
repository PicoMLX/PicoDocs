import Foundation
import Testing
@testable import PicoDocs

/// Decimal, currency and percentage cells present their table's number format.
struct NumbersDisplayFormatTests {
    typealias B = PagesConverterTests
    typealias C = NumbersTypedCellReviewTests
    typealias T = NumbersTraversalReviewTests
    typealias Format = IWATable.NumberFormat

    static func format(_ type: UInt64, places: UInt64? = nil, code: String? = nil, negative: UInt64? = nil, grouping: Bool = false, accounting: Bool = false) -> [UInt8] {
        var bytes = B.varintField(1, type)
        if let places { bytes += B.varintField(2, places) }
        if let code { bytes += B.lengthField(3, Array(code.utf8)) }
        if let negative { bytes += B.varintField(4, negative) }
        if grouping { bytes += B.varintField(5, 1) }
        if accounting { bytes += B.varintField(6, 1) }
        return bytes
    }
    static func parsed(_ type: UInt64, places: UInt64? = nil, code: String? = nil, negative: UInt64? = nil, grouping: Bool = false, accounting: Bool = false) -> Format? {
        Format(format(type, places: places, code: code, negative: negative, grouping: grouping, accounting: accounting), objectBudget: IWAObjectBudget())
    }
    /// An IEEE-754 decimal128 (BID) with a small coefficient.
    static func decimal(_ coefficient: UInt64, exponent: Int, negative: Bool = false) -> [UInt8] {
        var bytes = (0..<8).map { UInt8(truncatingIfNeeded: coefficient >> ($0 * 8)) } + Array(repeating: UInt8(0), count: 8)
        let biased = exponent + 6176
        bytes[14] = UInt8((biased & 0x7F) << 1)
        bytes[15] = UInt8((biased >> 7) & 0x7F) | (negative ? 0x80 : 0)
        return bytes
    }
    static func key(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }

    @Test func percentagesScaleWithoutRoundingStoredDigits() throws {
        let percent = try #require(Self.parsed(258, places: 0))
        #expect(percent.display(negative: false, digits: "62", exponent: -2) == "62%")
        #expect(percent.display(negative: false, digits: "1", exponent: 0) == "100%")
        #expect(percent.display(negative: false, digits: "504545454545455", exponent: -15) == "50.4545454545455%")
        #expect(percent.display(negative: true, digits: "0", exponent: -2) == "0%")
        #expect(Self.parsed(258, places: 1)?.display(negative: false, digits: "5", exponent: -1) == "50.0%")
    }

    @Test func currenciesUseTheirSymbolPlacesAndGrouping() throws {
        let usd = try #require(Self.parsed(257, places: 2, code: "USD", grouping: true))
        #expect(usd.display(negative: false, digits: "540375", exponent: -1) == "$54,037.50")
        #expect(usd.display(negative: true, digits: "5", exponent: 0) == "-$5.00")
        #expect(Self.parsed(257, places: 2, code: "USD", grouping: true, accounting: true)?.display(negative: true, digits: "1", exponent: 3) == "($1,000.00)")
        #expect(Self.parsed(257, places: 2, code: "EUR")?.display(negative: false, digits: "466", exponent: -2) == "€4.66")
        #expect(Self.parsed(257, places: 2, code: "CHF")?.display(negative: false, digits: "125", exponent: -1) == "CHF 12.50")
        for code in ["usd", "US", "USDX", "€€€"] { #expect(Self.parsed(257, places: 2, code: code) == nil) }
        #expect(Self.parsed(257, places: 2) == nil)
    }

    @Test func decimalsPadGroupAndMarkNegatives() throws {
        let automatic = try #require(Self.parsed(256, places: 253, grouping: true))
        #expect(automatic.display(negative: false, digits: "12345", exponent: -1) == "1,234.5")
        #expect(Self.parsed(256)?.display(negative: false, digits: "35", exponent: -2) == "0.35")
        for (digits, grouped) in [("100", "100"), ("1000", "1,000"), ("123456", "123,456"), ("1234567", "1,234,567")] {
            #expect(automatic.display(negative: false, digits: digits, exponent: 0) == grouped)
        }
        for (style, shown) in [(UInt64(0), "-5.00"), (1, "-5.00"), (2, "(5.00)"), (3, "(5.00)")] {
            #expect(Self.parsed(256, places: 2, negative: style)?.display(negative: true, digits: "5", exponent: 0) == shown)
        }
        // Fixed places pad; stored digits beyond them remain.
        let whole = try #require(Self.parsed(256, places: 0))
        #expect(whole.display(negative: false, digits: "540375", exponent: -1) == "54037.5")
        #expect(Self.parsed(256, places: 2)?.display(negative: false, digits: "185", exponent: -1) == "18.50")
        #expect(Self.parsed(256, places: 2)?.display(negative: false, digits: "0", exponent: 0) == "0.00")
        // Extreme magnitudes keep the unformatted scientific notation.
        #expect(whole.display(negative: false, digits: "1", exponent: 21) == nil)
        #expect(whole.display(negative: false, digits: "1", exponent: 20) == "100000000000000000000")
        #expect(whole.display(negative: false, digits: "1", exponent: -7) == nil)
        #expect(whole.display(negative: false, digits: "1", exponent: -6) == "0.000001")
    }

    @Test func otherFormatsKeepTheStoredValue() {
        for type in [UInt64(1), 259, 260, 261, 262, 268, 270, 272, 274] { #expect(Self.parsed(type, places: 2) == nil) }
        #expect(Self.parsed(256, places: 35) == nil)
        #expect(Self.parsed(256, places: 34)?.decimalPlaces == 34)
        #expect(Self.parsed(256, places: 253)?.decimalPlaces == nil)
    }

    @Test func cellsKeyTheirTablesFormatListPastOtherFlaggedFields() async throws {
        // Bits 0, 5, 6 and 12 precede the number (13) and currency (14) keys.
        let cells = [
            C.cell(2, Self.decimal(62, exponent: -2) + Self.key(7) + Self.key(8) + Self.key(2), fields: 0x3041),
            C.cell(10, Self.decimal(12345, exponent: -1) + Self.key(1) + Self.key(7) + Self.key(8) + Self.key(3), fields: 0x5061),
            C.cell(2, Self.decimal(1_234_567_891, exponent: -3, negative: true) + Self.key(4), fields: 0x2001),
            C.cell(2, Self.decimal(75, exponent: -1) + Self.key(9), fields: 0x2001),
            C.cell(2, Self.decimal(25, exponent: -2), fields: 0x1)
        ]
        var buffer: [UInt8] = [], offsets: [UInt8] = []
        for cell in cells {
            offsets += [UInt8(truncatingIfNeeded: buffer.count), UInt8(truncatingIfNeeded: buffer.count >> 8)]
            buffer += cell
        }
        let tile = B.lengthField(5, B.varintField(1, 0) + B.lengthField(6, buffer) + B.lengthField(7, offsets))
        func entry(_ key: UInt64, _ format: [UInt8]) -> [UInt8] { B.lengthField(3, B.varintField(1, key) + B.lengthField(6, format)) }
        let list = B.varintField(1, 2) + entry(2, Self.format(258, places: 0)) + entry(3, Self.format(257, places: 2, code: "USD", grouping: true))
            + entry(4, Self.format(256, places: 2, negative: 2, grouping: true))
        func convert(_ model: [UInt8]) async throws -> String {
            let objects: [T.O] = [(20, 6001, model, [21, 30]), (21, 6002, tile, []), (30, 6005, list, [])]
            return try await NumbersConverter().convert(T.workbook(objects, drawables: [20]), info: StreamInfo(detectedFormat: .numbers)).markdown()
        }
        let formatted = try await convert(B.lengthField(4, B.lengthField(22, T.reference(30))))
        #expect(formatted.contains("| 62% | $1,234.50 | (1,234,567.891) | 7.5 | 0.25 |"))
        // Without the data store's format list, the same cells keep their values.
        #expect(try await convert([]).contains("| 0.62 | 1234.5 | -1234567.891 | 7.5 | 0.25 |"))
    }
}
