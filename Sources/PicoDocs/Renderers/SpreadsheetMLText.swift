import Foundation

/// SpreadsheetML uses UTF-16 escape tokens in addition to XML escaping.
enum SpreadsheetMLText {
    static func encode(_ text: String) -> String {
        let protected = text.replacingOccurrences(of: "_(?=x[0-9A-Fa-f]{4}_)", with: "_x005F_", options: .regularExpression)
        return protected.unicodeScalars.map { scalar in
            if (scalar.value < 0x20 && ![9,10,13].contains(scalar.value)) || scalar.value == 0xFFFE || scalar.value == 0xFFFF {
                return String(format: "_x%04X_", scalar.value)
            }
            return String(scalar)
        }.joined()
    }

    static func decode(_ text: String) -> String {
        let ns = text as NSString
        let pattern = try! NSRegularExpression(pattern: "_x([0-9A-Fa-f]{4})_")
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
