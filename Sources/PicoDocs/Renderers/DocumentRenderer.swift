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
//  emit. Raw-text *inputs* are currently stored verbatim by PlainTextConverter
//  (it doesn't Markdown-escape text), so re-exporting that specific input to
//  plaintext can drop a literal `*` and the like. Fixing this well needs either
//  CommonMark backslash-escape support in this hand-rolled parser (risky) or a
//  verbatim-fence in PlainTextConverter (regresses prose); both are deliberately
//  deferred. The cleaner long-term fix is likely to replace this Markdown subset
//  parser with swift-markdown (a real CommonMark parser/renderer) — revisit then.
//

import Foundation

public enum DocumentRenderer {

    public static func render(_ result: ConverterResult, to format: ExportFileType) throws -> String {
        switch format {
        case .markdown:
            return result.markdown()
        case .plaintext:
            return try renderPlaintext(result)
        case .html:
            return try renderHTML(result)
        case .xml:
            return try renderXML(result)
        case .csv:
            return try renderCSV(result)
        }
    }

    /// Charge line-array/string slots before footnote and block parsing split
    /// input. Both passes retain line strings; byte-only limits miss empty lines.
    static func preflightRenderInput(_ result: ConverterResult, maximumBytes: Int = 64 * 1024 * 1024, maximumLines: Int = 100_000, markdownFallbackOnly: Bool = false) throws {
        guard maximumBytes >= 0, maximumLines > 0 else { throw PicoDocsError.fileCorrupted }
        var remaining = maximumBytes, lines = 1, sections = 0
        for section in result.sections where section.kind != .image {
            try Task.checkCancellation()
            if markdownFallbackOnly, let csv = section.metadata["csv"], !csv.isEmpty { continue }
            let bytes = section.markdown.utf8.count
            guard bytes <= remaining else { throw PicoDocsError.fileCorrupted }
            remaining -= bytes
            var previousWasCR = false
            for byte in section.markdown.utf8 {
                if byte == 13 || (byte == 10 && !previousWasCR) {
                    guard lines < maximumLines else { throw PicoDocsError.fileCorrupted }
                    lines += 1
                }
                previousWasCR = byte == 13
            }
            if sections > 0 {
                guard lines <= maximumLines - 2, remaining >= 2 else { throw PicoDocsError.fileCorrupted }
                lines += 2; remaining -= 2
            }
            sections += 1
        }
        guard lines <= remaining / 256 else { throw PicoDocsError.fileCorrupted }
    }

    /// Only a producer that owns preserved-space metadata can introduce internal
    /// whitespace tokens. Literal numeric entities from every other producer stay
    /// literal; source private-use delimiters are doubled before token insertion.
    private static func renderMarkdown(_ result: ConverterResult) throws -> String {
        var remaining = 64 * 1024 * 1024
        var sections: [String] = []
        for section in result.sections where section.kind != .image {
            let text = try preparedMarkdown(section, remaining: &remaining)
            guard sections.isEmpty || remaining >= 2 else { throw PicoDocsError.fileCorrupted }
            if !sections.isEmpty { remaining -= 2 }
            sections.append(text)
        }
        return sections.joined(separator: "\n\n")
    }

