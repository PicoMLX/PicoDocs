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
        guard text.unicodeScalars.contains("`") else { return plain(text) }
        let scalars = text.unicodeScalars
        var index = scalars.startIndex, plainStart = index
        var output = ""
        // Only the last run of each distinct length is needed to rule out
        // unmatched openers. Successful searches then consume disjoint spans,
        // keeping both passes linear without retaining every character/run.
        var lastRun: [Int: String.Index] = [:]
        var scan = scalars.startIndex
        while scan < scalars.endIndex {
            guard scalars[scan] == "`" else { scan = scalars.index(after: scan); continue }
            let start = scan
            var length = 0
            while scan < scalars.endIndex, scalars[scan] == "`" { length += 1; scan = scalars.index(after: scan) }
            lastRun[length] = start
        }
        while index < scalars.endIndex {
            if scalars[index] == "\\" {
                index = scalars.index(after: index)
                if index < scalars.endIndex { index = scalars.index(after: index) }
                continue
            }
            guard scalars[index] == "`" else { index = scalars.index(after: index); continue }
            let opener = index
            var length = 0
            while index < scalars.endIndex, scalars[index] == "`" { length += 1; index = scalars.index(after: index) }
            let contentStart = index
            guard let last = lastRun[length], last > opener else { continue }
            var search = index, closing: (String.Index, String.Index)?
            while search < scalars.endIndex {
                guard scalars[search] == "`" else { search = scalars.index(after: search); continue }
                let start = search
                var count = 0
                while search < scalars.endIndex, scalars[search] == "`" { count += 1; search = scalars.index(after: search) }
                if count == length { closing = (start, search); break }
            }
            guard let (close, afterClose) = closing else { continue }
            output += plain(String(text[plainStart..<opener]))
            let delimiter = keepDelimiters ? String(text[opener..<contentStart]) : ""
            output += delimiter + code(String(text[contentStart..<close])) + delimiter
            index = afterClose; plainStart = index
        }
        return output + plain(String(text[plainStart...]))
    }



    /// Only runs immediately before pipes need a table layer inside code.
    /// Backslashes elsewhere are source text and must remain untouched.
    static func codePipes(_ text: String, encoding: Bool) -> String {
        var output = "", slashes = 0
        for character in text {
            if character == "\\" { slashes += 1; continue }
            let count: Int
            if character == "|" {
                count = encoding ? slashes * 2 + 1 : (slashes.isMultiple(of: 2) ? slashes : (slashes - 1) / 2)
            } else { count = slashes }
            output += String(repeating: "\\", count: count)
            output.append(character); slashes = 0
        }
        return output + String(repeating: "\\", count: slashes)
    }

    static func decodeCodePipes(_ text: String) -> String {
        mapCodeSpans(text, code: { codePipes($0, encoding: false) }, plain: { $0 })
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
