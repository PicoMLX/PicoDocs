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

        let blocks = try Self.renderBlocks(in: body, relationships: relationships)
        var markdown = blocks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)

        // Footnote/endnote text lives in separate parts; append the referenced
        // ones as Markdown footnote definitions (the body carries `[^fnN]`/
        // `[^enN]` reference markers at their positions).
        let notes = Self.parseNotes(archive)
        let definitions = Self.referencedNoteIDs(in: body).compactMap { id in
            notes[id].map { "[^\(id)]: \($0)" }
        }
        if !definitions.isEmpty {
            markdown += (markdown.isEmpty ? "" : "\n\n") + definitions.joined(separator: "\n")
        }

        // Extract embedded images as separate .image sections (bytes preserved
        // for downstream OCR/captioning); the body Markdown references them inline.
        let imageSections = Self.extractImages(from: body, relationships: relationships, archive: archive)

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
                // NOTE: text-box content (w:txbxContent) isn't extracted yet —
                // a later enhancement.
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
                // content controls (w:sdt) within the cell are included too.
                for paragraph in (try? tc.getElementsByTag("w:p").array()) ?? [] {
                    let t = renderInline(paragraph, relationships: relationships).trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { cellText += (cellText.isEmpty ? "" : "\n") + t }
                }
                // Single-line Markdown cells: escape pipes; CR/LF become <br>.
                cells.append(cellText
                    .replacingOccurrences(of: "|", with: "\\|")
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
        // Footnotes/endnotes have their own relationship parts, so inline
        // hyperlinks/images inside notes resolve against those, not the body's.
        let footnoteRels = parseRelationships(archive, path: "word/_rels/footnotes.xml.rels")
        var notes = parseNotePart(archive, path: "word/footnotes.xml", tag: "w:footnote", prefix: "fn", relationships: footnoteRels)
        let endnoteRels = parseRelationships(archive, path: "word/_rels/endnotes.xml.rels")
        for (key, value) in parseNotePart(archive, path: "word/endnotes.xml", tag: "w:endnote", prefix: "en", relationships: endnoteRels) {
            notes[key] = value
        }
        return notes
    }

    private static func parseNotePart(_ archive: Archive, path: String, tag: String, prefix: String, relationships: [String: String]) -> [String: String] {
        guard let data = readEntry(archive, path: path),
              let xml = decodeText(data),
              let doc = try? SwiftSoup.parse(xml, "", SwiftSoup.Parser.xmlParser()) else {
            return [:]
        }
        var notes: [String: String] = [:]
        for note in (try? doc.getElementsByTag(tag).array()) ?? [] {
            guard let id = try? note.attr("w:id"), !id.isEmpty else { continue }
            // Skip the auto separator / continuation-separator notes (w:type).
            if let type = try? note.attr("w:type"), !type.isEmpty { continue }
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
    static func extractImages(from body: Element, relationships: [String: String], archive: Archive) -> [DocumentSection] {
        let blips = (try? body.getElementsByTag("a:blip").array()) ?? []
        let vmlImages = (try? body.getElementsByTag("v:imagedata").array()) ?? []

        var sections: [DocumentSection] = []
        var seen = Set<String>()
        for element in blips + vmlImages {
            var relId = (try? element.attr("r:embed")) ?? ""
            if relId.isEmpty { relId = (try? element.attr("r:id")) ?? "" }
            guard !relId.isEmpty, let target = relationships[relId], !target.isEmpty else { continue }

            let mediaPath = resolveMediaPath(target)
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

    /// Resolves a `document.xml.rels` image Target (relative to `word/`) to its
    /// path inside the archive. Normalizes segment-by-segment (single pass), so
    /// `.`/`..` are collapsed without any risk of looping.
    private static func resolveMediaPath(_ target: String) -> String {
        // A leading "/" is package-absolute; otherwise the target is relative to
        // the part's folder (`word/`).
        let combined = target.hasPrefix("/") ? String(target.dropFirst()) : "word/\(target)"
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
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "emf": return "image/emf"
        case "wmf": return "image/wmf"
        default: return "application/octet-stream"
        }
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
