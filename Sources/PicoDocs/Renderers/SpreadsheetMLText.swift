import Foundation

/// SpreadsheetML uses UTF-16 escape tokens in addition to XML escaping.
enum SpreadsheetMLText {
    private static func forbidden(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value < 0x20 && ![9, 10, 13].contains(scalar.value)) || scalar.value == 0xFFFE || scalar.value == 0xFFFF
    }

    private static func startsEscape(_ scalars: String.UnicodeScalarView, at start: String.Index) -> Bool {
        var index = scalars.index(after: start)
        guard index < scalars.endIndex, scalars[index] == "x" else { return false }
        for _ in 0..<4 {
            index = scalars.index(after: index)
            guard index < scalars.endIndex, "0123456789abcdefABCDEF".unicodeScalars.contains(scalars[index]) else { return false }
        }
        index = scalars.index(after: index)
        return index < scalars.endIndex && scalars[index] == "_"
    }

    static func encode(_ text: String) -> String {
        var output = ""
        let scalars = text.unicodeScalars
        for index in scalars.indices {
            let scalar = scalars[index]
            if scalar == "_", startsEscape(scalars, at: index) { output += "_x005F_" }
            else if forbidden(scalar) { output += String(format: "_x%04X_", scalar.value) }
            else { output.unicodeScalars.append(scalar) }
        }
        return output
    }

    static func xmlEncodedByteCount(_ text: String) -> Int {
        var bytes = 0
        let scalars = text.unicodeScalars
        for index in scalars.indices {
            let scalar = scalars[index], value = scalar.value
            if forbidden(scalar) || (scalar == "_" && startsEscape(scalars, at: index)) { bytes += 7 }
            else if scalar == "&" { bytes += 5 }
            else if scalar == "<" || scalar == ">" { bytes += 4 }
            else { bytes += value <= 0x7F ? 1 : value <= 0x7FF ? 2 : value <= 0xFFFF ? 3 : 4 }
        }
        return bytes
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
