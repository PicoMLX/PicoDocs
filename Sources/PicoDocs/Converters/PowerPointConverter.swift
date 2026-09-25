//
//  PowerPointConverter.swift
//  PicoDocs
//
//  Converts PowerPoint (PPTX, OOXML PresentationML) to Markdown: unzip with
//  ZIPFoundation, resolve the deck's slide order from `ppt/presentation.xml`,
//  and walk each slide's shape tree via SwiftSoup's XML parser. One `.slide`
//  section per slide, in presentation order:
//
//    ## <slide title>
//
//    body text, bullet / numbered lists (nested by level), tables, images
//
//    ### Notes
//
//    <speaker notes>
//
//  Shapes render in the slide's shape-tree order (PowerPoint's reading order),
//  title first. Date / footer / slide-number placeholders are boilerplate and
//  skipped; charts and SmartArt are not extracted. Embedded pictures become
//  inline image references plus `.image` sections carrying their bytes, as the
//  DOCX converter does.
//

import Foundation
import ZIPFoundation
import SwiftSoup

public struct PowerPointConverter: DocumentConverter {

    public init() {}

    public func accepts(_ info: StreamInfo) -> Bool {
        info.detectedFormat == .pptx
    }

    public func convert(_ data: Data, info: StreamInfo) async throws -> ConverterResult {
        guard let archive = Archive(data: data, accessMode: .read) else {
            throw PicoDocsError.fileCorrupted
        }
        guard let presentation = Self.xml(archive, path: "ppt/presentation.xml") else {
            throw PicoDocsError.fileCorrupted
        }

        var sections: [DocumentSection] = []
        var images = ImageCollector()
        var parts = PartCache(archive: archive)
        for (index, slidePath) in Self.slidePaths(presentation, archive: archive).enumerated() {
            try Task.checkCancellation()
            guard let slide = Self.xml(archive, path: slidePath) else { continue }
            let relationships = Self.relationships(archive, forPart: slidePath)
            var context = SlideContext(archive: archive, partPath: slidePath, relationships: relationships, images: images)
            // Layout and master supply inherited list formatting for placeholders.
            let layoutPath = Self.relatedPart(of: slidePath, type: "/slideLayout", relationships: relationships)
            context.layout = layoutPath.flatMap { parts.document($0) }
            context.master = layoutPath
                .flatMap { Self.relatedPart(of: $0, type: "/slideMaster", relationships: Self.relationships(archive, forPart: $0)) }
                .flatMap { parts.document($0) }
            let rendered = Self.renderSlide(slide, context: &context)
            images = context.images
            let notes = Self.notes(forSlide: slidePath, relationships: relationships, archive: archive)

            var blocks: [String] = []
            if let title = rendered.title { blocks.append("## \(title)") }
            blocks += rendered.blocks
            if let notes { blocks.append("### Notes\n\n\(notes)") }
            guard !blocks.isEmpty else { continue }   // empty slide: keep its number, emit nothing

            sections.append(DocumentSection(
                title: rendered.title,
                kind: .slide,
                markdown: blocks.joined(separator: "\n\n"),
                sourcePath: slidePath,
                slideNumber: index + 1,
                metadata: notes.map { ["notes": $0] } ?? [:]
            ))
        }
        sections += images.sections
        guard sections.contains(where: { $0.kind != .image }) else { throw PicoDocsError.emptyDocument }

        let properties = Self.coreProperties(archive)
        return ConverterResult(
            title: properties.title ?? info.filename,
            author: properties.author,
            sections: sections
        )
    }

    // MARK: - Deck structure

    /// Slide part paths in presentation order: `p:sldIdLst` entries resolved
    /// through `presentation.xml.rels` (slide file names don't encode order — a
    /// moved slide keeps its `slideN.xml`).
    static func slidePaths(_ presentation: Document, archive: Archive) -> [String] {
        let relationships = relationships(archive, forPart: "ppt/presentation.xml")
        var paths: [String] = []
        for slideID in (try? presentation.getElementsByTag("p:sldId").array()) ?? [] {
            guard let id = try? slideID.attr("r:id"), let target = relationships[id]?.target else { continue }
            paths.append(WordConverter.resolvePartPath(target, relativeTo: "ppt"))
        }
        return paths
    }

