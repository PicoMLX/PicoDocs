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

    static func decode(_ text: String) -> String {
        guard text.contains("_x") else { return text }
        let input = text.utf16
        var index = input.startIndex, output = ""
        var highSurrogate: UInt16?
        // Decode directly into the result, retaining neither regex matches nor
        // a second full UTF-16 buffer. Pair escaped and literal UTF-16 units alike.
        func append(_ unit: UInt16) {
            if let high = highSurrogate {
                highSurrogate = nil
                if (0xDC00...0xDFFF).contains(unit) {
                    let value = 0x10000 + (UInt32(high - 0xD800) << 10) + UInt32(unit - 0xDC00)
                    output.unicodeScalars.append(Unicode.Scalar(value)!)
                    return
                }
                output.unicodeScalars.append("\u{FFFD}")
            }
            if (0xD800...0xDBFF).contains(unit) { highSurrogate = unit }
            else if (0xDC00...0xDFFF).contains(unit) { output.unicodeScalars.append("\u{FFFD}") }
            else { output.unicodeScalars.append(Unicode.Scalar(UInt32(unit))!) }
        }
        func escape(at start: String.Index) -> (UInt16, String.Index)? {
            var cursor = input.index(after: start)
            guard cursor < input.endIndex, input[cursor] == 0x78 else { return nil }
            var value: UInt16 = 0
            for _ in 0..<4 {
                cursor = input.index(after: cursor)
                guard cursor < input.endIndex else { return nil }
                let unit = input[cursor], digit: UInt16
                switch unit {
                case 0x30...0x39: digit = unit - 0x30
                case 0x41...0x46: digit = unit - 0x41 + 10
                case 0x61...0x66: digit = unit - 0x61 + 10
                default: return nil
                }
                value = value * 16 + digit
            }
            cursor = input.index(after: cursor)
            guard cursor < input.endIndex, input[cursor] == 0x5F else { return nil }
            return (value, input.index(after: cursor))
        }
        while index < input.endIndex {
            if input[index] == 0x5F, let (unit, next) = escape(at: index) {
                append(unit); index = next
            } else {
                append(input[index]); index = input.index(after: index)
            }
        }
        if highSurrogate != nil { output.unicodeScalars.append("\u{FFFD}") }
        return output
    }
}
