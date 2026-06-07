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

    /// Escapes the characters that are structural in a pipe-table cell: a literal
    /// backslash (`\` -> `\\`, done first) and the pipe delimiter (`|` -> `\|`).
    /// Newlines are handled separately by callers (some join with spaces, some
    /// with `<br>`).
    static func escapeDelimiters(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
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
