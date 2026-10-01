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
    static func parse(_ markdown: String, structureLists: Bool = true, depth: Int = 0) -> [MarkdownBlock] {
        let rawLines = normalizedLineEndings(markdown).components(separatedBy: "\n")
        let lines = rawLines.map { line in
            let whitespace = line.prefix { $0 == " " || $0 == "\t" }
            return String(repeating: " ", count: indentWidth(line)) + line.dropFirst(whitespace.count)
        }
        var blocks: [MarkdownBlock] = []
        var i = 0

        func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if isBlank(line) || trimmed == MarkdownLiteral.listRestartBoundary { i += 1; continue }

            if let opening = fence(trimmed) {
                i += 1
                var code: [String] = []
                while i < lines.count, !closesFence(lines[i], opening: opening) {
                    code.append(rawLines[i]); i += 1
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
                    let cells = parseTableRow(lines[i]).map { structureLists ? MarkdownTableCell.decodeCodePipes($0) : $0 }
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

            let leadingBare = confirmedBareMarker(lines, index: i)
            let confirmedBare = leadingBare != nil
            if listMarker(trimmed) != nil || confirmedBare {
                let ordered = (listMarker(trimmed) ?? leadingBare) == .ordered
                let start = ordered ? listStart(trimmed) : 1
                // Items sit at the list's own indent; a line indented two or more
                // columns past it continues the current item. It keeps its
                // indentation relative to the item's content column, so a nested
                // list stays nested (the renderers parse each item's text again).
                let base = indentWidth(line)
                var contentColumn = base
                var items: [MarkdownList.Item] = []
                while i < lines.count {
                    let raw = lines[i]
                    let itemLine = raw.trimmingCharacters(in: .whitespaces)
                    let indent = indentWidth(raw)
                    if indent < base + 2, let marker = listMarker(itemLine), (marker == .ordered) == ordered {
                        guard let item = MarkdownList.item(from: raw), !ordered || item.delimiter == items.first?.delimiter || items.isEmpty else { break }
                        items.append(item)
                        contentColumn = MarkdownList.contentIndent(of: raw) ?? indent + markerWidth(itemLine); i += 1
                    } else if indent < base + 2, let marker = bareListMarker(itemLine), (marker == .ordered) == ordered {
                        guard let item = MarkdownList.item(from: raw), !ordered || item.delimiter == items.first?.delimiter || items.isEmpty else { break }
                        items.append(item)                  // an empty item inside the list
                        contentColumn = MarkdownList.contentIndent(of: raw) ?? indent + itemLine.count + 1; i += 1
                    } else if isBlank(raw), !items.isEmpty {
                        var next = i + 1
                        while next < lines.count, isBlank(lines[next]) { next += 1 }
                        guard next < lines.count else { break }
                        // Blank lines separate loose items as well as nested
                        // blocks. Native restarts carry an explicit boundary.
                        let resumesList = resumesLooseList(lines[next], after: items[items.count - 1], base: base)
                        guard resumesList || indentWidth(lines[next]) >= contentColumn else { break }
                        if !resumesList { items[items.count - 1].appendText("") }
                        i = next
                    } else if !isBlank(raw), !items.isEmpty, literalListContains(raw, base: base, content: contentColumn) {
                        items[items.count - 1].appendText(dropStructuralIndent(rawLines[i], columns: min(indent, contentColumn)))
                        i += 1
                    } else {
                        break
                    }
                }
                let list = MarkdownList(ordered: ordered, items: items)
                blocks.append(.list(structureLists && depth < 16 ? list.structured(depth: depth + 1) : list)); continue
            }

            // Paragraph: gather until a blank line or a structural line.
            var paragraph: [String] = []
            while i < lines.count {
                let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                if isBlank(lines[i]) || candidate == MarkdownLiteral.listRestartBoundary || fence(candidate) != nil || candidate.hasPrefix("|")
                    || candidate.hasPrefix(">") || candidate == "---" || candidate == "***" || candidate == "___"
                    || headingMatch(candidate) != nil || listMarker(candidate) != nil || confirmedBareMarker(lines, index: i) != nil {
                    break
                }
                // Preserve canonical escapes until inline parsing has protected them.
                paragraph.append(lines[i]); i += 1
            }
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            } else {
                blocks.append(.paragraph(lines[i])); i += 1
            }
        }
        return blocks
    }

    /// Remove only the container's indentation columns. Tabs after that column
    /// belong to literal content (including nested fenced code), not structure.
    private static func dropStructuralIndent(_ line: String, columns: Int) -> String {
        var index = line.startIndex, consumed = 0
        while index < line.endIndex, consumed < columns {
            let character = line[index]
            guard character == " " || character == "\t" else { break }
            consumed += character == "\t" ? 4 - consumed % 4 : 1
            index = line.index(after: index)
        }
        return String(repeating: " ", count: max(0, consumed - columns)) + line[index...]
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

    static func isStructuralContinuation(_ line: String) -> Bool {
        if line.hasPrefix("|") || headingMatch(line) != nil || line.hasPrefix(">") || fence(line) != nil { return true }
        if listMarker(line) != nil || bareListMarker(line) != nil { return true }
        return ["---", "***", "___"].contains(line)
    }

    static func listMarker(_ line: String) -> ListKind? {
        guard let ordered = MarkdownList.isOrderedMarker(line), let item = MarkdownList.item(from: line),
              !DocumentRenderer.listItemText(item).isEmpty else { return nil }
        return ordered ? .ordered : .unordered
    }

    /// Match the list parser's continuation grammar for both literal escaping and CSV.
    static func literalListContains(_ line: String, base: Int, content: Int, afterBlank: Bool = false) -> Bool {
        let indent = indentWidth(line)
        return indent >= content || (!afterBlank && indent >= base + 2 && !isStructuralContinuation(line.trimmingCharacters(in: .whitespaces)))
    }

    static func indentWidth(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $1 == "\t" ? $0 + (4 - $0 % 4) : $0 + 1 }
    }

    /// The width of a list line's marker and the space after it (`- ` → 2, `12. ` → 4).
    static func markerWidth(_ line: String) -> Int {
        MarkdownList.contentIndent(of: line) ?? 0
    }

    /// A marker with no content (`-`, `2.`) — an empty list item. Only accepted
    /// inside an open list, so a lone `-` or `2020.` line never starts one.
    static func bareListMarker(_ line: String) -> ListKind? {
        if line == "-" || line == "*" || line == "+" { return .unordered }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        return (1...9).contains(digits.count) && [".", ")"].contains(String(line.dropFirst(digits.count))) ? .ordered : nil
    }

    /// The number an ordered list starts at (`5. x` → 5), 1 when it isn't a
    /// CommonMark list number (one to nine ASCII digits).
    static func listStart(_ line: String) -> Int {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        return digits.count <= 9 ? Int(digits) ?? 1 : 1
    }

    static func confirmedBareMarker(_ lines: [String], index: Int) -> ListKind? {
        let line = lines[index], trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = bareListMarker(trimmed) else { return nil }
        let next = index + 1, base = indentWidth(line), content = indentWidth(line) + trimmed.count + 1
        let adjacent = next < lines.count && !lines[next].trimmingCharacters(in: .whitespaces).isEmpty
            && (indentWidth(lines[next]) < base + 2 || indentWidth(lines[next]) >= content)
            && (listMarker(lines[next].trimmingCharacters(in: .whitespaces)) ?? bareListMarker(lines[next].trimmingCharacters(in: .whitespaces))) == marker
        var following = next
        while following < lines.count, lines[following].trimmingCharacters(in: .whitespaces).isEmpty { following += 1 }
        let looseSibling = following > next && following < lines.count
            && MarkdownList.item(from: line).map { resumesLooseList(lines[following], after: $0, base: base) } == true
        return adjacent || looseSibling || (following < lines.count && indentWidth(lines[following]) >= content) ? marker : nil
    }

    /// The same continuation rule confirms a leading empty item and resumes an
    /// open list. Sequential ordered markers avoid turning `2020.\n\n1. item`
    /// into a list; unordered siblings need no numbering evidence.
    static func resumesLooseList(_ line: String, after previous: MarkdownList.Item, base: Int) -> Bool {
        guard indentWidth(line) < base + 2, let next = MarkdownList.item(from: line) else { return false }
        if let number = previous.number {
            return next.number == number + 1 && next.delimiter == previous.delimiter
        }
        return next.number == nil
    }

    static func literalListIndent(_ lines: [String], index: Int) -> (base: Int, content: Int)? {
        let line = lines[index], trimmed = line.trimmingCharacters(in: .whitespaces)
        let filled = listMarker(trimmed) != nil
        guard filled || confirmedBareMarker(lines, index: index) != nil else { return nil }
        let base = indentWidth(line)
        return (base, base + (filled ? markerWidth(trimmed) : trimmed.count + 1))
    }

    /// The block parser removes an item's marker before parsing its first block.
    static func literalListFenceStart(_ line: String) -> Bool { listFence(line) != nil }
    static func listFence(_ line: String) -> (character: Character, length: Int)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard listMarker(trimmed) != nil else { return nil }
        return fence(trimmed.dropFirst(markerWidth(trimmed)).trimmingCharacters(in: .whitespaces))
    }

    static func literalFootnoteDefinition(_ line: String) -> Bool {
        DocumentRenderer.parseFootnoteDefinition(DocumentRenderer.dropLeadingSpaces(line, max: 3)) != nil
    }

    static func literalBlockBoundary(_ line: String) -> (starts: Bool, ends: Bool) {
        let isFootnote = literalFootnoteDefinition(line)
        let line = line.trimmingCharacters(in: .whitespaces)
        let single = headingMatch(line) != nil || line.hasPrefix("|") || line.hasPrefix(">")
            || ["---", "***", "___", MarkdownLiteral.listRestartBoundary].contains(line)
        return (single || listMarker(line) != nil || isFootnote, single)
    }

    static func stripListMarker(_ line: String) -> String {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
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

    static func normalizedLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