    /// Speaker notes for a slide, from its notes-slide part's body placeholder.
    static func notes(forSlide slidePath: String, relationships: [String: Relationship], archive: Archive) -> String? {
        guard let target = relationships.values.first(where: { $0.type.hasSuffix("/notesSlide") })?.target else { return nil }
        let notesPath = WordConverter.resolvePartPath(target, relativeTo: directory(of: slidePath))
        guard let notes = xml(archive, path: notesPath) else { return nil }
        var context = SlideContext(archive: archive, partPath: notesPath,
                                   relationships: Self.relationships(archive, forPart: notesPath),
                                   images: ImageCollector(), embedsImages: false)
        let paragraphs = ((try? notes.getElementsByTag("p:sp").array()) ?? [])
            .filter { placeholderType(of: $0) == "body" }
            .flatMap { shape in textBody(of: shape).map { renderParagraphs($0, inherited: noInheritance, context: &context) } ?? [] }
        let text = paragraphs.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Title and author from `docProps/core.xml`.
    static func coreProperties(_ archive: Archive) -> (title: String?, author: String?) {
        guard let core = xml(archive, path: "docProps/core.xml") else { return (nil, nil) }
        func value(_ tag: String) -> String? {
            let text = (try? core.getElementsByTag(tag).first()?.text())?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty ?? true) ? nil : text
        }
        return (value("dc:title"), value("dc:creator"))
    }

    // MARK: - Slides

    /// Per-part rendering state: where relationship targets resolve from, and the
    /// images collected so far (shared across the deck so each is emitted once).
    struct SlideContext {
        let archive: Archive
        let partPath: String
        let relationships: [String: Relationship]
        var images: ImageCollector
        var embedsImages = true
        /// The slide's layout and master parts, when resolvable.
        var layout: Document?
        var master: Document?
    }

    /// Parses each shared part (layouts, masters) once per deck.
    struct PartCache {
        let archive: Archive
        private var documents: [String: Document?] = [:]

        init(archive: Archive) { self.archive = archive }

        mutating func document(_ path: String) -> Document? {
            if let cached = documents[path] { return cached }
            let parsed = PowerPointConverter.xml(archive, path: path)
            documents[path] = parsed
            return parsed
        }
    }

    /// The part a relationship of `type` (e.g. "/slideLayout") points to.
    static func relatedPart(of part: String, type: String, relationships: [String: Relationship]) -> String? {
        relationships.values.first { $0.type.hasSuffix(type) }
            .map { WordConverter.resolvePartPath($0.target, relativeTo: directory(of: part)) }
    }

    /// A slide's title (from its title placeholder) and its other content blocks.
    static func renderSlide(_ slide: Document, context: inout SlideContext) -> (title: String?, blocks: [String]) {
        guard let tree = try? slide.getElementsByTag("p:spTree").first() else { return (nil, []) }
        var title: String?
        var blocks: [String] = []
        renderShapes(in: tree, title: &title, blocks: &blocks, context: &context)
        return (title, blocks)
    }

    /// Placeholder types that are slide furniture, not content.
    private static let skippedPlaceholders: Set<String> = ["dt", "ftr", "sldNum", "hdr", "sldImg"]

