//
//  MarkdownBlock.swift
//  PicoDocs
//
//  The shared block-level intermediate representation for the Markdown subset
//  PicoDocs converters emit. Extracted from `DocumentRenderer` so that *both*
//  halves of the engine use one parser: the renderer (Markdown -> HTML/plaintext/
//  XML/CSV) and the exporters (Markdown -> DOCX/XLSX/PPTX). A fix to table/list/
//  heading parsing then benefits both directions.
//
//  This is deliberately a narrow, hand-rolled parser for the canonical Markdown
//  the converters produce — not a full CommonMark parser. `DocumentRenderer`'s
//  header comment floats replacing it with swift-markdown; if that ever happens,
//  it should slot in behind this same `[MarkdownBlock]` contract, with the
//  renderer + exporter round-trip tests as the safety net.
//

import Foundation

/// A block-level element of the canonical Markdown subset.
enum MarkdownBlock: Equatable {
    case heading(Int, String)
    case paragraph(String)
    case code(String)
    case blockquote([String])
    case list(MarkdownList)
    case table([[String]])
    case rule
}

/// Parses canonical Markdown into `[MarkdownBlock]`. The structural helpers
/// (`parseTableRow`, `isTableSeparatorRow`, …) are `internal` because the
/// renderer's CSV path and the exporters reuse them.
enum MarkdownBlockParser {

    static func normalizedLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = normalizedLineEndings(markdown).components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var i = 0

        func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if isBlank(line) { i += 1; continue }

            if let opening = fence(trimmed) {
                i += 1
                var code: [String] = []
                while i < lines.count, !closesFence(lines[i], opening: opening) {
                    code.append(lines[i]); i += 1
                }
                if i < lines.count { i += 1 }   // closing fence
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.rule); i += 1; continue
            }

            if let heading = headingMatch(trimmed) {
                blocks.append(.heading(heading.level, heading.text)); i += 1; continue
            }

            if trimmed.hasPrefix("|") {
                var rows: [[String]] = []
                var rowIndex = 0
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let cells = parseTableRow(lines[i]).map { MarkdownTableCell.unescape($0) }
                    // The header/body separator is conventionally the second row;
                    // only drop an all-dash row there, so real data rows that
                    // happen to be all dashes elsewhere are kept.
                    if !(rowIndex == 1 && isTableSeparatorRow(cells)) { rows.append(cells) }
                    rowIndex += 1
                    i += 1
                }
                if !rows.isEmpty { blocks.append(.table(rows)) }
                continue
            }

            if trimmed.hasPrefix(">") {
                var inner: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var quoted = lines[i].trimmingCharacters(in: .whitespaces)
                    quoted.removeFirst()                       // ">"
                    if quoted.hasPrefix(" ") { quoted.removeFirst() }
                    inner.append(quoted)
                    i += 1
                }
                blocks.append(.blockquote(inner)); continue
            }

            if listMarker(trimmed) != nil {
                if let list = MarkdownList.parse(lines, index: &i) { blocks.append(.list(list)) }
                else { blocks.append(.paragraph(lines[i])); i += 1 }
                continue
            }

            // Paragraph: gather until a blank line or a structural line.
            var paragraph: [String] = []
            while i < lines.count {
                let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                if isBlank(lines[i]) || fence(candidate) != nil || candidate.hasPrefix("|")
                    || candidate.hasPrefix(">") || candidate == "---" || candidate == "***"
                    || headingMatch(candidate) != nil || listMarker(candidate) != nil {
                    break
                }
                paragraph.append(lines[i]); i += 1
            }
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            }
        }
        return blocks
    }

    static func fence(_ line: String) -> (character: Character, length: Int)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let length = line.prefix { $0 == first }.count
        guard length >= 3, first != "`" || !line.dropFirst(length).contains("`") else { return nil }
        return (first, length)
    }

    static func closesFence(_ line: String, opening: (character: Character, length: Int)) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let length = trimmed.prefix { $0 == opening.character }.count
        return length >= opening.length && trimmed.dropFirst(length).trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func headingMatch(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#", level < 6 {
            level += 1; index = line.index(after: index)
        }
        guard level > 0, index < line.endIndex, line[index] == " " else { return nil }
        let text = String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    enum ListKind: Equatable { case ordered, unordered }

    static func listMarker(_ line: String) -> ListKind? {
        MarkdownList.isOrderedMarker(line).map { $0 ? .ordered : .unordered }
    }

    static func stripListMarker(_ line: String) -> String {
        if listMarker(line) == .unordered {
            return String(line.dropFirst(2))
        }
        if let dot = line.firstIndex(of: "."), line[line.startIndex..<dot].allSatisfy(\.isNumber) {
            return String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
        }
        return line
    }

    static func parseTableRow(_ line: String) -> [String] {
        var cells = line.trimmingCharacters(in: .whitespaces)
        if cells.hasPrefix("|") { cells.removeFirst() }
        if cells.hasSuffix("|") {
            // Strip the trailing delimiter only if the pipe is unescaped (an even
            // number of backslashes precede it); otherwise it's a literal `\|` in
            // a row that omits the closing delimiter.
            let backslashes = cells.dropLast().reversed().prefix { $0 == "\\" }.count
            if backslashes.isMultiple(of: 2) { cells.removeLast() }
        }
        // Split on unescaped pipes only; a backslash escapes the next character,
        // so `\|` stays in the cell while `\\|` is a literal backslash + delimiter.
        var result: [String] = []
        var current = ""
        var escaped = false
        for character in cells {
            if escaped {
                current.append(character); escaped = false
            } else if character == "\\" {
                current.append(character); escaped = true
            } else if character == "|" {
                result.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            } else {
                current.append(character)
            }
        }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }

    static func isTableSeparatorRow(_ cells: [String]) -> Bool {
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && trimmed.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }
}
