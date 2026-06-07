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
//  These renderers assume their input is the canonical Markdown the converters
//  emit. Raw-text and CSV *inputs* are currently stored verbatim by
//  PlainTextConverter (it doesn't Markdown-escape text or parse CSV into a
//  table), so re-exporting those specific inputs to plaintext/CSV can drop a
//  literal `*` or collapse columns — making those round-trips lossless is a
//  PlainTextConverter follow-up, not a renderer change.
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
        let (bodyMarkdown, notes) = extractFootnotes(result.markdown())
        let parsed = parseBlocks(bodyMarkdown)
        let numbers = footnoteNumbers(blocks: parsed, notes: notes)
        var out: [String] = []
        // Inline `[^id]` references become `[N]` inside `stripInline` (code spans
        // protected; code blocks keep literal markers).
        for block in parsed {
            switch block {
            case .heading(_, let text):
                out.append(stripInline(text, footnoteNumbers: numbers))
            case .paragraph(let text):
                out.append(stripInline(text, footnoteNumbers: numbers))
            case .code(let code):
                out.append(code)
            case .rule:
                out.append("---")
            case .blockquote(let lines):
                out.append(lines.map { stripInline($0, footnoteNumbers: numbers) }.joined(separator: "\n"))
            case .list(let ordered, let items):
                let rendered = items.enumerated().map { index, item in
                    let marker = ordered ? "\(index + 1). " : "- "
                    return marker + stripInline(item, footnoteNumbers: numbers).replacingOccurrences(of: "\n", with: " ")
                }
                out.append(rendered.joined(separator: "\n"))
            case .table(let rows):
                out.append(rows.map { $0.map { stripInline($0, footnoteNumbers: numbers) }.joined(separator: "\t") }.joined(separator: "\n"))
            }
        }
        var text = out.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // Append numbered definitions for referenced notes (parseBlocks would
        // otherwise leak them as plain text); references were numbered above.
        let referenced = referencedNotes(notes, numbers)
        if !referenced.isEmpty {
            let defs = referenced
                .map { "[\(numbers[$0.id]!)] " + stripInline($0.text.replacingOccurrences(of: "\n", with: " "), footnoteNumbers: numbers) }
                .joined(separator: "\n")
            text += "\n\n" + defs
        }
        return text
    }

    // MARK: - HTML

    private static func renderHTML(_ result: ConverterResult) -> String {
        let (bodyMarkdown, notes) = extractFootnotes(result.markdown())
        let parsed = parseBlocks(bodyMarkdown)
        let numbers = footnoteNumbers(blocks: parsed, notes: notes)
        var blocks: [String] = []
        // Inline `[^id]` references are turned into superscript links inside
        // `inlineHTML` (so code spans are protected and code blocks, which never
        // reach `inlineHTML`, keep literal markers).
        for block in parsed {
            switch block {
            case .heading(let level, let text):
                blocks.append("<h\(level)>\(inlineHTML(text, footnoteNumbers: numbers))</h\(level)>")
            case .paragraph(let text):
                let html = inlineHTML(text, footnoteNumbers: numbers).replacingOccurrences(of: "\n", with: "<br>\n")
                blocks.append("<p>\(html)</p>")
            case .code(let code):
                blocks.append("<pre><code>\(escapeHTML(code))</code></pre>")
            case .rule:
                blocks.append("<hr>")
            case .blockquote(let lines):
                let inner = lines.map { inlineHTML($0, footnoteNumbers: numbers) }.joined(separator: "<br>\n")
                blocks.append("<blockquote>\(inner)</blockquote>")
            case .list(let ordered, let items):
                let tag = ordered ? "ol" : "ul"
                let lis = items.map { "<li>\(inlineHTML($0, footnoteNumbers: numbers).replacingOccurrences(of: "\n", with: " "))</li>" }
                blocks.append("<\(tag)>\n\(lis.joined(separator: "\n"))\n</\(tag)>")
            case .table(let rows):
                blocks.append(renderHTMLTable(rows, footnoteNumbers: numbers))
            }
        }
        var bodyHTML = blocks.joined(separator: "\n")
        let footnotes = footnotesHTML(notes: notes, numbers: numbers)
        if !footnotes.isEmpty { bodyHTML += "\n" + footnotes }
        let title = result.title.map { "<title>\(escapeHTML($0))</title>\n" } ?? ""
        var html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        \(title)</head>
        <body>
        \(bodyHTML)
        </body>
        </html>
        """
        // Make HTML export self-contained: rewrite `<img src="filename">`
        // references to data URLs using the bytes carried on `.image` sections
        // (the body Markdown keeps clean filename refs for the other formats).
        html = embedImageDataURLs(html, sections: result.sections)
        return html
    }

    /// Replaces bare image `src="filename"` references with `data:` URLs built
    /// from the `.image` sections' base64/MIME metadata.
    private static func embedImageDataURLs(_ html: String, sections: [DocumentSection]) -> String {
        var result = html
        for section in sections where section.kind == .image {
            let filename = (section.sourcePath as NSString?)?.lastPathComponent ?? section.title
            guard let filename, !filename.isEmpty,
                  let base64 = section.metadata["base64"], !base64.isEmpty else { continue }
            let mime = section.metadata["mimeType"] ?? "application/octet-stream"
            result = result.replacingOccurrences(
                of: "src=\"\(filename)\"",
                with: "src=\"data:\(mime);base64,\(base64)\""
            )
        }
        return result
    }

    private static func renderHTMLTable(_ rows: [[String]], footnoteNumbers: [String: Int] = [:]) -> String {
        guard let header = rows.first else { return "" }
        var out = "<table>\n<thead>\n<tr>"
        out += header.map { "<th>\(inlineHTML($0, footnoteNumbers: footnoteNumbers))</th>" }.joined()
        out += "</tr>\n</thead>\n<tbody>\n"
        for row in rows.dropFirst() {
            out += "<tr>" + row.map { "<td>\(inlineHTML($0, footnoteNumbers: footnoteNumbers))</td>" }.joined() + "</tr>\n"
        }
        out += "</tbody>\n</table>"
        return out
    }

    // MARK: - Footnotes
    //
    // Footnote rendering applies to the prose-rendering formats (HTML/plaintext).
    // The XML and CSV exports emit section Markdown structurally, so they keep the
    // canonical `[^id]` markers verbatim rather than rendering them.

    /// Splits canonical Markdown into its body (with `[^id]` reference markers left
    /// in place) and the footnote definitions (`[^id]: text`, with indented
    /// continuation lines folded in), in definition order.
    private static func extractFootnotes(_ markdown: String) -> (body: String, notes: [(id: String, text: String)]) {
        let lines = markdown.components(separatedBy: "\n")
        var bodyLines: [String] = []
        var notes: [(id: String, text: String)] = []
        var i = 0
        var inFence = false
        while i < lines.count {
            // A `[^id]: text` line inside a fenced code block is literal code, not
            // a definition — track the fence so it stays in the body.
            if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                bodyLines.append(lines[i])
                i += 1
                continue
            }
            // Allow up to 3 leading spaces before a definition (Markdown block
            // indentation); 4+ spaces is an indented code block, left in the body.
            if !inFence, let (id, first) = parseFootnoteDefinition(dropLeadingSpaces(lines[i], max: 3)) {
                var textLines = [first]
                i += 1
                while i < lines.count {                       // indented continuation lines
                    let line = lines[i]
                    if line.hasPrefix("    ") { textLines.append(String(line.dropFirst(4))); i += 1 }
                    else if line.hasPrefix("\t") { textLines.append(String(line.dropFirst())); i += 1 }
                    else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                        // A blank line continues the note only when an indented line
                        // follows (a multi-paragraph footnote); otherwise it ends it.
                        var j = i + 1
                        while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                        guard j < lines.count, lines[j].hasPrefix("    ") || lines[j].hasPrefix("\t") else { break }
                        textLines.append("")
                        i += 1
                    }
                    else { break }
                }
                notes.append((id, textLines.joined(separator: "\n")))
            } else {
                bodyLines.append(lines[i])
                i += 1
            }
        }
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (body, notes)
    }

    /// Parses a CommonMark footnote definition line `[^id]: text`, returning the
    /// id and first-line text (nil if the line isn't a definition).
    private static func parseFootnoteDefinition(_ line: String) -> (id: String, text: String)? {
        guard line.hasPrefix("[^"), let close = line.firstIndex(of: "]") else { return nil }
        let idStart = line.index(line.startIndex, offsetBy: 2)
        guard idStart < close else { return nil }
        let id = String(line[idStart..<close])
        let afterClose = line.index(after: close)
        guard !id.isEmpty, afterClose < line.endIndex, line[afterClose] == ":" else { return nil }
        var text = String(line[line.index(after: afterClose)...])
        if text.hasPrefix(" ") { text.removeFirst() }
        return (id, text)
    }

    /// Drops up to `max` leading spaces (used to allow Markdown's 1-3 space block
    /// indentation before a footnote definition without consuming a 4-space code indent).
    private static func dropLeadingSpaces(_ line: String, max: Int) -> String {
        var count = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == " ", count < max {
            count += 1
            index = line.index(after: index)
        }
        return String(line[index...])
    }

    /// Numbers footnotes in the order their `[^id]` reference is actually rendered:
    /// it scans the parsed blocks with code spans and links removed (mirroring the
    /// inline pipeline), so markers inside code, or consumed by a link, aren't
    /// counted. Body references are numbered first, then numbered notes' bodies are
    /// scanned breadth-first, so a note referenced only from another note is still
    /// numbered while visible body numbers stay in document order. Unreferenced
    /// definitions get no number (and so aren't rendered), matching how Markdown
    /// footnote processors treat them.
    private static func footnoteNumbers(blocks: [Block], notes: [(id: String, text: String)]) -> [String: Int] {
        let noteText = Dictionary(notes.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        var numbers: [String: Int] = [:]
        var next = 1

        var pending: [String] = []   // numbered notes whose bodies still need scanning

        func register(_ id: String) {
            guard noteText[id] != nil, numbers[id] == nil else { return }
            numbers[id] = next; next += 1
            pending.append(id)        // defer scanning its body (breadth-first)
        }
        func scan(_ text: String) {
            // Mirror inlineHTML/stripInline: code spans and links become
            // placeholders, so a `[^id]` inside them isn't treated as a reference.
            let (afterCode, _) = extractCodeSpans(text)
            let (afterLinks, _) = extractLinks(afterCode)
            var cursor = afterLinks.startIndex
            while let open = afterLinks.range(of: "[^", range: cursor..<afterLinks.endIndex) {
                guard let close = afterLinks.range(of: "]", range: open.upperBound..<afterLinks.endIndex) else { break }
                register(String(afterLinks[open.upperBound..<close.lowerBound]))
                cursor = close.upperBound
            }
        }

        for block in blocks {
            switch block {
            case .code, .rule: continue        // code blocks never render footnote refs
            case .heading(_, let text): scan(text)
            case .paragraph(let text): scan(text)
            case .blockquote(let lines): lines.forEach(scan)
            case .list(_, let items): items.forEach(scan)
            case .table(let rows): rows.forEach { $0.forEach(scan) }
            }
        }
        // Number notes referenced only from other notes after all body references
        // (breadth-first), so visible body numbers stay in document order.
        var index = 0
        while index < pending.count {
            scan(noteText[pending[index]] ?? "")
            index += 1
        }
        return numbers
    }

    /// The trailing `<section class="footnotes">` list, ordered by footnote number,
    /// each item carrying a backreference to its inline marker.
    /// Referenced notes, de-duplicated by id (first definition wins), ordered by
    /// footnote number — so a label defined more than once still renders once.
    private static func referencedNotes(_ notes: [(id: String, text: String)], _ numbers: [String: Int]) -> [(id: String, text: String)] {
        var seen = Set<String>()
        return notes
            .filter { numbers[$0.id] != nil && seen.insert($0.id).inserted }
            .sorted { numbers[$0.id]! < numbers[$1.id]! }
    }

    /// The trailing `<section class="footnotes">` list of referenced notes, ordered
    /// by number. Returns "" when no note is referenced.
    private static func footnotesHTML(notes: [(id: String, text: String)], numbers: [String: Int]) -> String {
        let items = referencedNotes(notes, numbers)
            .map { note -> String in
                // Escape the id for attribute context (it comes from document text).
                // Render the note body with the same numbers so a reference inside a
                // note is rendered too. No backreference link: references omit a
                // per-occurrence `id`, so there's no unique anchor to return to
                // (which keeps element ids unique under repeated references).
                let inner = inlineHTML(note.text.replacingOccurrences(of: "\n", with: " "), footnoteNumbers: numbers)
                return "<li id=\"fn-\(escapeHTML(note.id))\">\(inner)</li>"
            }
            .joined(separator: "\n")
        return items.isEmpty ? "" : "<section class=\"footnotes\">\n<hr>\n<ol>\n\(items)\n</ol>\n</section>"
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

    /// Emits CSV from the document. A section that carries a lossless CSV
    /// serialization in `metadata["csv"]` (e.g. `CSVConverter`, whose Markdown
    /// table can't hold embedded newlines/whitespace) is emitted verbatim;
    /// otherwise pipe-table rows become CSV rows and any other non-blank line
    /// becomes a single-field row, so prose isn't silently dropped.
    private static func renderCSV(_ result: ConverterResult) -> String {
        var parts: [String] = []
        for section in result.sections where section.kind != .image {
            if let rawCSV = section.metadata["csv"], !rawCSV.isEmpty {
                parts.append(rawCSV)
            } else {
                let rows = csvRows(fromMarkdown: section.markdown)
                if !rows.isEmpty { parts.append(rows.joined(separator: "\n")) }
            }
        }
        return parts.joined(separator: "\n")
    }

    private static func csvRows(fromMarkdown markdown: String) -> [String] {
        var rows: [String] = []
        let lines = markdown.components(separatedBy: "\n")
        var i = 0
        var inCodeFence = false
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inCodeFence.toggle()
                i += 1
                continue
            }
            if inCodeFence {
                // Preserve fenced code verbatim as a single field, so a pipe-
                // containing code line isn't split into CSV cells.
                rows.append(csvField(lines[i]))
                i += 1
                continue
            }
            if line.isEmpty { i += 1; continue }
            if line.hasPrefix("|") {
                // Within a run of table rows, drop only the conventional separator
                // (second row), so all-dash data rows elsewhere are preserved.
                var rowIndex = 0
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let cells = parseTableRow(lines[i]).map { MarkdownTableCell.unescape($0) }
                    if !(rowIndex == 1 && isTableSeparatorRow(cells)) {
                        rows.append(cells.map { csvField($0) }.joined(separator: ","))
                    }
                    rowIndex += 1
                    i += 1
                }
            } else {
                rows.append(csvField(stripInline(line)))
                i += 1
            }
        }
        return rows
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

    private static func isTableSeparatorRow(_ cells: [String]) -> Bool {
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && trimmed.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }


    // MARK: - Inline rendering

    // Sentinels that bracket extracted spans; private-use scalars that won't
    // appear in document text and aren't touched by escaping or emphasis regexes.
    private static let codeOpen = "\u{E000}"
    private static let codeClose = "\u{E001}"
    private static let linkOpen = "\u{E002}"
    private static let linkClose = "\u{E003}"

    private struct InlineLink { let label: String; let url: String; let isImage: Bool }

    /// Replaces inline code spans with placeholders so the link/emphasis passes
    /// don't rewrite Markdown metacharacters inside code.
    private static func extractCodeSpans(_ text: String) -> (text: String, spans: [String]) {
        var spans: [String] = []
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "`",
               let close = text[text.index(after: index)...].firstIndex(of: "`") {
                spans.append(String(text[text.index(after: index)..<close]))
                result += "\(codeOpen)\(spans.count - 1)\(codeClose)"
                index = text.index(after: close)
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return (result, spans)
    }

    /// Replaces links/images with placeholders before escaping/emphasis so a URL
    /// (or alt text) containing emphasis characters isn't rewritten inside the
    /// generated attribute. Handles CommonMark angle-bracket destinations
    /// `(<url with spaces (and parens)>)` that WordConverter emits.
    private static func extractLinks(_ text: String) -> (text: String, links: [InlineLink]) {
        let pattern = "(!)?\\[([^\\]]*)\\]\\((?:<([^>]+)>|([^)]+))\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (text, []) }
        let ns = text as NSString
        var links: [InlineLink] = []
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let isImage = match.range(at: 1).location != NSNotFound
            let label = nsSubstring(ns, match.range(at: 2))
            let url = match.range(at: 3).location != NSNotFound ? nsSubstring(ns, match.range(at: 3)) : nsSubstring(ns, match.range(at: 4))
            result += "\(linkOpen)\(links.count)\(linkClose)"
            links.append(InlineLink(label: label, url: url, isImage: isImage))
            last = match.range.location + match.range.length
        }
        result += ns.substring(with: NSRange(location: last, length: ns.length - last))
        return (result, links)
    }

    private static func nsSubstring(_ ns: NSString, _ range: NSRange) -> String {
        range.location == NSNotFound ? "" : ns.substring(with: range)
    }

    /// Converts inline Markdown to HTML. Code spans and links/images are pulled
    /// out first (so their contents/URLs aren't touched by escaping or emphasis),
    /// the remaining text is HTML-escaped and emphasized, then they're restored.
    private static func inlineHTML(_ text: String, footnoteNumbers: [String: Int] = [:]) -> String {
        let (afterCode, spans) = extractCodeSpans(text)
        let (afterLinks, links) = extractLinks(afterCode)
        var result = applyEmphasisHTML(escapeHTML(afterLinks))
        // Footnote references: `[^id]` -> a superscript link. Done here, where code
        // spans are already placeholders, so markers inside code are not touched
        // (code blocks never reach inlineHTML). The id is HTML-escaped for attribute
        // safety and references carry no `id`, so repeated references don't produce
        // duplicate element ids. The escaped id also matches the escaped body text.
        for (id, number) in footnoteNumbers {
            let escapedId = escapeHTML(id)
            result = result.replacingOccurrences(
                of: "[^\(escapedId)]",
                with: "<sup class=\"footnote-ref\"><a href=\"#fn-\(escapedId)\">\(number)</a></sup>"
            )
        }
        for (index, link) in links.enumerated() {
            let tag = link.isImage
                ? "<img src=\"\(escapeHTML(link.url))\" alt=\"\(escapeHTML(link.label))\">"
                : "<a href=\"\(escapeHTML(link.url))\">\(applyEmphasisHTML(escapeHTML(link.label)))</a>"
            result = result.replacingOccurrences(of: "\(linkOpen)\(index)\(linkClose)", with: tag)
        }
        for (index, span) in spans.enumerated() {
            result = result.replacingOccurrences(of: "\(codeOpen)\(index)\(codeClose)", with: "<code>\(escapeHTML(span))</code>")
        }
        return result
    }

    private static func applyEmphasisHTML(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "\\*\\*\\*(.+?)\\*\\*\\*", with: "<strong><em>$1</em></strong>", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "<strong>$1</strong>", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\*(.+?)\\*", with: "<em>$1</em>", options: .regularExpression)
        return result
    }

    /// Strips inline Markdown to plain text (links/images become their label/alt;
    /// code spans keep their literal contents).
    private static func stripInline(_ text: String, footnoteNumbers: [String: Int] = [:]) -> String {
        let (afterCode, spans) = extractCodeSpans(text)
        let (afterLinks, links) = extractLinks(afterCode)
        var result = applyEmphasisStrip(afterLinks)
        // Footnote references become `[N]` here (code spans already extracted, so
        // markers inside code are preserved; code blocks never reach stripInline).
        for (id, number) in footnoteNumbers {
            result = result.replacingOccurrences(of: "[^\(id)]", with: "[\(number)]")
        }
        for (index, link) in links.enumerated() {
            result = result.replacingOccurrences(of: "\(linkOpen)\(index)\(linkClose)", with: applyEmphasisStrip(link.label))
        }
        for (index, span) in spans.enumerated() {
            result = result.replacingOccurrences(of: "\(codeOpen)\(index)\(codeClose)", with: span)
        }
        return result
    }

    private static func applyEmphasisStrip(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "\\*\\*\\*(.+?)\\*\\*\\*", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\*(.+?)\\*", with: "$1", options: .regularExpression)
        return result
    }

    // MARK: - Escaping

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func escapeXML(_ text: String) -> String {
        escapeHTML(text)
    }

    // `escapeHTML` already escapes the double quote, so attribute values are safe.
    private static func escapeXMLAttribute(_ text: String) -> String {
        escapeHTML(text)
    }

    /// Quotes a CSV field per RFC 4180 when it contains a comma, quote, or newline.
    private static func csvField(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
