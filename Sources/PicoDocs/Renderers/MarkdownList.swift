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
        if let first = content.first, "-*+".contains(first),
           content.count == 1 || content.dropFirst().hasPrefix(" ") {
            return Marker(indent: indent, number: nil, text: String(content.dropFirst(2)), contentIndent: indent + 2)
        }
        let digits = content.prefix { $0.isASCII && $0.isNumber }
        let tail = content.dropFirst(digits.count)
        guard !digits.isEmpty, let number = Int(digits), tail == "." || tail.hasPrefix(". ") else { return nil }
        return Marker(indent: indent, number: number, text: String(tail.dropFirst(2)), contentIndent: indent + digits.count + 2)
    }

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
                    if blank, !list.items.isEmpty, current.number == first.number, list.ordered { break }
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

    func plaintext(indent: String = "", inline: (String) -> String) -> String {
        items.map { item in
            let marker = item.number.map { "\($0). " } ?? "- "
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
        let body = items.map { item in
            let value = item.number.map { $0 == expected ? "" : " value=\"\($0)\"" } ?? ""
            if let number = item.number { expected = min(number, Int.max - 1) + 1 }
            let children = item.children.map { $0.html(inline: inline) }.joined(separator: "\n")
            return "<li\(value)>\(Self.inlineText(item.text, breakText: "<br>", inline: inline))\(children.isEmpty ? "" : "\n" + children)</li>"
        }.joined(separator: "\n")
        return "<\(tag)\(attribute)>\n\(body)\n</\(tag)>"
    }

    private static func inlineText(_ text: String, breakText: String, inline: (String) -> String) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.enumerated().map { index, line in
            guard index + 1 < lines.count else { return inline(line) }
            if line.hasSuffix("  ") { return inline(line.trimmingCharacters(in: .whitespaces)) + breakText }
            return inline(line) + " "
        }.joined()
    }

    var texts: [String] { items.flatMap { [$0.text] + $0.children.flatMap(\.texts) } }
}