    /// Renders a shape tree (or group) in order. The first title placeholder
    /// becomes the slide title; nested groups and markup-compatibility branches
    /// are walked recursively.
    private static func renderShapes(in container: Element, title: inout String?, blocks: inout [String], context: inout SlideContext) {
        for shape in container.children().array() {
            switch shape.tagName().lowercased() {
            case "p:sp":
                let type = placeholderType(of: shape)
                if let type, skippedPlaceholders.contains(type) { continue }
                guard let body = textBody(of: shape) else { continue }
                if type == "title" || type == "ctrTitle" {
                    let text = renderParagraphs(body, inherited: noInheritance, context: &context)
                        .joined(separator: " ")
                        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    if title == nil, !text.isEmpty { title = text; continue }
                    if !text.isEmpty { blocks.append(text) }
                    continue
                }
                let inherited = inheritedBullets(for: shape, context: context)
                let paragraphs = renderParagraphs(body, inherited: inherited, context: &context)
                if !paragraphs.isEmpty { blocks.append(paragraphs.joined(separator: "\n\n")) }
            case "p:graphicframe":
                if let table = try? shape.getElementsByTag("a:tbl").first() {
                    let markdown = renderTable(table, context: &context)
                    if !markdown.isEmpty { blocks.append(markdown) }
                }
            case "p:pic":
                if let image = pictureMarkdown(shape, context: &context) { blocks.append(image) }
            case "p:grpsp":
                renderShapes(in: shape, title: &title, blocks: &blocks, context: &context)
            case "mc:alternatecontent":
                // One branch only: the first `mc:Choice`, else the `mc:Fallback`.
                let branches = shape.children().array()
                if let branch = branches.first(where: { $0.tagName().lowercased() == "mc:choice" })
                    ?? branches.first(where: { $0.tagName().lowercased() == "mc:fallback" }) {
                    renderShapes(in: branch, title: &title, blocks: &blocks, context: &context)
                }
            default:
                continue
            }
        }
    }

    /// The `type` of a shape's placeholder (`p:nvSpPr/p:nvPr/p:ph`); nil when the
    /// shape isn't a placeholder or its placeholder has no type (a body/object one).
    static func placeholderType(of shape: Element) -> String? {
        guard let placeholder = self.placeholder(of: shape) else { return nil }
        let type = (try? placeholder.attr("type")) ?? ""
        return type.isEmpty ? nil : type
    }

    // MARK: - Inherited list formatting

    /// How a paragraph is marked.
    enum Bullet: Equatable {
        case plain
        case bullet
        case number(startAt: Int)
    }

    /// No inherited list formatting (titles, notes, table cells).
    static let noInheritance: [Bullet?] = Array(repeating: nil, count: 9)

    /// The bullet a paragraph-properties element (`a:pPr`, `a:lvlNpPr`) sets, or
    /// nil when it doesn't say (and the next level of inheritance decides).
    static func bullet(in properties: Element?) -> Bullet? {
        guard let properties else { return nil }
        if child(of: properties, named: "a:bunone") != nil { return .plain }
        if let number = child(of: properties, named: "a:buautonum") {
            return .number(startAt: Int((try? number.attr("startAt")) ?? "") ?? 1)
        }
        if child(of: properties, named: "a:buchar") != nil || child(of: properties, named: "a:bublip") != nil {
            return .bullet
        }
        return nil
    }

    /// Per-level bullets a shape's paragraphs inherit when they don't set their
    /// own. PowerPoint resolves list formatting through the shape's `a:lstStyle`,
    /// then — for placeholders — the matching layout placeholder, the matching
    /// master placeholder, and the master's `p:bodyStyle`. That's how a content
    /// placeholder gets bullets while a Section Header or caption placeholder
    /// (whose layout sets `a:buNone`) doesn't. Without a resolvable layout and
    /// master, body/object placeholders fall back to bullets.
    static func inheritedBullets(for shape: Element, context: SlideContext) -> [Bullet?] {
        var sources: [Element?] = [textBody(of: shape).flatMap { child(of: $0, named: "a:lststyle") }]
        if let placeholder = placeholder(of: shape) {
            let type = ((try? placeholder.attr("type")) ?? "").isEmpty ? "obj" : ((try? placeholder.attr("type")) ?? "")
            let index = (try? placeholder.attr("idx")) ?? ""
            let bodyLike = ["obj", "body", "subTitle"].contains(type)
            if context.layout == nil, context.master == nil {
                // No inheritance chain to read: content placeholders are bulleted.
                return (0..<9).map { _ in type == "subTitle" ? nil : Bullet.bullet }
            }
            if let layout = context.layout {
                sources.append(matchingPlaceholder(in: layout, type: type, index: index).flatMap(listStyle))
            }
            if let master = context.master {
                sources.append(matchingPlaceholder(in: master, type: bodyLike ? "body" : type, index: "").flatMap(listStyle))
                if bodyLike {
                    sources.append(try? master.getElementsByTag("p:bodyStyle").first())
                }
            }
        }
        return (0..<9).map { level in
            for source in sources {
                if let source, let bullet = bullet(in: child(of: source, named: "a:lvl\(level + 1)ppr")) {
                    return bullet
                }
            }
            return nil
        }
    }

