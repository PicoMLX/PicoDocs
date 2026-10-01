//
//  WordConverter.swift
//  PicoDocs
//
//  Converts DOCX (OOXML WordprocessingML) to Markdown: unzip with ZIPFoundation,
//  walk word/document.xml via SwiftSoup's XML parser, and map paragraph styles /
//  runs / hyperlinks / tables to Markdown. Replaces the old NSAttributedString
//  DOCX path (lossy, font-size heading guessing, and a hard throw on iOS).
//

import Foundation
import ZIPFoundation
import SwiftSoup

public struct WordConverter: DocumentConverter {

    public init() {}

    public func accepts(_ info: StreamInfo) -> Bool {
        info.detectedFormat == .docx
    }

    public func convert(_ data: Data, info: StreamInfo) async throws -> ConverterResult {
        guard let archive = Archive(data: data, accessMode: .read) else {
            throw PicoDocsError.fileCorrupted
        }
        guard let documentData = try Self.readEntry(archive, path: "word/document.xml"),
              let documentXML = Self.decodeText(documentData) else {
            throw PicoDocsError.fileCorrupted
        }

        var relationships = try Self.parseRelationships(archive)
        let document = try SwiftSoup.parse(documentXML, "", SwiftSoup.Parser.xmlParser())
        guard let body = try document.getElementsByTag("w:body").first() else {
            throw PicoDocsError.emptyDocument
        }

        // Map heading bookmarks to their canonical fragments before rendering,
        // so forward internal links survive the DOCX round trip.
        let previewNumbering = WordListNumbering(archive: archive)
        if let failure = previewNumbering.failure { throw failure }
        var headings: [Element] = [], titles: [String] = []
        let observe: (Element, String) -> Void = { heading, text in
            headings.append(heading); titles.append(MarkdownInlineParser.parse(text).plainText)
        }
        try Self.collectHeadings(in: body, relationships: relationships, numbering: previewNumbering, observe: observe)
        for (heading, slug) in zip(headings, MarkdownHeadingAnchors.slugs(titles)) {
            for bookmark in try heading.getElementsByTag("w:bookmarkStart").array() {
                let name = try bookmark.attr("w:name")
                if !name.isEmpty { relationships["#" + name] = "#" + slug }
            }
        }
        let numbering = WordListNumbering(archive: archive)
        if let failure = numbering.failure { throw failure }
        let tableBudget = TableBudget()
        let blocks = try Self.renderBlocks(in: body, relationships: relationships, numbering: numbering, tableBudget: tableBudget)
        var markdown = blocks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)

        // Footnote/endnote text lives in separate parts; append the referenced
        // ones as Markdown footnote definitions (the body carries `[^fnN]`/
        // `[^enN]` reference markers at their positions).
        //
        // NOTE: these are CommonMark footnote markers in the canonical Markdown;
        // DocumentRenderer also renders them for the HTML and plaintext exports.
        let notes = try Self.parseNotes(archive, bookmarks: relationships.filter { $0.key.hasPrefix("#") })
        let definitions = Self.referencedNoteIDs(in: body).compactMap { id in
            notes[id].map { text in
                // Indent continuation lines (from a manual w:br inside the note) so
                // a multi-line note stays one CommonMark footnote definition rather
                // than splitting into a separate top-level paragraph.
                "[^\(id)]: \(text.replacingOccurrences(of: "\n", with: "\n    "))"
            }
        }
        if !definitions.isEmpty {
            markdown += (markdown.isEmpty ? "" : "\n\n") + definitions.joined(separator: "\n")
        }

        // Extract embedded images (body + notes) as separate .image sections
        // (bytes preserved for downstream OCR/captioning, and for HTML data-URL
        // embedding); the Markdown references them inline.
        let mediaBudget = MediaBudget()
        var imageSections = try Self.extractImages(from: body, relationships: relationships, archive: archive, budget: mediaBudget)
        imageSections += try Self.extractNoteImages(archive, budget: mediaBudget)
        // De-duplicate an image referenced from both the body and a note (by
        // archive path). NOTE: image identity downstream (the inline `src` and the
        // renderer's data-URL embedding) is keyed by basename, so two *different*
        // images that share a basename would collide — only possible when a note
        // part lives in its own subfolder with its own media. The renderer detects
        // that collision and leaves the ref unresolved rather than embedding the
        // wrong image (see DocumentRenderer.embedImageDataURLs); giving each image
        // a clean, unique/path-aware name so both still render is a deferred
        // cross-cutting follow-up. Standard DOCX layouts (all media under
        // `word/media/` with unique names) are unaffected.
        var seenImagePaths = Set<String>()
        imageSections = imageSections.filter { section in
            guard let path = section.sourcePath else { return true }
            return seenImagePaths.insert(path).inserted
        }

