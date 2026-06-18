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
        guard let documentData = Self.readEntry(archive, path: "word/document.xml"),
              let documentXML = Self.decodeText(documentData) else {
            throw PicoDocsError.fileCorrupted
        }

        let relationships = Self.parseRelationships(archive)
        let document = try SwiftSoup.parse(documentXML, "", SwiftSoup.Parser.xmlParser())
        guard let body = try document.getElementsByTag("w:body").first() else {
            throw PicoDocsError.emptyDocument
        }

        var blocks = try Self.renderBlocks(in: body, relationships: relationships)
        // Text boxes (shapes with text) store their content in `w:txbxContent`
        // outside the normal block flow; extract it and append as body blocks.
        blocks += try Self.extractTextBoxes(from: body, relationships: relationships)
        var markdown = blocks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)

        // Footnote/endnote text lives in separate parts; append the referenced
        // ones as Markdown footnote definitions (the body carries `[^fnN]`/
        // `[^enN]` reference markers at their positions).
        //
        // NOTE: these are CommonMark footnote markers in the canonical Markdown;
        // DocumentRenderer also renders them for the HTML and plaintext exports.
        let notes = Self.parseNotes(archive)
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
        var imageSections = Self.extractImages(from: body, relationships: relationships, archive: archive)
        imageSections += Self.extractNoteImages(archive)
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
        return ConverterResult(title: info.filename, sections: sections)
    }

    // MARK: - Blocks

    /// Renders the block-level children of a container (the body, or a content
    /// control's content) to Markdown blocks, recursing into `w:sdt` content
    /// controls (forms/templates wrap paragraphs and tables in them).
    static func renderBlocks(in container: Element, relationships: [String: String]) throws -> [String] {
        var blocks: [String] = []
        for element in container.children().array() {
            try Task.checkCancellation()
            switch element.tagName().lowercased() {
            case "w:p":
                if let markdown = renderParagraph(element, relationships: relationships), !markdown.isEmpty {
                    blocks.append(markdown)
                }
            case "w:tbl":
                let table = renderTable(element, relationships: relationships)
                if !table.isEmpty { blocks.append(table) }
            case "w:sdt":
                if let content = try? element.getElementsByTag("w:sdtContent").first() {
                    blocks.append(contentsOf: try renderBlocks(in: content, relationships: relationships))
                }
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
    static func extractTextBoxes(from body: Element, relationships: [String: String]) throws -> [String] {
        var blocks: [String] = []
        // Iterate the Elements sequence directly (no intermediate array copy).
        guard let textBoxes = try? body.getElementsByTag("w:txbxContent") else { return blocks }
        for txbx in textBoxes {
            if !shouldRenderTextBox(txbx) { continue }
            blocks.append(contentsOf: try renderBlocks(in: txbx, relationships: relationships))
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

    static func renderParagraph(_ paragraph: Element, relationships: [String: String]) -> String? {
        let style = try? paragraph.getElementsByTag("w:pStyle").first()?.attr("w:val")
        let isListItem = (try? paragraph.getElementsByTag("w:numPr").first()) != nil
        let text = renderInline(paragraph, relationships: relationships).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        if let level = headingLevel(forStyle: style) {
            return String(repeating: "#", count: level) + " " + text
        }
        if isListItem {
            return "- " + text
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

    static func renderInline(_ container: Element, relationships: [String: String]) -> String {
        var out = ""
        for child in container.children().array() {
            switch child.tagName().lowercased() {
            case "w:ppr":
                continue // paragraph properties, not content
            case "w:r":
                out += renderRun(child, relationships: relationships)
            case "w:hyperlink":
                let inner = renderInline(child, relationships: relationships)
                let relId = (try? child.attr("r:id")) ?? ""
                if let url = relationships[relId], !url.isEmpty, !inner.isEmpty {
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
                        out += "[\(escapeLinkLabel(inner))](\(escapeLinkDestination(url)))"
                    }
                } else {
                    out += inner
                }
            default:
                // smartTag / ins / proofErr / other wrappers: recurse for nested runs.
                out += renderInline(child, relationships: relationships)
            }
        }
        return out
    }

    static func renderRun(_ run: Element, relationships: [String: String]) -> String {
        let properties = try? run.getElementsByTag("w:rPr").first()
        let bold = isFormattingEnabled(properties, tag: "w:b")
        let italic = isFormattingEnabled(properties, tag: "w:i")

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
                    if let textNode = child as? TextNode { textBuffer += textNode.getWholeText() }
                }
            case "w:tab":
                textBuffer += "\t"
            case "w:br", "w:cr":
                textBuffer += "  \n"
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

    /// True when a run-property toggle (`w:b`/`w:i`) is present and not explicitly
    /// disabled (`w:val="false"/"0"/"none"`, used to override style hierarchies).
    private static func isFormattingEnabled(_ properties: Element?, tag: String) -> Bool {
        guard let element = try? properties?.getElementsByTag(tag).first() else { return false }
        if let val = try? element.attr("w:val"), !val.isEmpty {
            return val != "false" && val != "0" && val != "none"
        }
        return true
    }

    private static func escapeLinkLabel(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "\\[")
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
        // Spaces / parens break inline link destinations; wrap in <> (a valid
        // CommonMark destination form) when present.
        if url.contains(" ") || url.contains("(") || url.contains(")") {
            return "<\(url)>"
        }
        return url
    }

    // MARK: - Tables

    static func renderTable(_ table: Element, relationships: [String: String]) -> String {
        var rows: [[String]] = []
        for tr in table.children().array() where tr.tagName().lowercased() == "w:tr" {
            var cells: [String] = []
            for tc in tr.children().array() where tc.tagName().lowercased() == "w:tc" {
                var cellText = ""
                // Gather all descendant paragraphs so paragraphs inside block
                // content controls (w:sdt) within the cell are included too. Skip
                // paragraphs belonging to a text box nested in this cell — those are
                // emitted once by extractTextBoxes, so rendering them here too would
                // duplicate them. (A table inside a text box is not skipped, so its
                // own cells still render — see isInsideTextBox.)
                for paragraph in (try? tc.getElementsByTag("w:p").array()) ?? [] {
                    if isInsideTextBox(paragraph, before: tc) { continue }
                    let t = renderInline(paragraph, relationships: relationships).trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { cellText += (cellText.isEmpty ? "" : "\n") + t }
                }
                // Single-line Markdown cells: escape delimiters; CR/LF become <br>.
                cells.append(MarkdownTableCell.escapeDelimiters(cellText)
                    .replacingOccurrences(of: "\r\n", with: "<br>")
                    .replacingOccurrences(of: "\r", with: "<br>")
                    .replacingOccurrences(of: "\n", with: "<br>"))
                // Honor horizontally merged cells (w:gridSpan) so later columns
                // stay aligned, by emitting empty placeholders for the span.
                let span = gridSpan(of: tc)
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
    private static func gridSpan(of cell: Element) -> Int {
        guard let value = try? cell.getElementsByTag("w:gridSpan").first()?.attr("w:val"),
              let span = Int(value) else { return 1 }
        return max(1, span)
    }

    // MARK: - Relationships (hyperlink targets)

    static func parseRelationships(_ archive: Archive, path: String = "word/_rels/document.xml.rels") -> [String: String] {
        guard let data = readEntry(archive, path: path),
              let xml = decodeText(data),
              let doc = try? SwiftSoup.parse(xml, "", SwiftSoup.Parser.xmlParser()) else {
            return [:]
        }
        var map: [String: String] = [:]
        for rel in (try? doc.getElementsByTag("Relationship").array()) ?? [] {
            guard let id = try? rel.attr("Id"), let target = try? rel.attr("Target"),
                  !id.isEmpty, !target.isEmpty else { continue }
            map[id] = target
        }
        return map
    }

    // MARK: - Footnotes / endnotes

    /// Parses footnote and endnote text (stored in separate parts) into a map
    /// keyed by reference id (`fn<id>` / `en<id>`), skipping the auto separator
    /// and continuation notes.
    static func parseNotes(_ archive: Archive) -> [String: String] {
        var notes: [String: String] = [:]
        // Resolve each note part from its document relationship Target (falling
        // back to the standard name), then render it against that part's own
        // relationships so inline hyperlinks/images inside notes resolve correctly.
        for (typeSuffix, fallback, tag, prefix) in [
            ("/footnotes", "word/footnotes.xml", "w:footnote", "fn"),
            ("/endnotes", "word/endnotes.xml", "w:endnote", "en"),
        ] {
            let part = relationshipTarget(archive, typeSuffix: typeSuffix).map { resolvePartPath($0, relativeTo: "word") } ?? fallback
            let relationships = parseRelationships(archive, path: relationshipsPath(forPart: part))
            for (key, value) in parseNotePart(archive, path: part, tag: tag, prefix: prefix, relationships: relationships) {
                notes[key] = value
            }
        }
        return notes
    }

    /// The Target of the first `document.xml.rels` relationship whose Type ends
    /// with `typeSuffix` (e.g. "/footnotes"); relative to `word/`.
    private static func relationshipTarget(_ archive: Archive, typeSuffix: String) -> String? {
        guard let data = readEntry(archive, path: "word/_rels/document.xml.rels"),
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

    private static func parseNotePart(_ archive: Archive, path: String, tag: String, prefix: String, relationships: [String: String]) -> [String: String] {
        guard let data = readEntry(archive, path: path),
              let xml = decodeText(data),
              let doc = try? SwiftSoup.parse(xml, "", SwiftSoup.Parser.xmlParser()) else {
            return [:]
        }
        var notes: [String: String] = [:]
        for note in (try? doc.getElementsByTag(tag).array()) ?? [] {
            guard let id = try? note.attr("w:id"), !id.isEmpty else { continue }
            // Skip only the auto separator/continuation notes; keep ordinary
            // referenced notes even when explicitly typed "normal".
            if let type = try? note.attr("w:type"), separatorNoteTypes.contains(type) { continue }
            let text = ((try? note.getElementsByTag("w:p").array()) ?? [])
                .map { renderInline($0, relationships: relationships).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
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
    static func extractNoteImages(_ archive: Archive) -> [DocumentSection] {
        var sections: [DocumentSection] = []
        for (typeSuffix, fallback, rootTag) in [
            ("/footnotes", "word/footnotes.xml", "w:footnotes"),
            ("/endnotes", "word/endnotes.xml", "w:endnotes"),
        ] {
            let part = relationshipTarget(archive, typeSuffix: typeSuffix).map { resolvePartPath($0, relativeTo: "word") } ?? fallback
            guard let data = readEntry(archive, path: part),
                  let xml = decodeText(data),
                  let doc = try? SwiftSoup.parse(xml, "", SwiftSoup.Parser.xmlParser()),
                  let root = try? doc.getElementsByTag(rootTag).first() else { continue }
            let relationships = parseRelationships(archive, path: relationshipsPath(forPart: part))
            // A note part's image targets resolve relative to the note part's own
            // folder (usually `word`, but a subfolder when the part lives in one).
            let partDirectory = (part as NSString).deletingLastPathComponent
            sections.append(contentsOf: extractImages(from: root, relationships: relationships, archive: archive, partDirectory: partDirectory))
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
        let filename = (target as NSString).lastPathComponent
        return "![\(escapeLinkLabel(imageAltText(in: drawing)))](\(escapeLinkDestination(filename)))"
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

    /// Extracts each embedded image once as an `.image` section carrying the raw
    /// bytes (base64) and MIME type, so consumers can render or caption them.
    static func extractImages(from body: Element, relationships: [String: String], archive: Archive, partDirectory: String = "word") -> [DocumentSection] {
        let blips = (try? body.getElementsByTag("a:blip").array()) ?? []
        let vmlImages = (try? body.getElementsByTag("v:imagedata").array()) ?? []

        var sections: [DocumentSection] = []
        var seen = Set<String>()
        for element in blips + vmlImages {
            var relId = (try? element.attr("r:embed")) ?? ""
            if relId.isEmpty { relId = (try? element.attr("r:id")) ?? "" }
            guard !relId.isEmpty, let target = relationships[relId], !target.isEmpty else { continue }

            let mediaPath = resolvePartPath(target, relativeTo: partDirectory)
            guard !seen.contains(mediaPath) else { continue }
            seen.insert(mediaPath)

            guard let bytes = readEntry(archive, path: mediaPath), !bytes.isEmpty else { continue }
            let filename = (target as NSString).lastPathComponent
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
    // (mirror EPUBConverter's; candidates for a shared ZIP utility later.)

    static func readEntry(_ archive: Archive, path: String) -> Data? {
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let entry = archive[cleanPath] else { return nil }
        var data = Data(capacity: Int(entry.uncompressedSize))
        do {
            _ = try archive.extract(entry) { data.append($0) }
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
