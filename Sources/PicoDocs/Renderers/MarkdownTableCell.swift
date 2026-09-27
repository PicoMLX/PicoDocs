//
//  MarkdownTableCell.swift
//  PicoDocs
//
//  Escaping/unescaping for pipe-table cell values, shared by the converters that
//  produce Markdown tables (Word, spreadsheet, CSV, HTML) and the renderer that
//  re-parses them, so cell values round-trip. Both the backslash and the pipe
//  delimiter are structural, so backslash is escaped first and the pipe second
//  (and unescaped in the same order), letting a literal `\` or `|` survive.
//

import Foundation

enum MarkdownTableCell {
    /// Transform semantic code spans separately from canonical literal text.
    static func mapCodeSpans(_ text: String, keepDelimiters: Bool = true, code: (String) -> String, plain: (String) -> String) -> String {
        let chars = Array(text)
        var runs: [(Int, Int)] = [], index = 0
        while index < chars.count {
            if chars[index] == "`" {
                let start = index
                while index < chars.count, chars[index] == "`" { index += 1 }
                runs.append((start, index - start))
            } else { index += 1 }
        }
        var closers: [Int: (Int, Int)] = [:], next: [Int: Int] = [:]
        for (start, length) in runs.reversed() {
            if let close = next[length] { closers[start] = (close, length) }
            next[length] = start
        }
        index = 0
        var buffer = "", output = ""
        while index < chars.count {
            if chars[index] == "\\", index + 1 < chars.count {
                buffer.append(chars[index]); buffer.append(chars[index + 1]); index += 2
            } else if chars[index] == "`", let (close, length) = closers[index] {
                output += plain(buffer); buffer = ""
                let delimiter = keepDelimiters ? String(repeating: "`", count: length) : ""
                output += delimiter + code(String(chars[(index + length)..<close])) + delimiter
                index = close + length
            } else {
                buffer.append(chars[index]); index += 1
            }
        }
        return output + plain(buffer)
    }



    /// Escapes the characters that are structural in a pipe-table cell: a literal
    /// backslash (`\` -> `\\`, done first) and the pipe delimiter (`|` -> `\|`).
    /// Newlines are handled separately by callers (some join with spaces, some
    /// with `<br>`).
    static func escapeDelimiters(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
    }

    /// Add only the missing pipe escapes to already escaped Markdown.
    static func escapeCanonicalPipes(_ text: String) -> String {
        var output = "", slashes = 0
        for character in text {
            if character == "|", slashes.isMultiple(of: 2) { output.append("\\") }
            output.append(character)
            slashes = character == "\\" ? slashes + 1 : 0
        }
        return output
    }

    /// Decode canonical breaks without interpreting an escaped literal marker.
    static func decodeBreaks(_ text: String) -> String {
        var brackets = 0, destinationDepth = 0
        return mapCodeSpans(text, code: { $0 }, plain: { plain in
            var output = "", index = plain.startIndex
            while index < plain.endIndex {
                let character = plain[index]
                let next = plain.index(after: index)
                if character == "\\" {
                    output.append(character); index = next
                    if index < plain.endIndex { output.append(plain[index]); index = plain.index(after: index) }
                    continue
                }
                if destinationDepth > 0 {
                    if character == "(" { destinationDepth += 1 }
                    if character == ")" { destinationDepth -= 1 }
                } else if character == "[" { brackets += 1 }
                else if character == "]", brackets > 0 {
                    brackets -= 1
                    if next < plain.endIndex, plain[next] == "(" {
                        destinationDepth = 1; output += "]("; index = plain.index(after: next); continue
                    }
                } else if plain[index...].hasPrefix("<br>") {
                    output.append("\n"); index = plain.index(index, offsetBy: 4); continue
                }
                output.append(character); index = next
            }
            return output
        })
    }

    /// Inverse of `escapeDelimiters`: turns `\\` back into `\` and `\|` into `|`,
    /// leaving any other backslash sequence untouched (so a stray `\x` from a
    /// non-escaping source isn't corrupted).
    static func unescape(_ value: String) -> String {
        var result = ""
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(after: index)
            if value[index] == "\\", next < value.endIndex, value[next] == "\\" || value[next] == "|" {
                result.append(value[next])
                index = value.index(after: next)
            } else {
                result.append(value[index])
                index = next
            }
        }
        return result
    }
}