    /// The placeholder shape in a layout/master matching a slide placeholder: by
    /// `idx` when both have one, else by type (a typeless placeholder is "obj",
    /// which a master provides as "body").
    private static func matchingPlaceholder(in part: Document, type: String, index: String) -> Element? {
        let shapes = (try? part.getElementsByTag("p:sp").array()) ?? []
        func phType(_ shape: Element) -> String? {
            guard let placeholder = placeholder(of: shape) else { return nil }
            let type = (try? placeholder.attr("type")) ?? ""
            return type.isEmpty ? "obj" : type
        }
        if !index.isEmpty, let match = shapes.first(where: { shape in
            placeholder(of: shape).flatMap { try? $0.attr("idx") } == index
        }) {
            return match
        }
        let equivalent: Set<String> = type == "title" || type == "ctrTitle" ? ["title", "ctrTitle"]
            : type == "obj" || type == "body" ? ["obj", "body"] : [type]
        return shapes.first { phType($0).map(equivalent.contains) ?? false }
    }

    private static func listStyle(_ shape: Element) -> Element? {
        textBody(of: shape).flatMap { child(of: $0, named: "a:lststyle") }
    }

    private static func placeholder(of shape: Element) -> Element? {
        child(of: shape, named: "p:nvsppr").flatMap { child(of: $0, named: "p:nvpr") }.flatMap { child(of: $0, named: "p:ph") }
    }

    private static func textBody(of shape: Element) -> Element? {
        child(of: shape, named: "p:txbody")
    }

    // MARK: - Paragraphs and lists

    /// Renders a text body's paragraphs to Markdown blocks. Consecutive list items
    /// are joined tight into one block; a nested item is indented under its parent
    /// (by the parent marker's width), and numbered lists count per level,
    /// honoring `startAt`.
    static func renderParagraphs(_ body: Element, inherited: [Bullet?], context: inout SlideContext) -> [String] {
        var blocks: [String] = []
        var listLines: [String] = []
        var markerWidths: [Int] = []          // marker width per open level
        var counters: [Int: Int] = [:]        // numbered-list count per level
        var baseLevel = 0                     // shallowest level in the current list

        func flushList() {
            if !listLines.isEmpty { blocks.append(listLines.joined(separator: "\n")) }
            listLines = []; markerWidths = []; counters = [:]
        }

        for paragraph in body.children().array() where paragraph.tagName().lowercased() == "a:p" {
            let properties = child(of: paragraph, named: "a:ppr")
            let level = min(max(Int((try? properties?.attr("lvl")) ?? "") ?? 0, 0), 8)
            let text = renderRuns(paragraph, context: &context).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            let marker: String?
            switch bullet(in: properties) ?? inherited[level] ?? .plain {
            case .plain:
                marker = nil
            case .bullet:
                marker = "- "
            case .number(let start):
                let number = (counters[level] ?? start - 1) + 1
                counters[level] = number
                marker = "\(number). "
            }

            guard let marker else {
                flushList()
                blocks.append(text.replacingOccurrences(of: "\n", with: "  \n"))
                continue
            }
            // Deeper levels restart their numbering when a shallower item intervenes.
            counters = counters.filter { $0.key <= level }
            if marker == "- " { counters[level] = nil }
            // Indent relative to the list's shallowest item, so a list that opens
            // at level 1 (e.g. under a plain paragraph) isn't indented with no parent.
            if listLines.isEmpty || level < baseLevel { baseLevel = level; markerWidths = [] }
            let depth = level - baseLevel
            if markerWidths.count > depth { markerWidths.removeSubrange(depth...) }
            while markerWidths.count < depth { markerWidths.append(2) }
            let indent = String(repeating: " ", count: markerWidths.reduce(0, +))
            markerWidths.append(marker.count)
            let continuation = "\n" + indent + String(repeating: " ", count: marker.count)
            listLines.append(indent + marker + text.replacingOccurrences(of: "\n", with: continuation))
        }
        flushList()
        return blocks
    }

