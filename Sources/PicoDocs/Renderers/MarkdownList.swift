import Foundation

/// A list retains source markers and the reading order of text and child lists.
struct MarkdownList: Equatable {
    static func escapeBareMarkerText(_ text: String) -> String {
        guard !text.contains("\n") else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let parsed = marker(trimmed), parsed.text.isEmpty else { return text }
        let leading = text.prefix { $0 == " " || $0 == "\t" }
        let trailing = text.reversed().prefix { $0 == " " || $0 == "\t" }.reversed()
        let escaped = parsed.number == nil ? "\\" + trimmed : String(trimmed.dropLast()) + "\\."
        return String(leading) + escaped + String(trailing)
    }

    static func inlineText(_ text: String, breakText: String, inline: (String) throws -> String) rethrows -> String {
        let hardBreak = MarkdownTableCell.breakToken
        let protected = MarkdownTableCell.mapCodeSpans(MarkdownTableCell.protectBreakSentinels(text), code: { $0 }, plain: {
            $0.replacingOccurrences(of: " {2,}\n", with: hardBreak, options: .regularExpression)
        })
        return MarkdownTableCell.restoreBreakSentinels(try inline(protected).replacingOccurrences(of: "\n", with: " "), breakText: breakText)
    }

    struct Item: Equatable {
        let number: Int?
        let padding: String
        let delimiter: Character
        enum Content: Equatable {
            case text(String)
            case list(MarkdownList)
        }
        var content: [Content]
        init(number: Int?, text: String, padding: String = " ", delimiter: Character = ".") {
            self.number = number
            self.padding = padding
            self.delimiter = delimiter
            content = [.text(text)]
        }
        mutating func appendText(_ text: String) {
            if case .text(let previous) = content.last {
                content[content.count - 1] = .text(previous + "\n" + text)
            } else { content.append(.text(text)) }
        }
    }
    let ordered: Bool
    var items: [Item] = []

    private struct Marker {
        let indent: Int
        let contentIndent: Int
        let number: Int?
        let text: String
        let padding: String
        let delimiter: Character
    }

    private static func marker(_ line: String) -> Marker? {
        let whitespace = line.prefix { $0 == " " || $0 == "\t" }
        let indent = whitespace.reduce(0) { $1 == "\t" ? $0 + (4 - $0 % 4) : $0 + 1 }
        let content = line.dropFirst(whitespace.count)
        let number: Int?
        let markerWidth: Int
        let delimiter: Character
        if let first = content.first, "-*+".contains(first) {
            number = nil; markerWidth = 1; delimiter = first
        } else {
            let digits = content.prefix { $0.isASCII && $0.isNumber }
            guard (1...9).contains(digits.count), let value = Int(digits), let ending = content.dropFirst(digits.count).first, ending == "." || ending == ")" else { return nil }
            number = value; markerWidth = digits.count + 1; delimiter = ending
        }
        let tail = content.dropFirst(markerWidth)
        guard tail.isEmpty || tail.first == " " || tail.first == "\t" else { return nil }
        let padding = tail.prefix { $0 == " " || $0 == "\t" }
        let contentIndent = padding.isEmpty ? indent + markerWidth + 1 : padding.reduce(indent + markerWidth) {
            $1 == "\t" ? $0 + (4 - $0 % 4) : $0 + 1
        }
        return Marker(indent: indent, contentIndent: contentIndent, number: number, text: String(tail.dropFirst(padding.count)), padding: padding.isEmpty ? " " : String(padding), delimiter: delimiter)
    }

    /// Preserve source numbering, delimiter and padding in the block renderer.
    static func item(from line: String) -> Item? {
        guard let marker = marker(line) else { return nil }
        return Item(number: marker.number, text: marker.text, padding: marker.padding, delimiter: marker.delimiter)
    }

    static func contentIndent(of line: String) -> Int? { marker(line)?.contentIndent }

    static func isOrderedMarker(_ line: String) -> Bool? { marker(line).map { $0.number != nil } }