    private static func preparedMarkdown(_ section: DocumentSection, remaining: inout Int) throws -> String {
        var bytes = section.markdown.utf8.count
        for scalar in section.markdown.unicodeScalars where scalar == "\u{E008}" || scalar == "\u{E009}" {
            guard bytes <= remaining - 3 else { throw PicoDocsError.fileCorrupted }; bytes += 3
        }
        guard bytes <= remaining else { throw PicoDocsError.fileCorrupted }
        var text = section.markdown.replacingOccurrences(of: "\u{E008}", with: "\u{E008}\u{E008}").replacingOccurrences(of: "\u{E009}", with: "\u{E009}\u{E009}")
        if section.metadata["preservedWhitespace"] == "1" {
            let source = text as NSString
            var offset = 0, output = "", exceeded = false
            whitespaceReference.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, stop in
                guard let match, let value = UInt32(source.substring(with: match.range(at: 1))),
                  let scalar = UnicodeScalar(value), CharacterSet.whitespaces.contains(scalar) else { return }
                var preceding = match.range.location, slashes = 0
                while preceding > 0, source.character(at: preceding - 1) == 92 { preceding -= 1; slashes += 1 }
                guard slashes.isMultiple(of: 2) else { return }
                let token = "\u{E008}\(value)\u{E009}"
                let growth = token.utf8.count - source.substring(with: match.range).utf8.count
                guard growth <= remaining - bytes else { exceeded = true; stop.pointee = true; return }
                bytes += growth
                output += source.substring(with: NSRange(location: offset, length: match.range.location - offset)) + token
                offset = NSMaxRange(match.range)
            }
            guard !exceeded else { throw PicoDocsError.fileCorrupted }
            output += source.substring(from: offset)
            text = output
        }
        remaining -= bytes
        return text
    }

    // MARK: - Plaintext

    private static func renderPlaintext(_ result: ConverterResult) throws -> String {
        try preflightRenderInput(result)
        let (bodyMarkdown, notes) = extractFootnotes(try renderMarkdown(result))
        let parsed = parseBlocks(bodyMarkdown)
        let numbers = try footnoteNumbers(blocks: parsed, notes: notes)
        let out = plaintextBlocks(parsed, footnoteNumbers: numbers)
        var text = out.joined(separator: "\n\n")
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

    /// Each block as plaintext. Inline `[^id]` references become `[N]` inside
    /// `stripInline` (code spans protected; code blocks keep literal markers).
    private static func plaintextBlocks(_ parsed: [Block], footnoteNumbers numbers: [String: Int],
                                        depth: Int = 0) -> [String] {
        parsed.map { block in
            switch block {
            case .heading(_, let text):
                return stripInline(text, footnoteNumbers: numbers)
            case .paragraph(let text):
                return stripInline(text, footnoteNumbers: numbers)
            case .code(let code):
                return restoredCodeText(code)
            case .rule:
                return "---"
            case .blockquote(let lines):
                return lines.map { stripInline($0, footnoteNumbers: numbers) }.joined(separator: "\n")
            case .list(let list):
                let items = list.items
                return items.map { item in
                    let marker = item.number.map { "\($0)\(item.delimiter)" } ?? "-"
                    return plaintextListItem(marker + item.padding, listItemText(item), footnoteNumbers: numbers, depth: depth)
                }.joined(separator: "\n")
            case .table(let rows):
                return rows.map { $0.map { MarkdownTableCell.inlineText($0) { stripInline($0, footnoteNumbers: numbers) } }.joined(separator: "\t") }.joined(separator: "\n")
            }
        }
    }

    static func listItemText(_ item: MarkdownList.Item) -> String {
        item.content.map { content in
            switch content {
            case .text(let text): return text
            case .list(let list): return list.plaintext { $0 }
            }
        }.joined(separator: "\n")
    }

    /// A list item as plaintext: the marker and its leading text on one line, with
    /// any nested content (e.g. a sub-list) indented under it.
    private static func plaintextListItem(_ marker: String, _ item: String,
                                          footnoteNumbers numbers: [String: Int], depth: Int) -> String {
        let (lead, nested) = listItemContent(item, depth: depth)
        var out = lead.isEmpty ? marker.trimmingCharacters(in: .whitespaces)
            : marker + MarkdownList.inlineText(lead, breakText: "\n" + String(repeating: " ", count: WordListNumbering.displayWidth(marker))) { stripInline($0, footnoteNumbers: numbers) }
        let indent = String(repeating: " ", count: WordListNumbering.displayWidth(marker))
        for block in plaintextBlocks(nested, footnoteNumbers: numbers, depth: depth + 1) {
            out += "\n" + block.components(separatedBy: "\n").map { indent + $0 }.joined(separator: "\n")
        }
        return out
    }

    /// Splits a list item's text into its leading paragraph and the blocks nested
    /// under it (a sub-list keeps its indentation relative to the item). Past a
    /// fixed depth the rest stays flat text, so hostile nesting can't recurse
    /// without bound.
    private static func listItemContent(_ item: String, depth: Int) -> (lead: String, nested: [Block]) {
        guard depth < maxListNesting else { return (item, []) }
        var blocks = parseBlocks(item)
        guard case .paragraph(let lead)? = blocks.first else { return ("", blocks) }
        blocks.removeFirst()
        return (lead, blocks)
    }

    private static let maxListNesting = 16

    // MARK: - HTML

    private static func renderHTML(_ result: ConverterResult) throws -> String {
        try preflightRenderInput(result)
        let (bodyMarkdown, notes) = extractFootnotes(try renderMarkdown(result))
        let parsed = parseBlocks(bodyMarkdown)
        let numbers = try footnoteNumbers(blocks: parsed, notes: notes, maximumProtectedBytes: 64 * 1024 * 1024)
        let budget = HTMLBudget()
        let blocks = try htmlBlocks(parsed, footnoteNumbers: numbers, budget: budget)
        var bodyHTML = blocks.joined(separator: "\n")
        let footnotes = try footnotesHTML(notes: notes, numbers: numbers, budget: budget)
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
        html = try embedImageDataURLs(html, sections: result.sections)
        return html
    }

    /// Replaces bare image `src="filename"` references with `data:` URLs built
    /// from the `.image` sections' base64/MIME metadata.
    ///
    /// The body refers to images by basename, so two *distinct* images that share
    /// a basename (only possible with non-standard layouts — e.g. a DOCX note part
    /// carrying its own media folder) are indistinguishable in the body HTML.
    /// Embedding either would silently show the wrong image, so such references are
    /// left unresolved (an honest broken ref) rather than confidently wrong. Giving
    /// every image a clean, unique/path-aware name would need generation-time
    /// threading through the converters — a deferred follow-up; standard documents
    /// (unique media names) embed exactly as before.
    private static func embedImageDataURLs(_ html: String, sections: [DocumentSection]) throws -> String {
        let imageSections = sections.filter { $0.kind == .image }
        // Count owners across every emitted identity. An alias can collide
        // with another carrier's exact path as well as another alias.
        func references(_ section: DocumentSection) -> Set<String> {
            Set([section.sourcePath, imageRefName(for: section)].compactMap { $0 }.filter { !$0.isEmpty })
        }
        var referenceCounts: [String: Int] = [:]
        for section in imageSections where !(section.metadata["base64"] ?? "").isEmpty {
            for reference in references(section) { referenceCounts[reference, default: 0] += 1 }
        }
        var replacements: [String: (mime: String, base64: String)] = [:]
        for section in imageSections {
            guard let base64 = section.metadata["base64"], !base64.isEmpty else { continue }
            // Parameters are metadata, not part of the payload delimiter syntax.
            let mime = (section.metadata["mimeType"] ?? "application/octet-stream")
                .split(separator: ";", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "application/octet-stream"
            for reference in references(section) where referenceCounts[reference] == 1 {
                replacements[reference] = (mime, base64)
            }
        }
        return try boundedImageReplacements(html, replacements: replacements)
    }

    /// Charge every projected occurrence before materializing any data URLs.
    static func boundedImageReplacement(_ html: String, reference: String, mime: String, base64: String, maximumBytes: Int = 64 * 1024 * 1024) throws -> String {
        try boundedImageReplacements(html, replacements: [reference: (mime, base64)], maximumBytes: maximumBytes)
    }

    static func boundedImageReplacements(_ html: String, replacements: [String: (mime: String, base64: String)], maximumBytes: Int = 64 * 1024 * 1024) throws -> String {
        var bytes = html.utf8.count
        guard bytes <= maximumBytes else { throw PicoDocsError.fileCorrupted }
        var byEscapedReference: [String: (mime: String, base64: String)] = [:]
        var keyBytes = 0
        for (reference, payload) in replacements {
            try Task.checkCancellation()
            let key = try boundedEscapeHTML(reference, maximumBytes: maximumBytes - keyBytes)
            keyBytes += key.utf8.count
            byEscapedReference[key] = payload
        }
        let regex = try NSRegularExpression(pattern: #"src="([^"]*)""#)
        let source = html as NSString
        var sizes: [String: Int] = [:], failed = false
        regex.enumerateMatches(in: html, range: NSRange(location: 0, length: source.length)) { match, _, stop in
            guard let match, !failed else { return }
            let reference = source.substring(with: match.range(at: 1))
            guard let payload = byEscapedReference[reference] else { return }
            do {
                let size: Int
                if let cached = sizes[reference] { size = cached }
                else {
                    guard maximumBytes >= 13 else { throw PicoDocsError.fileCorrupted }
                    let mimeBytes = try htmlEscapedByteCount(payload.mime, maximumBytes: maximumBytes - 13)
                    let base64Bytes = try htmlEscapedByteCount(payload.base64, maximumBytes: maximumBytes - 13 - mimeBytes)
                    size = 13 + mimeBytes + base64Bytes
                    sizes[reference] = size
                }
                let growth = size - reference.utf8.count
                guard growth <= maximumBytes - bytes else { throw PicoDocsError.fileCorrupted }
                bytes += growth
            } catch { failed = true; stop.pointee = true }
        }
        try Task.checkCancellation()
        guard !failed else { throw PicoDocsError.fileCorrupted }
        var output = "", offset = 0, payloads: [String: String] = [:]
        output.reserveCapacity(bytes)
        regex.enumerateMatches(in: html, range: NSRange(location: 0, length: source.length)) { match, _, _ in
            guard let match else { return }
            let reference = source.substring(with: match.range(at: 1))
            guard let payload = byEscapedReference[reference] else { return }
            let value: String
            if let cached = payloads[reference] { value = cached }
            else {
                value = "data:" + escapeHTML(payload.mime) + ";base64," + escapeHTML(payload.base64)
                payloads[reference] = value
            }
            let range = match.range(at: 1)
            output += source.substring(with: NSRange(location: offset, length: range.location - offset)) + value
            offset = NSMaxRange(range)
        }
        try Task.checkCancellation()
        output += source.substring(from: offset)
        return output
    }

    /// The serialized destination carried by an image producer, or its source
    /// basename/title for producers that emit their filenames unchanged.
    private static func imageRefName(for section: DocumentSection) -> String? {
        let filename = section.metadata["markdownReference"] ?? (section.sourcePath as NSString?)?.lastPathComponent ?? section.title
        guard let filename, !filename.isEmpty else { return nil }
        return filename
    }

    /// Each block as HTML. Inline `[^id]` references are turned into superscript
    /// links inside `inlineHTML` (so code spans are protected and code blocks,
    /// which never reach `inlineHTML`, keep literal markers).
    private static func htmlBlocks(_ parsed: [Block], footnoteNumbers numbers: [String: Int],
                                   depth: Int = 0, budget: HTMLBudget) throws -> [String] {
        try parsed.map { block in
            switch block {
            case .heading(let level, let text):
                return "<h\(level)>\(try inlineHTML(text, footnoteNumbers: numbers, budget: budget))</h\(level)>"
            case .paragraph(let text):
                let html = try inlineHTML(text, footnoteNumbers: numbers, budget: budget).replacingOccurrences(of: "\n", with: "<br>\n")
                return "<p>\(html)</p>"
            case .code(let code):
                let escaped = try boundedEscapeHTML(restoredCodeText(code), maximumBytes: budget.remaining)
                budget.remaining -= escaped.utf8.count
                return "<pre><code>\(escaped)</code></pre>"
            case .rule:
                return "<hr>"
            case .blockquote(let lines):
                let inner = try lines.map { try inlineHTML($0, footnoteNumbers: numbers, budget: budget) }.joined(separator: "<br>\n")
                return "<blockquote>\(inner)</blockquote>"
            case .list(let list):
                let ordered = list.ordered, start = list.items.first?.number ?? 1, items = list.items
                let tag = ordered ? "ol" : "ul"
                var expected = start
                let lis = try items.map { item -> String in
                    let value = item.number.map { $0 == expected ? "" : " value=\"\($0)\"" } ?? ""
                    if let number = item.number { expected = number + 1 }
                    let (lead, nested) = listItemContent(listItemText(item), depth: depth)
                    var html = try MarkdownList.inlineText(lead, breakText: "<br>") { try inlineHTML($0, footnoteNumbers: numbers, budget: budget) }
                    if !lead.isEmpty, nested.contains(where: { if case .paragraph = $0 { return true }; return false }) { html = "<p>" + html + "</p>" }
                    if !nested.isEmpty {
                        html += "\n" + (try htmlBlocks(nested, footnoteNumbers: numbers, depth: depth + 1, budget: budget).joined(separator: "\n"))
                        if case .list? = nested.last {} else { html += "\n" }
                    }
                    return "<li\(value)>\(html)</li>"
                }
                let startAttribute = ordered && start != 1 ? " start=\"\(start)\"" : ""
                return "<\(tag)\(startAttribute)>\n\(lis.joined(separator: "\n"))\n</\(tag)>"
            case .table(let rows):
                return try renderHTMLTable(rows, footnoteNumbers: numbers, budget: budget)
            }
        }
    }

    private static func renderHTMLTable(_ rows: [[String]], footnoteNumbers: [String: Int] = [:], budget: HTMLBudget) throws -> String {
        guard let header = rows.first else { return "" }
        var out = "<table>\n<thead>\n<tr>"
        out += try header.map { "<th>\(try MarkdownTableCell.inlineText($0, breakText: "<br>") { try inlineHTML($0, footnoteNumbers: footnoteNumbers, budget: budget) })</th>" }.joined()
        out += "</tr>\n</thead>\n<tbody>\n"
        for row in rows.dropFirst() {
            out += "<tr>" + (try row.map { "<td>\(try MarkdownTableCell.inlineText($0, breakText: "<br>") { try inlineHTML($0, footnoteNumbers: footnoteNumbers, budget: budget) })</td>" }).joined() + "</tr>\n"
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
        let lines = MarkdownBlockParser.normalizedLineEndings(markdown).components(separatedBy: "\n")
        var bodyLines: [String] = []
        var notes: [(id: String, text: String)] = []
        var i = 0
        var openingFence: (character: Character, length: Int)?
        var inFence: Bool { openingFence != nil }
        var fenceList: (base: Int, content: Int)?
        var lists: [(base: Int, content: Int)] = []
        var followsBlank = false
        while i < lines.count {
            let blank = lines[i].trimmingCharacters(in: .whitespaces).isEmpty
            if inFence, let container = fenceList, !blank,
               !MarkdownBlockParser.literalListContains(lines[i], base: container.base, content: container.content, afterBlank: followsBlank) {
                openingFence = nil; fenceList = nil
            }
            if !inFence, !blank {
                while let last = lists.last, !MarkdownBlockParser.literalListContains(lines[i], base: last.base, content: last.content, afterBlank: followsBlank) { lists.removeLast() }
                if let item = MarkdownBlockParser.literalListIndent(lines, index: i) { lists.append(item) }
            }
            followsBlank = blank
            // A `[^id]: text` line inside a fenced code block is literal code, not
            // a definition — track the fence so it stays in the body.
            if let candidate = MarkdownBlockParser.fence(lines[i].trimmingCharacters(in: .whitespaces)) ?? (!inFence ? MarkdownBlockParser.listFence(lines[i]) : nil) {
                if let opening = openingFence {
                    if MarkdownBlockParser.closesFence(lines[i], opening: opening) { openingFence = nil }
                } else { openingFence = candidate }
                fenceList = inFence ? lists.last : nil
                bodyLines.append(lines[i])
                i += 1
                continue
            }
            // Allow up to 3 leading spaces before a definition (Markdown block
            // indentation); 4+ spaces is an indented code block, left in the body.
            if !inFence, let (id, first) = parseFootnoteDefinition(dropLeadingSpaces(lines[i], max: 3)) {
                // Preserve prose boundaries without splitting an enclosing list.
                let inList = lists.last.map { MarkdownBlockParser.indentWidth(lines[i]) >= $0.content } ?? false
                if inList, let container = lists.last {
                    // End inline code context inside the item without a blank line,
                    // which would change continuation indentation or split the list.
                    bodyLines.append(String(repeating: " ", count: container.content) + MarkdownLiteral.listRestartBoundary)
                } else if !bodyLines.isEmpty {
                    // A root definition ends the preceding list even when the
                    // following block has enough indentation to look like a continuation.
                    bodyLines.append(MarkdownLiteral.listRestartBoundary)
                }
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
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        return (body, notes)
    }

    /// Parses a CommonMark footnote definition line `[^id]: text`, returning the
    /// id and first-line text (nil if the line isn't a definition).
    static func parseFootnoteDefinition(_ line: String) -> (id: String, text: String)? {
        guard line.hasPrefix("[^") else { return nil }
        let idStart = line.index(line.startIndex, offsetBy: 2)
        var close = idStart
        while close < line.endIndex {
            if line[close] == "\\" {
                close = line.index(after: close)
                if close < line.endIndex { close = line.index(after: close) }
            } else if line[close] == "]" { break }
            else { close = line.index(after: close) }
        }
        guard close < line.endIndex else { return nil }
        guard idStart < close else { return nil }
        let id = decodedFootnoteID(String(line[idStart..<close]))
        let afterClose = line.index(after: close)
        guard !id.isEmpty, afterClose < line.endIndex, line[afterClose] == ":" else { return nil }
        var text = String(line[line.index(after: afterClose)...])
        if text.hasPrefix(" ") { text.removeFirst() }
        return (id, text)
    }

    /// Drops up to `max` leading spaces (used to allow Markdown's 1-3 space block
    /// indentation before a footnote definition without consuming a 4-space code indent).
    static func dropLeadingSpaces(_ line: String, max: Int) -> String {
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
    private static func footnoteNumbers(blocks: [Block], notes: [(id: String, text: String)], maximumProtectedBytes: Int = Int.max) throws -> [String: Int] {
        guard !notes.isEmpty else { return [:] }
        let noteText = Dictionary(notes.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        var numbers: [String: Int] = [:]
        var next = 1

        var pending: [String] = []   // numbered notes whose bodies still need scanning

        func register(_ id: String) {
            guard noteText[id] != nil, numbers[id] == nil else { return }
            numbers[id] = next; next += 1
            pending.append(id)        // defer scanning its body (breadth-first)
        }
        func scan(_ text: String) throws {
            // Mirror inlineHTML/stripInline: code spans and links become
            // placeholders, so a `[^id]` inside them isn't treated as a reference.
            let (afterCode, _) = extractCodeSpans(text)
            let protected = try boundedProtectEscapes(afterCode, maximumBytes: maximumProtectedBytes)
            let (afterLinks, _) = extractLinks(protected)
            var cursor = afterLinks.startIndex
            while let open = afterLinks.range(of: "[^", range: cursor..<afterLinks.endIndex) {
                guard let close = afterLinks.range(of: "]", range: open.upperBound..<afterLinks.endIndex) else { break }
                register(restoreEscapes(String(afterLinks[open.upperBound..<close.lowerBound]), html: false))
                cursor = close.upperBound
            }
        }

        func scanBlocks(_ blocks: [Block], depth: Int = 0) throws {
            for block in blocks {
                switch block {
                case .code, .rule: continue        // code blocks never render footnote refs
                case .heading(_, let text): try scan(text)
                case .paragraph(let text): try scan(text)
                case .blockquote(let lines): try lines.forEach(scan)
                case .list(let list):
                    let items = list.items
                    if depth < maxListNesting { try items.forEach { try scanBlocks(parseBlocks(listItemText($0)), depth: depth + 1) } }
                    else { try items.forEach { try scan(listItemText($0)) } }
                case .table(let rows): try rows.forEach { try $0.forEach(scan) }
                }
            }
        }
        try scanBlocks(blocks)
        // Number notes referenced only from other notes after all body references
        // (breadth-first), so visible body numbers stay in document order.
        var index = 0
        while index < pending.count {
            try scan(noteText[pending[index]] ?? "")
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
    private static func footnotesHTML(notes: [(id: String, text: String)], numbers: [String: Int], budget: HTMLBudget) throws -> String {
        let items = try referencedNotes(notes, numbers)
            .map { note -> String in
                // Escape the id for attribute context (it comes from document text).
                // Render the note body with the same numbers so a reference inside a
                // note is rendered too. No backreference link: references omit a
                // per-occurrence `id`, so there's no unique anchor to return to
                // (which keeps element ids unique under repeated references).
                let inner = try inlineHTML(note.text.replacingOccurrences(of: "\n", with: " "), footnoteNumbers: numbers, budget: budget)
                return "<li id=\"fn-\(escapeHTML(restoredCodeText(note.id)))\">\(inner)</li>"
            }
            .joined(separator: "\n")
        return items.isEmpty ? "" : "<section class=\"footnotes\">\n<hr>\n<ol>\n\(items)\n</ol>\n</section>"
    }

    // MARK: - XML

    static func renderXML(_ result: ConverterResult, maximumBytes: Int = 64 * 1024 * 1024) throws -> String {
        // Admit the entire escaped document, including attributes and wrappers,
        // before constructing any expanded text. XML uses the HTML entity map.
        var remaining = max(0, maximumBytes)
        func charge(_ text: String, escaped: Bool = false) throws {
            let bytes = escaped ? try htmlEscapedByteCount(text, maximumBytes: remaining) : text.utf8.count
            guard bytes <= remaining else { throw PicoDocsError.fileCorrupted }
            remaining -= bytes
        }
        try charge("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<document")
        for (key, value) in [("title", result.title), ("author", result.author)] {
            if let value { try charge(" " + key + "=\"\""); try charge(value, escaped: true) }
        }
        try charge(">\n")
        for section in result.sections {
            try Task.checkCancellation()
            try charge("  <section kind=\"" + section.kind.rawValue + "\"")
            if let title = section.title { try charge(" title=\"\""); try charge(title, escaped: true) }
            try charge(">\n    ")
            try charge(section.markdown, escaped: true)
            try charge("\n  </section>\n")
        }
        try charge("</document>")
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
    private static func renderCSV(_ result: ConverterResult) throws -> String {
        try preflightRenderInput(result, markdownFallbackOnly: true)
        var parts: [String] = []
        var markdown: [String] = []
        var remaining = 64 * 1024 * 1024
        var outputRemaining = 64 * 1024 * 1024
        func appendPart(_ text: String) throws {
            let separator = parts.isEmpty ? 0 : 1
            guard separator <= outputRemaining, text.utf8.count <= outputRemaining - separator else { throw PicoDocsError.fileCorrupted }
            outputRemaining -= text.utf8.count + separator
            parts.append(text)
        }
        func flush() throws {
            let rows = csvRows(fromMarkdown: markdown.joined(separator: "\n\n"))
            if !rows.isEmpty { try appendPart(rows.joined(separator: "\n")) }
            markdown.removeAll(keepingCapacity: true)
        }
        let namedSheets = result.sections.filter { $0.kind == .sheet }.count
        for section in result.sections where section.kind != .image {
            if let rawCSV = section.metadata["csv"], !rawCSV.isEmpty ||
               ([SectionKind.sheet, .table].contains(section.kind) && section.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                try flush()
                if namedSheets > 1, section.kind == .sheet, let name = section.sheetName ?? section.metadata["sheetName"] ?? section.title {
                    let separator = parts.isEmpty ? 0 : 1
                    guard separator <= outputRemaining else { throw PicoDocsError.fileCorrupted }
                    try appendPart(boundedCSVField(name, maximumBytes: outputRemaining - separator))
                }
                if !rawCSV.isEmpty { try appendPart(rawCSV) }
            } else { markdown.append(try preparedMarkdown(section, remaining: &remaining)) }
        }
        try flush()
        return parts.joined(separator: "\n")
    }

    static func boundedCSVField(_ text: String, maximumBytes: Int) throws -> String {
        var bytes = text.utf8.count
        guard bytes <= maximumBytes else { throw PicoDocsError.fileCorrupted }
        var quotes = 0, needsQuotes = false
        for scalar in text.unicodeScalars {
            if scalar == "\"" { quotes += 1 }
            if scalar == "\"" || scalar == "," || scalar == "\n" || scalar == "\r" { needsQuotes = true }
        }
        let extra = needsQuotes ? quotes + 2 : 0
        guard extra <= maximumBytes - bytes else { throw PicoDocsError.fileCorrupted }
        bytes += extra
        return csvField(text)
    }

    private static func csvRows(fromMarkdown markdown: String) -> [String] {
        var rows: [String] = []
        let lines = MarkdownBlockParser.normalizedLineEndings(markdown).components(separatedBy: "\n")
        var i = 0
        var codeFence: (character: Character, length: Int)?
        var inCodeFence: Bool { codeFence != nil }
        var fenceList: (base: Int, content: Int)?
        var lists: [(base: Int, content: Int)] = []
        var followsBlank = false
        var inNote = false
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if inCodeFence, let container = fenceList, !line.isEmpty,
               !MarkdownBlockParser.literalListContains(lines[i], base: container.base, content: container.content, afterBlank: followsBlank) {
                codeFence = nil; fenceList = nil
            }
            if !inCodeFence, !line.isEmpty {
                if inNote, !lines[i].hasPrefix("    "), !lines[i].hasPrefix("\t") { inNote = false }
                if MarkdownBlockParser.literalFootnoteDefinition(lines[i]) { inNote = true }
                while let last = lists.last, !MarkdownBlockParser.literalListContains(lines[i], base: last.base, content: last.content, afterBlank: followsBlank) { lists.removeLast() }
                if let item = MarkdownBlockParser.literalListIndent(lines, index: i) { lists.append(item) }
            }
            followsBlank = line.isEmpty
            if let candidate = MarkdownBlockParser.fence(line) ?? (!inCodeFence ? MarkdownBlockParser.listFence(lines[i]) : nil) {
                if let opening = codeFence {
                    if MarkdownBlockParser.closesFence(line, opening: opening) { codeFence = nil }
                    else { rows.append(csvField(restoredCodeText(lines[i]))) }
                } else { codeFence = candidate }
                fenceList = inCodeFence ? lists.last : nil
                i += 1
                continue
            }
            if inCodeFence {
                // Preserve fenced code verbatim as a single field, so a pipe-
                // containing code line isn't split into CSV cells.
                rows.append(csvField(restoredCodeText(lines[i])))
                i += 1
                continue
            }
            if line.isEmpty || line == MarkdownLiteral.listRestartBoundary { i += 1; continue }
            if line.hasPrefix("|") {
                // Within a run of table rows, drop only the conventional separator
                // (second row), so all-dash data rows elsewhere are preserved.
                var rowIndex = 0
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let cells = parseTableRow(lines[i])
                    if !(rowIndex == 1 && isTableSeparatorRow(cells)) {
                        rows.append(cells.map { csvField(MarkdownTableCell.inlineText($0) { stripInline($0) }) }.joined(separator: ","))
                    }
                    rowIndex += 1
                    i += 1
                }
            } else {
                var paragraph = [line]
                i += 1
                if !MarkdownBlockParser.literalBlockBoundary(lines[i - 1]).ends {
                    while i < lines.count {
                        let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                        if inNote {
                            if lines[i].hasPrefix("    ") || lines[i].hasPrefix("\t") {
                                paragraph.append(candidate); i += 1; continue
                            }
                            if candidate.isEmpty {
                                var next = i + 1
                                while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
                                if next < lines.count, lines[next].hasPrefix("    ") || lines[next].hasPrefix("\t") {
                                    paragraph += Array(repeating: "", count: next - i); i = next; continue
                                }
                            }
                        }
                        if candidate.isEmpty || MarkdownBlockParser.fence(candidate) != nil || MarkdownBlockParser.literalBlockBoundary(lines[i]).starts || MarkdownBlockParser.confirmedBareMarker(lines, index: i) != nil { break }
                        if let list = lists.last, MarkdownBlockParser.indentWidth(lines[i]) < list.base + 2 { break }
                        if inNote, !lines[i].hasPrefix("    "), !lines[i].hasPrefix("\t") { break }
                        paragraph.append(candidate)
                        i += 1
                    }
                }
                rows += stripInline(paragraph.joined(separator: "\n")).components(separatedBy: "\n").map(csvField)
            }
        }
        return rows
    }

    // MARK: - Markdown block parsing

    private typealias Block = MarkdownBlock
    private static func parseBlocks(_ markdown: String) -> [Block] { MarkdownBlockParser.parse(markdown, structureLists: false) }
    private static func parseTableRow(_ line: String) -> [String] { MarkdownBlockParser.parseTableRow(line) }
    private static func isTableSeparatorRow(_ cells: [String]) -> Bool { MarkdownBlockParser.isTableSeparatorRow(cells) }
    // MARK: - Inline rendering

    // Sentinels that bracket extracted spans; private-use scalars that won't
    // appear in document text and aren't touched by escaping or emphasis regexes.
    private static let codeOpen = "\u{E000}"
    private static let codeClose = "\u{E001}"
    private static let linkOpen = "\u{E002}"
    private static let linkClose = "\u{E003}"

    private struct InlineLink { let label: String; let url: String; let isImage: Bool; var imageSource: String? = nil }

    /// Replaces inline code spans with placeholders so the link/emphasis passes
    /// don't rewrite Markdown metacharacters inside code.
    private static func extractCodeSpans(_ text: String) -> (text: String, spans: [String]) {
        var spans: [String] = []
        let result = MarkdownTableCell.mapCodeSpans(protectInlineSentinels(text), keepDelimiters: false, code: { raw in
            var content = raw.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            if content.hasPrefix(" "), content.hasSuffix(" "), content.contains(where: { $0 != " " }) {
                content = String(content.dropFirst().dropLast())
            }
            spans.append(content)
            return "\(codeOpen)\(spans.count - 1)\(codeClose)"
        }, plain: { $0 })
        return (result, spans)
    }

    /// Replaces links/images with placeholders before escaping/emphasis so a URL
    /// (or alt text) containing emphasis characters isn't rewritten inside the
    /// generated attribute. Handles CommonMark angle-bracket destinations
    /// `(<url with spaces (and parens)>)` that WordConverter emits.
    private static func extractLinks(_ text: String) -> (text: String, links: [InlineLink]) {
        var links: [InlineLink] = []
        let destination = #"\((?:<([^>]+)>|([^)]+))\)"#
        let linkedImagePattern = #"\[!\[([^\]]*)\]"# + destination + #"\]"# + destination
        let source = text as NSString
        var afterImages = "", offset = 0
        if let linkedImage = try? NSRegularExpression(pattern: linkedImagePattern) {
            for match in linkedImage.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                afterImages += source.substring(with: NSRange(location: offset, length: match.range.location - offset))
                let image = nsSubstring(source, match.range(at: match.range(at: 2).location != NSNotFound ? 2 : 3))
                let target = nsSubstring(source, match.range(at: match.range(at: 4).location != NSNotFound ? 4 : 5))
                afterImages += "\(linkOpen)\(links.count)\(linkClose)"
                links.append(InlineLink(label: nsSubstring(source, match.range(at: 1)), url: target, isImage: false, imageSource: image))
                offset = NSMaxRange(match.range)
            }
        }
        afterImages += source.substring(from: offset)
        let pattern = "(!)?\\[([^\\]]*)\\]\\((?:<([^>]+)>|([^)]+))\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (text, []) }
        let ns = afterImages as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: afterImages, range: NSRange(location: 0, length: ns.length)) {
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
    private final class HTMLBudget { var remaining = 64 * 1024 * 1024 }

    private static func inlineHTML(_ text: String, footnoteNumbers: [String: Int] = [:], budget: HTMLBudget) throws -> String {
        _ = try inlineSentinelByteCount(text, maximumBytes: budget.remaining)
        let (afterCode, spans) = extractCodeSpans(text)
        let protected = try boundedProtectEscapes(afterCode, maximumBytes: budget.remaining)
        let (afterLinks, links) = extractLinks(protected)
        var result = applyEmphasisHTML(try boundedEscapeHTML(afterLinks, maximumBytes: budget.remaining))
        // Footnote references: `[^id]` -> a superscript link. Done here, where code
        // spans are already placeholders, so markers inside code are not touched
        // (code blocks never reach inlineHTML). The id is HTML-escaped for attribute
        // safety and references carry no `id`, so repeated references don't produce
        // duplicate element ids. The escaped id also matches the escaped body text.
        result = renderFootnoteReferences(result, numbers: footnoteNumbers, html: true)
        var linkTags: [String] = [], linkBytes = 0
        for link in links {
            var tag = "", tagBytes = 0
            let available = budget.remaining - linkBytes
            func append(_ fragment: String) throws {
                guard fragment.utf8.count <= available - tagBytes else { throw PicoDocsError.fileCorrupted }
                tagBytes += fragment.utf8.count; tag += fragment
            }
            func escaped(_ value: String) throws -> String {
                try boundedEscapeHTML(value, maximumBytes: available - tagBytes)
            }
            if let image = link.imageSource, isSafeURL(image, isImage: true) {
                let liveLink = isSafeURL(link.url, isImage: false)
                if liveLink { try append("<a href=\""); try append(escaped(link.url)); try append("\">") }
                try append("<img src=\""); try append(escaped(image)); try append("\" alt=\"")
                try append(escaped(link.label)); try append("\">")
                if liveLink { try append("</a>") }
            } else if !isSafeURL(link.url, isImage: link.isImage) {
                // A script-capable URL (`javascript:` …) would make the exported
                // page executable when displayed; keep only the visible text.
                let label = try escaped(link.label)
                try append(link.isImage ? label : applyEmphasisHTML(label))
            } else if link.isImage {
                try append("<img src=\""); try append(escaped(link.url)); try append("\" alt=\"")
                try append(escaped(link.label)); try append("\">")
            } else {
                try append("<a href=\""); try append(escaped(link.url)); try append("\">")
                try append(applyEmphasisHTML(escaped(link.label))); try append("</a>")
            }
            linkBytes += tagBytes; linkTags.append(tag)
        }
        result = try boundedInlineTokenReplacements(result, open: linkOpen, close: linkClose, replacements: linkTags, maximumBytes: budget.remaining)
        result = try boundedHTMLWhitespaceReferences(result, maximumBytes: budget.remaining)
        result = restoreEscapes(result, html: true)
        var codeTags: [String] = [], codeBytes = 0
        for span in spans {
            guard budget.remaining - codeBytes >= 13 else { throw PicoDocsError.fileCorrupted }
            let escaped = try boundedEscapeHTML(span, maximumBytes: budget.remaining - codeBytes - 13)
            let tag = "<code>\(escaped)</code>"
            codeBytes += tag.utf8.count; codeTags.append(tag)
        }
        result = try boundedInlineTokenReplacements(result, open: codeOpen, close: codeClose, replacements: codeTags, maximumBytes: budget.remaining)
        guard result.utf8.count <= budget.remaining else { throw PicoDocsError.fileCorrupted }
        budget.remaining -= result.utf8.count
        return restoreInlineSentinels(result)
    }

    /// URL schemes the HTML export emits as live links. Link and image URLs come
    /// from untrusted documents (web pages, DOCX hyperlinks, LLM output), and the
    /// HTML export is meant to be displayed, so anything that can run script —
    /// `javascript:`, `vbscript:`, `data:text/html`, … — must not become an `href`
    /// or `src`.
    private static let safeLinkSchemes: Set<String> = ["http", "https", "mailto", "tel", "ftp"]

    /// Whether `url` is safe to emit as an `href` (or, for images, a `src`):
    /// relative references and fragments (no scheme) and allowlisted schemes are;
    /// images may also use `data:image/…`. Browsers ignore ASCII whitespace and
    /// control characters inside a scheme (`java\tscript:`), so those are dropped
    /// before the scheme is read.
    static func isSafeURL(_ url: String, isImage: Bool) -> Bool {
        let compact = String(String.UnicodeScalarView(url.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F }))
        guard let colon = compact.firstIndex(of: ":") else { return true }   // relative
        let scheme = compact[..<colon]
        // A `:` after `/`, `?` or `#` belongs to a path, query or fragment, so the
        // reference is relative (`docs/a:b`, `#x:y`).
        if scheme.contains(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { return true }
        let lowered = scheme.lowercased()
        if safeLinkSchemes.contains(lowered) { return true }
        return isImage && lowered == "data" && compact.lowercased().hasPrefix("data:image/")
    }

    private static func inlineSentinelByteCount(_ text: String, maximumBytes: Int) throws -> Int {
        var bytes = text.utf8.count
        guard bytes <= maximumBytes else { throw PicoDocsError.fileCorrupted }
        for scalar in text.unicodeScalars where (0xE000...0xE003).contains(scalar.value) {
            guard bytes <= maximumBytes - 3 else { throw PicoDocsError.fileCorrupted }; bytes += 3
        }
        return bytes
    }

    private static func protectInlineSentinels(_ text: String) -> String {
        var output = ""
        for scalar in text.unicodeScalars {
            output.unicodeScalars.append(scalar)
            if (0xE000...0xE003).contains(scalar.value) { output.unicodeScalars.append(scalar) }
        }
        return output
    }

    private static func restoredCodeText(_ code: String) -> String {
        var text = restoreWhitespaceReferences(code, html: false)
        for value in [0xE008, 0xE009] {
            let scalar = String(UnicodeScalar(value)!)
            text = text.replacingOccurrences(of: scalar + scalar, with: scalar)
        }
        return text
    }

    private static func restoreInlineSentinels(_ text: String) -> String {
        var output = text
        for value in [0xE000, 0xE001, 0xE002, 0xE003, 0xE008, 0xE009] {
            let scalar = String(UnicodeScalar(value)!)
            output = output.replacingOccurrences(of: scalar + scalar, with: scalar)
        }
        return output
    }

    /// Admit the complete restored output before constructing it. Each stage
    /// scans the source twice regardless of the number of distinct spans.
    static func boundedInlineTokenReplacements(_ text: String, open: String, close: String, replacements: [String], maximumBytes: Int) throws -> String {
        // Consume doubled literal opens first. A generated token beside one
        // remains a single open, even at a three-sentinel boundary.
        let pattern = open + open + "|" + open + "([0-9]+)" + close
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        var bytes = text.utf8.count, exceeded = bytes > maximumBytes
        func replacement(for match: NSTextCheckingResult) -> (text: String, needleBytes: Int)? {
            guard match.range(at: 1).location != NSNotFound else { return nil }
            let digits = source.substring(with: match.range(at: 1))
            guard let index = Int(digits), index >= 0, index < replacements.count, String(index) == digits else { return nil }
            return (replacements[index], open.utf8.count + digits.utf8.count + close.utf8.count)
        }
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, stop in
            guard let match, let replacement = replacement(for: match), !exceeded else { return }
            let growth = replacement.text.utf8.count - replacement.needleBytes
            if growth > maximumBytes - bytes { exceeded = true; stop.pointee = true }
            else { bytes += growth }
        }
        guard !exceeded else { throw PicoDocsError.fileCorrupted }
        var output = "", offset = 0
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, _ in
            guard let match, let replacement = replacement(for: match) else { return }
            output += source.substring(with: NSRange(location: offset, length: match.range.location - offset)) + replacement.text
            offset = NSMaxRange(match.range)
        }
        return output + source.substring(from: offset)
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
        let protected = protectEscapes(afterCode)
        let (afterLinks, links) = extractLinks(protected)
        var result = applyEmphasisStrip(afterLinks)
        // Footnote references become `[N]` here (code spans already extracted, so
        // markers inside code are preserved; code blocks never reach stripInline).
        result = renderFootnoteReferences(result, numbers: footnoteNumbers, html: false)
        result = (try? boundedInlineTokenReplacements(result, open: linkOpen, close: linkClose, replacements: links.map { applyEmphasisStrip($0.label) }, maximumBytes: Int.max)) ?? result
        result = restoreWhitespaceReferences(result, html: false)
        result = restoreEscapes(result, html: false)
        result = (try? boundedInlineTokenReplacements(result, open: codeOpen, close: codeClose, replacements: spans, maximumBytes: Int.max)) ?? result
        return restoreInlineSentinels(result)
    }

    private static func applyEmphasisStrip(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "\\*\\*\\*(.+?)\\*\\*\\*", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\*(.+?)\\*", with: "$1", options: .regularExpression)
        return result
    }

    private static let whitespaceReference = try! NSRegularExpression(pattern: #"&#([0-9]{1,7});"#)
    private static let internalWhitespaceReference = try! NSRegularExpression(pattern: "\u{E008}\u{E008}|\u{E008}([0-9]{1,7})\u{E009}")
    static func boundedHTMLWhitespaceReferences(_ text: String, maximumBytes: Int = 64 * 1024 * 1024) throws -> String {
        var projected = 0, exceeded = false
        restoreWhitespaceFragments(text, html: true) { fragment in
            guard !exceeded else { return }
            let bytes = fragment.utf8.count
            if bytes > maximumBytes - projected { exceeded = true }
            else { projected += bytes }
        }
        guard !exceeded else { throw PicoDocsError.fileCorrupted }
        var output = ""
        output.reserveCapacity(projected)
        restoreWhitespaceFragments(text, html: true) { output += $0 }
        return output
    }

    private static func restoreWhitespaceReferences(_ text: String, html: Bool) -> String {
        var output = ""
        restoreWhitespaceFragments(text, html: html) { output += $0 }
        return output
    }

    private static func restoreWhitespaceFragments(_ text: String, html: Bool, emit: @escaping (String) -> Void) {
        let source = text as NSString
        var last = 0, inTag = false, inSpan = false
        func closeSpan() { if inSpan { emit("</span>"); inSpan = false } }
        internalWhitespaceReference.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, _ in
            guard let match, match.range(at: 1).location != NSNotFound, let value = UInt32(source.substring(with: match.range(at: 1))),
                  let scalar = UnicodeScalar(value), CharacterSet.whitespaces.contains(scalar) else { return }
            let preceding = source.substring(with: NSRange(location: last, length: match.range.location - last))
            if !preceding.isEmpty { closeSpan() }
            if html {
                // References in href/src/IDs are attribute data, never text spans.
                for character in preceding {
                    if character == "<" { inTag = true }
                    else if character == ">" { inTag = false }
                }
            }
            emit(preceding)
            if html {
                if inTag { closeSpan(); emit("&amp;#\(value);") }
                else {
                    if !inSpan { emit("<span style=\"white-space:pre-wrap\">"); inSpan = true }
                    emit("&#\(value);")
                }
            } else { emit(String(scalar)) }
            last = match.range.location + match.range.length
        }
        closeSpan()
        emit(source.substring(from: last))
    }

    private static func decodedFootnoteID(_ id: String) -> String {
        let protected = protectEscapes(id)
        return restoreEscapes(protected, html: false)
    }

    private static func renderFootnoteReferences(_ text: String, numbers: [String: Int], html: Bool) -> String {
        let ns = text as NSString
        let regex = try! NSRegularExpression(pattern: "\\[\\^([^\\]]+)\\]")
        let lookup = Dictionary(numbers.map { (html ? escapeHTML($0.key) : $0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        var output = "", offset = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: offset, length: match.range.location - offset))
            let protectedID = ns.substring(with: match.range(at: 1))
            let id = restoreEscapes(protectedID, html: html)
            if let number = lookup[id] {
                output += html ? "<sup class=\"footnote-ref\"><a href=\"#fn-\(protectedID)\">\(number)</a></sup>" : "[\(number)]"
            } else { output += ns.substring(with: match.range) }
            offset = NSMaxRange(match.range)
        }
        return output + ns.substring(from: offset)
    }

    private static let escapableMarkdownScalars = Set(#"\`*_{}[]<>()#+-.!|&~"#.unicodeScalars)

    static func boundedProtectEscapes(_ text: String, maximumBytes: Int = 64 * 1024 * 1024) throws -> String {
        let scalars = text.unicodeScalars
        var projected = 0, index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index], next = scalars.index(after: index)
            let bytes: Int
            if scalar == "\u{E006}" { bytes = 6; index = next }
            else if scalar == "\\", next < scalars.endIndex,
                    escapableMarkdownScalars.contains(scalars[next]) {
                bytes = 6; index = scalars.index(after: next)
            } else {
                let value = scalar.value
                bytes = value <= 0x7F ? 1 : value <= 0x7FF ? 2 : value <= 0xFFFF ? 3 : 4
                index = next
            }
            guard bytes <= maximumBytes - projected else { throw PicoDocsError.fileCorrupted }
            projected += bytes
        }
        return protectEscapes(text)
    }

    private static func protectEscapes(_ text: String) -> String {
        let scalars = text.unicodeScalars
        var output = "", index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index], next = scalars.index(after: index)
            if scalar == "\u{E006}" {
                output += "\u{E006}\u{E006}"; index = next
            } else if scalar == "\\", next < scalars.endIndex,
                      escapableMarkdownScalars.contains(scalars[next]) {
                output.unicodeScalars.append("\u{E006}")
                output.unicodeScalars.append(UnicodeScalar(0xE100 + scalars[next].value)!)
                index = scalars.index(after: next)
            } else { output.unicodeScalars.append(scalar); index = next }
        }
        return output
    }

    private static func restoreEscapes(_ text: String, html: Bool) -> String {
        let scalars = text.unicodeScalars
        var output = "", index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index], next = scalars.index(after: index)
            if scalar == "\u{E006}", next < scalars.endIndex {
                if scalars[next] == "\u{E006}" {
                    output.unicodeScalars.append(scalar); index = scalars.index(after: next); continue
                }
                if (0xE100...0xE17F).contains(scalars[next].value) {
                    let decoded = String(UnicodeScalar(scalars[next].value - 0xE100)!)
                    output += html ? escapeHTML(decoded) : decoded
                    index = scalars.index(after: next); continue
                }
            }
            output.unicodeScalars.append(scalar); index = next
        }
        return output
    }

    // MARK: - Escaping

    private static func htmlEntity(_ scalar: Unicode.Scalar) -> String? {
        switch scalar {
        case "&": return "&amp;"
        case "<": return "&lt;"
        case ">": return "&gt;"
        case "\"": return "&quot;"
        case "'": return "&#39;"
        default: return nil
        }
    }

    /// Use the same entity mapping for projection and emission, before allocating
    /// an escaped copy of document text or an embedded-image attribute.
    static func htmlEscapedByteCount(_ text: String, maximumBytes: Int) throws -> Int {
        var bytes = 0
        for scalar in text.unicodeScalars {
            let size = htmlEntity(scalar)?.utf8.count ?? (scalar.value <= 0x7F ? 1 : scalar.value <= 0x7FF ? 2 : scalar.value <= 0xFFFF ? 3 : 4)
            guard size <= maximumBytes - bytes else { throw PicoDocsError.fileCorrupted }
            bytes += size
        }
        return bytes
    }

    static func boundedEscapeHTML(_ text: String, maximumBytes: Int) throws -> String {
        _ = try htmlEscapedByteCount(text, maximumBytes: maximumBytes)
        return escapeHTML(text)
    }

    private static func boundedHTMLReplacement(_ text: String, needle: String, replacement: String, maximumBytes: Int) throws -> String {
        var bytes = text.utf8.count
        guard bytes <= maximumBytes else { throw PicoDocsError.fileCorrupted }
        let growth = replacement.utf8.count - needle.utf8.count
        var start = text.startIndex
        while let range = text.range(of: needle, options: .literal, range: start..<text.endIndex) {
            guard growth <= 0 || growth <= maximumBytes - bytes else { throw PicoDocsError.fileCorrupted }
            bytes += growth; start = range.upperBound
        }
        return text.replacingOccurrences(of: needle, with: replacement, options: .literal)
    }

    private static func escapeHTML(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            if let entity = htmlEntity(scalar) { result += entity }
            else { result.unicodeScalars.append(scalar) }
        }
        return result
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
