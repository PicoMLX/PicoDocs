//
//  PowerPointConverter.swift
//  PicoDocs
//
//  Converts PowerPoint (PPTX, OOXML PresentationML) to Markdown: unzip with
//  ZIPFoundation, resolve the deck's presentation and slide order through OPC relationships,
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
        _ = Self.contentType("", archive: archive)
        try archive.check()
        let packageRelationships = Self.relationships(archive, forPart: "")
        let officeDocuments = packageRelationships.values.filter { $0.isType("/officeDocument") }
        guard officeDocuments.count == 1, let officeDocument = officeDocuments.first, !officeDocument.external else {
            try archive.check()
            throw PicoDocsError.fileCorrupted
        }
        let presentationPath = WordConverter.resolvePartPath(officeDocument.target, relativeTo: "")
        guard let presentation = Self.xml(archive, path: presentationPath), presentation.children().first()?.tagName().lowercased() == "p:presentation" else {
            try archive.check()
            throw PicoDocsError.fileCorrupted
        }

        let defaultTextStyle = presentation.children().first().flatMap { Self.selectedChild(of: $0, named: "p:defaulttextstyle") }
        var sections: [DocumentSection] = []
        let slidePaths = try Self.slidePaths(presentation, archive: archive, presentationPath: presentationPath)
        // Reserve all external image destinations first, including later slides,
        // so embedded references cannot claim an external occurrence's src.
        var externalReferences: Set<String> = []
        for path in Set(slidePaths) {
            try Task.checkCancellation()
            for relation in Self.relationships(archive, forPart: path).values
                where relation.external && relation.isType("/image") {
                externalReferences.insert(Self.linkDestination(relation.target))
            }
        }
        let images = ImageCollector(reservedReferences: externalReferences)
        var parts = PartCache(archive: archive)
        for (index, slidePath) in slidePaths.enumerated() {
            try Task.checkCancellation()
            guard let slide = Self.xml(archive, path: slidePath), slide.children().first()?.tagName().lowercased() == "p:sld" else { try archive.check(); throw PicoDocsError.fileCorrupted }
            let relationships = Self.relationships(archive, forPart: slidePath)
            var context = SlideContext(archive: archive, partPath: slidePath, relationships: relationships, images: images)
            context.defaultTextStyle = defaultTextStyle
            context.placeholders = parts.placeholders
            // Layout and master supply inherited list formatting for placeholders.
            let layoutPath = Self.relatedPart(of: slidePath, type: "/slideLayout", relationships: relationships, archive: archive)
            context.layout = layoutPath.flatMap { parts.document($0, root: "p:sldlayout") }
            context.master = layoutPath
                .flatMap { Self.relatedPart(of: $0, type: "/slideMaster", relationships: Self.relationships(archive, forPart: $0), archive: archive) }
                .flatMap { parts.document($0, root: "p:sldmaster") }
            let rendered = Self.renderSlide(slide, context: &context)
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
    static func slidePaths(_ presentation: Document, archive: PowerPointPackage, presentationPath: String = "ppt/presentation.xml", maximumPathBytes: Int = 8 * 1024 * 1024) throws -> [String] {
        let relationships = relationships(archive, forPart: presentationPath)
        var paths: [String] = []
        guard let root = presentation.children().first(), root.tagName().lowercased() == "p:presentation" else { throw PicoDocsError.fileCorrupted }
        let lists = selectedChildren(in: root).filter { $0.tagName().lowercased() == "p:sldidlst" }
        guard lists.count <= 1 else { throw PicoDocsError.fileCorrupted }
        let direct = lists.first.map { selectedChildren(in: $0).filter { $0.tagName().lowercased() == "p:sldid" } } ?? []
        // Repeated references still cost a full render, even when ZIP bytes are small.
        guard direct.count <= 10_000 else { throw PicoDocsError.fileCorrupted }
        var pending = selectedChildren(in: root), total = 0
        while let element = pending.popLast() {
            try Task.checkCancellation()
            if element.tagName().lowercased() == "p:sldid" { total += 1 }
            pending += selectedChildren(in: element)
        }
        guard total == direct.count else { throw PicoDocsError.fileCorrupted }
        var remainingPathBytes = maximumPathBytes
        var resolved: [String: String] = [:]
        for slideID in direct {
            guard let id = try? slideID.attr("r:id"), let relation = relationships[id], !relation.external, relation.isType("/slide") else { throw PicoDocsError.fileCorrupted }; let target = relation.target
            let path = resolved[target] ?? WordConverter.resolvePartPath(target, relativeTo: directory(of: presentationPath))
            guard path.utf8.count <= remainingPathBytes else { throw PicoDocsError.fileCorrupted }
            remainingPathBytes -= path.utf8.count
            resolved[target] = path
            paths.append(path)
        }
        return paths
    }

    /// Speaker notes for a slide, from its notes-slide part's body placeholder.
    static func notes(forSlide slidePath: String, relationships: [String: Relationship], archive: PowerPointPackage, parts: inout PartCache) -> String? {
        let noteRelations = relationships.values.filter { $0.isType("/notesSlide") }
        guard noteRelations.count <= 1 else { archive.fail(PicoDocsError.fileCorrupted); return nil }
        guard let relation = noteRelations.first else { return nil }
        guard !relation.external else { archive.fail(PicoDocsError.fileCorrupted); return nil }
        let target = relation.target
        let notesPath = WordConverter.resolvePartPath(target, relativeTo: directory(of: slidePath))
        guard let notes = parts.document(notesPath, root: "p:notes", cache: false) else { archive.fail(PicoDocsError.fileCorrupted); return nil }
        guard let root = notes.children().first(), let common = selectedChild(of: root, named: "p:csld"),
              let tree = selectedChild(of: common, named: "p:sptree") else { archive.fail(PicoDocsError.fileCorrupted); return nil }
        var context = SlideContext(archive: archive, partPath: notesPath,
                                   relationships: Self.relationships(archive, forPart: notesPath),
                                   images: ImageCollector(), embedsImages: false)
        let notesRels = Self.relationships(archive, forPart: notesPath)
        let backlinks = notesRels.values.filter { $0.isType("/slide") }
        guard backlinks.count == 1, let backlink = backlinks.first, !backlink.external,
              WordConverter.resolvePartPath(backlink.target, relativeTo: directory(of: notesPath)) == slidePath else {
            archive.fail(PicoDocsError.fileCorrupted); return nil
        }
        let masters = notesRels.values.filter { $0.isType("/notesMaster") }
        guard masters.count <= 1 else { archive.fail(PicoDocsError.fileCorrupted); return nil }
        if let master = masters.first {
            guard !master.external else { archive.fail(PicoDocsError.fileCorrupted); return nil }
            let path = WordConverter.resolvePartPath(master.target, relativeTo: directory(of: notesPath))
            guard let document = parts.document(path, root: "p:notesmaster") else { archive.fail(PicoDocsError.fileCorrupted); return nil }
            context.master = document
            context.placeholders = parts.placeholders
        }
        var paragraphs: [String] = []
        func appendNotes(in container: Element, inheritedLink: String? = nil) {
            guard !Task.isCancelled else { return }
            for shape in selectedChildren(in: container, visibleOnly: true) {
                if Task.isCancelled { return }
                let click = shapeClick(shape)
                let link = click == nil ? inheritedLink : hyperlink(click, context: context)
                if shape.tagName().lowercased() == "p:grpsp" {
                    appendNotes(in: shape, inheritedLink: link)
                } else if shape.tagName().lowercased() == "p:sp", placeholderType(of: shape) == "body" {
                    context.defaultLink = link
                    context.runDefaults = inheritedRunDefaults(for: shape, context: context)
                    if let body = textBody(of: shape) {
                        paragraphs += renderParagraphs(body, inherited: inheritedBullets(for: shape, context: context), context: &context)
                    }
                }
            }
        }
        appendNotes(in: tree)
        let text = paragraphs.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Optional core-properties metadata is located by the package relationship.
    static func coreProperties(_ archive: PowerPointPackage) -> (title: String?, author: String?) {
        let properties = relationships(archive, forPart: "").values.filter { $0.isType("/metadata/core-properties") }
        guard properties.count <= 1 else { archive.fail(PicoDocsError.fileCorrupted); return (nil, nil) }
        guard let relation = properties.first else { return (nil, nil) }
        let path = WordConverter.resolvePartPath(relation.target, relativeTo: "")
        guard !relation.external, let core = xml(archive, path: path),
              core.children().first()?.tagName().lowercased() == "cp:coreproperties" else {
            archive.fail(PicoDocsError.fileCorrupted)
            return (nil, nil)
        }
        func value(_ tag: String) -> String? {
            let text = core.children().first().flatMap { selectedChild(of: $0, named: tag) }.map(wholeText)?
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
        var defaultTextStyle: Element?
        var placeholders = PlaceholderCache()
    }

    /// Parses each shared part (layouts, masters) once per deck.
    struct PartCache {
        let archive: PowerPointPackage
        private var documents: [String: Document?] = [:]
        let placeholders = PlaceholderCache()
        private let budget: PowerPointXML.Budget

        init(archive: PowerPointPackage, budget: PowerPointXML.Budget = .init()) {
            self.archive = archive; self.budget = budget
        }

        mutating func document(_ path: String, root: String, cache: Bool = true) -> Document? {
            let parsed: Document?
            if cache, let cached = documents[path] { parsed = cached }
            else {
                parsed = PowerPointConverter.xml(archive, path: path, budget: cache ? budget : nil)
                if cache { documents[path] = parsed }
            }
            guard let parsed, parsed.children().first()?.tagName().lowercased() == root else {
                archive.fail(PicoDocsError.fileCorrupted)
                return nil
            }
            if ["p:sldlayout", "p:sldmaster", "p:notesmaster", "p:handoutmaster"].contains(root) {
                guard let element = parsed.children().first(),
                      let common = PowerPointConverter.selectedChild(of: element, named: "p:csld"),
                      PowerPointConverter.selectedChild(of: common, named: "p:sptree") != nil else {
                    archive.fail(PicoDocsError.fileCorrupted); return nil
                }
            }
            return parsed
        }
    }

    /// The part a relationship of `type` (e.g. "/slideLayout") points to.
    static func relatedPart(of part: String, type: String, relationships: [String: Relationship], archive: PowerPointPackage) -> String? {
        let matches = relationships.values.filter { $0.isType(type) }
        guard matches.count <= 1 else { archive.fail(PicoDocsError.fileCorrupted); return nil }
        guard let relation = matches.first else { return nil }
        guard !relation.external else { archive.fail(PicoDocsError.fileCorrupted); return nil }
        return WordConverter.resolvePartPath(relation.target, relativeTo: directory(of: part))
    }

    /// A slide's title (from its title placeholder) and its other content blocks.
    static func renderSlide(_ slide: Document, context: inout SlideContext) -> (title: String?, blocks: [String]) {
        guard let root = slide.children().first(), root.tagName().lowercased() == "p:sld",
              let common = selectedChild(of: root, named: "p:csld"), let tree = selectedChild(of: common, named: "p:sptree") else {
            context.archive.fail(PicoDocsError.fileCorrupted)
            return (nil, [])
        }
        var title: String?
        var blocks: [String] = []
        renderShapes(in: tree, title: &title, blocks: &blocks, context: &context)
        return (title, blocks)
    }

    private static func isHidden(_ shape: Element) -> Bool {
        let nonvisualNames: Set<String> = ["p:nvsppr", "p:nvpicpr", "p:nvgraphicframepr", "p:nvgrpsppr", "p:nvcxnsppr"]
        guard let properties = selectedChildren(in: shape).first(where: { nonvisualNames.contains($0.tagName().lowercased()) }),
              let common = selectedChildren(in: properties).first(where: { $0.tagName().lowercased() == "p:cnvpr" }) else { return false }
        return isOn(common, "hidden")
    }

    private static func shapeClick(_ shape: Element) -> Element? {
        let names: Set<String> = ["p:nvsppr", "p:nvpicpr", "p:nvgraphicframepr", "p:nvgrpsppr"]
        let properties = selectedChildren(in: shape).first { names.contains($0.tagName().lowercased()) }
        return properties.flatMap { selectedChild(of: $0, named: "p:cnvpr") }.flatMap { selectedChild(of: $0, named: "a:hlinkclick") }
    }

    private static func shapeLink(_ shape: Element, context: SlideContext) -> String? {
        hyperlink(shapeClick(shape), context: context)
    }

    private static func hyperlink(_ click: Element?, context: SlideContext) -> String? {
        guard let id = try? click?.attr("r:id"), !id.isEmpty else { return nil }
        guard let relation = context.relationships[id] else { context.archive.fail(PicoDocsError.fileCorrupted); return nil }
        guard relation.external else { return nil }
        guard relation.isType("/hyperlink") else {
            context.archive.fail(PicoDocsError.fileCorrupted)
            return nil
        }
        return isValidTarget(relation.target, isImage: false) ? relation.target : nil
    }

    /// Placeholder types that are slide furniture, not content.
    private static let skippedPlaceholders: Set<String> = ["dt", "ftr", "sldNum", "hdr", "sldImg"]

    /// Renders a shape tree (or group) in order. The first title placeholder
    /// becomes the slide title; nested groups and markup-compatibility branches
    /// are walked recursively.
    private static func renderShapes(in container: Element, title: inout String?, blocks: inout [String], context: inout SlideContext, inheritedLink: String? = nil) {
        for shape in container.children().array() {
            if Task.isCancelled { return }
            if isHidden(shape) { continue }
            let click = shapeClick(shape)
            context.defaultLink = click == nil ? inheritedLink : hyperlink(click, context: context)
            switch shape.tagName().lowercased() {
            case "p:sp":
                let type = placeholderType(of: shape)
                if let type, skippedPlaceholders.contains(type) { continue }
                guard let body = textBody(of: shape) else { continue }
                context.runDefaults = inheritedRunDefaults(for: shape, context: context)
                if type == "title" || type == "ctrTitle" {
                    let text = normalizedWhitespace(renderParagraphs(body, inherited: noInheritance, context: &context).joined(separator: " "))
                    if title == nil, !text.isEmpty {
                        title = text
                        context.plainTitle = normalizedWhitespace(selectedParagraphs(in: body).map { paragraph in
                            selectedChildren(in: paragraph).map { node in
                                if node.tagName().lowercased() == "a:br" { return " " }
                                guard ["a:r", "a:fld"].contains(node.tagName().lowercased()) else { return "" }
                                return selectedChild(of: node, named: "a:t").map(wholeText) ?? ""
                            }.joined()
                        }.joined(separator: " "))
                        continue
                    }
                    if !text.isEmpty { blocks.append(text) }
                    continue
                }
                let inherited = inheritedBullets(for: shape, context: context)
                let paragraphs = renderParagraphs(body, inherited: inherited, context: &context)
                if !paragraphs.isEmpty { blocks.append(paragraphs.joined(separator: "\n\n")) }
            case "p:graphicframe":
                if let table = selectedDescendant(in: shape, named: "a:tbl") {
                    context.runDefaults = Array(repeating: [], count: 9)
                    let markdown = renderTable(table, context: &context)
                    if !markdown.isEmpty { blocks.append(markdown) }
                } else if let object = selectedDescendant(in: shape, named: "p:oleobj"),
                          let preview = selectedDescendant(in: object, named: "p:pic"), !isHidden(preview),
                          let image = pictureMarkdown(preview, context: &context) { blocks.append(image) }
            case "p:pic":
                if let image = pictureMarkdown(shape, context: &context) { blocks.append(image) }
            case "p:grpsp":
                renderShapes(in: shape, title: &title, blocks: &blocks, context: &context, inheritedLink: context.defaultLink)
            case "mc:alternatecontent":
                if let branch = selectedAlternateBranch(shape) {
                    renderShapes(in: branch, title: &title, blocks: &blocks, context: &context, inheritedLink: inheritedLink)
                }
            default:
                continue
            }
        }
    }

    /// Flatten whitespace without allocating one substring per word.
    static func normalizedWhitespace(_ text: String) -> String {
        var output = "", pendingSpace = false
        for (index, scalar) in text.unicodeScalars.enumerated() {
            if index.isMultiple(of: 4096), Task.isCancelled { return "" }
            if scalar.properties.isWhitespace { pendingSpace = !output.isEmpty }
            else {
                if pendingSpace { output.append(" "); pendingSpace = false }
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    private static func selectedAlternateBranch(_ element: Element) -> Element? {
        let branches = element.children().array()
        return branches.first {
            guard $0.tagName().lowercased() == "mc:choice" else { return false }
            let requires = ((try? $0.attr("Requires")) ?? "").split(separator: " ")
            return !requires.isEmpty && requires.allSatisfy { ["p", "a", "r", "mc", "dc", "dcterms", "dcmitype", "xsi", "cp", "xml"].contains(String($0)) }
        } ?? branches.first { $0.tagName().lowercased() == "mc:fallback" }
    }

    static func selectedDescendant(in element: Element, named name: String) -> Element? {
        guard !Task.isCancelled else { return nil }
        guard !["p:ext", "a:ext"].contains(element.tagName().lowercased()) else { return nil }
        guard !element.tagName().lowercased().hasPrefix("extension"), !element.tagName().lowercased().hasPrefix("requiredextension") else { return nil }
        if name == "a:tbl", element.tagName().lowercased() == "a:graphicdata",
           (try? element.attr("uri")) != "http://schemas.openxmlformats.org/drawingml/2006/table" { return nil }
        if element.tagName().lowercased() == name { return element }
        if element.tagName().lowercased() == "mc:alternatecontent" {
            return selectedAlternateBranch(element).flatMap { selectedDescendant(in: $0, named: name) }
        }
        for child in element.children().array() {
            if let blip = selectedDescendant(in: child, named: name) { return blip }
        }
        return nil
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
        if selectedChild(of: properties, named: "a:bunone") != nil { return .plain }
        if let number = selectedChild(of: properties, named: "a:buautonum") {
            let raw = (try? number.attr("startAt")) ?? ""
            let scheme = (try? number.attr("type")) ?? ""
            return .number(startAt: raw.isEmpty ? 1 : (Int(raw) ?? 0), scheme: scheme.isEmpty ? "arabicPeriod" : scheme)
        }
        if selectedChild(of: properties, named: "a:buchar") != nil || selectedChild(of: properties, named: "a:bublip") != nil {
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
        var sources: [Element?] = [textBody(of: shape).flatMap { selectedChild(of: $0, named: "a:lststyle") }]
        if let placeholder = placeholder(of: shape) {
            let type = ((try? placeholder.attr("type")) ?? "").isEmpty ? "obj" : ((try? placeholder.attr("type")) ?? "")
            let index = (try? placeholder.attr("idx")) ?? ""
            let bodyLike = ["obj", "body", "subTitle"].contains(type)
            if context.layout == nil, context.master == nil {
                // No inheritance chain to read: content placeholders are bulleted.
                fallback = bodyLike && type != "subTitle" ? .bullet : nil
            }
            if let layout = context.layout {
                sources.append(matchingPlaceholder(in: layout, type: type, index: index, cache: context.placeholders).flatMap(listStyle))
            }
            if let master = context.master {
                sources.append(matchingPlaceholder(in: master, type: bodyLike ? "body" : type, index: "", cache: context.placeholders).flatMap(listStyle))
                let style = master.children().first()?.tagName().lowercased() == "p:notesmaster" ? "p:notesStyle" : (bodyLike ? "p:bodyStyle" : (["title", "ctrTitle"].contains(type) ? "p:titleStyle" : "p:otherStyle"))
                sources.append(masterTextStyle(master, named: style))
            }
        }
        sources.append(context.defaultTextStyle)
        return (0..<9).map { level in
            for source in sources {
                if let source, let bullet = bullet(in: selectedChild(of: source, named: "a:lvl\(level + 1)ppr")) ?? bullet(in: selectedChild(of: source, named: "a:defppr")) {
                    return bullet
                }
            }
            return fallback
        }
    }

    /// Run toggles inherit independently through the active paragraph level.
    private static func inheritedRunDefaults(for shape: Element, context: SlideContext) -> [[Element]] {
        var styles: [Element?] = [textBody(of: shape).flatMap { selectedChild(of: $0, named: "a:lststyle") }]
        if let placeholder = placeholder(of: shape) {
            let raw = (try? placeholder.attr("type")) ?? ""
            let type = raw.isEmpty ? "obj" : raw
            let index = (try? placeholder.attr("idx")) ?? ""
            let bodyLike = ["obj", "body", "subTitle"].contains(type)
            if let layout = context.layout { styles.append(matchingPlaceholder(in: layout, type: type, index: index, cache: context.placeholders).flatMap(listStyle)) }
            if let master = context.master {
                styles.append(matchingPlaceholder(in: master, type: bodyLike ? "body" : type, index: "", cache: context.placeholders).flatMap(listStyle))
                let style = master.children().first()?.tagName().lowercased() == "p:notesmaster" ? "p:notesStyle" : (bodyLike ? "p:bodyStyle" : (["title", "ctrTitle"].contains(type) ? "p:titleStyle" : "p:otherStyle"))
                styles.append(masterTextStyle(master, named: style))
            }
        }
        styles.append(context.defaultTextStyle)
        return (0..<9).map { level in
            styles.flatMap { source -> [Element] in
                guard let source else { return [] }
                return [selectedChild(of: source, named: "a:lvl\(level + 1)ppr"), selectedChild(of: source, named: "a:defppr")]
                    .compactMap { $0.flatMap { selectedChild(of: $0, named: "a:defrpr") } }
            }
        }
    }

    private static func masterTextStyle(_ master: Document, named name: String) -> Element? {
        guard let root = master.children().first() else { return nil }
        let container = root.tagName().lowercased() == "p:notesmaster" ? root : selectedChild(of: root, named: "p:txstyles")
        return container.flatMap { selectedChild(of: $0, named: name.lowercased()) }
    }

    /// The placeholder shape in a layout/master matching a slide placeholder: by
    /// `idx` when both have one, else by type (a typeless placeholder is "obj",
    /// which a master provides as "body").
    final class PlaceholderCache {
        private struct Index { var byID: [String: Element] = [:]; var byType: [String: Element] = [:] }
        private var indexes: [ObjectIdentifier: Index] = [:]
        private(set) var buildCount = 0

        func match(in part: Document, type: String, index: String) -> Element? {
            guard !Task.isCancelled else { return nil }
            let key = ObjectIdentifier(part)
            if indexes[key] == nil {
                var result = Index()
                func collect(_ container: Element) {
                    guard !Task.isCancelled else { return }
                    for element in container.children().array() {
                        if Task.isCancelled { return }
                        switch element.tagName().lowercased() {
                        case "p:sp":
                            guard let ph = PowerPointConverter.placeholder(of: element) else { continue }
                            let id = (try? ph.attr("idx")) ?? ""
                            let raw = (try? ph.attr("type")) ?? ""
                            let kind = raw.isEmpty ? "obj" : raw
                            let equivalent = ["title", "ctrTitle"].contains(kind) ? "title" : (["body", "obj"].contains(kind) ? "body" : kind)
                            if !id.isEmpty, result.byID[id] == nil { result.byID[id] = element }
                            if result.byType[equivalent] == nil { result.byType[equivalent] = element }
                        case "p:grpsp": collect(element)
                        case "mc:alternatecontent": if let selected = PowerPointConverter.selectedAlternateBranch(element) { collect(selected) }
                        default: break
                        }
                    }
                }
                if let root = part.children().first(), let common = PowerPointConverter.selectedChild(of: root, named: "p:csld"),
                   let tree = PowerPointConverter.selectedChild(of: common, named: "p:sptree") { collect(tree) }
                guard !Task.isCancelled else { return nil }
                indexes[key] = result; buildCount += 1
            }
            let equivalent = ["title", "ctrTitle"].contains(type) ? "title" : (["body", "obj"].contains(type) ? "body" : type)
            return index.isEmpty ? indexes[key]?.byType[equivalent] : indexes[key]?.byID[index]
        }
    }

    private static func matchingPlaceholder(in part: Document, type: String, index: String, cache: PlaceholderCache) -> Element? {
        cache.match(in: part, type: type, index: index)
    }

    private static func listStyle(_ shape: Element) -> Element? {
        textBody(of: shape).flatMap { selectedChild(of: $0, named: "a:lststyle") }
    }

    private static func placeholder(of shape: Element) -> Element? {
        selectedChild(of: shape, named: "p:nvsppr").flatMap { selectedChild(of: $0, named: "p:nvpr") }.flatMap { selectedChild(of: $0, named: "p:ph") }
    }

    private static func textBody(of shape: Element) -> Element? {
        selectedChildren(in: shape).first { $0.tagName().lowercased() == "p:txbody" }
    }

    // MARK: - Paragraphs and lists

    private static func selectedChildren(in container: Element, descendingInto groups: Set<String> = [], visibleOnly: Bool = false) -> [Element] {
        guard !Task.isCancelled else { return [] }
        var children: [Element] = []
        var pending = Array(container.children().array().reversed())
        while let element = pending.popLast() {
            if Task.isCancelled { return [] }
            let tag = element.tagName().lowercased()
            if tag.hasPrefix("extension") || tag.hasPrefix("requiredextension") || (visibleOnly && isHidden(element)) { continue }
            if tag == "mc:alternatecontent" {
                if let branch = selectedAlternateBranch(element) { pending += branch.children().array().reversed() }
            } else if groups.contains(tag) { pending += element.children().array().reversed() }
            else { children.append(element) }
        }
        return children
    }

    private static func selectedChild(of container: Element, named name: String) -> Element? {
        selectedChildren(in: container).first { $0.tagName().lowercased() == name }
    }

    private static func selectedParagraphs(in body: Element) -> [Element] {
        selectedChildren(in: body).filter { $0.tagName().lowercased() == "a:p" }
    }

    /// Renders a text body's paragraphs to Markdown blocks. Consecutive list items
    /// are joined tight into one block; a nested item is indented under its parent
    /// (by the parent marker's width), and numbered lists count per level,
    /// honoring `startAt`.
    static func renderParagraphs(_ body: Element, inherited: [Bullet?], context: inout SlideContext) -> [String] {
        var blocks: [String] = []
        var listLines: [String] = []
        var markerWidths: [Int] = []          // marker width per open level
        var schemes: [Int: String] = [:]
        var starts: [Int: Int] = [:]
        var counters: [Int: Int] = [:]        // numbered-list count per level
        var baseLevel = 0                     // shallowest level in the current list

        func flushList() {
            if !listLines.isEmpty { blocks.append(listLines.joined(separator: "\n")) }
            listLines = []; markerWidths = []; counters = [:]; schemes = [:]; starts = [:]
        }

        for paragraph in selectedParagraphs(in: body) {
            if Task.isCancelled { return [] }
            let properties = selectedChild(of: paragraph, named: "a:ppr")
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
                let explicitStart = properties.flatMap { selectedChild(of: $0, named: "a:buautonum") }.flatMap { try? $0.attr("startAt") }.flatMap(Int.init)
                if schemes[level] != scheme { counters[level] = nil; starts[level] = nil }
                if explicitStart != nil && starts[level] != start { counters[level] = nil }
                if starts[level] == nil || explicitStart != nil { starts[level] = start }
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
            starts = starts.filter { $0.key <= level }
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
        let paragraphProperties = selectedChild(of: paragraph, named: "a:ppr")
        let level = min(max(Int((try? paragraphProperties?.attr("lvl")) ?? "") ?? 0, 0), 8)
        let defaults = [paragraphProperties.flatMap { selectedChild(of: $0, named: "a:defrpr") }].compactMap { $0 } + context.runDefaults[level]
        for node in selectedChildren(in: paragraph) {
            if Task.isCancelled { return "" }
            switch node.tagName().lowercased() {
            case "a:r", "a:fld":
                let properties = selectedChild(of: node, named: "a:rpr")
                let text = escapeMarkdown(selectedChild(of: node, named: "a:t").map(wholeText) ?? "")
                guard !text.isEmpty else { continue }
                let click = properties.flatMap { selectedChild(of: $0, named: "a:hlinkclick") }
                let link = hyperlink(click, context: context)
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

    static func escapeBlockMarkers(_ text: String) -> String {
        var output = ""
        func appendLine(_ slice: Substring) {
            guard !slice.isEmpty else { return }
            let line = String(slice)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.unicodeScalars.first, "#-+|0123456789".unicodeScalars.contains(first) else { output += line; return }
            if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "-" || $0 == " " }) {
                output += line.replacingOccurrences(of: "-", with: "\\-")
                return
            }
            output += line.replacingOccurrences(of: #"^(\s*)(#{1,6}|[-+]|\|)(?=\s|$)"#, with: #"$1\\$2"#, options: .regularExpression)
                .replacingOccurrences(of: #"^(\s*)([0-9]+)([.)])(?=\s|$)"#, with: #"$1$2\\$3"#, options: .regularExpression)
                .replacingOccurrences(of: #"^(\s*)\|"#, with: #"$1\\|"#, options: .regularExpression)
        }
        var start = text.startIndex
        for index in text.unicodeScalars.indices where text.unicodeScalars[index] == "\n" {
            appendLine(text[start..<index]); output.append("\n")
            start = text.unicodeScalars.index(after: index)
        }
        appendLine(text[start...])
        return output
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

    private static func isValidTarget(_ url: String, isImage: Bool) -> Bool {
        !url.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) })
            && DocumentRenderer.isSafeURL(url, isImage: isImage)
    }

    private static func linkDestination(_ url: String) -> String {
        var encoded = ""
        for scalar in url.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
                || "<>[]()\\\"`".unicodeScalars.contains(scalar) {
                for byte in String(scalar).utf8 { encoded += String(format: "%%%02X", byte) }
            } else { encoded.unicodeScalars.append(scalar) }
        }
        return encoded
    }

    // MARK: - Tables

    /// A DrawingML table as a Markdown pipe table. Every grid cell is present in
    /// PPTX (merged-away cells carry `hMerge`/`vMerge`), so rows stay aligned;
    /// merged-away cells render empty.
    static func renderTable(_ table: Element, context: inout SlideContext) -> String {
        var rows: [[String]] = []
        for row in selectedChildren(in: table) where row.tagName().lowercased() == "a:tr" {
            if Task.isCancelled { return "" }
            var cells: [String] = []
            for cell in selectedChildren(in: row) where cell.tagName().lowercased() == "a:tc" {
                let merged = isOn(cell, "hMerge") || isOn(cell, "vMerge")
                var text = ""
                if !merged, let body = textBody(ofCell: cell) {
                    let style = selectedChild(of: body, named: "a:lststyle")
                    let styles = [style, context.defaultTextStyle].compactMap { $0 }
                    let inherited = (0..<9).map { level -> Bullet? in
                        for style in styles {
                            if let value = bullet(in: selectedChild(of: style, named: "a:lvl\(level + 1)ppr")) ?? bullet(in: selectedChild(of: style, named: "a:defppr")) { return value }
                        }
                        return nil
                    }
                    context.runDefaults = (0..<9).map { level in
                        styles.flatMap { style in
                            [selectedChild(of: style, named: "a:lvl\(level + 1)ppr"), selectedChild(of: style, named: "a:defppr")]
                                .compactMap { $0.flatMap { selectedChild(of: $0, named: "a:defrpr") } }
                        }
                    }
                    text = renderParagraphs(body, inherited: inherited, context: &context).joined(separator: "\n")
                }
                cells.append(MarkdownTableCell.escapeCanonicalPipes(text).replacingOccurrences(of: "\n", with: "<br>"))
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
        selectedChildren(in: cell).first { $0.tagName().lowercased() == "a:txbody" }
    }

    // MARK: - Pictures

    /// An inline image reference for a picture (alt text from `descr`, then
    /// `title`, then `name`), registering its bytes as an `.image` section.
    static func pictureMarkdown(_ picture: Element, context: inout SlideContext) -> String? {
        guard let fill = selectedChildren(in: picture).first(where: { $0.tagName().lowercased() == "p:blipfill" }),
              let blip = selectedDescendant(in: fill, named: "a:blip") else { return nil }
        let embedded = (try? blip.attr("r:embed")) ?? ""
        let linked = (try? blip.attr("r:link")) ?? ""
        let id = embedded.isEmpty ? linked : embedded
        guard !id.isEmpty else { return nil }
        guard let relation = context.relationships[id], relation.isType("/image"),
              relation.external == embedded.isEmpty else { context.archive.fail(PicoDocsError.fileCorrupted); return nil }
        let source: String
        if embedded.isEmpty {
            guard isValidTarget(relation.target, isImage: true) else { return nil }
            source = relation.target
        } else {
            let mediaPath = WordConverter.resolvePartPath(relation.target, relativeTo: directory(of: context.partPath))
            let filename = (mediaPath as NSString).lastPathComponent
            source = context.embedsImages
                ? (context.images.add(path: mediaPath, filename: filename, archive: context.archive) ?? filename)
                : filename
        }
        let properties = selectedChild(of: picture, named: "p:nvpicpr").flatMap { selectedChild(of: $0, named: "p:cnvpr") }
        let description = (try? properties?.attr("descr")) ?? ""
        let title = (try? properties?.attr("title")) ?? ""
        let name = (try? properties?.attr("name")) ?? ""
        let alt = [description, title, name].first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? "image"
        let label = escapeMarkdown(normalizedWhitespace(alt))
        let image = "![\(label)](\(linkDestination(source)))"
        let click = properties.flatMap { selectedChild(of: $0, named: "a:hlinkclick") }
        if let target = click == nil ? context.defaultLink : hyperlink(click, context: context) { return "[\(image)](\(linkDestination(target)))" }
        return image
    }

    /// Collects each embedded image once (by archive path) as an `.image` section.
    final class ImageCollector {
        private(set) var sections: [DocumentSection] = []
        private var references: [String: String] = [:]
        private var usedReferences: Set<String>
        private var nextReference = 0

        private var remainingEncodedBytes: Int

        init(reservedReferences: Set<String> = [], maximumEncodedBytes: Int = 32 * 1024 * 1024) {
            usedReferences = reservedReferences
            remainingEncodedBytes = max(0, maximumEncodedBytes)
        }

        @discardableResult
        func add(path: String, filename: String, archive: PowerPointPackage) -> String? {
            if let existing = references[path] { return existing }
            // Base64 consumes four bytes for every three source bytes. Check the
            // declared size before inflating, then charge the verified byte count.
            guard let entry = archive.archive[path], entry.uncompressedSize <= UInt64(remainingEncodedBytes / 4 * 3) else {
                archive.fail(PicoDocsError.fileCorrupted); return nil
            }
            guard let bytes = archive.read(path), !bytes.isEmpty else {
                archive.fail(PicoDocsError.fileCorrupted)
                return nil
            }
            let encodedBytes = ((bytes.count + 2) / 3) * 4
            guard encodedBytes <= remainingEncodedBytes else { archive.fail(PicoDocsError.fileCorrupted); return nil }
            remainingEncodedBytes -= encodedBytes
            var reference = filename
            while usedReferences.contains(PowerPointConverter.linkDestination(reference)) {
                nextReference += 1
                reference = "picodocs-embedded/\(nextReference)/" + filename
            }
            let emitted = PowerPointConverter.linkDestination(reference)
            usedReferences.insert(emitted); references[path] = reference
            sections.append(DocumentSection(
                title: filename,
                kind: .image,
                markdown: "![\(PowerPointConverter.escapeMarkdown(filename))](\(emitted))",
                sourcePath: path,
                metadata: [
                    "mimeType": PowerPointConverter.contentType(path, archive: archive) ?? PowerPointConverter.mimeType(forExtension: (filename as NSString).pathExtension),
                    "base64": bytes.base64EncodedString(),
                    "markdownReference": emitted,
                ]
            ))
            return reference
        }
    }

    static func contentType(_ path: String, archive: PowerPointPackage) -> String? {
        if archive.contentTypes == nil {
            var types: [String: String] = [:]
            guard let manifest = xml(archive, path: "[Content_Types].xml"),
                  let root = manifest.children().first(), root.tagName().lowercased() == "types" else {
                archive.fail(PicoDocsError.fileCorrupted); return nil
            }
            for entry in root.children().array() {
                let key: String
                switch entry.tagName().lowercased() {
                case "override":
                    guard let name = try? entry.attr("PartName"), name.hasPrefix("/"), name.count > 1 else { archive.fail(PicoDocsError.fileCorrupted); return nil }
                    key = name
                case "default":
                    guard let ext = try? entry.attr("Extension"), !ext.isEmpty else { archive.fail(PicoDocsError.fileCorrupted); return nil }
                    key = "." + ext.lowercased()
                default: archive.fail(PicoDocsError.fileCorrupted); return nil
                }
                guard entry.children().isEmpty(), let type = validatedMIME(try? entry.attr("ContentType")), types[key] == nil else { archive.fail(PicoDocsError.fileCorrupted); return nil }
                types[key] = type
            }
            archive.contentTypes = types
        }
        return archive.contentTypes?["/" + path] ?? archive.contentTypes?["." + (path as NSString).pathExtension.lowercased()]
    }

    private static let mediaTypePattern: NSRegularExpression = {
        let token = #"[A-Za-z0-9!#$%&'*+.^_`|~-]+"#
        let quoted = #""(?:[\x20-\x21\x23-\x5B\x5D-\x7E\x80-\xFF]|\\[\x20-\x7E])*""#
        return try! NSRegularExpression(pattern: "\\A" + token + "/" + token + "(?:[ \t]*;[ \t]*" + token + "=(?:" + token + "|" + quoted + "))*\\z")
    }()

    private static func validatedMIME(_ value: String?) -> String? {
        guard let value, mediaTypePattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil else { return nil }
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

        func isType(_ suffix: String) -> Bool {
            if suffix == "/metadata/core-properties" {
                return type == "http://schemas.openxmlformats.org/package/2006/relationships" + suffix
            }
            return type == "http://schemas.openxmlformats.org/officeDocument/2006/relationships" + suffix
                || type == "http://purl.oclc.org/ooxml/officeDocument/relationships" + suffix
        }
    }

    /// A part's relationships (`<dir>/_rels/<file>.rels`), keyed by id.
    static func relationships(_ archive: PowerPointPackage, forPart part: String) -> [String: Relationship] {
        if let cached = archive.relationshipMaps[part] { return cached }
        guard archive.reserveRelationshipMap(part) else { return [:] }
        let parent = directory(of: part)
        let relsPath = (parent.isEmpty ? "" : parent + "/") + "_rels/\((part as NSString).lastPathComponent).rels"
        guard let document = xml(archive, path: relsPath) else {
            if archive.archive[relsPath] != nil { archive.fail(PicoDocsError.fileCorrupted) }
            archive.relationshipMaps[part] = [:]
            return [:]
        }
        guard document.children().first()?.tagName().lowercased() == "relationships" else {
            archive.fail(PicoDocsError.fileCorrupted)
            return [:]
        }
        var map: [String: Relationship] = [:]
        for element in document.children().first()?.children().array() ?? [] {
            guard element.tagName().lowercased() == "relationship", element.children().isEmpty() else {
                archive.fail(PicoDocsError.fileCorrupted); return [:]
            }
            guard let id = try? element.attr("Id"), let target = try? element.attr("Target"),
                  !id.isEmpty, !target.isEmpty, let type = try? element.attr("Type"), !type.isEmpty else { archive.fail(PicoDocsError.fileCorrupted); return [:] }
            guard map[id] == nil else { archive.fail(PicoDocsError.fileCorrupted); return [:] }
            let mode = (try? element.attr("TargetMode")) ?? ""
            guard !element.hasAttr("TargetMode") || ["Internal", "External"].contains(mode) else { archive.fail(PicoDocsError.fileCorrupted); return [:] }
            // Bound allocation in this validation and subsequent path resolution.
            guard target.utf8.count <= 32 * 1024 else { archive.fail(PicoDocsError.fileCorrupted); return [:] }
            let external = mode == "External"
            if !external {
                var depth = target.hasPrefix("/") ? 0 : directory(of: part).split(separator: "/").count
                for segment in target.split(separator: "/") {
                    if segment == ".." {
                        guard depth > 0 else { archive.fail(PicoDocsError.fileCorrupted); return [:] }
                        depth -= 1
                    } else if segment != "." { depth += 1 }
                }
            }
            guard archive.reserveRelationship(id: id, type: type, target: target) else { return [:] }
            map[id] = Relationship(type: type, target: target, external: external)
        }
        archive.relationshipMaps[part] = map
        return map
    }

    private static func directory(of part: String) -> String {
        (part as NSString).deletingLastPathComponent
    }

    /// Reads and parses an XML part, or nil when missing/unreadable.
    static func xml(_ archive: PowerPointPackage, path: String, budget: PowerPointXML.Budget? = nil) -> Document? {
        guard let data = archive.read(path),
              let text = PowerPointXML.normalize(data, budget: budget) else { return nil }
        guard let document = try? SwiftSoup.parse(text, "", SwiftSoup.Parser.xmlParser()) else { return nil }
        // MustUnderstand applies to the processed tree, excluding ignored extension
        // subtrees and unselected AlternateContent branches.
        var pending = document.children().array().map { ($0, false) }
        while let (element, allowsUnknown) = pending.popLast() {
            let tag = element.tagName().lowercased()
            if tag.hasPrefix("requiredextension") {
                if allowsUnknown { continue }
                archive.fail(PicoDocsError.fileCorrupted); return nil
            }
            if tag.hasPrefix("extension") || tag == "p:ext" || tag == "a:ext" { continue }
            if element.getAttributes()?.asList().contains(where: { $0.getKey().hasPrefix("requiredextension") }) == true {
                archive.fail(PicoDocsError.fileCorrupted); return nil
            }
            let required = ((try? element.attr("mc:MustUnderstand")) ?? "").split(whereSeparator: \.isWhitespace)
            if required.contains("unsupported") { archive.fail(PicoDocsError.fileCorrupted); return nil }
            if tag == "mc:alternatecontent" {
                if let selected = selectedAlternateBranch(element) { pending.append((selected, allowsUnknown)) }
            } else {
                let childAllowsUnknown = tag == "a:graphicdata" || ((tag == "mc:choice" || tag == "mc:fallback") && allowsUnknown)
                pending += element.children().array().map { ($0, childAllowsUnknown) }
            }
        }
        return document
    }

    /// Raw text of an element's text nodes, preserving significant whitespace
    /// (SwiftSoup's `text()` collapses it).
    private static func wholeText(_ element: Element) -> String {
        element.getChildNodes().compactMap { ($0 as? TextNode)?.getWholeText() }.joined()
    }


}
