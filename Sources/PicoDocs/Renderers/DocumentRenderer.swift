//
//  DocumentRenderer.swift
//  PicoDocs
//
//  Renders a (canonical, structured) `ConverterResult` to a requested
//  `ExportFileType`. Markdown is the canonical form converters emit; the other
//  formats are derived from it here, so converters never branch on output format.
//
//  The non-Markdown renderers parse the Markdown subset PicoDocs produces
//  (headings, emphasis, links/images, code spans/fences, blockquotes, lists,
//  pipe tables, rules) rather than implementing a full CommonMark parser.
//

import Foundation

public enum DocumentRenderer {

    public static func render(_ result: ConverterResult, to format: ExportFileType) throws -> String {
        switch format {
        case .markdown:
            return result.markdown()
        case .plaintext:
            return renderPlaintext(result)
        case .html:
            return renderHTML(result)
        case .xml:
            return renderXML(result)
        case .csv:
            return renderCSV(result)
        }
    }

    // MARK: - Plaintext

    private static func renderPlaintext(_ result: ConverterResult) -> String {
        var out: [String] = []
        for block in parseBlocks(result.markdown()) {
            switch block {
            case .heading(_, let text):
                out.append(stripInline(text))
            case .paragraph(let text):
                out.append(stripInline(text))
            case .code(let code):
                out.append(code)
            case .rule:
                out.append("")
            case .blockquote(let lines):
                out.append(lines.map { stripInline($0) }.joined(separator: "\n"))
            case .list(let ordered, let items):
                let rendered = items.enumerated().map { index, item in
                    let marker = ordered ? "\(index + 1). " : "- "
                    return marker + stripInline(item).replacingOccurrences(of: "\n", with: " ")
                }
                out.append(rendered.joined(separator: "\n"))
            case .table(let rows):
                out.append(rows.map { $0.map { stripInline($0) }.joined(separator: "\t") }.joined(separator: "\n"))
            }
        }
        return out.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - HTML

    private static func renderHTML(_ result: ConverterResult) -> String {
        var body: [String] = []
        for block in parseBlocks(result.markdown()) {
            switch block {
            case .heading(let level, let text):
                body.append("<h\(level)>\(inlineHTML(text))</h\(level)>")
            case .paragraph(let text):
                let html = inlineHTML(text).replacingOccurrences(of: "\n", with: "<br>\n")
                body.append("<p>\(html)</p>")
            case .code(let code):
                body.append("<pre><code>\(escapeHTML(code))</code></pre>")
            case .rule:
                body.append("<hr>")
            case .blockquote(let lines):
                let inner = lines.map { inlineHTML($0) }.joined(separator: "<br>\n")
                body.append("<blockquote>\(inner)</blockquote>")
            case .list(let ordered, let items):
                let tag = ordered ? "ol" : "ul"
                let lis = items.map { "<li>\(inlineHTML($0).replacingOccurrences(of: "\n", with: " "))</li>" }
                body.append("<\(tag)>\n\(lis.joined(separator: "\n"))\n</\(tag)>")
            case .table(let rows):
                body.append(renderHTMLTable(rows))
            }
        }
        let title = result.title.map { "<title>\(escapeHTML($0))</title>\n" } ?? ""
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        \(title)</head>
        <body>
        \(body.joined(separator: "\n"))
        </body>
        </html>
        """
    }

    private static func renderHTMLTable(_ rows: [[String]]) -> String {
        guard let header = rows.first else { return "" }
        var out = "<table>\n<thead>\n<tr>"
        out += header.map { "<th>\(inlineHTML($0))</th>" }.joined()
        out += "</tr>\n</thead>\n<tbody>\n"
        for row in rows.dropFirst() {
            out += "<tr>" + row.map { "<td>\(inlineHTML($0))</td>" }.joined() + "</tr>\n"
        }
        out += "</tbody>\n</table>"
        return out
    }

    // MARK: - XML

    private static func renderXML(_ result: ConverterResult) -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<document"
        if let title = result.title { out += " title=\"\(escapeXMLAttribute(title))\"" }
        if let author = result.author { out += " author=\"\(escapeXMLAttribute(author))\"" }
        out += ">\n"
        for section in result.sections {
            out += "  <section kind=\"\(section.kind.rawValue)\""
            if let title = section.title { out += " title=\"\(escapeXMLAttribute(title))\"" }
            out += ">\n"
            out += "    \(escapeXML(section.markdown))\n"
            out += "  </section>\n"
        }
        out += "</document>"
        return out
    }

    // MARK: - CSV

    /// Emits CSV from the document's Markdown: pipe-table rows become CSV rows,
    /// and any other non-blank line becomes a single-field row, so spreadsheet
    /// exports are clean and prose isn't silently dropped.
    private static func renderCSV(_ result: ConverterResult) -> String {
        var rows: [String] = []
        for rawLine in result.markdown().components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("|") {
                let cells = parseTableRow(rawLine).map { unescapePipes($0) }
                if isTableSeparatorRow(cells) { continue }
                rows.append(cells.map { csvField($0) }.joined(separator: ","))
            } else {
                rows.append(csvField(stripInline(line)))
            }
        }
        return rows.joined(separator: "\n")
    }

    // MARK: - Markdown block parsing

    private enum Block {
        case heading(Int, String)
        case paragraph(String)
        case code(String)
        case blockquote([String])
        case list(ordered: Bool, items: [String])
        case table([[String]])
        case rule
    }

    private static func parseBlocks(_ markdown: String) -> [Block] {
        let lines = markdown.components(separatedBy: "\n")
        var blocks: [Block] = []
        var i = 0

        func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if isBlank(line) { i += 1; continue }

            if trimmed.hasPrefix("```") {
                i += 1
                var code: [String] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
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
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let cells = parseTableRow(lines[i]).map { unescapePipes($0) }
                    if !isTableSeparatorRow(cells) { rows.append(cells) }
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
                let ordered = listMarker(trimmed) == .ordered
                var items: [String] = []
                while i < lines.count {
                    let itemLine = lines[i].trimmingCharacters(in: .whitespaces)
                    if let marker = listMarker(itemLine), (marker == .ordered) == ordered {
                        items.append(stripListMarker(itemLine)); i += 1
                    } else if !isBlank(lines[i]), lines[i].hasPrefix("  "), !items.isEmpty {
                        items[items.count - 1] += "\n" + lines[i].trimmingCharacters(in: .whitespaces)
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(ordered: ordered, items: items)); continue
            }

            // Paragraph: gather until a blank line or a structural line.
            var paragraph: [String] = []
            while i < lines.count {
                let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                if isBlank(lines[i]) || candidate.hasPrefix("```") || candidate.hasPrefix("|")
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

    private static func headingMatch(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#", level < 6 {
            level += 1; index = line.index(after: index)
        }
        guard level > 0, index < line.endIndex, line[index] == " " else { return nil }
        let text = String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    private enum ListKind: Equatable { case ordered, unordered }

    private static func listMarker(_ line: String) -> ListKind? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { return .unordered }
        // ordered: one-or-more digits, then ". "
        var index = line.startIndex
        var digits = 0
        while index < line.endIndex, line[index].isNumber { digits += 1; index = line.index(after: index) }
        if digits > 0, index < line.endIndex, line[index] == "." {
            let after = line.index(after: index)
            if after < line.endIndex, line[after] == " " { return .ordered }
        }
        return nil
    }

    private static func stripListMarker(_ line: String) -> String {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return String(line.dropFirst(2))
        }
        if let dot = line.firstIndex(of: "."), line[line.startIndex..<dot].allSatisfy(\.isNumber) {
            return String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
        }
        return line
    }

    private static func parseTableRow(_ line: String) -> [String] {
        var cells = line.trimmingCharacters(in: .whitespaces)
        if cells.hasPrefix("|") { cells.removeFirst() }
        if cells.hasSuffix("|") { cells.removeLast() }
        // Split on unescaped pipes only.
        var result: [String] = []
        var current = ""
        var previous: Character?
        for character in cells {
            if character == "|", previous != "\\" {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }

    private static func isTableSeparatorRow(_ cells: [String]) -> Bool {
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && trimmed.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func unescapePipes(_ s: String) -> String {
        s.replacingOccurrences(of: "\\|", with: "|")
    }

    // MARK: - Inline rendering

    /// Converts inline Markdown to HTML on an HTML-escaped string.
    private static func inlineHTML(_ text: String) -> String {
        var result = escapeHTML(text)
        result = result.replacingOccurrences(of: "`([^`]+)`", with: "<code>$1</code>", options: .regularExpression)
        result = result.replacingOccurrences(of: "!\\[([^\\]]*)\\]\\(([^)]+)\\)", with: "<img src=\"$2\" alt=\"$1\">", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\[([^\\]]*)\\]\\(([^)]+)\\)", with: "<a href=\"$2\">$1</a>", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "<strong>$1</strong>", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\*([^*]+)\\*", with: "<em>$1</em>", options: .regularExpression)
        return result
    }

    /// Strips inline Markdown to plain text (links/images become their label/alt).
    private static func stripInline(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "!\\[([^\\]]*)\\]\\(([^)]+)\\)", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\[([^\\]]*)\\]\\(([^)]+)\\)", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\*([^*]+)\\*", with: "$1", options: .regularExpression)
        return result
    }

    // MARK: - Escaping

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeXML(_ text: String) -> String {
        escapeHTML(text)
    }

    private static func escapeXMLAttribute(_ text: String) -> String {
        escapeHTML(text).replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Quotes a CSV field per RFC 4180 when it contains a comma, quote, or newline.
    private static func csvField(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
