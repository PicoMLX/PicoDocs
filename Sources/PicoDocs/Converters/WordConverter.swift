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
        let markdown = blocks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else { throw PicoDocsError.emptyDocument }
        return ConverterResult(title: info.filename, sections: [DocumentSection(kind: .body, markdown: markdown)])
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
                out += renderRun(child)
            case "w:hyperlink":
                let inner = renderInline(child, relationships: relationships)
                let relId = (try? child.attr("r:id")) ?? ""
                if let url = relationships[relId], !url.isEmpty, !inner.isEmpty {
                    out += "[\(escapeLinkLabel(inner))](\(escapeLinkDestination(url)))"
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

    static func renderRun(_ run: Element) -> String {
        var text = ""
        for node in run.children().array() {
            switch node.tagName().lowercased() {
            case "w:t":
                // Read raw text nodes to preserve significant whitespace
                // (w:t may carry xml:space="preserve").
                for child in node.getChildNodes() {
                    if let textNode = child as? TextNode { text += textNode.getWholeText() }
                }
            case "w:tab":
                text += "\t"
            case "w:br", "w:cr":
                text += "  \n"
            default:
                // NOTE: text-box content (w:drawing/w:pict -> w:txbxContent),
                // embedded images, and footnote/endnote references (whose text
                // lives in word/footnotes.xml / endnotes.xml) aren't extracted
                // yet — later enhancements.
                continue
            }
        }
        guard !text.isEmpty else { return "" }

        let properties = try? run.getElementsByTag("w:rPr").first()
        var result = text
        if isFormattingEnabled(properties, tag: "w:b") { result = "**\(result)**" }
        if isFormattingEnabled(properties, tag: "w:i") { result = "*\(result)*" }
        return result
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

    static func parseRelationships(_ archive: Archive) -> [String: String] {
        guard let data = readEntry(archive, path: "word/_rels/document.xml.rels"),
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