    /// A paragraph's runs as inline Markdown: bold/italic emphasis, external
    /// hyperlinks, fields (e.g. dates), and line breaks as `\n`.
    static func renderRuns(_ paragraph: Element, context: inout SlideContext) -> String {
        struct Run { var text: String; var bold: Bool; var italic: Bool; var link: String? }
        var runs: [Run] = []
        for node in paragraph.children().array() {
            switch node.tagName().lowercased() {
            case "a:r", "a:fld":
                let properties = child(of: node, named: "a:rpr")
                let text = child(of: node, named: "a:t").map(wholeText) ?? ""
                guard !text.isEmpty else { continue }
                let link = properties
                    .flatMap { child(of: $0, named: "a:hlinkclick") }
                    .flatMap { try? $0.attr("r:id") }
                    .flatMap { context.relationships[$0]?.target }
                    .flatMap { isExternalURL($0) ? $0 : nil }
                runs.append(Run(text: text, bold: isOn(properties, "b"), italic: isOn(properties, "i"), link: link))
            case "a:br":
                runs.append(Run(text: "\n", bold: false, italic: false, link: nil))
            default:
                continue
            }
        }

        // Consecutive runs sharing a link form one link label.
        var out = ""
        var index = 0
        while index < runs.count {
            let link = runs[index].link
            var label = ""
            while index < runs.count, runs[index].link == link {
                label += emphasized(runs[index].text, bold: runs[index].bold, italic: runs[index].italic)
                index += 1
            }
            if let link {
                out += "[\(label.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]"))](\(linkDestination(link)))"
            } else {
                out += label
            }
        }
        return out
    }

    /// Wraps text in Markdown emphasis, keeping surrounding whitespace outside the
    /// markers (`** x**` isn't emphasis).
    private static func emphasized(_ text: String, bold: Bool, italic: Bool) -> String {
        guard bold || italic, !text.contains("\n") else { return text }
        let core = text.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return text }
        let leading = String(text.prefix { $0 == " " || $0 == "\t" })
        let trailing = String(text.reversed().prefix { $0 == " " || $0 == "\t" })
        let marker = bold && italic ? "***" : bold ? "**" : "*"
        return leading + marker + core + marker + trailing
    }

    /// Whether a run-property toggle (`b`/`i`) is on (`"1"` / `"true"`).
    private static func isOn(_ properties: Element?, _ attribute: String) -> Bool {
        guard let value = try? properties?.attr(attribute) else { return false }
        return value == "1" || value == "true"
    }

    private static func isExternalURL(_ target: String) -> Bool {
        let lower = target.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:")
    }

    private static func linkDestination(_ url: String) -> String {
        url.contains(" ") || url.contains("(") || url.contains(")") ? "<\(url)>" : url
    }

    // MARK: - Tables

    /// A DrawingML table as a Markdown pipe table. Every grid cell is present in
    /// PPTX (merged-away cells carry `hMerge`/`vMerge`), so rows stay aligned;
    /// merged-away cells render empty.
    static func renderTable(_ table: Element, context: inout SlideContext) -> String {
        var rows: [[String]] = []
        for row in table.children().array() where row.tagName().lowercased() == "a:tr" {
            var cells: [String] = []
            for cell in row.children().array() where cell.tagName().lowercased() == "a:tc" {
                let merged = ((try? cell.attr("hMerge")) ?? "") == "1" || ((try? cell.attr("vMerge")) ?? "") == "1"
                var text = ""
                if !merged, let body = textBody(ofCell: cell) {
                    text = body.children().array()
                        .filter { $0.tagName().lowercased() == "a:p" }
                        .map { renderRuns($0, context: &context).trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                }
                cells.append(MarkdownTableCell.escapeDelimiters(text).replacingOccurrences(of: "\n", with: "<br>"))
            }
            if !cells.isEmpty { rows.append(cells) }
        }
        guard rows.contains(where: { $0.contains { !$0.isEmpty } }) else { return "" }
        let columns = rows.map(\.count).max() ?? 0
        func pad(_ row: [String]) -> [String] { row + Array(repeating: "", count: columns - row.count) }
        var markdown = "| " + pad(rows[0]).joined(separator: " | ") + " |\n"
        markdown += "| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |"
        for row in rows.dropFirst() {
            markdown += "\n| " + pad(row).joined(separator: " | ") + " |"
        }
        return markdown
    }

    private static func textBody(ofCell cell: Element) -> Element? {
        child(of: cell, named: "a:txbody")
    }

    // MARK: - Pictures

    /// An inline image reference for a picture (alt text from its `descr`, else
    /// `name`), registering its bytes as an `.image` section.
    static func pictureMarkdown(_ picture: Element, context: inout SlideContext) -> String? {
        guard let blip = try? picture.getElementsByTag("a:blip").first(),
              let id = try? blip.attr("r:embed"), !id.isEmpty,
              let target = context.relationships[id]?.target else { return nil }
        let mediaPath = WordConverter.resolvePartPath(target, relativeTo: directory(of: context.partPath))
        let filename = (mediaPath as NSString).lastPathComponent
        let properties = child(of: picture, named: "p:nvpicpr").flatMap { child(of: $0, named: "p:cnvpr") }
        let description = (try? properties?.attr("descr")) ?? ""
        let name = (try? properties?.attr("name")) ?? ""
        let alt = !description.isEmpty ? description : (!name.isEmpty ? name : "image")
        if context.embedsImages {
            context.images.add(path: mediaPath, filename: filename, archive: context.archive)
        }
        let label = alt.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        return "![\(label)](\(linkDestination(filename)))"
    }

    /// Collects each embedded image once (by archive path) as an `.image` section.
    struct ImageCollector {
        private(set) var sections: [DocumentSection] = []
        private var seen: Set<String> = []

        mutating func add(path: String, filename: String, archive: Archive) {
            guard seen.insert(path).inserted,
                  let bytes = ZIPEntryReader.read(archive, path: path), !bytes.isEmpty else { return }
            sections.append(DocumentSection(
                title: filename,
                kind: .image,
                markdown: "![\(filename)](\(filename))",
                sourcePath: path,
                metadata: [
                    "mimeType": PowerPointConverter.mimeType(forExtension: (filename as NSString).pathExtension),
                    "base64": bytes.base64EncodedString(),
                ]
            ))
        }
    }

    static func mimeType(forExtension ext: String) -> String {
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

    // MARK: - Package helpers

    struct Relationship {
        let type: String
        let target: String
    }

    /// A part's relationships (`<dir>/_rels/<file>.rels`), keyed by id.
    static func relationships(_ archive: Archive, forPart part: String) -> [String: Relationship] {
        let relsPath = "\(directory(of: part))/_rels/\((part as NSString).lastPathComponent).rels"
        guard let document = xml(archive, path: relsPath) else { return [:] }
        var map: [String: Relationship] = [:]
        for element in (try? document.getElementsByTag("Relationship").array()) ?? [] {
            guard let id = try? element.attr("Id"), let target = try? element.attr("Target"),
                  !id.isEmpty, !target.isEmpty else { continue }
            map[id] = Relationship(type: (try? element.attr("Type")) ?? "", target: target)
        }
        return map
    }

    private static func directory(of part: String) -> String {
        (part as NSString).deletingLastPathComponent
    }

    /// Reads and parses an XML part, or nil when missing/unreadable.
    static func xml(_ archive: Archive, path: String) -> Document? {
        guard let data = ZIPEntryReader.read(archive, path: path),
              let text = WordConverter.decodeText(data) else { return nil }
        return try? SwiftSoup.parse(text, "", SwiftSoup.Parser.xmlParser())
    }

    /// Raw text of an element's text nodes, preserving significant whitespace
    /// (SwiftSoup's `text()` collapses it).
    private static func wholeText(_ element: Element) -> String {
        element.getChildNodes().compactMap { ($0 as? TextNode)?.getWholeText() }.joined()
    }

    /// The first direct child of `element` with the given (lowercased) tag name.
    private static func child(of element: Element, named tag: String) -> Element? {
        element.children().first { $0.tagName().lowercased() == tag }
    }
}
