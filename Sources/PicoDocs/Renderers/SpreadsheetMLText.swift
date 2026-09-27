import Foundation

/// SpreadsheetML uses UTF-16 escape tokens in addition to XML escaping.
enum SpreadsheetMLText {
    private static let encodePattern = try! NSRegularExpression(pattern: "_(?=x[0-9A-Fa-f]{4}_)")
    private static func forbidden(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value < 0x20 && ![9, 10, 13].contains(scalar.value)) || scalar.value == 0xFFFE || scalar.value == 0xFFFF
    }

    static func encode(_ text: String) -> String {
        let hasEscapes = text.contains("_x")
        guard hasEscapes || text.unicodeScalars.contains(where: forbidden) else { return text }
        let protected = hasEscapes ? encodePattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "_x005F_") : text
        return protected.unicodeScalars.map { scalar in
            if forbidden(scalar) {
                return String(format: "_x%04X_", scalar.value)
            }
            return String(scalar)
        }.joined()
    }

    private static let pattern = try! NSRegularExpression(pattern: "_x([0-9A-Fa-f]{4})_")

    static func decode(_ text: String) -> String {
        guard text.contains("_x") else { return text }
        let ns = text as NSString
        var units: [UInt16] = [], offset = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            units += ns.substring(with: NSRange(location: offset, length: match.range.location - offset)).utf16
            units.append(UInt16(ns.substring(with: match.range(at: 1)), radix: 16)!)
            offset = NSMaxRange(match.range)
        }
        units += ns.substring(from: offset).utf16
        return String(decoding: units, as: UTF16.self)
    }
}