        var sections: [DocumentSection] = []
        if !markdown.isEmpty {
            sections.append(DocumentSection(kind: .body, markdown: markdown))
        }
        sections.append(contentsOf: imageSections)
        guard !sections.isEmpty else { throw PicoDocsError.emptyDocument }
        try Task.checkCancellation()
        return ConverterResult(title: info.filename, sections: sections)
    }

    /// Collect only heading text; advance list counters from metadata without
    /// rendering ordinary paragraphs or allocating projected tables.
    static func collectHeadings(in container: Element, relationships: [String: String], numbering: WordListNumbering?, observe: @escaping (Element, String) -> Void) throws {
        func advance(_ paragraph: Element) {
            let properties = paragraph.children().first { $0.tagName().lowercased() == "w:ppr" }
            let style = try? properties?.children().first { $0.tagName().lowercased() == "w:pstyle" }?.attr("w:val")
            let numPr = properties?.children().first { $0.tagName().lowercased() == "w:numpr" }
            _ = numbering?.prefix(numPr: numPr, style: style)
        }
        func collectBoxes(_ anchor: Element) throws {
            for textBox in try anchor.getElementsByTag("w:txbxContent") where shouldRenderTextBox(textBox) && !isInsideTextBox(textBox, before: anchor) {
                try collectHeadings(in: textBox, relationships: relationships, numbering: numbering, observe: observe)
            }
        }
        var pending = Array(container.children().array().reversed())
        while let element = pending.popLast() {
            try Task.checkCancellation()
            switch element.tagName().lowercased() {
            case "w:p":
                defer { if child(of: element, named: "w:ppr").flatMap({ child(of: $0, named: "w:sectpr") }) != nil { numbering?.sectionBreak() } }
                let properties = element.children().first { $0.tagName().lowercased() == "w:ppr" }
                let style = try? properties?.children().first { $0.tagName().lowercased() == "w:pstyle" }?.attr("w:val")
                if headingLevel(forStyle: style) != nil {
                    _ = renderParagraph(element, relationships: relationships, numbering: numbering, headingObserver: observe)
                } else if style != "PicoCodeBlock" { advance(element) }
                try collectBoxes(element)
            case "w:tbl":
                for row in element.children().array() where row.tagName().lowercased() == "w:tr" {
                    for cell in row.children().array() where cell.tagName().lowercased() == "w:tc" {
                        for paragraph in try cell.getElementsByTag("w:p") where !isInsideTextBox(paragraph, before: cell) && !paragraph.parents().prefix(while: { $0 !== cell }).contains(where: { ["w:del", "w:movefrom"].contains($0.tagName().lowercased()) }) {
                            advance(paragraph)
                            try collectBoxes(paragraph)
                        }
                    }
                }
            case "w:sdt":
                if let content = element.children().first(where: { $0.tagName().lowercased() == "w:sdtcontent" }) { pending.append(contentsOf: content.children().array().reversed()) }
            case "w:customxml", "w:ins", "w:moveto", "w:smarttag":
                pending.append(contentsOf: element.children().array().reversed())
            case "w:sectpr": numbering?.sectionBreak()
            default: break
            }
        }
    }

    // MARK: - Blocks

    /// Renders the block-level children of a container (the body, or a content
    /// control's content) to Markdown blocks, recursing into `w:sdt` content
    /// controls (forms/templates wrap paragraphs and tables in them).
    static func renderBlocks(in container: Element, relationships: [String: String], numbering: WordListNumbering? = nil, headingObserver: ((Element, String) -> Void)? = nil, tableBudget: TableBudget = TableBudget()) throws -> [String] {
        var blocks: [String] = []
        var previousList: MarkdownBlockParser.ListKind?
        var rootListInstance: String?
        var pending = Array(container.children().array().reversed())
        while let element = pending.popLast() {
            try Task.checkCancellation()
            switch element.tagName().lowercased() {
            case "w:p":
                defer { if child(of: element, named: "w:ppr").flatMap({ child(of: $0, named: "w:sectpr") }) != nil { numbering?.sectionBreak() } }
                if let markdown = renderParagraph(element, relationships: relationships, numbering: numbering, headingObserver: headingObserver), !markdown.isEmpty {
                    let marker = MarkdownBlockParser.listMarker(markdown.trimmingCharacters(in: .whitespaces))
                    let continuation = numbering?.lastParagraphIsContinuation == true
                    let identity = marker == nil && !continuation ? nil : numbering?.lastParagraphList
                    let exportedItem = child(of: element, named: "w:ppr").flatMap { child(of: $0, named: "w:pstyle") }.flatMap { try? $0.attr("w:val") } == "PicoListItem"
                    let joins = (exportedItem || continuation) && (identity.map { continuation ? ($0.instance == rootListInstance || numbering?.lastParagraphIsExportedContinuation == true) : ($0.level > 0 || $0.instance == rootListInstance) } ?? (marker != nil && marker == previousList))
                    if joins, previousList != nil, !blocks.isEmpty {
                        blocks[blocks.count - 1] += (continuation ? "\n\n" : "\n") + markdown
                    } else { blocks.append(markdown) }
                    if !continuation { previousList = marker }
                    if !continuation, let identity, identity.level == 0 { rootListInstance = identity.instance }
                    if marker == nil && !continuation { rootListInstance = nil }
                }
                blocks += try extractTextBoxes(from: element, relationships: relationships, numbering: numbering, tableBudget: tableBudget)
            case "w:sectpr":
                numbering?.sectionBreak()
            case "w:tbl":
                previousList = nil
                var boxes: [String] = []
                let table = try renderTable(element, relationships: relationships, numbering: numbering, budget: tableBudget) { paragraph in
                    boxes += try extractTextBoxes(from: paragraph, relationships: relationships, numbering: numbering, tableBudget: tableBudget)
                }
                if !table.isEmpty { blocks.append(table) }
                blocks += boxes
            case "w:sdt":
                if let content = element.children().first(where: { $0.tagName().lowercased() == "w:sdtcontent" }) {
                    pending.append(contentsOf: content.children().array().reversed())
                }
            case "w:customxml", "w:ins", "w:moveto", "w:smarttag":
                pending.append(contentsOf: element.children().array().reversed())
            default:
                continue
            }
        }
        return blocks
    }

    /// Extracts the text of text boxes (shapes with text), whose content is stored
    /// in `w:txbxContent` outside the normal block flow, rendered as Markdown
    /// blocks. Honors markup-compatibility (`mc:AlternateContent`) semantics by
    /// rendering only one branch per AlternateContent, so a text box isn't
    /// duplicated across `mc:Choice`/`mc:Fallback` (or multiple choices).
    static func extractTextBoxes(from body: Element, relationships: [String: String], numbering: WordListNumbering? = nil, tableBudget: TableBudget = TableBudget()) throws -> [String] {
        var blocks: [String] = []
        // Iterate the Elements sequence directly (no intermediate array copy).
        guard let textBoxes = try? body.getElementsByTag("w:txbxContent") else { return blocks }
        for txbx in textBoxes {
            if !shouldRenderTextBox(txbx) || isInsideTextBox(txbx, before: body) { continue }
            blocks.append(contentsOf: try renderBlocks(in: txbx, relationships: relationships, numbering: numbering, tableBudget: tableBudget))
        }
        return blocks
    }

    /// The nearest ancestor element with the given (lowercased) tag name.
    private static func ancestor(of element: Element, named tag: String) -> Element? {
        element.parents().first { $0.tagName().lowercased() == tag }
    }

    /// True when `paragraph` is inside a `w:txbxContent` that is nested *within*
    /// `boundary` (a table cell) — i.e. a text box inside the cell, whose content
    /// is emitted separately by extractTextBoxes. Walking up from the paragraph,
    /// a `w:txbxContent` found before reaching `boundary` is such a nested text
    /// box; reaching `boundary` first means any text box is an ancestor of the
    /// cell (a table inside a text box), so the cell's own paragraphs still render.
    private static func isInsideTextBox(_ paragraph: Element, before boundary: Element) -> Bool {
        for ancestor in paragraph.parents() {
            if ancestor === boundary { return false }
            if ancestor.tagName().lowercased() == "w:txbxcontent" { return true }
        }
        return false
    }

    /// Whether a `w:txbxContent` should be rendered, honoring markup-compatibility
    /// (`mc:AlternateContent`) semantics: one branch is chosen per AlternateContent
    /// — the first `mc:Choice` containing a text box, else the `mc:Fallback` — and
    /// only text boxes inside the chosen branch render. A text box outside any
    /// AlternateContent always renders. Every enclosing AlternateContent must
    /// select this text box's branch, so nested cases are handled too.
    private static func shouldRenderTextBox(_ txbx: Element) -> Bool {
        var inner = txbx
        while let alternate = ancestor(of: inner, named: "mc:alternatecontent") {
            guard let branch = selectedBranch(of: alternate),
                  txbx.parents().contains(where: { $0 === branch }) else { return false }
            inner = alternate
        }
        return true
    }

    /// The single `mc:AlternateContent` branch whose text boxes are rendered: the
    /// first `mc:Choice` containing a `w:txbxContent`, otherwise the `mc:Fallback`.
    private static func selectedBranch(of alternate: Element) -> Element? {
        if let choice = alternate.children().first(where: {
            $0.tagName().lowercased() == "mc:choice" && containsTextBox($0)
        }) {
            return choice
        }
        return alternate.children().first {
            $0.tagName().lowercased() == "mc:fallback" && containsTextBox($0)
        }
    }

    private static func containsTextBox(_ element: Element) -> Bool {
        !((try? element.getElementsByTag("w:txbxContent").array()) ?? []).isEmpty
    }

    // MARK: - Paragraphs

    static func renderParagraph(_ paragraph: Element, relationships: [String: String], numbering: WordListNumbering? = nil, headingObserver: ((Element, String) -> Void)? = nil) -> String? {
        let properties = paragraph.children().first { $0.tagName().lowercased() == "w:ppr" }
        let style = try? properties?.children().first { $0.tagName().lowercased() == "w:pstyle" }?.attr("w:val")
        if style == "PicoCodeBlock" {
            let code = codeText(paragraph)
            let fence = String(repeating: "`", count: max(3, (code.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0) + 1))
            return fence + "\n" + code + "\n" + fence
        }
        let numPr = properties?.children().first { $0.tagName().lowercased() == "w:numpr" }
        let heading = numbering?.headingLevel(style: style, paragraphProperties: properties) ?? headingLevel(forStyle: style)
        let prefix = numbering.map { $0.prefix(numPr: numPr, style: style, visibleMarker: heading == nil, paragraphProperties: properties) ?? (numPr?.children().size() == 0 ? "- " : nil) } ?? (numPr != nil ? "- " : nil)
        let boundary = numbering?.listRestartIndent.map { String(repeating: " ", count: $0) + MarkdownLiteral.listRestartBoundary + "\n\n" } ?? ""
        let text = escapeBlockStarts(renderInline(paragraph, relationships: relationships).trimmingCharacters(in: .whitespaces))
        guard !text.isEmpty else {
            if let borders = properties?.children().first(where: { $0.tagName().lowercased() == "w:pbdr" }),
               let bottom = borders.children().first(where: { $0.tagName().lowercased() == "w:bottom" }),
               let value = try? bottom.attr("w:val"), !value.isEmpty, !["nil", "none"].contains(value) { return "---" }
            return heading == nil ? prefix.map { boundary + $0 } : nil
        }

        if let level = heading {
            let title = text
            headingObserver?(paragraph, title)
            return String(repeating: "#", count: level) + " " + title
        }
        if style?.lowercased() == "quote" {
            return text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        }
        if let prefix {
            // Every hard-break line belongs at the item's content column. This
            // also handles markerless continuation paragraphs and nested lists.
            let continuationIndent = String(repeating: " ", count: WordListNumbering.displayWidth(prefix))
            return boundary + prefix + text.replacingOccurrences(of: "\n", with: "\n" + continuationIndent)
        }
        return text
    }

    static func headingLevel(forStyle style: String?) -> Int? {
        guard let style = style?.lowercased() else { return nil }
        if style == "title" { return 1 }
        if style.hasPrefix("heading") {
            // Tolerate "heading1", "heading 1", "heading-1", etc. (filter returns
            // [Character], so wrap in String before Int(_:)).
            let digits = String(style.dropFirst("heading".count).filter { $0.isNumber })
            if let n = Int(digits) { return min(max(n, 1), 6) }
        }
        return nil
    }

    // MARK: - Inline content (runs, hyperlinks)

    static func renderInline(_ container: Element, relationships: [String: String], hardBreak: String = "  \n") -> String {
        var out = ""
        for child in container.children().array() {
            switch child.tagName().lowercased() {
            case "w:ppr":
                continue // paragraph properties, not content
            case "w:r":
                out += renderRun(child, relationships: relationships, hardBreak: hardBreak)
            case "w:hyperlink":
                let inner = renderInline(child, relationships: relationships, hardBreak: hardBreak)
                let relId = (try? child.attr("r:id")) ?? ""
                let anchor = (try? child.attr("w:anchor")) ?? ""
                let target = relationships[relId] ?? (anchor.isEmpty ? nil : (relationships["#" + anchor] ?? "#" + anchor))
                if let url = target, !url.isEmpty, !inner.isEmpty {
                    if isImageOnlyMarkdown(inner) {
                        // Hyperlink wrapping an image: keep the image. A nested
                        // linked image ([![alt](src)](url)) isn't round-trippable
                        // through the renderers, so we drop the outer link rather
                        // than emit syntax they can't parse.
                        out += inner
                    } else {
                        // Mixed image+text hyperlink content is escaped as a text
                        // label, so an embedded image in such a link renders as
                        // literal text (its bytes are still extracted as an .image
                        // section). Preserving image fragments inside a mixed linked
                        // label needs a structured inline representation (a run-level
                        // "contains image" signal) — a deliberately deferred
                        // enhancement for this narrow icon+label case.
                        out += "[\(escapeCanonicalLabel(inner))](\(escapeLinkDestination(url)))"
                    }
                } else {
                    out += inner
                }
            default:
                // smartTag / ins / proofErr / other wrappers: recurse for nested runs.
                out += renderInline(child, relationships: relationships, hardBreak: hardBreak)
            }
        }
        return out
    }

    static func renderRun(_ run: Element, relationships: [String: String], hardBreak: String = "  \n") -> String {
        let properties = child(of: run, named: "w:rpr")
        let bold = isFormattingEnabled(properties, tag: "w:b")
        let italic = isFormattingEnabled(properties, tag: "w:i")
        if (try? properties?.getElementsByTag("w:rStyle").first()?.attr("w:val")) == "PicoFootnoteMarker" {
            let marker = codeText(run)
            let parsed = MarkdownInlineParser.parse(marker)
            if parsed.count == 1, case .footnoteReference = parsed[0] { return marker }
        }
        if (try? properties?.getElementsByTag("w:rStyle").first()?.attr("w:val")) == "PicoCode" {
            let code = codeText(run)
            guard !code.isEmpty else { return "" }
            let delimiter = String(repeating: "`", count: max(1, (code.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0) + 1))
            let pad = code.hasPrefix("`") || code.hasSuffix("`") || (code.hasPrefix(" ") && code.hasSuffix(" ") && code.contains(where: { $0 != " " })) ? " " : ""
            var fragment = delimiter + pad + code + pad + delimiter
            if bold { fragment = "**\(fragment)**" }
            if italic { fragment = "*\(fragment)*" }
            return fragment
        }

        var out = ""
        var textBuffer = ""
        // Emit accumulated text (with the run's emphasis) before the next image,
        // so images keep their position in runs that interleave text and drawings.
        func flushText() {
            guard !textBuffer.isEmpty else { return }
            var fragment = textBuffer
            if bold { fragment = "**\(fragment)**" }
            if italic { fragment = "*\(fragment)*" }
            out += fragment
            textBuffer = ""
        }

        for node in run.children().array() {
            switch node.tagName().lowercased() {
            case "w:t":
                // Read raw text nodes to preserve significant whitespace
                // (w:t may carry xml:space="preserve").
                for child in node.getChildNodes() {
                    if let textNode = child as? TextNode { textBuffer += escapeLiteralText(textNode.getWholeText()) }
                }
            case "w:tab":
                textBuffer += "\t"
            case "w:br", "w:cr":
                textBuffer += hardBreak
            case "w:drawing", "w:pict":
                flushText()
                out += imageMarkdown(in: node, relationships: relationships)   // not wrapped in emphasis
            case "w:footnotereference":
                if let id = try? node.attr("w:id"), !id.isEmpty { textBuffer += "[^fn\(id)]" }
            case "w:endnotereference":
                if let id = try? node.attr("w:id"), !id.isEmpty { textBuffer += "[^en\(id)]" }
            default:
                // Text-box content (w:txbxContent) is intentionally NOT rendered
                // here — it's extracted once by extractTextBoxes (a separate pass),
                // so rendering it inline too would double-count nested text boxes.
                continue
            }
        }
        flushText()
        return out
    }

    private static func codeText(_ element: Element) -> String {
        var text = ""
        for child in element.children().array() {
            switch child.tagName().lowercased() {
            case "w:t": text += child.getChildNodes().compactMap { ($0 as? TextNode)?.getWholeText() }.joined()
            case "w:br", "w:cr": text += "\n"
            case "w:tab": text += "\t"
            case "w:rpr", "w:ppr": continue
            default: text += codeText(child)
            }
        }
        return text
    }

    /// True when a run-property toggle (`w:b`/`w:i`) is present and not explicitly
    /// disabled (`w:val="false"/"0"/"none"`, used to override style hierarchies).
    private static func isFormattingEnabled(_ properties: Element?, tag: String) -> Bool {
        guard let element = try? properties?.getElementsByTag(tag).first() else { return false }
        if let val = try? element.attr("w:val"), !val.isEmpty {
            return val != "false" && val != "0" && val != "none"
        }
        return true
    }

    private static func escapeBlockStarts(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            let body = String(line.dropFirst(leading.count))
            if let first = body.first, "#+-~|".contains(first) {
                return String(leading) + "\\" + body
            }
            let digits = body.prefix { $0.isASCII && $0.isNumber }
            if !digits.isEmpty, body.dropFirst(digits.count).hasPrefix(".") {
                return String(leading) + digits + "\\" + body.dropFirst(digits.count)
            }
            return line
        }.joined(separator: "\n")
    }

    private static func escapeLiteralText(_ text: String) -> String {
        MarkdownLiteral.escapePunctuation(text, characters: #"\`*_{}[]<>"#)
    }

    private static func escapeCanonicalLabel(_ text: String) -> String {
        // Code content is literal: label escapes belong only to the surrounding Markdown.
        MarkdownTableCell.mapCodeSpans(text, code: { $0 }) { plain in
            var output = "", escaped = false
            for scalar in plain.unicodeScalars {
                if !escaped, scalar == "[" || scalar == "]" { output.append("\\") }
                output.unicodeScalars.append(scalar)
                if escaped { escaped = false } else { escaped = scalar == "\\" }
            }
            return output
        }
    }

    private static func escapeLinkLabel(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    /// Whether `text` is exactly a single Markdown image (produced by an image
    /// run), so a wrapping hyperlink shouldn't escape its brackets. Deliberately
    /// strict (prefix `![` and suffix `)`) so a plain link whose visible text
    /// merely contains `![` is still escaped normally.
    private static func isImageOnlyMarkdown(_ text: String) -> Bool {
        text.hasPrefix("![") && text.hasSuffix(")")
    }

    private static func escapeLinkDestination(_ url: String) -> String {
        let url = url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E")
        // Spaces / parens break inline link destinations; wrap in <> (a valid
        // CommonMark destination form) when present.
        if url.contains(" ") || url.contains("(") || url.contains(")") {
            return "<\(url)>"
        }
        return url
    }

    // Local image identities must decode back to their carrier path. URI percent
    // encoding belongs to hyperlinks; canonical Markdown escapes preserve names.
    private static func escapeImageDestination(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "<", with: "\\<").replacingOccurrences(of: ">", with: "\\>")
        if path.contains(where: \.isWhitespace) || path.contains("(") || path.contains(")") || path.contains("<") || path.contains(">") {
            return "<\(escaped)>"
        }
        return escaped
    }

    // MARK: - Tables

    final class TableBudget {
        private var remainingCells: Int
        private var remainingBytes: Int
        init(maximumCells: Int = 1_000_000, maximumBytes: Int = 64 * 1024 * 1024) {
            remainingCells = maximumCells; remainingBytes = maximumBytes
        }
        func reserve(rows: Int, columns: Int) throws {
            guard rows >= 0, columns > 0, rows <= remainingCells / columns else { throw PicoDocsError.fileCorrupted }
            let cells = rows * columns
            let bytes = cells * 40 + rows * 32 + columns * 8
            guard bytes <= remainingBytes else { throw PicoDocsError.fileCorrupted }
            remainingCells -= cells; remainingBytes -= bytes
        }
        func reserveText(_ text: String) throws {
            guard text.utf8.count < remainingBytes / 8 else { throw PicoDocsError.fileCorrupted }
            remainingBytes -= (text.utf8.count + 1) * 8
        }
    }

    static func renderTable(_ table: Element, relationships: [String: String], numbering: WordListNumbering? = nil, budget: TableBudget = TableBudget(), textBoxes: ((Element) throws -> Void)? = nil) throws -> String {
        // Reserve the padded grid across the whole conversion before allocating
        // any span placeholders or serialized Markdown for this table.
        var rowCount = 0, columnCount = 0
        for row in table.children().array() where row.tagName().lowercased() == "w:tr" {
            var columns = 0
            for cell in row.children().array() where cell.tagName().lowercased() == "w:tc" {
                let span = try gridSpan(of: cell)
                guard columns <= 16_384 - span else { throw PicoDocsError.fileCorrupted }
                columns += span
            }
            if columns > 0 { rowCount += 1; columnCount = max(columnCount, columns) }
        }
        guard columnCount > 0 else { return "" }
        try budget.reserve(rows: rowCount, columns: columnCount)
        var rows: [[String]] = []
        var widestRow = 0
        for tr in table.children().array() where tr.tagName().lowercased() == "w:tr" {
            var cells: [String] = []
            for tc in tr.children().array() where tc.tagName().lowercased() == "w:tc" {
                let span = try gridSpan(of: tc)
                guard cells.count <= 16_384 - span else { throw PicoDocsError.fileCorrupted }
                widestRow = max(widestRow, cells.count + span)
                guard rows.count < 1_000_000 / widestRow else { throw PicoDocsError.fileCorrupted }
                var cellText = ""
                // Gather all descendant paragraphs so paragraphs inside block
                // content controls (w:sdt) within the cell are included too. Skip
                // paragraphs belonging to a text box nested in this cell — those are
                // emitted once by extractTextBoxes, so rendering them here too would
                // duplicate them. (A table inside a text box is not skipped, so its
                // own cells still render — see isInsideTextBox.)
                for paragraph in (try? tc.getElementsByTag("w:p").array()) ?? [] {
                    if isInsideTextBox(paragraph, before: tc) || paragraph.parents().prefix(while: { $0 !== tc }).contains(where: { ["w:del", "w:movefrom"].contains($0.tagName().lowercased()) }) { continue }
                    let properties = paragraph.children().first { $0.tagName().lowercased() == "w:ppr" }
                    let numPr = properties?.children().first { $0.tagName().lowercased() == "w:numpr" }
                    let style = try? properties?.children().first { $0.tagName().lowercased() == "w:pstyle" }?.attr("w:val")
                    let prefix = numbering?.prefix(numPr: numPr, style: style, visibleMarker: false, paragraphProperties: properties)
                    let t = (style == "PicoListItem" ? (prefix ?? "") : "") + renderInline(paragraph, relationships: relationships, hardBreak: "\n").trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty {
                        try budget.reserveText(t)
                        cellText += (cellText.isEmpty ? "" : "\n") + t
                    }
                    try textBoxes?(paragraph)
                }
                // Single-line Markdown cells: escape delimiters; CR/LF become <br>.
                cells.append(MarkdownTableCell.escapeCanonicalDelimiters(cellText)
                    .replacingOccurrences(of: "\r\n", with: "<br>")
                    .replacingOccurrences(of: "\r", with: "<br>")
                    .replacingOccurrences(of: "\n", with: "<br>"))
                // Honor horizontally merged cells (w:gridSpan) so later columns
                // stay aligned, by emitting empty placeholders for the span.
                if span > 1 {
                    cells.append(contentsOf: Array(repeating: "", count: span - 1))
                }
            }
            if !cells.isEmpty { rows.append(cells) }
        }
        guard !rows.isEmpty else { return "" }

        let columns = rows.map(\.count).max() ?? 0
        func pad(_ row: [String]) -> [String] { row + Array(repeating: "", count: max(0, columns - row.count)) }
        var md = "| " + pad(rows[0]).joined(separator: " | ") + " |\n"
        md += "| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |"
        for row in rows.dropFirst() {
            md += "\n| " + pad(row).joined(separator: " | ") + " |"
        }
        return md
    }

    /// Number of grid columns a table cell spans (`w:gridSpan`); 1 if absent.
    private static func gridSpan(of cell: Element) throws -> Int {
        guard let properties = cell.children().first(where: { $0.tagName().lowercased() == "w:tcpr" }),
              let element = properties.children().first(where: { $0.tagName().lowercased() == "w:gridspan" }) else { return 1 }
        guard let span = Int(try element.attr("w:val")), (1...16_384).contains(span) else { throw PicoDocsError.fileCorrupted }
        return span
    }

    /// The first direct child of `element` with the given (lowercased) tag name.
    private static func child(of element: Element, named tag: String) -> Element? {
        element.children().first { $0.tagName().lowercased() == tag }
    }

    // MARK: - Relationships (hyperlink targets)

    static func parseRelationships(_ archive: Archive, path: String = "word/_rels/document.xml.rels") throws -> [String: String] {
        guard let data = try readEntry(archive, path: path),
              let xml = decodeText(data),
              let doc = try? SwiftSoup.parse(xml, "", SwiftSoup.Parser.xmlParser()) else {
            return [:]
        }
        var map: [String: String] = [:]
        for rel in (try? doc.getElementsByTag("Relationship").array()) ?? [] {
            guard let id = try? rel.attr("Id"), let target = try? rel.attr("Target"),
                  !id.isEmpty, !target.isEmpty else { continue }
            let isImage = ((try? rel.attr("Type")) ?? "").hasSuffix("/image")
            let directory = ((path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            // Image entries carry decoded package-absolute paths; consumers must
            // not percent-decode these a second time. Hyperlinks retain their URI.
            map[id] = isImage ? "/" + resolvePartPath(target, relativeTo: directory) : target
        }
        return map
    }

    // MARK: - Footnotes / endnotes

    /// Parses footnote and endnote text (stored in separate parts) into a map
    /// keyed by reference id (`fn<id>` / `en<id>`), skipping the auto separator
    /// and continuation notes.
    static func parseNotes(_ archive: Archive, bookmarks: [String: String] = [:]) throws -> [String: String] {
        var notes: [String: String] = [:]
        // Resolve each note part from its document relationship Target (falling
        // back to the standard name), then render it against that part's own
        // relationships so inline hyperlinks/images inside notes resolve correctly.
        for (typeSuffix, fallback, tag, prefix) in [
            ("/footnotes", "word/footnotes.xml", "w:footnote", "fn"),
            ("/endnotes", "word/endnotes.xml", "w:endnote", "en"),
        ] {
            let part = try relationshipTarget(archive, typeSuffix: typeSuffix).map { resolvePartPath($0, relativeTo: "word") } ?? fallback
            let relationships = try parseRelationships(archive, path: relationshipsPath(forPart: part)).merging(bookmarks) { _, canonical in canonical }
            for (key, value) in try parseNotePart(archive, path: part, tag: tag, prefix: prefix, relationships: relationships) {
                notes[key] = value
            }
        }
        return notes
    }

    /// The Target of the first `document.xml.rels` relationship whose Type ends
    /// with `typeSuffix` (e.g. "/footnotes"); relative to `word/`.
    static func relationshipTarget(_ archive: Archive, typeSuffix: String) throws -> String? {
        guard let data = try readEntry(archive, path: "word/_rels/document.xml.rels"),
              let xml = decodeText(data),
              let doc = try? SwiftSoup.parse(xml, "", SwiftSoup.Parser.xmlParser()) else {
            return nil
        }
        for rel in (try? doc.getElementsByTag("Relationship").array()) ?? [] {
            guard let type = try? rel.attr("Type"), type.hasSuffix(typeSuffix),
                  let target = try? rel.attr("Target"), !target.isEmpty else { continue }
            return target
        }
        return nil
    }

    /// The `_rels` path for a part (e.g. "word/footnotes.xml" -> "word/_rels/footnotes.xml.rels").
    private static func relationshipsPath(forPart part: String) -> String {
        let directory = (part as NSString).deletingLastPathComponent
        let file = (part as NSString).lastPathComponent
        return directory.isEmpty ? "_rels/\(file).rels" : "\(directory)/_rels/\(file).rels"
    }

    /// Note types that are structural auto-separators, not real referenced notes.
    private static let separatorNoteTypes: Set<String> = [
        "separator", "continuationSeparator", "continuationNotice",
    ]

    private static func parseNotePart(_ archive: Archive, path: String, tag: String, prefix: String, relationships: [String: String]) throws -> [String: String] {
        guard let data = try readEntry(archive, path: path),
              let xml = decodeText(data),
              let doc = try? SwiftSoup.parse(xml, "", SwiftSoup.Parser.xmlParser()) else {
            return [:]
        }
        // Each note part has independent counters from the body and other stories.
        let numbering = WordListNumbering(archive: archive)
        if let failure = numbering.failure { throw failure }
        var notes: [String: String] = [:]
        for note in (try? doc.getElementsByTag(tag).array()) ?? [] {
            guard let id = try? note.attr("w:id"), !id.isEmpty else { continue }
            // Skip only the auto separator/continuation notes; keep ordinary
            // referenced notes even when explicitly typed "normal".
            if let type = try? note.attr("w:type"), separatorNoteTypes.contains(type) { continue }
            let text = try renderBlocks(in: note, relationships: relationships, numbering: numbering)
                .joined(separator: "\n\n")
            guard !text.isEmpty else { continue }
            notes["\(prefix)\(id)"] = text
        }
        return notes
    }

    /// Reference ids (`fn<id>`/`en<id>`) found in the body, de-duplicated —
    /// footnotes then endnotes, the order their definitions are appended.
    static func referencedNoteIDs(in body: Element) -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        func collect(tag: String, prefix: String) {
            for ref in (try? body.getElementsByTag(tag).array()) ?? [] {
                guard let id = try? ref.attr("w:id"), !id.isEmpty else { continue }
                let key = "\(prefix)\(id)"
                if seen.insert(key).inserted { ids.append(key) }
            }
        }
        collect(tag: "w:footnoteReference", prefix: "fn")
        collect(tag: "w:endnoteReference", prefix: "en")
        return ids
    }

    /// Extracts embedded images from the footnote/endnote parts as `.image`
    /// sections, using each part's own relationships — so an image inside a note
    /// is preserved/embeddable like a body image (notes reference it inline).
    static func extractNoteImages(_ archive: Archive, budget: MediaBudget = MediaBudget()) throws -> [DocumentSection] {
        var sections: [DocumentSection] = []
        for (typeSuffix, fallback, rootTag) in [
            ("/footnotes", "word/footnotes.xml", "w:footnotes"),
            ("/endnotes", "word/endnotes.xml", "w:endnotes"),
        ] {
            let part = try relationshipTarget(archive, typeSuffix: typeSuffix).map { resolvePartPath($0, relativeTo: "word") } ?? fallback
            guard let data = try readEntry(archive, path: part),
                  let xml = decodeText(data),
                  let doc = try? SwiftSoup.parse(xml, "", SwiftSoup.Parser.xmlParser()),
                  let root = try? doc.getElementsByTag(rootTag).first() else { continue }
            let relationships = try parseRelationships(archive, path: relationshipsPath(forPart: part))
            // A note part's image targets resolve relative to the note part's own
            // folder (usually `word`, but a subfolder when the part lives in one).
            let partDirectory = (part as NSString).deletingLastPathComponent
            sections.append(contentsOf: try extractImages(from: root, relationships: relationships, archive: archive, partDirectory: partDirectory, budget: budget))
        }
        return sections
    }

    // MARK: - Images

    /// Inline Markdown image reference for a `w:drawing`/`w:pict`, using the
    /// drawing's alt text (`descr`/`name`) and the embedded media's filename.
    ///
    /// The reference is emitted from the relationship target even if the media
    /// bytes are later found unreadable (`extractImages` then omits the bytes):
    /// a document whose text parses shouldn't fail — or lose the image's alt
    /// text — over one missing media part. Deliberate graceful degradation, not
    /// strict failure.
    static func imageMarkdown(in drawing: Element, relationships: [String: String]) -> String {
        guard let target = imageTarget(in: drawing, relationships: relationships) else { return "" }
        let path = target.hasPrefix("/") ? String(target.dropFirst()) : resolvePartPath(target, relativeTo: "word")
        return "![\(escapeLiteralText(imageAltText(in: drawing)))](\(escapeImageDestination(path)))"
    }

    /// The relationship Target (e.g. "media/image1.png") an image references via
    /// `a:blip/@r:embed` (DrawingML) or `v:imagedata/@r:id` (legacy VML).
    private static func imageTarget(in drawing: Element, relationships: [String: String]) -> String? {
        var relId = (try? drawing.getElementsByTag("a:blip").first()?.attr("r:embed")) ?? ""
        if relId.isEmpty { relId = (try? drawing.getElementsByTag("v:imagedata").first()?.attr("r:id")) ?? "" }
        guard !relId.isEmpty, let target = relationships[relId], !target.isEmpty else { return nil }
        return target
    }

    /// Alt text for an image: `descr` then `name` (from `wp:docPr`, then
    /// `pic:cNvPr`); falls back to "image".
    private static func imageAltText(in drawing: Element) -> String {
        for tag in ["wp:docPr", "pic:cNvPr"] {
            guard let element = try? drawing.getElementsByTag(tag).first() else { continue }
            if let descr = try? element.attr("descr"), !descr.isEmpty { return descr }
            if let name = try? element.attr("name"), !name.isEmpty { return name }
        }
        return "image"
    }

    /// One budget covers body, footnotes, and endnotes before base64 retention.
    final class MediaBudget {
        var remainingBytes: Int
        var remainingImages: Int
        var seen: Set<String> = []
        init(maxBytes: Int = 64 * 1024 * 1024, maxImages: Int = 1024) {
            remainingBytes = max(0, maxBytes); remainingImages = max(0, maxImages)
        }
    }

    /// Extracts each embedded image once as an `.image` section carrying the raw
    /// bytes (base64) and MIME type, so consumers can render or caption them.
    static func extractImages(from body: Element, relationships: [String: String], archive: Archive, partDirectory: String = "word", budget: MediaBudget = MediaBudget()) throws -> [DocumentSection] {
        let blips = (try? body.getElementsByTag("a:blip").array()) ?? []
        let vmlImages = (try? body.getElementsByTag("v:imagedata").array()) ?? []

        var sections: [DocumentSection] = []
        for element in blips + vmlImages {
            var relId = (try? element.attr("r:embed")) ?? ""
            if relId.isEmpty { relId = (try? element.attr("r:id")) ?? "" }
            guard !relId.isEmpty, let target = relationships[relId], !target.isEmpty else { continue }

            // parseRelationships already decoded package-absolute image paths.
            let mediaPath = target.hasPrefix("/") ? String(target.dropFirst()) : resolvePartPath(target, relativeTo: partDirectory)
            guard budget.seen.insert(mediaPath).inserted else { continue }
            try Task.checkCancellation()
            guard let entry = archive[mediaPath] else { continue }
            guard budget.remainingImages > 0, entry.uncompressedSize <= UInt64(budget.remainingBytes) else { continue }

            guard let bytes = try readEntry(archive, path: mediaPath, maxBytes: min(32 * 1024 * 1024, budget.remainingBytes)), !bytes.isEmpty else { continue }
            budget.remainingBytes -= bytes.count
            budget.remainingImages -= 1
            let filename = (mediaPath as NSString).lastPathComponent
            sections.append(DocumentSection(
                title: filename,
                kind: .image,
                markdown: "![\(filename)](\(filename))",
                sourcePath: mediaPath,
                metadata: [
                    "mimeType": mimeType(forExtension: (filename as NSString).pathExtension),
                    "base64": bytes.base64EncodedString(),
                ]
            ))
        }
        return sections
    }

    /// Resolves a relationship Target to its path inside the archive — used for
    /// image media and note parts. A leading "/" is package-absolute; otherwise
    /// the Target is relative to `baseDirectory`, the folder of the part whose
    /// `.rels` it came from (e.g. `word` for `word/document.xml`, or `word/notes`
    /// for a notes part stored in a subfolder). Normalizes segment-by-segment
    /// (single pass), so `.`/`..` are collapsed without any risk of looping.
    static func resolvePartPath(_ target: String, relativeTo baseDirectory: String) -> String {
        // Relationship targets are package URIs, while ZIP entries use decoded names.
        let target = target.removingPercentEncoding ?? target
        let combined: String
        if target.hasPrefix("/") {
            combined = String(target.dropFirst())
        } else if baseDirectory.isEmpty {
            combined = target
        } else {
            combined = "\(baseDirectory)/\(target)"
        }
        var stack: [String] = []
        for raw in combined.split(separator: "/", omittingEmptySubsequences: true) {
            let segment = String(raw)
            if segment == ".." {
                if !stack.isEmpty { stack.removeLast() }
            } else if segment != "." {
                stack.append(segment)
            }
        }
        return stack.joined(separator: "/")
    }

    private static func mimeType(forExtension ext: String) -> String {
        OfficeMediaType.mimeType(forExtension: ext)
    }

    // MARK: - Archive helpers
    // (entry reads go through the shared, size-hardened ZIPEntryReader.)

    static func readEntry(_ archive: Archive, path: String, maxBytes: Int = 32 * 1024 * 1024) throws -> Data? {
        try Task.checkCancellation()
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let entry = archive[cleanPath] else { return nil }
        let archiveSize = UInt64(archive.data?.count ?? Int.max)
        guard maxBytes >= 0, entry.uncompressedSize <= UInt64(maxBytes), entry.compressedSize <= archiveSize,
              entry.isCompressed || entry.uncompressedSize <= archiveSize else { return nil }
        var data = Data(capacity: Int(min(entry.uncompressedSize, 1024 * 1024)))
        do {
            let checksum = try archive.extract(entry) { chunk in
                try Task.checkCancellation()
                guard chunk.count <= maxBytes - data.count, !chunk.isEmpty || entry.uncompressedSize == 0 else { throw PicoDocsError.fileCorrupted }
                data.append(chunk)
            }
            guard checksum == entry.checksum, UInt64(data.count) == entry.uncompressedSize else { return nil }
        } catch let error as CancellationError {
            throw error
        } catch {
            return nil
        }
        return data
    }

    static func decodeText(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let utf16 = String(data: data, encoding: .utf16) { return utf16 }
        return String(data: data, encoding: .isoLatin1)
    }
}
