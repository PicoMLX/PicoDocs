import Foundation

/// A list retains source markers and the reading order of text and child lists.
struct MarkdownList: Equatable {
    struct Item: Equatable {
        let number: Int?
        enum Content: Equatable {
            case text(String)
            case list(MarkdownList)
        }
        var content: [Content]
        init(number: Int?, text: String) {
            self.number = number
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
    }

    private static func indentation(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $1 == "\t" ? $0 + (4 - $0 % 4) : $0 + 1 }
    }

    private static func marker(_ line: String) -> Marker? {
        let whitespace = line.prefix { $0 == " " || $0 == "\t" }
        let indent = whitespace.reduce(0) { $1 == "\t" ? $0 + (4 - $0 % 4) : $0 + 1 }
        let content = line.dropFirst(whitespace.count)
        let number: Int?
        let markerWidth: Int
        if let first = content.first, "-*+".contains(first) {
            number = nil; markerWidth = 1
        } else {
            let digits = content.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits), content.dropFirst(digits.count).first == "." else { return nil }
            number = value; markerWidth = digits.count + 1
        }
        let tail = content.dropFirst(markerWidth)
        guard tail.isEmpty || tail.first == " " || tail.first == "\t" else { return nil }
        let padding = tail.prefix { $0 == " " || $0 == "\t" }
        let contentIndent = padding.isEmpty ? indent + markerWidth + 1 : padding.reduce(indent + markerWidth) {
            $1 == "\t" ? $0 + (4 - $0 % 4) : $0 + 1
        }
        return Marker(indent: indent, contentIndent: contentIndent, number: number, text: String(tail.dropFirst(padding.count)))
    }

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
                    guard (current.number != nil) == list.ordered else { break }
                    // An explicit restart following a blank line opens a new list.
                    if blank, !list.items.isEmpty, current.number == first.number, list.ordered { break }
                    index = next + 1
                    list.items.append(Item(number: current.number, text: current.text))
                    contentIndent = current.contentIndent
                } else {
                    guard !list.items.isEmpty else { break }
                    var childIndex = next
                    guard let child = parse(lines, index: &childIndex, depth: depth + 1, minimumIndent: contentIndent) else { break }
                    list.items[list.items.count - 1].content.append(.list(child))
                    index = childIndex
                }
            } else {
                let indent = indentation(lines[next])
                guard !blank, indent >= contentIndent, !list.items.isEmpty else { break }
                list.items[list.items.count - 1].appendText(String(lines[next].drop { $0 == " " || $0 == "\t" }))
                index = next + 1
            }
        }
        return list
    }

    func plaintext(indent: String = "", inline: (String) -> String) -> String {
        items.map { item in
            let marker = item.number.map { "\($0). " } ?? "- "
            let continuation = indent + String(repeating: " ", count: marker.count)
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

    var texts: [String] {
        items.flatMap { $0.content.flatMap { content in
            switch content {
            case .text(let text): return [text]
            case .list(let child): return child.texts
            }
        } }
    }
}
