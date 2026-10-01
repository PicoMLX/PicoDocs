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

    private let maximumRenderedBytes: Int

    public init() { maximumRenderedBytes = 64 * 1024 * 1024 }
    init(maximumRenderedBytes: Int) { self.maximumRenderedBytes = max(0, maximumRenderedBytes) }

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
        let presentationPath = Self.resolvePartPath(officeDocument.target, relativeTo: "")
        guard let presentation = Self.xml(archive, path: presentationPath), presentation.children().first()?.tagName().lowercased() == "p:presentation" else {
            try archive.check()
            throw PicoDocsError.fileCorrupted
        }

        let defaultTextStyle = presentation.children().first().flatMap { Self.selectedChild(of: $0, named: "p:defaulttextstyle") }
        var sections: [DocumentSection] = []
        var remainingRenderedBytes = maximumRenderedBytes
        var activeBudget: RenderBudget?
        var activeFixedBytes = 0
        var activeCopies = 1
        func charge(_ text: String?) throws {
            let bytes = text?.utf8.count ?? 0
            guard bytes <= remainingRenderedBytes else { throw PicoDocsError.fileCorrupted }
            remainingRenderedBytes -= bytes
        }
        func chargeSection(_ section: DocumentSection) throws {
            try charge(section.markdown); try charge(section.title); try charge(section.sourcePath)
            for (key, value) in section.metadata where key != "base64" { try charge(key); try charge(value) }
        }
        let properties = Self.coreProperties(archive)
        try charge(properties.title ?? info.filename); try charge(properties.author)
        let slidePaths = try Self.slidePaths(presentation, archive: archive, presentationPath: presentationPath)
        // Reserve all external image destinations first, including later slides,
        // so embedded references cannot claim an external occurrence's src.
        var externalReferences: Set<String> = []
        var pendingParts = Array(Set(slidePaths)), visitedParts: Set<String> = []
        while let path = pendingParts.popLast() {
            try Task.checkCancellation()
            guard visitedParts.insert(path).inserted else { continue }
            for relation in Self.relationships(archive, forPart: path).values {
                if relation.external && relation.isType("/image") {
                    externalReferences.insert(Self.linkDestination(relation.target))
                } else if !relation.external, ["/slideLayout", "/slideMaster", "/notesSlide", "/notesMaster"].contains(where: relation.isType) {
                    pendingParts.append(Self.resolvePartPath(relation.target, relativeTo: Self.directory(of: path)))
                }
            }
        }
        let images = ImageCollector(reservedReferences: externalReferences, reserveCarrierBytes: { bytes in
            let retained = activeFixedBytes + activeCopies * (activeBudget?.retainedContentBytes ?? 0)
            guard bytes <= remainingRenderedBytes - retained else { archive.fail(PicoDocsError.fileCorrupted); return false }
            remainingRenderedBytes -= bytes
            return true
        })
        var parts = PartCache(archive: archive)
        parts.styles.register(presentation)
        for (index, slidePath) in slidePaths.enumerated() {
            try Task.checkCancellation()
            guard let slide = parts.document(slidePath, root: "p:sld", cache: false), slide.children().first()?.tagName().lowercased() == "p:sld" else { try archive.check(); throw PicoDocsError.fileCorrupted }
            let relationships = Self.relationships(archive, forPart: slidePath)
            var context = SlideContext(archive: archive, partPath: slidePath, relationships: relationships, images: images)
            let renderBudget = RenderBudget(maximumBytes: remainingRenderedBytes - slidePath.utf8.count, archive: archive,
                                            liveMaximum: { remainingRenderedBytes - slidePath.utf8.count })
            activeBudget = renderBudget; activeFixedBytes = slidePath.utf8.count; activeCopies = 1
            context.renderBudget = renderBudget
            context.defaultTextStyle = defaultTextStyle
            context.placeholders = parts.placeholders
            context.shapeBudget = parts.shapeBudget
            context.styles = StyleChildCache(shared: parts.styles)
            // Layout and master supply inherited list formatting for placeholders.
            let layoutPath = Self.relatedPart(of: slidePath, type: "/slideLayout", relationships: relationships, archive: archive)
            context.layoutPath = layoutPath
            context.layout = layoutPath.flatMap { parts.document($0, root: "p:sldlayout") }
            context.masterPath = layoutPath
                .flatMap { Self.relatedPart(of: $0, type: "/slideMaster", relationships: Self.relationships(archive, forPart: $0), archive: archive) }
            context.master = context.masterPath.flatMap { parts.document($0, root: "p:sldmaster") }
            let rendered = Self.renderSlide(slide, context: &context)
            try archive.check()
            let slideBlocks = (rendered.title.map { [renderBudget.join(["## ", $0])] } ?? []) + rendered.blocks
            let slideText = renderBudget.join(slideBlocks, separator: "\n\n")
            try archive.check()
            // Notes survive twice: in Markdown and in metadata. Reserve both copies,
            // their heading/key/separator, and the already retained section fields.
            let fixedBytes = slideText.utf8.count + (context.plainTitle?.utf8.count ?? 0) + slidePath.utf8.count
            let notesOverhead = "### Notes\n\n".utf8.count + "notes".utf8.count + (slideText.isEmpty ? 0 : 2)
            let notesBudget = RenderBudget(maximumBytes: max(0, remainingRenderedBytes - fixedBytes - notesOverhead) / 2, archive: archive,
                                           liveMaximum: { max(0, remainingRenderedBytes - fixedBytes - notesOverhead) / 2 })
            activeBudget = notesBudget; activeFixedBytes = fixedBytes + notesOverhead; activeCopies = 2
            let notes = Self.notes(forSlide: slidePath, relationships: relationships, archive: archive, parts: &parts,
                                   renderBudget: notesBudget, defaultTextStyle: defaultTextStyle, images: images)
            activeBudget = nil; activeFixedBytes = 0; activeCopies = 1

            var blocks: [String] = []
            if !slideText.isEmpty { blocks.append(slideText) }
            if let notes { blocks.append(renderBudget.join(["### Notes\n\n", notes])) }
            try archive.check()
            guard !blocks.isEmpty else { continue }   // empty slide: keep its number, emit nothing

            let section = DocumentSection(
                title: context.plainTitle,
                kind: .slide,
                markdown: renderBudget.join(blocks, separator: "\n\n"),
                sourcePath: slidePath,
                slideNumber: index + 1,
                metadata: notes.map { ["notes": $0] } ?? [:]
            )
            try archive.check()
            try chargeSection(section)
            sections.append(section)
        }
        sections += images.sections
        try archive.check()
        guard sections.contains(where: { $0.kind != .image }) else { throw PicoDocsError.emptyDocument }

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
            let path = resolved[target] ?? Self.resolvePartPath(target, relativeTo: directory(of: presentationPath))
            guard path.utf8.count <= remainingPathBytes else { throw PicoDocsError.fileCorrupted }
            remainingPathBytes -= path.utf8.count
            resolved[target] = path
            paths.append(path)
        }
        return paths
    }

    /// Visible Notes Page content, including inherited non-placeholder master shapes.
    static func notes(forSlide slidePath: String, relationships: [String: Relationship], archive: PowerPointPackage, parts: inout PartCache, renderBudget: RenderBudget? = nil, defaultTextStyle: Element? = nil, images: ImageCollector? = nil) -> String? {
        let noteRelations = relationshipsOfType("/notesSlide", archive: archive, part: slidePath, map: relationships)
        guard noteRelations.count <= 1 else { archive.fail(PicoDocsError.fileCorrupted); return nil }
        guard let relation = noteRelations.first else { return nil }
        guard !relation.external else { archive.fail(PicoDocsError.fileCorrupted); return nil }
        let target = relation.target
        let notesPath = Self.resolvePartPath(target, relativeTo: directory(of: slidePath))
        guard let notes = parts.document(notesPath, root: "p:notes", cache: false) else { archive.fail(PicoDocsError.fileCorrupted); return nil }
        guard let root = notes.children().first(), let common = selectedChild(of: root, named: "p:csld"),
              let tree = selectedChild(of: common, named: "p:sptree") else { archive.fail(PicoDocsError.fileCorrupted); return nil }
        var context = SlideContext(archive: archive, partPath: notesPath,
                                   relationships: Self.relationships(archive, forPart: notesPath),
                                   images: images ?? ImageCollector(), embedsImages: images != nil)
        context.renderBudget = renderBudget
        context.defaultTextStyle = defaultTextStyle
        context.styles = StyleChildCache(shared: parts.styles)
        context.shapeBudget = parts.shapeBudget
        let notesRels = Self.relationships(archive, forPart: notesPath)
        let backlinks = relationshipsOfType("/slide", archive: archive, part: notesPath, map: notesRels)
        guard backlinks.count == 1, let backlink = backlinks.first, !backlink.external,
              Self.resolvePartPath(backlink.target, relativeTo: directory(of: notesPath)) == slidePath else {
            archive.fail(PicoDocsError.fileCorrupted); return nil
        }
        let masters = relationshipsOfType("/notesMaster", archive: archive, part: notesPath, map: notesRels)
        guard masters.count <= 1 else { archive.fail(PicoDocsError.fileCorrupted); return nil }
        if let master = masters.first {
            guard !master.external else { archive.fail(PicoDocsError.fileCorrupted); return nil }
            let path = Self.resolvePartPath(master.target, relativeTo: directory(of: notesPath))
            guard let document = parts.document(path, root: "p:notesmaster") else { archive.fail(PicoDocsError.fileCorrupted); return nil }
            context.master = document
            context.masterPath = path
            context.placeholders = parts.placeholders
            context.styles = StyleChildCache(shared: parts.styles)
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
                } else if shape.tagName().lowercased() == "p:sp" {
                    if let type = placeholderType(of: shape, cache: context.styles), skippedPlaceholders.contains(type) { continue }
                    context.defaultLink = link
                    if let image = pictureMarkdown(shape, context: &context) { context.appendBlock(image, to: &paragraphs) }
                    context.runDefaults = inheritedRunDefaults(for: shape, context: context)
                    if let body = textBody(of: shape) {
                        let rendered = renderParagraphs(body, inherited: inheritedBullets(for: shape, context: context), context: &context)
                        for paragraph in rendered { context.appendBlock(paragraph, to: &paragraphs) }
                    }
                } else if shape.tagName().lowercased() == "p:graphicframe" {
                    context.defaultLink = link
                    if let table = selectedDescendant(in: shape, named: "a:tbl") {
                        context.runDefaults = Array(repeating: [], count: 9)
                        let text = renderTable(table, context: &context)
                        if !text.isEmpty { context.appendBlock(text, to: &paragraphs) }
                    } else if let object = selectedDescendant(in: shape, named: "p:oleobj"),
                              let preview = selectedDescendant(in: object, named: "p:pic"), !isHidden(preview),
                              let image = pictureMarkdown(preview, context: &context) { context.appendBlock(image, to: &paragraphs) }
                } else if shape.tagName().lowercased() == "p:pic" {
                    context.defaultLink = link
                    if let image = pictureMarkdown(shape, context: &context) { context.appendBlock(image, to: &paragraphs) }
                }
            }
        }
        if !["0", "false"].contains(booleanValue((try? root.attr("showMasterSp")) ?? "")),
           let master = context.master, let path = context.masterPath,
           let masterRoot = master.children().first(),
           let common = context.styles.child(of: masterRoot, named: "p:csld"),
           let masterTree = context.styles.child(of: common, named: "p:sptree") {
            var masterContext = context
            masterContext.partPath = path
            masterContext.relationships = Self.relationships(archive, forPart: path)
            var ignoredTitle: String?
            renderShapes(in: masterTree, title: &ignoredTitle, blocks: &paragraphs, context: &masterContext, inheritedOnly: true)
            context.renderedBlockBytes = masterContext.renderedBlockBytes
        }
        appendNotes(in: tree)
        let text = (renderBudget?.join(paragraphs, separator: "\n\n") ?? paragraphs.joined(separator: "\n\n")).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Optional core-properties metadata is located by the package relationship.
    static func coreProperties(_ archive: PowerPointPackage) -> (title: String?, author: String?) {
        let properties = relationships(archive, forPart: "").values.filter { $0.isType("/metadata/core-properties") }
        guard properties.count <= 1 else { archive.fail(PicoDocsError.fileCorrupted); return (nil, nil) }
        guard let relation = properties.first else { return (nil, nil) }
        let path = Self.resolvePartPath(relation.target, relativeTo: "")
        guard !relation.external, let core = xml(archive, path: path, maximumBytes: 1024 * 1024),
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

    final class RenderBudget {
        private let initialMaximum: Int
        private let liveMaximum: (() -> Int)?
        var maximumBytes: Int { max(0, min(initialMaximum, liveMaximum?() ?? initialMaximum)) }
        var retainedContentBytes = 0
        let archive: PowerPointPackage
        private var overLimit = false
        var failed: Bool { overLimit || archive.failure != nil }
        init(maximumBytes: Int, archive: PowerPointPackage, liveMaximum: (() -> Int)? = nil) {
            self.initialMaximum = max(0, maximumBytes); self.archive = archive; self.liveMaximum = liveMaximum
        }
        func admit(_ bytes: Int, retained: inout Int) -> Bool {
            guard !failed, bytes >= 0, bytes <= maximumBytes - retained else {
                overLimit = true; archive.fail(PicoDocsError.fileCorrupted); return false
            }
            retained += bytes; return true
        }
        func fits(_ bytes: Int) -> Bool {
            var retained = 0
            return admit(bytes, retained: &retained)
        }
        func join(_ fragments: [String], separator: String = "") -> String {
            var bytes = 0
            for (index, fragment) in fragments.enumerated() {
                if index > 0, !admit(separator.utf8.count, retained: &bytes) { return "" }
                guard admit(fragment.utf8.count, retained: &bytes) else { return "" }
            }
            return fragments.joined(separator: separator)
        }
        func append(_ fragment: String, to output: inout String) -> Bool {
            var bytes = output.utf8.count
            guard admit(fragment.utf8.count, retained: &bytes) else { return false }
            output.append(contentsOf: fragment); return true
        }
        func replaceNewlines(_ text: String, with replacement: String) -> String {
            var bytes = text.utf8.count
            guard fits(bytes) else { return "" }
            let growth = max(0, replacement.utf8.count - 1)
            for scalar in text.unicodeScalars where scalar == "\n" {
                guard admit(growth, retained: &bytes) else { return "" }
            }
            return text.replacingOccurrences(of: "\n", with: replacement)
        }
    }

    /// Per-part rendering state: where relationship targets resolve from, and the
    /// images collected so far (shared across the deck so each is emitted once).
    struct SlideContext {
        let archive: PowerPointPackage
        var partPath: String
        var relationships: [String: Relationship]
        var images: ImageCollector
        var renderBudget: RenderBudget? = nil
        var shapeBudget: ShapeBudget? = nil
        var renderedBlockBytes = 0
        mutating func appendBlock(_ text: String, to blocks: inout [String]) {
            if let renderBudget {
                guard renderBudget.admit(text.utf8.count + (blocks.isEmpty && plainTitle == nil ? 0 : 2), retained: &renderedBlockBytes) else { return }
                renderBudget.retainedContentBytes = renderedBlockBytes
            }
            blocks.append(text)
        }
        var embedsImages = true
        var defaultLink: String?
        var plainTitle: String?
        var runDefaults: [[Element]] = Array(repeating: [], count: 9)
        /// The slide's layout and master parts, when resolvable.
        var layout: Document?
        var master: Document?
        var layoutPath: String?
        var masterPath: String?
        var defaultTextStyle: Element?
        var placeholders = PlaceholderCache()
        var styles = StyleChildCache()
    }

    /// Caches shared parts and charges every slide/notes parse to one deck budget.
    struct PartCache {
        let archive: PowerPointPackage
        private var documents: [String: Document?] = [:]
        let placeholders = PlaceholderCache()
        let styles = StyleChildCache()
        let shapeBudget = ShapeBudget()
        private let budget: PowerPointXML.Budget

        init(archive: PowerPointPackage, budget: PowerPointXML.Budget = .init()) {
            self.archive = archive; self.budget = budget
        }

        mutating func document(_ path: String, root: String, cache: Bool = true) -> Document? {
            let parsed: Document?
            if cache, let cached = documents[path] { parsed = cached }
            else {
                parsed = PowerPointConverter.xml(archive, path: path, budget: budget)
                if cache { documents[path] = parsed; if let parsed { styles.register(parsed) } }
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
        let matches = relationshipsOfType(type, archive: archive, part: part, map: relationships)
        guard matches.count <= 1 else { archive.fail(PicoDocsError.fileCorrupted); return nil }
        guard let relation = matches.first else { return nil }
        guard !relation.external else { archive.fail(PicoDocsError.fileCorrupted); return nil }
        return Self.resolvePartPath(relation.target, relativeTo: directory(of: part))
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
        let backgroundOwners = [(common, Optional(context.partPath)),
                                (context.layout?.children().first().flatMap { context.styles.child(of: $0, named: "p:csld") }, context.layoutPath),
                                (context.master?.children().first().flatMap { context.styles.child(of: $0, named: "p:csld") }, context.masterPath)]
        for (owner, path) in backgroundOwners {
            guard let owner, let path, let background = context.styles.child(of: owner, named: "p:bg") else { continue }
            if let properties = context.styles.child(of: background, named: "p:bgpr"),
               let fill = context.styles.child(of: properties, named: "a:blipfill") {
                var backgroundContext = context
                backgroundContext.partPath = path
                backgroundContext.relationships = relationships(context.archive, forPart: path)
                if let image = blipMarkdown(fill, properties: nil, context: &backgroundContext) { context.appendBlock(image, to: &blocks) }
            }
            // Any explicitly defined background overrides its ancestors,
            // including solid fills and theme background references.
            break
        }
        let showInherited = !["0", "false"].contains(booleanValue((try? root.attr("showMasterSp")) ?? ""))
        let showMaster = !["0", "false"].contains(booleanValue((try? context.layout?.children().first()?.attr("showMasterSp")) ?? ""))
        if showInherited {
            let inherited = [(showMaster ? context.master : nil, context.masterPath), (context.layout, context.layoutPath)]
            for (part, path) in inherited {
                guard let part, let path, let root = part.children().first(),
                      let common = context.styles.child(of: root, named: "p:csld"),
                      let tree = context.styles.child(of: common, named: "p:sptree") else { continue }
                var inheritedContext = context
                inheritedContext.partPath = path
                inheritedContext.relationships = relationships(context.archive, forPart: path)
                renderShapes(in: tree, title: &title, blocks: &blocks, context: &inheritedContext, inheritedOnly: true)
                context.renderedBlockBytes = inheritedContext.renderedBlockBytes
            }
        }
        renderShapes(in: tree, title: &title, blocks: &blocks, context: &context)
        return (title, blocks)
    }

    private static func isHidden(_ shape: Element, cache: StyleChildCache? = nil) -> Bool {
        let nonvisualNames: Set<String> = ["p:nvsppr", "p:nvpicpr", "p:nvgraphicframepr", "p:nvgrpsppr", "p:nvcxnsppr"]
        let properties = cache.map { cache in nonvisualNames.compactMap { cache.child(of: shape, named: $0) }.first }
            ?? selectedChildren(in: shape).first(where: { nonvisualNames.contains($0.tagName().lowercased()) })
        guard let properties, let common = selectedChild(of: properties, named: "p:cnvpr", cache: cache) else { return false }
        return isOn(common, "hidden")
    }

    private static func shapeClick(_ shape: Element, cache: StyleChildCache? = nil) -> Element? {
        let names: Set<String> = ["p:nvsppr", "p:nvpicpr", "p:nvgraphicframepr", "p:nvgrpsppr"]
        let properties = cache.map { cache in names.compactMap { cache.child(of: shape, named: $0) }.first }
            ?? selectedChildren(in: shape).first { names.contains($0.tagName().lowercased()) }
        return properties.flatMap { selectedChild(of: $0, named: "p:cnvpr", cache: cache) }
            .flatMap { selectedChild(of: $0, named: "a:hlinkclick", cache: cache) }
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
    private static func renderShapes(in container: Element, title: inout String?, blocks: inout [String], context: inout SlideContext, inheritedLink: String? = nil, inheritedOnly: Bool = false) {
        for shape in context.styles.shapes(in: container) {
            if Task.isCancelled || context.renderBudget?.failed == true { return }
            if context.shapeBudget?.admit(context.archive) == false { return }
            if inheritedOnly, placeholder(of: shape, cache: context.styles) != nil { continue }
            if isHidden(shape, cache: context.styles) { continue }
            let click = shapeClick(shape, cache: context.styles)
            context.defaultLink = click == nil ? inheritedLink : hyperlink(click, context: context)
            switch shape.tagName().lowercased() {
            case "p:sp":
                let type = placeholderType(of: shape, cache: context.styles)
                if let type, skippedPlaceholders.contains(type) { continue }
                if let image = pictureMarkdown(shape, context: &context) { context.appendBlock(image, to: &blocks) }
                guard let body = context.styles.child(of: shape, named: "p:txbody") else { continue }
                context.runDefaults = inheritedRunDefaults(for: shape, context: context)
                if type == "title" || type == "ctrTitle" {
                    let paragraphs = renderParagraphs(body, inherited: noInheritance, context: &context)
                    let text = normalizedWhitespace(context.renderBudget?.join(paragraphs, separator: " ") ?? paragraphs.joined(separator: " "))
                    if title == nil, !text.isEmpty {
                        title = text
                        let titleBudget = context.renderBudget.map { RenderBudget(maximumBytes: $0.maximumBytes - text.utf8.count - 3 - (blocks.isEmpty ? 0 : 2) - context.renderedBlockBytes, archive: context.archive) }
                        let plainParagraphs = selectedParagraphs(in: body).map { paragraph in
                            let fragments = selectedChildren(in: paragraph).map { node in
                                if node.tagName().lowercased() == "a:br" { return " " }
                                guard ["a:r", "a:fld"].contains(node.tagName().lowercased()) else { return "" }
                                return selectedChild(of: node, named: "a:t").map(wholeText) ?? ""
                            }
                            return titleBudget?.join(fragments) ?? fragments.joined()
                        }
                        context.plainTitle = normalizedWhitespace(titleBudget?.join(plainParagraphs, separator: " ") ?? plainParagraphs.joined(separator: " "))
                        if let budget = context.renderBudget {
                            let bytes = 3 + text.utf8.count + (context.plainTitle?.utf8.count ?? 0) + (blocks.isEmpty ? 0 : 2)
                            guard budget.admit(bytes, retained: &context.renderedBlockBytes) else { return }
                            budget.retainedContentBytes = context.renderedBlockBytes
                        }
                        continue
                    }
                    if !text.isEmpty { context.appendBlock(text, to: &blocks) }
                    continue
                }
                let inherited = inheritedBullets(for: shape, context: context)
                let paragraphs = renderParagraphs(body, inherited: inherited, context: &context)
                if !paragraphs.isEmpty { context.appendBlock(context.renderBudget?.join(paragraphs, separator: "\n\n") ?? paragraphs.joined(separator: "\n\n"), to: &blocks) }
            case "p:graphicframe":
                if let table = selectedDescendant(in: shape, named: "a:tbl") {
                    context.runDefaults = Array(repeating: [], count: 9)
                    let markdown = renderTable(table, context: &context)
                    if !markdown.isEmpty { context.appendBlock(markdown, to: &blocks) }
                } else if let object = selectedDescendant(in: shape, named: "p:oleobj"),
                          let preview = selectedDescendant(in: object, named: "p:pic"), !isHidden(preview),
                          let image = pictureMarkdown(preview, context: &context) { context.appendBlock(image, to: &blocks) }
            case "p:pic":
                if let image = pictureMarkdown(shape, context: &context) { context.appendBlock(image, to: &blocks) }
            case "p:grpsp":
                renderShapes(in: shape, title: &title, blocks: &blocks, context: &context, inheritedLink: context.defaultLink, inheritedOnly: inheritedOnly)
            case "mc:alternatecontent":
                if let branch = selectedAlternateBranch(shape) {
                    renderShapes(in: branch, title: &title, blocks: &blocks, context: &context, inheritedLink: inheritedLink, inheritedOnly: inheritedOnly)
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

    private static func graphicPayloadTag(uri: String) -> String? {
        switch uri {
        case "http://schemas.openxmlformats.org/drawingml/2006/table", "http://purl.oclc.org/ooxml/drawingml/table": return "a:tbl"
        case "http://schemas.openxmlformats.org/presentationml/2006/ole", "http://purl.oclc.org/ooxml/presentationml/ole": return "p:oleobj"
        default: return nil
        }
    }

    static func selectedDescendant(in element: Element, named name: String) -> Element? {
        guard !Task.isCancelled else { return nil }
        guard !["p:ext", "a:ext"].contains(element.tagName().lowercased()) else { return nil }
        guard !element.tagName().lowercased().hasPrefix("extension"), !element.tagName().lowercased().hasPrefix("requiredextension") else { return nil }
        if element.tagName().lowercased() == "a:graphicdata", name == "a:tbl" || name == "p:oleobj" {
            guard graphicPayloadTag(uri: (try? element.attr("uri")) ?? "") == name else { return nil }
        }
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
    static func placeholderType(of shape: Element, cache: StyleChildCache? = nil) -> String? {
        guard let placeholder = self.placeholder(of: shape, cache: cache) else { return nil }
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
    static func bullet(in properties: Element?, cache: StyleChildCache? = nil) -> Bullet? {
        guard let properties else { return nil }
        func lookup(_ name: String) -> Element? {
            if let cache { return cache.child(of: properties, named: name) }
            return selectedChild(of: properties, named: name)
        }
        if lookup("a:bunone") != nil { return .plain }
        if let number = lookup("a:buautonum") {
            let raw = (try? number.attr("startAt")) ?? ""
            let scheme = (try? number.attr("type")) ?? ""
            return .number(startAt: raw.isEmpty ? 1 : (Int(raw) ?? 0), scheme: scheme.isEmpty ? "arabicPeriod" : scheme)
        }
        if lookup("a:buchar") != nil || lookup("a:bublip") != nil {
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
        var sources: [Element?] = [listStyle(shape, cache: context.styles)]
        if let placeholder = placeholder(of: shape, cache: context.styles) {
            let type = ((try? placeholder.attr("type")) ?? "").isEmpty ? "obj" : ((try? placeholder.attr("type")) ?? "")
            let index = (try? placeholder.attr("idx")).flatMap { $0.isEmpty ? nil : $0 } ?? "0"
            let bodyLike = ["obj", "body", "subTitle"].contains(type)
            if context.layout == nil, context.master == nil {
                // No inheritance chain to read: content placeholders are bulleted.
                fallback = bodyLike && type != "subTitle" ? .bullet : nil
            }
            if let layout = context.layout {
                sources.append(matchingPlaceholder(in: layout, type: type, index: index, cache: context.placeholders).flatMap { listStyle($0, cache: context.styles) })
            }
            if let master = context.master {
                sources.append(matchingPlaceholder(in: master, type: bodyLike ? "body" : type, index: "", cache: context.placeholders).flatMap { listStyle($0, cache: context.styles) })
            }
        }
        sources.append(applicableMasterTextStyle(for: shape, context: context))
        sources.append(context.defaultTextStyle)
        return (0..<9).map { level in
            for source in sources {
                if let source, let bullet = bullet(in: context.styles.child(of: source, named: "a:lvl\(level + 1)ppr"), cache: context.styles) ?? bullet(in: context.styles.child(of: source, named: "a:defppr"), cache: context.styles) {
                    return bullet
                }
            }
            return fallback
        }
    }

    /// Run toggles inherit independently through the active paragraph level.
    private static func inheritedRunDefaults(for shape: Element, context: SlideContext) -> [[Element]] {
        var styles: [Element?] = [listStyle(shape, cache: context.styles)]
        if let placeholder = placeholder(of: shape, cache: context.styles) {
            let raw = (try? placeholder.attr("type")) ?? ""
            let type = raw.isEmpty ? "obj" : raw
            let index = (try? placeholder.attr("idx")).flatMap { $0.isEmpty ? nil : $0 } ?? "0"
            let bodyLike = ["obj", "body", "subTitle"].contains(type)
            if let layout = context.layout { styles.append(matchingPlaceholder(in: layout, type: type, index: index, cache: context.placeholders).flatMap { listStyle($0, cache: context.styles) }) }
            if let master = context.master {
                styles.append(matchingPlaceholder(in: master, type: bodyLike ? "body" : type, index: "", cache: context.placeholders).flatMap { listStyle($0, cache: context.styles) })
            }
        }
        styles.append(applicableMasterTextStyle(for: shape, context: context))
        styles.append(context.defaultTextStyle)
        return (0..<9).map { level in
            styles.flatMap { source -> [Element] in
                guard let source else { return [] }
                return [context.styles.child(of: source, named: "a:lvl\(level + 1)ppr"), context.styles.child(of: source, named: "a:defppr")]
                    .compactMap { $0.flatMap { context.styles.child(of: $0, named: "a:defrpr") } }
            }
        }
    }

    private static func applicableMasterTextStyle(for shape: Element, context: SlideContext) -> Element? {
        guard let master = context.master else { return nil }
        let style: String
        if master.children().first()?.tagName().lowercased() == "p:notesmaster" {
            style = "p:notesStyle"
        } else {
            let raw = placeholder(of: shape, cache: context.styles).flatMap { try? $0.attr("type") }
            let type = raw.map { $0.isEmpty ? "obj" : $0 }
            let nonvisual = context.styles.child(of: shape, named: "p:nvsppr")
            let properties = nonvisual.flatMap { context.styles.child(of: $0, named: "p:cnvsppr") }
            let bodyLike = type.map { ["obj", "body", "subTitle"].contains($0) } ?? isOn(properties, "txBox")
            style = bodyLike ? "p:bodyStyle" : (type.map { ["title", "ctrTitle"].contains($0) } == true ? "p:titleStyle" : "p:otherStyle")
        }
        return masterTextStyle(master, named: style, cache: context.styles)
    }

    private static func masterTextStyle(_ master: Document, named name: String, cache: StyleChildCache) -> Element? {
        guard let root = master.children().first() else { return nil }
        let container = root.tagName().lowercased() == "p:notesmaster" ? root : cache.child(of: root, named: "p:txstyles")
        return container.flatMap { cache.child(of: $0, named: name.lowercased()) }
    }

    /// Index shared style containers once while keeping transient slide styles local.
    final class StyleChildCache {
        private struct Index { let owner: Element; let children: [String: Element]; let shapes: [Element] }
        private var indexes: [ObjectIdentifier: Index] = [:]
        private(set) var buildCount = 0
        private let shared: StyleChildCache?
        private var documents: [ObjectIdentifier: Document] = [:]
        init(shared: StyleChildCache? = nil) { self.shared = shared }
        func register(_ document: Document) { documents[ObjectIdentifier(document)] = document }
        func child(of parent: Element, named name: String) -> Element? {
            if let shared, let document = parent.ownerDocument(), shared.documents[ObjectIdentifier(document)] != nil {
                return shared.child(of: parent, named: name)
            }
            return index(parent).children[name]
        }
        func shapes(in parent: Element) -> [Element] {
            if let shared, let document = parent.ownerDocument(), shared.documents[ObjectIdentifier(document)] != nil {
                return shared.shapes(in: parent)
            }
            return index(parent).shapes
        }
        private func index(_ parent: Element) -> Index {
            let key = ObjectIdentifier(parent)
            if indexes[key] == nil {
                var children: [String: Element] = [:]
                let selected = selectedChildren(in: parent)
                for child in selected {
                    let name = child.tagName().lowercased()
                    if children[name] == nil { children[name] = child }
                }
                let shapeNames: Set<String> = ["p:sp", "p:pic", "p:graphicframe", "p:grpsp"]
                indexes[key] = Index(owner: parent, children: children, shapes: selected.filter { shapeNames.contains($0.tagName().lowercased()) })
                buildCount += 1
            }
            return indexes[key]!
        }
    }

    /// Shared inherited shapes can render repeatedly without another XML parse.
    final class ShapeBudget {
        private var remaining = 250_000
        func admit(_ archive: PowerPointPackage) -> Bool {
            guard remaining > 0 else { archive.fail(PicoDocsError.fileCorrupted); return false }
            remaining -= 1; return true
        }
    }

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
                            let id = (try? ph.attr("idx")).flatMap { $0.isEmpty ? nil : $0 } ?? "0"
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

    private static func listStyle(_ shape: Element, cache: StyleChildCache) -> Element? {
        cache.child(of: shape, named: "p:txbody").flatMap { cache.child(of: $0, named: "a:lststyle") }
    }

    private static func placeholder(of shape: Element, cache: StyleChildCache? = nil) -> Element? {
        let names: Set<String> = ["p:nvsppr", "p:nvpicpr", "p:nvgraphicframepr"]
        let properties = cache.map { cache in names.compactMap { cache.child(of: shape, named: $0) }.first }
            ?? selectedChildren(in: shape).first { names.contains($0.tagName().lowercased()) }
        return properties.flatMap { selectedChild(of: $0, named: "p:nvpr", cache: cache) }
            .flatMap { selectedChild(of: $0, named: "p:ph", cache: cache) }
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

    private static func selectedChild(of container: Element, named name: String, cache: StyleChildCache? = nil) -> Element? {
        if let cache { return cache.child(of: container, named: name) }
        return selectedChildren(in: container).first { $0.tagName().lowercased() == name }
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
        var blockBytes = 0, listBytes = 0
        let budget = context.renderBudget.map { RenderBudget(maximumBytes: $0.maximumBytes - context.renderedBlockBytes, archive: context.archive) }
        func appendBlock(_ text: String) {
            if let budget, !budget.admit(text.utf8.count + (blocks.isEmpty ? 0 : 2), retained: &blockBytes) { return }
            blocks.append(text)
        }
        func appendListLine(_ text: String) {
            let bytes = text.utf8.count + (listLines.isEmpty ? 0 : 1)
            var retained = blockBytes + listBytes
            if let budget, !budget.admit(bytes, retained: &retained) { return }
            listBytes += bytes
            listLines.append(text)
        }
        var markerWidths: [Int] = []          // marker width per open level
        var schemes: [Int: String] = [:]
        var starts: [Int: Int] = [:]
        var counters: [Int: Int] = [:]        // numbered-list count per level
        var baseLevel = 0                     // shallowest level in the current list

        func flushList() {
            if !listLines.isEmpty { appendBlock(budget?.join(listLines, separator: "\n") ?? listLines.joined(separator: "\n")) }
            listLines = []; listBytes = 0; markerWidths = []; counters = [:]; schemes = [:]; starts = [:]
        }

        for paragraph in selectedParagraphs(in: body) {
            if Task.isCancelled || budget?.failed == true { return [] }
            let properties = selectedChild(of: paragraph, named: "a:ppr")
            let level = min(max(Int((try? properties?.attr("lvl")) ?? "") ?? 0, 0), 8)
            let paragraphBudget = budget.map { RenderBudget(maximumBytes: $0.maximumBytes - blockBytes - listBytes, archive: context.archive) }
            var runContext = context
            runContext.renderBudget = paragraphBudget
            let text = escapeBlockMarkers(renderRuns(paragraph, context: &runContext).trimmingCharacters(in: .whitespaces), budget: paragraphBudget)
            if paragraphBudget?.failed == true { return [] }
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
                appendBlock(paragraphBudget?.replaceNewlines(text, with: "  \n") ?? text.replacingOccurrences(of: "\n", with: "  \n"))
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
            let continued = paragraphBudget?.replaceNewlines(text, with: continuation) ?? text.replacingOccurrences(of: "\n", with: continuation)
            appendListLine(budget?.join([indent, marker, continued]) ?? (indent + marker + continued))
        }
        flushList()
        return blocks
    }

    /// A paragraph's runs as inline Markdown: bold/italic emphasis, external
    /// hyperlinks, fields (e.g. dates), and line breaks as `\n`.
    static func renderRuns(_ paragraph: Element, context: inout SlideContext) -> String {
        struct Run { var text: String; var bold: Bool; var italic: Bool; var link: String? }
        var runs: [Run] = []
        var retainedRunBytes = 0
        let budget = context.renderBudget
        let paragraphProperties = selectedChild(of: paragraph, named: "a:ppr")
        let level = min(max(Int((try? paragraphProperties?.attr("lvl")) ?? "") ?? 0, 0), 8)
        let defaults = [paragraphProperties.flatMap { selectedChild(of: $0, named: "a:defrpr") }].compactMap { $0 } + context.runDefaults[level]
        for node in selectedChildren(in: paragraph) {
            if Task.isCancelled || budget?.failed == true { return "" }
            switch node.tagName().lowercased() {
            case "a:r", "a:fld":
                let properties = selectedChild(of: node, named: "a:rpr")
                let textNode = selectedChild(of: node, named: "a:t")
                let runBudget = budget.map { RenderBudget(maximumBytes: $0.maximumBytes - retainedRunBytes, archive: context.archive) }
                let escaped = escapeMarkdown(textNode.map(wholeText) ?? "", budget: runBudget)
                let text = preservesSpace(textNode) ? encodeWhitespace(escaped, budget: runBudget) : escaped
                if runBudget?.failed == true { return "" }
                guard !text.isEmpty else { continue }
                if let budget, !budget.admit(text.utf8.count, retained: &retainedRunBytes) { return "" }
                let click = properties.flatMap { selectedChild(of: $0, named: "a:hlinkclick") }
                let link = hyperlink(click, context: context)
                let bold = isOn(properties, "b", defaults: defaults), italic = isOn(properties, "i", defaults: defaults)
                let destination = click == nil ? context.defaultLink : link
                let last = runs.count - 1
                if last >= 0, runs[last].bold == bold, runs[last].italic == italic, runs[last].link == destination {
                    runs[last].text += text
                } else {
                    runs.append(Run(text: text, bold: bold, italic: italic, link: destination))
                }
            case "a:br":
                if let budget, !budget.admit(1, retained: &retainedRunBytes) { return "" }
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
                let run = runs[index]
                let perLine = run.bold && run.italic ? 6 : run.bold ? 4 : run.italic ? 2 : 0
                var wrapperBytes = 0, hasContent = false
                if perLine > 0 {
                    for scalar in run.text.unicodeScalars {
                        if scalar == "\n" { hasContent = false }
                        else if !hasContent, !CharacterSet.whitespaces.contains(scalar) {
                            wrapperBytes += perLine; hasContent = true
                        }
                    }
                }
                if let budget, !budget.fits(run.text.utf8.count + wrapperBytes) { return "" }
                let fragment = emphasized(run.text, bold: run.bold, italic: run.italic)
                if let budget { guard budget.append(fragment, to: &label) else { return "" } }
                else { label += fragment }
                index += 1
            }
            if let link {
                let fragments = ["[", label, "](", linkDestination(link), ")"]
                let linked = budget?.join(fragments) ?? fragments.joined()
                if let budget { guard budget.append(linked, to: &out) else { return "" } }
                else { out += linked }
            } else {
                if let budget { guard budget.append(label, to: &out) else { return "" } }
                else { out += label }
            }
        }
        return out
    }

    /// Wraps text in Markdown emphasis, keeping surrounding whitespace outside the
    /// markers (`** x**` isn't emphasis).
    private static func emphasized(_ text: String, bold: Bool, italic: Bool) -> String {
        guard bold || italic else { return text }
        if text.contains("\n") {
            var output = "", start = text.startIndex
            for index in text.unicodeScalars.indices where text.unicodeScalars[index] == "\n" {
                output += emphasized(String(text[start..<index]), bold: bold, italic: italic) + "\n"
                start = text.unicodeScalars.index(after: index)
            }
            output += emphasized(String(text[start...]), bold: bold, italic: italic)
            return output
        }
        let core = text.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return text }
        let leading = String(text.prefix { $0.unicodeScalars.allSatisfy(CharacterSet.whitespaces.contains) })
        let trailing = String(text.reversed().prefix { $0.unicodeScalars.allSatisfy(CharacterSet.whitespaces.contains) }.reversed())
        let marker = bold && italic ? "***" : bold ? "**" : "*"
        return leading + marker + core + marker + trailing
    }

    /// Whether a run-property toggle (`b`/`i`) is on (`"1"` / `"true"`).
    private static func isOn(_ properties: Element?, _ attribute: String, defaults: [Element] = []) -> Bool {
        let direct = booleanValue((try? properties?.attr(attribute)) ?? "")
        let value = direct.isEmpty ? defaults.compactMap { try? $0.attr(attribute) }.map(booleanValue).first(where: { !$0.isEmpty }) ?? "" : direct
        return value == "1" || value == "true"
    }

    private static func booleanValue(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n"))
    }

    private static func preservesSpace(_ node: Element?) -> Bool {
        var current = node
        while let element = current {
            if let value = try? element.attr("xml:space"), !value.isEmpty { return value == "preserve" }
            current = element.parent()
        }
        return false
    }

    private static func encodeWhitespace(_ text: String, budget: RenderBudget?) -> String {
        var bytes = text.utf8.count
        for scalar in text.unicodeScalars where CharacterSet.whitespaces.contains(scalar) {
            let growth = String(scalar.value).utf8.count + 3 - String(scalar).utf8.count
            if let budget, !budget.admit(growth, retained: &bytes) { return "" }
        }
        var output = ""
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespaces.contains(scalar) { output += "&#\(scalar.value);" }
            else { output.unicodeScalars.append(scalar) }
        }
        return output
    }

    private static func escapeMarkdown(_ text: String, budget: RenderBudget? = nil) -> String {
        if let budget {
            var bytes = text.utf8.count
            guard budget.fits(bytes) else { return "" }
            for scalar in text.unicodeScalars where #"\`*_{}[]<>&"#.unicodeScalars.contains(scalar) {
                guard budget.admit(1, retained: &bytes) else { return "" }
            }
        }
        var out = ""
        for scalar in text.unicodeScalars {
            if #"\`*_{}[]<>&"#.unicodeScalars.contains(scalar) { out.append("\\") }
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    private static let blockEscapes: [(NSRegularExpression, String)] = [
        (#"^(\s*)(#{1,6}|[-+]|\|)(?=\s|$)"#, #"$1\\$2"#),
        (#"^(\s*)([0-9]+)([.)])(?=\s|$)"#, #"$1$2\\$3"#),
        (#"^(\s*)\|"#, #"$1\\|"#)
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func escapeBlockMarkers(_ text: String, budget: RenderBudget? = nil) -> String {
        var output = ""
        func appendLine(_ slice: Substring) {
            guard !slice.isEmpty, budget?.failed != true else { return }
            if let budget {
                var bytes = output.utf8.count
                guard budget.admit(slice.utf8.count, retained: &bytes) else { return }
            }
            let line = String(slice)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.unicodeScalars.first, "#-+|0123456789~".unicodeScalars.contains(first) else { output += line; return }
            if trimmed.hasPrefix("~~~") {
                let leading = line.prefix { $0 == " " || $0 == "\t" }
                let escaped = String(leading) + "\\" + line.dropFirst(leading.count)
                if let budget { _ = budget.append(escaped, to: &output) } else { output += escaped }
                return
            }
            if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "-" || $0 == " " }) {
                if let budget {
                    var bytes = output.utf8.count
                    guard budget.admit(line.utf8.count, retained: &bytes) else { return }
                    for scalar in line.unicodeScalars where scalar == "-" {
                        guard budget.admit(1, retained: &bytes) else { return }
                    }
                }
                output += line.replacingOccurrences(of: "-", with: "\\-")
                return
            }
            var escaped = line
            for (regex, replacement) in blockEscapes {
                let range = NSRange(location: 0, length: (escaped as NSString).length)
                if regex.firstMatch(in: escaped, range: range) != nil {
                    if let budget, !budget.fits(output.utf8.count + escaped.utf8.count + 1) { return }
                    escaped = regex.stringByReplacingMatches(in: escaped, range: range, withTemplate: replacement)
                }
            }
            output += escaped
        }
        var start = text.startIndex
        for index in text.unicodeScalars.indices where text.unicodeScalars[index] == "\n" {
            appendLine(text[start..<index])
            if let budget { guard budget.append("\n", to: &output) else { return "" } }
            else { output.append("\n") }
            start = text.unicodeScalars.index(after: index)
        }
        appendLine(text[start...])
        if let budget, !budget.fits(output.utf8.count) { return "" }
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
        let budget = context.renderBudget.map { RenderBudget(maximumBytes: $0.maximumBytes - context.renderedBlockBytes, archive: context.archive) }
        var cellBytes = 0
        for row in selectedChildren(in: table) where row.tagName().lowercased() == "a:tr" {
            if Task.isCancelled || budget?.failed == true { return "" }
            var cells: [String] = []
            for cell in selectedChildren(in: row) where cell.tagName().lowercased() == "a:tc" {
                let cellBudget = budget.map { RenderBudget(maximumBytes: $0.maximumBytes - cellBytes, archive: context.archive) }
                var cellContext = context
                cellContext.renderBudget = cellBudget
                cellContext.renderedBlockBytes = 0
                let merged = isOn(cell, "hMerge") || isOn(cell, "vMerge")
                var text = ""
                if !merged, let body = textBody(ofCell: cell) {
                    let style = selectedChild(of: body, named: "a:lststyle")
                    let styles = [style, context.defaultTextStyle].compactMap { $0 }
                    let inherited = (0..<9).map { level -> Bullet? in
                        for style in styles {
                            if let value = bullet(in: context.styles.child(of: style, named: "a:lvl\(level + 1)ppr"), cache: context.styles) ?? bullet(in: context.styles.child(of: style, named: "a:defppr"), cache: context.styles) { return value }
                        }
                        return nil
                    }
                    cellContext.runDefaults = (0..<9).map { level in
                        styles.flatMap { style in
                            [context.styles.child(of: style, named: "a:lvl\(level + 1)ppr"), context.styles.child(of: style, named: "a:defppr")]
                                .compactMap { $0.flatMap { context.styles.child(of: $0, named: "a:defrpr") } }
                        }
                    }
                    let paragraphs = renderParagraphs(body, inherited: inherited, context: &cellContext)
                    text = cellBudget?.join(paragraphs, separator: "\n") ?? paragraphs.joined(separator: "\n")
                    if cellBudget?.failed == true { return "" }
                }
                if let budget {
                    var expanded = text.utf8.count
                    guard cellBudget?.fits(expanded) != false else { return "" }
                    for scalar in text.unicodeScalars where scalar == "|" || scalar == "\n" {
                        guard cellBudget?.admit(scalar == "\n" ? 3 : 1, retained: &expanded) != false else { return "" }
                    }
                    guard budget.admit(expanded, retained: &cellBytes) else { return "" }
                }
                cells.append(MarkdownTableCell.escapeCanonicalPipes(text).replacingOccurrences(of: "\n", with: "<br>"))
            }
            if !cells.isEmpty { rows.append(cells) }
        }
        guard rows.contains(where: { $0.contains { !$0.isEmpty } }) else { return "" }
        let columns = rows.map(\.count).max() ?? 0
        if let budget {
            // Table separators and padding are determined by the dense dimensions.
            guard columns <= budget.maximumBytes / 6, rows.count <= budget.maximumBytes / max(1, columns * 3 + 4) else {
                _ = budget.fits(budget.maximumBytes + 1); return ""
            }
            let wrappers = rows.count * (columns * 3 + 4) + columns * 6 + 4
            guard budget.admit(wrappers, retained: &cellBytes) else { return "" }
        }
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
        let fill = selectedChild(of: picture, named: "p:blipfill")
            ?? selectedChild(of: picture, named: "p:sppr").flatMap { selectedChild(of: $0, named: "a:blipfill") }
        guard let fill else { return nil }
        let nonvisual = selectedChild(of: picture, named: "p:nvpicpr") ?? selectedChild(of: picture, named: "p:nvsppr")
        let properties = nonvisual.flatMap { selectedChild(of: $0, named: "p:cnvpr") }
        return blipMarkdown(fill, properties: properties, context: &context)
    }

    private static func blipMarkdown(_ fill: Element, properties: Element?, context: inout SlideContext) -> String? {
        guard let blip = selectedDescendant(in: fill, named: "a:blip") else { return nil }
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
            let mediaPath = Self.resolvePartPath(relation.target, relativeTo: directory(of: context.partPath))
            let filename = (mediaPath as NSString).lastPathComponent
            source = context.embedsImages
                ? (context.images.add(path: mediaPath, filename: filename, archive: context.archive) ?? filename)
                : filename
        }
        let description = (try? properties?.attr("descr")) ?? ""
        let title = (try? properties?.attr("title")) ?? ""
        let name = (try? properties?.attr("name")) ?? ""
        let alt = [description, title, name].first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? "image"
        let budget = context.renderBudget.map { RenderBudget(maximumBytes: $0.maximumBytes - context.renderedBlockBytes, archive: context.archive) }
        let label = escapeMarkdown(normalizedWhitespace(alt), budget: budget)
        let fragments = ["![", label, "](", linkDestination(source), ")"]
        let image = budget?.join(fragments) ?? fragments.joined()
        if budget?.failed == true { return nil }
        let click = properties.flatMap { selectedChild(of: $0, named: "a:hlinkclick") }
        if let target = click == nil ? context.defaultLink : hyperlink(click, context: context) {
            let linked = ["[", image, "](", linkDestination(target), ")"]
            return budget?.join(linked) ?? linked.joined()
        }
        return image
    }

    /// Collects each embedded image once (by archive path) as an `.image` section.
    final class ImageCollector {
        private(set) var sections: [DocumentSection] = []
        private var references: [String: String] = [:]
        private var usedReferences: Set<String>
        private var nextReference = 0

        private var remainingEncodedBytes: Int
        private let reserveCarrierBytes: ((Int) -> Bool)?

        init(reservedReferences: Set<String> = [], maximumEncodedBytes: Int = 32 * 1024 * 1024, reserveCarrierBytes: ((Int) -> Bool)? = nil) {
            usedReferences = reservedReferences
            self.reserveCarrierBytes = reserveCarrierBytes
            remainingEncodedBytes = max(0, maximumEncodedBytes)
        }

        @discardableResult
        func add(path: String, filename: String, archive: PowerPointPackage) -> String? {
            if let existing = references[path] { return existing }
            // Base64 consumes four bytes for every three source bytes. Check the
            // declared size before inflating, then charge the verified byte count.
            guard let entry = archive.entry(path), entry.uncompressedSize <= UInt64(remainingEncodedBytes / 4 * 3) else {
                archive.fail(PicoDocsError.fileCorrupted); return nil
            }
            guard let bytes = archive.read(path), !bytes.isEmpty else {
                archive.fail(PicoDocsError.fileCorrupted)
                return nil
            }
            let encodedBytes = ((bytes.count + 2) / 3) * 4
            guard encodedBytes <= remainingEncodedBytes else { archive.fail(PicoDocsError.fileCorrupted); return nil }
            remainingEncodedBytes -= encodedBytes
            // A colon (including a percent-encoded one) must never occupy the
            // scheme position of a generated embedded-image URL.
            let needsRelativePrefix = filename.contains(":") || filename.contains("%") || filename.hasPrefix("/") || filename.hasPrefix("\\")
            var reference = needsRelativePrefix ? "./" + filename : filename
            while usedReferences.contains(PowerPointConverter.linkDestination(reference)) {
                nextReference += 1
                reference = "picodocs-embedded/\(nextReference)/" + filename
            }
            let emitted = PowerPointConverter.linkDestination(reference)
            let mime = PowerPointConverter.contentType(path, archive: archive) ?? PowerPointConverter.mimeType(forExtension: (filename as NSString).pathExtension)
            guard archive.failure == nil else { return nil }
            let labelBytes = filename.utf8.count + filename.unicodeScalars.filter { #"\`*_{}[]<>&"#.unicodeScalars.contains($0) }.count
            let carrierBytes = filename.utf8.count + path.utf8.count + labelBytes + 2 * emitted.utf8.count
                + mime.utf8.count + "mimeType".utf8.count + "markdownReference".utf8.count + 5
            guard reserveCarrierBytes?(carrierBytes) != false else { archive.fail(PicoDocsError.fileCorrupted); return nil }
            usedReferences.insert(emitted); references[path] = reference
            sections.append(DocumentSection(
                title: filename,
                kind: .image,
                markdown: "![\(PowerPointConverter.escapeMarkdown(filename))](\(emitted))",
                sourcePath: path,
                metadata: [
                    "mimeType": mime,
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
            guard let manifest = xml(archive, path: "[Content_Types].xml", budget: .init(nodes: 16_385, attributes: 32_768, bytes: 8 * 1024 * 1024), maximumBytes: 8 * 1024 * 1024),
                  let root = manifest.children().first(), root.tagName().lowercased() == "types" else {
                archive.fail(PicoDocsError.fileCorrupted); return nil
            }
            for entry in root.children().array() {
                let key: String
                switch entry.tagName().lowercased() {
                case "override":
                    guard let name = try? entry.attr("PartName"), name.hasPrefix("/"), name.count > 1 else { archive.fail(PicoDocsError.fileCorrupted); return nil }
                    key = PowerPointPackage.canonicalPartPath(name)
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
        return archive.contentTypes?["/" + PowerPointPackage.canonicalPartPath(path)] ?? archive.contentTypes?["." + (path as NSString).pathExtension.lowercased()]
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

    static func relationshipsOfType(_ suffix: String, archive: PowerPointPackage, part: String, map: [String: Relationship]) -> [Relationship] {
        if archive.relationshipTypeIndexes[part] == nil {
            archive.relationshipTypeIndexes[part] = Dictionary(grouping: map.values, by: \.type)
            archive.relationshipIndexBuildCount += 1
        }
        let index = archive.relationshipTypeIndexes[part] ?? [:]
        if suffix == "/metadata/core-properties" {
            return index["http://schemas.openxmlformats.org/package/2006/relationships" + suffix] ?? []
        }
        return (index["http://schemas.openxmlformats.org/officeDocument/2006/relationships" + suffix] ?? [])
            + (index["http://purl.oclc.org/ooxml/officeDocument/relationships" + suffix] ?? [])
    }

    /// A part's relationships (`<dir>/_rels/<file>.rels`), keyed by id.
    static func relationships(_ archive: PowerPointPackage, forPart part: String) -> [String: Relationship] {
        if let cached = archive.relationshipMaps[part] { return cached }
        guard archive.reserveRelationshipMap(part) else { return [:] }
        let parent = directory(of: part)
        let relsPath = (parent.isEmpty ? "" : parent + "/") + "_rels/\((part as NSString).lastPathComponent).rels"
        guard let document = xml(archive, path: relsPath) else {
            if archive.entry(relsPath) != nil { archive.fail(PicoDocsError.fileCorrupted) }
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

    static func resolvePartPath(_ target: String, relativeTo baseDirectory: String) -> String {
        PowerPointPackage.canonicalPartPath(WordConverter.resolvePartPath(target, relativeTo: baseDirectory))
    }

    private static func directory(of part: String) -> String {
        (part as NSString).deletingLastPathComponent
    }

    /// Reads and parses an XML part, or nil when missing/unreadable.
    static func xml(_ archive: PowerPointPackage, path: String, budget: PowerPointXML.Budget? = nil, maximumBytes: Int = Int.max) -> Document? {
        guard let data = archive.read(path, maximumBytes: maximumBytes),
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
                let opaqueGraphicPayload = tag == "a:graphicdata" && graphicPayloadTag(uri: (try? element.attr("uri")) ?? "") == nil
                let childAllowsUnknown = opaqueGraphicPayload || ((tag == "mc:choice" || tag == "mc:fallback") && allowsUnknown)
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
