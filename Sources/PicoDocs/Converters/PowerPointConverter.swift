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
        try Task.checkCancellation()
        guard let zip = Archive(data: data, accessMode: .read) else {
            throw PicoDocsError.fileCorrupted
        }
        let archive = PowerPointPackage(archive: zip)
        guard let presentation = Self.xml(archive, path: "ppt/presentation.xml") else {
            try archive.check()
            throw PicoDocsError.fileCorrupted
        }

        var sections: [DocumentSection] = []
        var images = ImageCollector()
        var parts = PartCache(archive: archive)
        for (index, slidePath) in try Self.slidePaths(presentation, archive: archive).enumerated() {
            try Task.checkCancellation()
            guard let slide = Self.xml(archive, path: slidePath), (try? slide.getElementsByTag("p:sld").first()) != nil else { try archive.check(); throw PicoDocsError.fileCorrupted }
            let relationships = Self.relationships(archive, forPart: slidePath)
            var context = SlideContext(archive: archive, partPath: slidePath, relationships: relationships, images: images)
            // Layout and master supply inherited list formatting for placeholders.
            let layoutPath = Self.relatedPart(of: slidePath, type: "/slideLayout", relationships: relationships)
            context.layout = layoutPath.flatMap { parts.document($0, root: "p:sldlayout") }
            context.master = layoutPath
                .flatMap { Self.relatedPart(of: $0, type: "/slideMaster", relationships: Self.relationships(archive, forPart: $0)) }
                .flatMap { parts.document($0, root: "p:sldmaster") }
            let rendered = Self.renderSlide(slide, context: &context)
            images = context.images
            let notes = Self.notes(forSlide: slidePath, relationships: relationships, archive: archive, parts: &parts)

            var blocks: [String] = []
            if let title = rendered.title { blocks.append("## \(title)") }
            blocks += rendered.blocks
            if let notes { blocks.append("### Notes\n\n\(notes)") }
            try archive.check()
            guard !blocks.isEmpty else { continue }   // empty slide: keep its number, emit nothing

            sections.append(DocumentSection(
                title: context.plainTitle,
                kind: .slide,
                markdown: blocks.joined(separator: "\n\n"),
                sourcePath: slidePath,
                slideNumber: index + 1,
                metadata: notes.map { ["notes": $0] } ?? [:]
            ))
        }
        sections += images.sections
        try archive.check()
        guard sections.contains(where: { $0.kind != .image }) else { throw PicoDocsError.emptyDocument }

        let properties = Self.coreProperties(archive)
        try archive.check()
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
    static func slidePaths(_ presentation: Document, archive: PowerPointPackage) throws -> [String] {
        let relationships = relationships(archive, forPart: "ppt/presentation.xml")
        var paths: [String] = []
        for slideID in (try? presentation.getElementsByTag("p:sldId").array()) ?? [] {
            guard let id = try? slideID.attr("r:id"), let relation = relationships[id], !relation.external, relation.type.hasSuffix("/slide") else { throw PicoDocsError.fileCorrupted }; let target = relation.target
            paths.append(WordConverter.resolvePartPath(target, relativeTo: "ppt"))
        }
        return paths
    }

    /// Speaker notes for a slide, from its notes-slide part's body placeholder.
    static func notes(forSlide slidePath: String, relationships: [String: Relationship], archive: PowerPointPackage, parts: inout PartCache) -> String? {
        guard let relation = relationships.values.first(where: { $0.type.hasSuffix("/notesSlide") }) else { return nil }
        guard !relation.external else { archive.fail(PicoDocsError.fileCorrupted); return nil }
        let target = relation.target
        let notesPath = WordConverter.resolvePartPath(target, relativeTo: directory(of: slidePath))
        guard let notes = parts.document(notesPath, root: "p:notes") else { archive.fail(PicoDocsError.fileCorrupted); return nil }
        var context = SlideContext(archive: archive, partPath: notesPath,
                                   relationships: Self.relationships(archive, forPart: notesPath),
                                   images: ImageCollector(), embedsImages: false)
        let notesRels = Self.relationships(archive, forPart: notesPath)
        if let master = notesRels.values.first(where: { $0.type.hasSuffix("/notesMaster") }) {
            guard !master.external else { archive.fail(PicoDocsError.fileCorrupted); return nil }
            let path = WordConverter.resolvePartPath(master.target, relativeTo: directory(of: notesPath))
            guard let document = parts.document(path, root: "p:notesmaster") else { archive.fail(PicoDocsError.fileCorrupted); return nil }
            context.master = document
        }
        let paragraphs = ((try? notes.getElementsByTag("p:sp").array()) ?? [])
            .filter { placeholderType(of: $0) == "body" }
            .flatMap { shape in
                context.defaultLink = shapeLink(shape, context: context)
                context.runDefaults = inheritedRunDefaults(for: shape, context: context)
                return textBody(of: shape).map { renderParagraphs($0, inherited: inheritedBullets(for: shape, context: context), context: &context) } ?? []
            }
        let text = paragraphs.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Title and author from `docProps/core.xml`.
    static func coreProperties(_ archive: PowerPointPackage) -> (title: String?, author: String?) {
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
        let archive: PowerPointPackage
        let partPath: String
        let relationships: [String: Relationship]
        var images: ImageCollector
        var embedsImages = true
        var defaultLink: String?
        var plainTitle: String?
        var runDefaults: [[Element]] = Array(repeating: [], count: 9)
        /// The slide's layout and master parts, when resolvable.
        var layout: Document?
        var master: Document?
    }

    /// Parses each shared part (layouts, masters) once per deck.
    struct PartCache {
        let archive: PowerPointPackage
        private var documents: [String: Document?] = [:]

        init(archive: PowerPointPackage) { self.archive = archive }

        mutating func document(_ path: String, root: String) -> Document? {
            let parsed: Document?
            if let cached = documents[path] { parsed = cached }
            else {
                parsed = PowerPointConverter.xml(archive, path: path)
                documents[path] = parsed
            }
            guard let parsed, parsed.children().first()?.tagName().lowercased() == root else {
                archive.fail(PicoDocsError.fileCorrupted)
                return nil
            }
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

    private static func shapeLink(_ shape: Element, context: SlideContext) -> String? {
        let properties = child(of: shape, named: "p:nvsppr").flatMap { child(of: $0, named: "p:cnvpr") }
        return properties.flatMap { child(of: $0, named: "a:hlinkclick") }
            .flatMap { try? $0.attr("r:id") }.flatMap { context.relationships[$0] }
            .flatMap { $0.external && DocumentRenderer.isSafeURL($0.target, isImage: false) ? $0.target : nil }
    }

    /// Placeholder types that are slide furniture, not content.
    private static let skippedPlaceholders: Set<String> = ["dt", "ftr", "sldNum", "hdr", "sldImg"]

    /// Renders a shape tree (or group) in order. The first title placeholder
    /// becomes the slide title; nested groups and markup-compatibility branches
    /// are walked recursively.
    private static func renderShapes(in container: Element, title: inout String?, blocks: inout [String], context: inout SlideContext) {
        for shape in container.children().array() {
            if Task.isCancelled { return }
            context.defaultLink = nil
            switch shape.tagName().lowercased() {
            case "p:sp":
                let type = placeholderType(of: shape)
                if let type, skippedPlaceholders.contains(type) { continue }
                guard let body = textBody(of: shape) else { continue }
                context.defaultLink = shapeLink(shape, context: context)
                context.runDefaults = inheritedRunDefaults(for: shape, context: context)
                if type == "title" || type == "ctrTitle" {
                    let text = renderParagraphs(body, inherited: noInheritance, context: &context)
                        .joined(separator: " ")
                        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    if title == nil, !text.isEmpty {
                        title = text
                        context.plainTitle = ((try? body.getElementsByTag("a:p").array()) ?? []).map { paragraph in
                            paragraph.children().array().map { node in
                                if node.tagName().lowercased() == "a:br" { return " " }
                                return ((try? node.getElementsByTag("a:t").array()) ?? []).map(wholeText).joined()
                            }.joined()
                        }.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
                        continue
                    }
                    if !text.isEmpty { blocks.append(text) }
                    continue
                }
                let inherited = inheritedBullets(for: shape, context: context)
                let paragraphs = renderParagraphs(body, inherited: inherited, context: &context)
                if !paragraphs.isEmpty { blocks.append(paragraphs.joined(separator: "\n\n")) }
            case "p:graphicframe":
                if let table = try? shape.getElementsByTag("a:tbl").first() {
                    context.runDefaults = Array(repeating: [], count: 9)
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
                if let branch = branches.first(where: {
                    guard $0.tagName().lowercased() == "mc:choice" else { return false }
                    let requires = ((try? $0.attr("Requires")) ?? "").split(separator: " ")
                    return !requires.isEmpty && requires.allSatisfy { ["p", "a", "r"].contains(String($0)) }
                })
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
        case number(startAt: Int, scheme: String)
    }

    /// No inherited list formatting (titles, notes, table cells).
    static let noInheritance: [Bullet?] = Array(repeating: nil, count: 9)

    /// The bullet a paragraph-properties element (`a:pPr`, `a:lvlNpPr`) sets, or
    /// nil when it doesn't say (and the next level of inheritance decides).
    static func bullet(in properties: Element?) -> Bullet? {
        guard let properties else { return nil }
        if child(of: properties, named: "a:bunone") != nil { return .plain }
        if let number = child(of: properties, named: "a:buautonum") {
            let raw = (try? number.attr("startAt")) ?? ""
            let scheme = (try? number.attr("type")) ?? ""
            return .number(startAt: raw.isEmpty ? 1 : (Int(raw) ?? 0), scheme: scheme.isEmpty ? "arabicPeriod" : scheme)
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
        var fallback: Bullet?
        var sources: [Element?] = [textBody(of: shape).flatMap { child(of: $0, named: "a:lststyle") }]
        if let placeholder = placeholder(of: shape) {
            let type = ((try? placeholder.attr("type")) ?? "").isEmpty ? "obj" : ((try? placeholder.attr("type")) ?? "")
            let index = (try? placeholder.attr("idx")) ?? ""
            let bodyLike = ["obj", "body", "subTitle"].contains(type)
            if context.layout == nil, context.master == nil {
                // No inheritance chain to read: content placeholders are bulleted.
                fallback = bodyLike && type != "subTitle" ? .bullet : nil
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
                if let source, let bullet = bullet(in: child(of: source, named: "a:lvl\(level + 1)ppr")) ?? bullet(in: child(of: source, named: "a:defppr")) {
                    return bullet
                }
            }
            return fallback
        }
    }

    /// Run toggles inherit independently through the active paragraph level.
    private static func inheritedRunDefaults(for shape: Element, context: SlideContext) -> [[Element]] {
        var styles: [Element?] = [textBody(of: shape).flatMap { child(of: $0, named: "a:lststyle") }]
        if let placeholder = placeholder(of: shape) {
            let raw = (try? placeholder.attr("type")) ?? ""
            let type = raw.isEmpty ? "obj" : raw
            let index = (try? placeholder.attr("idx")) ?? ""
            let bodyLike = ["obj", "body", "subTitle"].contains(type)
            if let layout = context.layout { styles.append(matchingPlaceholder(in: layout, type: type, index: index).flatMap(listStyle)) }
            if let master = context.master {
                styles.append(matchingPlaceholder(in: master, type: bodyLike ? "body" : type, index: "").flatMap(listStyle))
                let style = bodyLike ? "p:bodyStyle" : (["title", "ctrTitle"].contains(type) ? "p:titleStyle" : "p:otherStyle")
                styles.append(try? master.getElementsByTag(style).first())
            }
        }
        return (0..<9).map { level in
            styles.flatMap { source -> [Element] in
                guard let source else { return [] }
                return [child(of: source, named: "a:lvl\(level + 1)ppr"), child(of: source, named: "a:defppr")]
                    .compactMap { $0.flatMap { child(of: $0, named: "a:defrpr") } }
            }
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
        var schemes: [Int: String] = [:]
        var counters: [Int: Int] = [:]        // numbered-list count per level
        var baseLevel = 0                     // shallowest level in the current list

        func flushList() {
            if !listLines.isEmpty { blocks.append(listLines.joined(separator: "\n")) }
            listLines = []; markerWidths = []; counters = [:]; schemes = [:]
        }

        for paragraph in body.children().array() where paragraph.tagName().lowercased() == "a:p" {
            if Task.isCancelled { return [] }
            let properties = child(of: paragraph, named: "a:ppr")
            let level = min(max(Int((try? properties?.attr("lvl")) ?? "") ?? 0, 0), 8)
            let text = escapeBlockMarkers(renderRuns(paragraph, context: &context).trimmingCharacters(in: .whitespaces))
            guard !text.isEmpty else { continue }

            let marker: String?
            switch bullet(in: properties) ?? inherited[level] ?? .plain {
            case .plain:
                marker = nil
            case .bullet:
                marker = "- "
            case .number(let start, let scheme):
                guard (1...32767).contains(start), (counters[level] ?? 0) < Int.max else {
                    context.archive.fail(PicoDocsError.fileCorrupted)
                    return []
                }
                if schemes[level] != scheme { counters[level] = nil }
                schemes[level] = scheme
                let number = counters[level].map { $0 + 1 } ?? start
                counters[level] = number
                let formatted = automaticNumber(number, scheme: scheme)
                    ?? escapeMarkdown("[\(scheme): \(number)]")
                // CommonMark only has decimal markers. Preserve other schemes as
                // visible labels within a bullet item instead of changing them.
                marker = scheme == "arabicPeriod" ? formatted + " " : "- " + formatted + " "
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
            let continuation = "  \n" + indent + String(repeating: " ", count: marker.count)
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
        let paragraphProperties = child(of: paragraph, named: "a:ppr")
        let level = min(max(Int((try? paragraphProperties?.attr("lvl")) ?? "") ?? 0, 0), 8)
        let defaults = [paragraphProperties.flatMap { child(of: $0, named: "a:defrpr") }].compactMap { $0 } + context.runDefaults[level]
        for node in paragraph.children().array() {
            if Task.isCancelled { return "" }
            switch node.tagName().lowercased() {
            case "a:r", "a:fld":
                let properties = child(of: node, named: "a:rpr")
                let text = escapeMarkdown(child(of: node, named: "a:t").map(wholeText) ?? "")
                guard !text.isEmpty else { continue }
                let click = properties.flatMap { child(of: $0, named: "a:hlinkclick") }
                let link = click.flatMap { try? $0.attr("r:id") }
                    .flatMap { context.relationships[$0] }
                    .flatMap { $0.external && DocumentRenderer.isSafeURL($0.target, isImage: false) ? $0.target : nil }
                runs.append(Run(text: text, bold: isOn(properties, "b", defaults: defaults), italic: isOn(properties, "i", defaults: defaults), link: click == nil ? context.defaultLink : link))
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
                out += "[\(label)](\(linkDestination(link)))"
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
        let leading = String(text.prefix { $0.unicodeScalars.allSatisfy(CharacterSet.whitespaces.contains) })
        let trailing = String(text.reversed().prefix { $0.unicodeScalars.allSatisfy(CharacterSet.whitespaces.contains) }.reversed())
        let marker = bold && italic ? "***" : bold ? "**" : "*"
        return leading + marker + core + marker + trailing
    }

    /// Whether a run-property toggle (`b`/`i`) is on (`"1"` / `"true"`).
    private static func isOn(_ properties: Element?, _ attribute: String, defaults: [Element] = []) -> Bool {
        let direct = (try? properties?.attr(attribute)) ?? ""
        let value = direct.isEmpty ? defaults.compactMap { try? $0.attr(attribute) }.first(where: { !$0.isEmpty }) ?? "" : direct
        return value == "1" || value == "true"
    }

    private static func escapeMarkdown(_ text: String) -> String {
        var out = ""
        for character in text {
            if #"\`*_{}[]<>"#.contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    private static func escapeBlockMarkers(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "-" || $0 == " " }) {
                return line.replacingOccurrences(of: "-", with: "\\-")
            }
            return line.replacingOccurrences(of: #"^(\s*)(#{1,6}|[-+]|\|)(?=\s|$)"#, with: #"$1\\$2"#, options: .regularExpression)
                .replacingOccurrences(of: #"^(\s*)([0-9]+)([.)])(?=\s|$)"#, with: #"$1$2\\$3"#, options: .regularExpression)
                .replacingOccurrences(of: #"^(\s*)\|"#, with: #"$1\\|"#, options: .regularExpression)
        }.joined(separator: "\n")
    }

    /// Latin, Roman and decimal schemes specified by DrawingML. Unknown schemes
    /// use a visible scheme-and-counter fallback rather than aborting conversion.
    static func automaticNumber(_ number: Int, scheme: String) -> String? {
        let value: String
        func digits(_ zero: UInt32) -> String {
            String(String.UnicodeScalarView(String(number).unicodeScalars.map { UnicodeScalar(zero + $0.value - 48)! }))
        }
        if scheme == "circleNumWdBlackPlain", (1...10).contains(number) { return String(UnicodeScalar(0x2775 + number)!) }
        if ["circleNumWdWhitePlain", "circleNumDbPlain"].contains(scheme), (1...20).contains(number) { return String(UnicodeScalar(0x245F + number)!) }
        if scheme.hasPrefix("thaiNum") { value = digits(0x0E50) }
        else if scheme.hasPrefix("hindiNum") { value = digits(0x0966) }
        else if scheme.hasPrefix("arabicDb") { value = digits(0xFF10) }
        else if scheme.hasPrefix("hindiAlpha") {
            let alphabet = scheme.hasPrefix("hindiAlpha1") ? Array("कखगघङचछजझञटठडढणतथदधनपफबभमयरलवशषसह") : Array("अआइईउऊऋऌएऐओऔ")
            guard number > 0, number <= alphabet.count else { return nil }
            value = String(alphabet[number - 1])
        } else if scheme.hasPrefix("thaiAlpha") {
            let alphabet = Array("กขฃคฅฆงจฉชซฌญฎฏฐฑฒณดตถทนบปผฝพฟภมยรลวศษสหฬอฮ")
            guard number > 0, number <= alphabet.count else { return nil }
            value = String(alphabet[number - 1])
        } else if scheme.hasPrefix("alphaLc") || scheme.hasPrefix("alphaUc") {
            var n = number, letters = ""
            while n > 0 {
                n -= 1
                letters = String(UnicodeScalar(65 + n % 26)!) + letters
                n /= 26
            }
            value = scheme.hasPrefix("alphaLc") ? letters.lowercased() : letters
        } else if scheme.hasPrefix("romanLc") || scheme.hasPrefix("romanUc") {
            guard number < 4000 else { return nil }
            var n = number, roman = ""
            for (amount, symbol) in [(1000,"M"),(900,"CM"),(500,"D"),(400,"CD"),(100,"C"),(90,"XC"),(50,"L"),(40,"XL"),(10,"X"),(9,"IX"),(5,"V"),(4,"IV"),(1,"I")] {
                while n >= amount { roman += symbol; n -= amount }
            }
            value = scheme.hasPrefix("romanLc") ? roman.lowercased() : roman
        } else if scheme.hasPrefix("arabic") { value = String(number) }
        else { return nil }
        if scheme.hasSuffix("ParenBoth") { return "(" + value + ")" }
        if scheme.hasSuffix("ParenR") { return value + ")" }
        if scheme.hasSuffix("Period") { return value + (scheme.hasPrefix("arabicDb") ? "．" : ".") }
        if scheme == "arabicPlain" || scheme == "arabicDbPlain" { return value }
        return nil
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
            if Task.isCancelled { return "" }
            var cells: [String] = []
            for cell in row.children().array() where cell.tagName().lowercased() == "a:tc" {
                let merged = isOn(cell, "hMerge") || isOn(cell, "vMerge")
                var text = ""
                if !merged, let body = textBody(ofCell: cell) {
                    text = renderParagraphs(body, inherited: noInheritance, context: &context).joined(separator: "\n")
                }
                cells.append(text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>"))
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
              let id = try? blip.attr("r:embed"), !id.isEmpty else { return nil }
        guard let relation = context.relationships[id], !relation.external else { context.archive.fail(PicoDocsError.fileCorrupted); return nil }
        let target = relation.target
        let mediaPath = WordConverter.resolvePartPath(target, relativeTo: directory(of: context.partPath))
        let filename = (mediaPath as NSString).lastPathComponent
        let properties = child(of: picture, named: "p:nvpicpr").flatMap { child(of: $0, named: "p:cnvpr") }
        let description = (try? properties?.attr("descr")) ?? ""
        let name = (try? properties?.attr("name")) ?? ""
        let alt = !description.isEmpty ? description : (!name.isEmpty ? name : "image")
        if context.embedsImages {
            context.images.add(path: mediaPath, filename: filename, archive: context.archive)
        }
        let label = escapeMarkdown(alt)
        return "![\(label)](\(linkDestination(filename)))"
    }

    /// Collects each embedded image once (by archive path) as an `.image` section.
    struct ImageCollector {
        private(set) var sections: [DocumentSection] = []
        private var seen: Set<String> = []

        mutating func add(path: String, filename: String, archive: PowerPointPackage) {
            guard !seen.contains(path) else { return }
            guard let bytes = archive.read(path), !bytes.isEmpty else {
                archive.fail(PicoDocsError.fileCorrupted)
                return
            }
            seen.insert(path)
            sections.append(DocumentSection(
                title: filename,
                kind: .image,
                markdown: "![\(filename)](\(filename))",
                sourcePath: path,
                metadata: [
                    "mimeType": PowerPointConverter.contentType(path, archive: archive) ?? PowerPointConverter.mimeType(forExtension: (filename as NSString).pathExtension),
                    "base64": bytes.base64EncodedString(),
                ]
            ))
        }
    }

    static func contentType(_ path: String, archive: PowerPointPackage) -> String? {
        if archive.contentTypes == nil {
            var types: [String: String] = [:]
            if let manifest = xml(archive, path: "[Content_Types].xml") {
                for entry in (try? manifest.getElementsByTag("Override").array()) ?? [] {
                    if let name = try? entry.attr("PartName"), let type = validatedMIME(try? entry.attr("ContentType")) { types[name] = type }
                }
                for entry in (try? manifest.getElementsByTag("Default").array()) ?? [] {
                    if let ext = try? entry.attr("Extension"), let type = validatedMIME(try? entry.attr("ContentType")) { types["." + ext.lowercased()] = type }
                }
            }
            archive.contentTypes = types
        }
        return archive.contentTypes?["/" + path] ?? archive.contentTypes?["." + (path as NSString).pathExtension.lowercased()]
    }

    private static func validatedMIME(_ value: String?) -> String? {
        guard let value, value.range(of: #"^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$"#, options: .regularExpression) != nil else { return nil }
        return value
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
        var external = false
    }

    /// A part's relationships (`<dir>/_rels/<file>.rels`), keyed by id.
    static func relationships(_ archive: PowerPointPackage, forPart part: String) -> [String: Relationship] {
        if let cached = archive.relationshipMaps[part] { return cached }
        let relsPath = "\(directory(of: part))/_rels/\((part as NSString).lastPathComponent).rels"
        guard let document = xml(archive, path: relsPath) else {
            if archive.archive[relsPath] != nil { archive.fail(PicoDocsError.fileCorrupted) }
            archive.relationshipMaps[part] = [:]
            return [:]
        }
        var map: [String: Relationship] = [:]
        for element in (try? document.getElementsByTag("Relationship").array()) ?? [] {
            guard let id = try? element.attr("Id"), let target = try? element.attr("Target"),
                  !id.isEmpty, !target.isEmpty else { continue }
            map[id] = Relationship(type: (try? element.attr("Type")) ?? "", target: target, external: ((try? element.attr("TargetMode")) ?? "").lowercased() == "external")
        }
        archive.relationshipMaps[part] = map
        return map
    }

    private static func directory(of part: String) -> String {
        (part as NSString).deletingLastPathComponent
    }

    /// Reads and parses an XML part, or nil when missing/unreadable.
    static func xml(_ archive: PowerPointPackage, path: String) -> Document? {
        guard let data = archive.read(path),
              let text = PowerPointXML.normalize(data) else { return nil }
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
