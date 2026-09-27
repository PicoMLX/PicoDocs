import Foundation

/// A list retains each source marker and its child lists, including loose items.
struct MarkdownList {
    struct Item {
        let number: Int?
        var text: String
        var children: [MarkdownList] = []
    }
    let ordered: Bool
    var items: [Item] = []

    private struct Marker {
        let indent: Int
        let number: Int?
        let text: String
        let contentIndent: Int
    }

    private static func marker(_ line: String) -> Marker? {
        let whitespace = line.prefix { $0 == " " || $0 == "\t" }
        let indent = whitespace.reduce(0) { $1 == "\t" ? $0 + (4 - $0 % 4) : $0 + 1 }
        let content = String(line.dropFirst(whitespace.count))
        func item(markerWidth: Int, number: Int?) -> Marker? {
            let tail = content.dropFirst(markerWidth)
            guard tail.isEmpty || tail.first == " " else { return nil }
            let spaces = tail.prefix { $0 == " " }.count
            let padding = (1...4).contains(spaces) ? spaces : 1
            return Marker(indent: indent, number: number, text: String(tail.dropFirst(padding)), contentIndent: indent + markerWidth + padding)
        }
        if let first = content.first, "-*+".contains(first) { return item(markerWidth: 1, number: nil) }
        let digits = content.prefix { $0.isASCII && $0.isNumber }
        let tail = content.dropFirst(digits.count)
        guard (1...9).contains(digits.count), let number = Int(digits), tail.first == "." else { return nil }
        return item(markerWidth: digits.count + 1, number: number)
    }

    static func startsItem(_ line: String) -> Bool { marker(line) != nil }

    static func parse(_ lines: [String], index: inout Int, depth: Int = 0, minimumIndent: Int = 0) -> MarkdownList? {
        guard index < lines.count, depth < 32, let first = marker(lines[index]) else { return nil }
        var list = MarkdownList(ordered: first.number != nil)
        var contentIndent = first.contentIndent
        while index < lines.count {
            var next = index
            while next < lines.count, String(lines[next].drop { $0 == " " || $0 == "\t" }).isEmpty { next += 1 }
            guard next < lines.count else { break }
            let blank = next > index
            if let current = marker(lines[next]) {
                if current.indent < minimumIndent { break }
                if list.items.isEmpty || current.indent < contentIndent {
                    guard (current.number != nil) == list.ordered else { break }
                    // An explicit restart following a blank line opens a new list.
                    if blank, !list.items.isEmpty { break }
                    index = next + 1
                    list.items.append(Item(number: current.number, text: current.text))
                    contentIndent = current.contentIndent
                } else {
                    guard !list.items.isEmpty else { break }
                    var childIndex = next
                    guard let child = parse(lines, index: &childIndex, depth: depth + 1, minimumIndent: contentIndent) else { break }
                    list.items[list.items.count - 1].children.append(child)
                    index = childIndex
                }
            } else {
                let indent = lines[next].prefix { $0 == " " }.count
                guard !blank, indent > first.indent, !list.items.isEmpty else { break }
                list.items[list.items.count - 1].text += "\n" + String(lines[next].drop { $0 == " " || $0 == "\t" })
                index = next + 1
            }
        }
        return list
    }

    private var displayedNumbers: [Int?] {
        var previousDisplay: Int?
        var previousSource: Int?
        return items.map { item in
            guard let number = item.number else { return nil }
            // Repeated markers are shorthand; a decrease in the source is an explicit restart.
            let restarts = previousSource.map { number < $0 } ?? false
            let displayed = restarts ? number : previousDisplay.map { max(number, min($0, Int.max - 1) + 1) } ?? number
            previousSource = number
            previousDisplay = displayed
            return displayed
        }
    }

    func plaintext(indent: String = "", inline: (String) -> String) -> String {
        zip(items, displayedNumbers).map { item, displayed in
            let marker = displayed.map { "\($0). " } ?? "- "
            let line = indent + marker + Self.inlineText(item.text, breakText: "\n" + indent + String(repeating: " ", count: marker.count), inline: inline)
            let children = item.children.map { $0.plaintext(indent: indent + String(repeating: " ", count: marker.count), inline: inline) }
            return ([line] + children).joined(separator: "\n")
        }.joined(separator: "\n")
    }

    func html(inline: (String) -> String) -> String {
        let tag = ordered ? "ol" : "ul"
        let start = items.first?.number ?? 1
        let attribute = ordered && start != 1 ? " start=\"\(start)\"" : ""
        var expected = start
        let body = zip(items, displayedNumbers).map { item, displayed in
            let value = displayed.map { $0 == expected ? "" : " value=\"\($0)\"" } ?? ""
            if let number = displayed { expected = min(number, Int.max - 1) + 1 }
            let children = item.children.map { $0.html(inline: inline) }.joined(separator: "\n")
            return "<li\(value)>\(Self.inlineText(item.text, breakText: "<br>", inline: inline))\(children.isEmpty ? "" : "\n" + children)</li>"
        }.joined(separator: "\n")
        return "<\(tag)\(attribute)>\n\(body)\n</\(tag)>"
    }

    private static func inlineText(_ text: String, breakText: String, inline: (String) -> String) -> String {
        var hardBreak = "\u{E040}"
        while text.contains(hardBreak) { hardBreak += "\u{E041}" }
        let protected = MarkdownTableCell.mapCodeSpans(text, code: { $0 }, plain: {
            $0.replacingOccurrences(of: " {2,}\n", with: hardBreak, options: .regularExpression)
        })
        return inline(protected).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: hardBreak, with: breakText)
    }

    var texts: [String] { items.flatMap { [$0.text] + $0.children.flatMap(\.texts) } }
}