    static func parse(_ lines: [String], index: inout Int, depth: Int = 0, minimumIndent: Int = 0) -> MarkdownList? {
        guard index < lines.count, depth < 32, let first = marker(lines[index]) else { return nil }
        var list = MarkdownList(ordered: first.number != nil)
        var contentIndent = first.contentIndent
        while index < lines.count {
            var next = index
            while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
            guard next < lines.count else { break }
            let blank = next > index
            if let current = marker(lines[next]) {
                if current.indent < minimumIndent { break }
                if current.indent < contentIndent {
                    guard (current.number != nil) == list.ordered, !list.ordered || current.delimiter == first.delimiter else { break }
                    // An explicit restart following a blank line opens a new list.
                    if blank, let previous = list.items.last?.number, list.ordered, current.number != min(previous, Int.max - 1) + 1 { break }
                    index = next + 1
                    list.items.append(Item(number: current.number, text: current.text, padding: current.padding, delimiter: current.delimiter))
                    contentIndent = current.contentIndent
                } else {
                    guard !list.items.isEmpty else { break }
                    var childIndex = next
                    guard let child = parse(lines, index: &childIndex, depth: depth + 1, minimumIndent: contentIndent) else { break }
                    list.items[list.items.count - 1].content.append(.list(child))
                    index = childIndex
                }
            } else {
                let indent = lines[next].prefix { $0 == " " || $0 == "\t" }.reduce(0) { $1 == "\t" ? $0 + (4 - $0 % 4) : $0 + 1 }
                guard !blank, indent >= contentIndent, !list.items.isEmpty else { break }
                list.items[list.items.count - 1].appendText(lines[next].trimmingCharacters(in: .whitespaces))
                index = next + 1
            }
        }
        return list
    }

    func plaintext(indent: String = "", inline: (String) -> String) -> String {
        items.map { item in
            let marker = item.number.map { "\($0)\(item.delimiter)" + item.padding } ?? "-" + item.padding
            let width = (indent + marker).reduce(0) { $1 == "\t" ? $0 + (4 - $0 % 4) : $0 + 1 }
            let continuation = String(repeating: " ", count: width)
            return item.content.enumerated().map { index, content in
                switch content {
                case .text(let text):
                    return (index == 0 ? indent + marker : continuation) + inline(text).replacingOccurrences(of: "\n", with: " ")
                case .list(let child): return child.plaintext(indent: continuation, inline: inline)
                }
            }.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    func html(inline: (String) -> String) -> String {
        let tag = ordered ? "ol" : "ul"
        let start = items.first?.number ?? 1
        let attribute = ordered && start != 1 ? " start=\"\(start)\"" : ""
        var expected = start
        let body = items.map { item in
            let value = item.number.map { $0 == expected ? "" : " value=\"\($0)\"" } ?? ""
            if let number = item.number { expected = min(number, Int.max - 1) + 1 }
            let content = item.content.map { content in
                switch content {
                case .text(let text): return inline(text).replacingOccurrences(of: "\n", with: " ")
                case .list(let child): return child.html(inline: inline)
                }
            }.joined(separator: "\n")
            return "<li\(value)>\(content)</li>"
        }.joined(separator: "\n")
        return "<\(tag)\(attribute)>\n\(body)\n</\(tag)>"
    }

    var texts: [String] {
        items.flatMap { $0.content.flatMap { content in
            switch content {
            case .text(let text): return [text]
            case .list(let child): return child.texts
            }
        } }
    }
    struct Paragraph {
        let level: Int
        let ordered: Bool
        let number: Int?
        let text: String
        let continuation: Bool
    }
    func paragraphs(level: Int = 0) -> [Paragraph] {
        items.flatMap { item in item.content.enumerated().flatMap { index, content -> [Paragraph] in
            switch content {
            case .text(let text): return [Paragraph(level: level, ordered: ordered, number: item.number, text: text, continuation: index > 0)]
            case .list(let child): return child.paragraphs(level: level + 1)
            }
        } }
    }

    func structured(depth: Int) -> MarkdownList {
        var result = self
        for index in result.items.indices {
            let raw = result.items[index].content.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined(separator: "\n")
            let blocks = MarkdownBlockParser.parse(raw, depth: depth)
            var content: [Item.Content] = []
            for block in blocks {
                switch block {
                case .paragraph(let text): content.append(.text(text))
                case .list(let child): content.append(.list(child))
                // These were already retained as text by the export list model.
                case .heading(let level, let text): content.append(.text(String(repeating: "#", count: level) + " " + text))
                case .code(let text):
                    var longest = 0, run = 0
                    for character in text {
                        run = character == "`" ? run + 1 : 0
                        longest = max(longest, run)
                    }
                    let fence = String(repeating: "`", count: max(3, longest + 1))
                    content.append(.text(fence + "\n" + text + "\n" + fence))
                case .blockquote(let lines): content.append(.text(lines.map { "> " + $0 }.joined(separator: "\n")))
                case .rule: content.append(.text("---"))
                case .table(let rows): content.append(.text(rows.map { "| " + $0.joined(separator: " | ") + " |" }.joined(separator: "\n")))
                }
            }
            if content.isEmpty { content = [.text("")] }
            if case .list? = content.first { content.insert(.text(""), at: 0) }
            result.items[index].content = content
        }
        return result
    }
}
