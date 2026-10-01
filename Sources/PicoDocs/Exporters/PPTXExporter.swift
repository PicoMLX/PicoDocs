//
//  PPTXExporter.swift
//  PicoDocs
//
//  Hand-rolled PresentationML (PPTX) writer on `OOXMLPackageWriter`. One slide per
//  top-level heading (level 1–2): the heading is the title placeholder, the
//  following blocks become body text. Explicit `.slide` sections (from a future
//  presentation reader) map one section per slide.
//
//  PPTX is the strictest minimal OOXML package — it requires a slide master, a
//  layout, and a theme even for plain text — so those parts are fixed templates
//  (`PPTXTemplates`). There is no in-repo PPTX *reader*, so this is validated by
//  structural/golden tests (slide count, title text) rather than round-trip.
//  Images are rendered as their alt text on slides for now (no `<p:pic>` embedding).
//

import Foundation

public struct PPTXExporter: DocumentExporter {

    public init() {}

    public func accepts(_ format: ExportableFileType) -> Bool { format == .pptx }

    public func write(_ result: ConverterResult, format: ExportableFileType) throws -> Data {
        guard format == .pptx else { throw ExporterError.notAccepted }
        try OfficeDocumentBlocks.validateInput(result, includesNativeNotes: true)
        let sanitized = OOXMLPackageWriter.sanitizedDocument(result)
        guard !PicoDocsEngine.isEmptyForExport(sanitized) else { throw PicoDocsError.emptyDocument }
        let result = PicoDocsEngine.withSynthesizedImageReferences(sanitized)

        let slides = try Self.slides(from: result)
        if !result.sections.contains(where: { $0.kind == .slide || $0.slideNumber != nil }),
           !slides.contains(where: { !$0.title.isEmpty || !$0.body.isEmpty }) {
            throw PicoDocsError.emptyDocument
        }
        guard slides.allSatisfy({ ($0.body + ($0.notes ?? [])).allSatisfy { $0.level <= 8 } }) else {
            throw ExporterError.serializationFailed("PPTX supports at most nine native list levels")
        }
        let count = max(slides.count, 1)
        let effectiveSlides = slides.isEmpty ? [Slide(title: "", body: [])] : slides

        let headings = effectiveSlides.enumerated().flatMap { index, slide in
            let titles = (slide.title.isEmpty ? [] : [slide.title]) + slide.body.filter(\.isHeading).map(\.text)
            return titles.map { (title: $0, slide: index + 1) }
        }
        let fragments = MarkdownHeadingAnchors.slugs(headings.map(\.title))
        let fragmentSlides = Dictionary(uniqueKeysWithValues: zip(fragments, headings.map(\.slide)))
        var pkg = try OOXMLPackageWriter()
        try pkg.addCoreProperties(result)
        try pkg.addXML("[Content_Types].xml", OOXMLPackageWriter.withCoreContentType(Self.contentTypes(slideCount: count, noteSlideIDs: Set(effectiveSlides.indices.filter { effectiveSlides[$0].notes != nil }.map { $0 + 1 }))))
        try pkg.addXML("_rels/.rels", OOXMLPackageWriter.withCoreRelationship(Self.rootRels))
        try pkg.addXML("ppt/presentation.xml", Self.presentationXML(slideCount: count))
        try pkg.addXML("ppt/_rels/presentation.xml.rels", Self.presentationRels(slideCount: count))
        try pkg.addXML("ppt/slideMasters/slideMaster1.xml", PPTXTemplates.slideMaster)
        try pkg.addXML("ppt/slideMasters/_rels/slideMaster1.xml.rels", PPTXTemplates.slideMasterRels)
        try pkg.addXML("ppt/slideLayouts/slideLayout1.xml", PPTXTemplates.slideLayout)
        try pkg.addXML("ppt/slideLayouts/_rels/slideLayout1.xml.rels", PPTXTemplates.slideLayoutRels)
        try pkg.addXML("ppt/theme/theme1.xml", PPTXTemplates.theme)
        for (i, slide) in effectiveSlides.enumerated() {
            var relationships = SlideRelationships()
            try pkg.addXML("ppt/slides/slide\(i + 1).xml", try Self.slideXML(slide, fragmentSlides: fragmentSlides, relationships: &relationships))
            var extraRels = relationships.xml
            if let notes = slide.notes {
                var noteRelationships = SlideRelationships()
                let number = i + 1
                try pkg.addXML("ppt/notesSlides/notesSlide\(number).xml", try Self.notesXML(notes, relationships: &noteRelationships))
                let backlink = "<Relationship Id=\"slide\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"../slides/slide\(number).xml\"/>"
                let noteRels = OOXMLPackageWriter.xmlDeclaration + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" + backlink + noteRelationships.xml + "</Relationships>"
                try pkg.addXML("ppt/notesSlides/_rels/notesSlide\(number).xml.rels", noteRels)
                extraRels += "<Relationship Id=\"notes\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide\" Target=\"../notesSlides/notesSlide\(number).xml\"/>"
            }
            let rels = PPTXTemplates.slideRels.replacingOccurrences(of: "</Relationships>", with: extraRels + "</Relationships>")
            try pkg.addXML("ppt/slides/_rels/slide\(i + 1).xml.rels", rels)
        }
        return try pkg.data()
    }

    struct SlideRelationships {
        private var identifiers: [String: String] = [:]
        private(set) var xml = ""
        private var remainingBytes: Int
        init(maximumBytes: Int = 8 * 1024 * 1024) {
            remainingBytes = max(0, maximumBytes - 1024) // package wrapper/layout relationship
        }
        mutating func add(target: String, jump: Bool) throws -> String {
            let key = (jump ? "slide:" : "external:") + target
            if let id = identifiers[key] { return id }
            guard identifiers.count < 65_536, target.utf8.count <= remainingBytes / 6 else {
                throw ExporterError.serializationFailed("Slide relationships exceed the supported budget")
            }
            let id = "hyperlink\(identifiers.count + 1)"
            let type = jump ? "slide" : "hyperlink"
            let mode = jump ? "" : " TargetMode=\"External\""
            let fragment = "<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/\(type)\" Target=\"\(OOXMLPackageWriter.escapeAttribute(target))\"\(mode)/>"
            guard fragment.utf8.count <= remainingBytes else {
                throw ExporterError.serializationFailed("Slide relationships exceed the supported budget")
            }
            remainingBytes -= fragment.utf8.count
            identifiers[key] = id
            xml.append(contentsOf: fragment)
            return id
        }
    }

    // MARK: - Slide model

    struct Paragraph {
        let text: String
        var ordered: Bool? = nil
        var number: Int = 1
        var level: Int = 0
        var inlines: [MarkdownInline]? = nil
        var isHeading = false
        var listContinuation = false

        init(text: String, ordered: Bool? = nil, number: Int = 1, level: Int = 0, inlines: [MarkdownInline]? = nil) {
            self.text = text; self.ordered = ordered; self.number = number; self.level = level; self.inlines = inlines
        }
        init(markdown: String, ordered: Bool? = nil, number: Int = 1, level: Int = 0, normalizeLineBreaks: Bool = false) {
            let parsed = MarkdownInlineParser.parse(markdown)
            let nodes = normalizeLineBreaks ? normalizedBreaks(parsed) : parsed
            self.init(text: nodes.plainText, ordered: ordered, number: number, level: level, inlines: nodes)
        }
    }
    struct Slide { let title: String; let body: [Paragraph]; var titleInlines: [MarkdownInline]? = nil; var notes: [Paragraph]? = nil }

    private static func slides(from result: ConverterResult) throws -> [Slide] {
        // Preserve associated tables, including slides containing only tables.
        let explicit = result.sections.filter { $0.kind == .slide || ($0.slideNumber != nil && $0.kind != .image) }
        if !explicit.isEmpty {
            var numbered: [Int: [DocumentSection]] = [:]
            var unnumberedSlides: [[DocumentSection]] = []
            for section in explicit {
                if let number = section.slideNumber, number > 0 {
                    guard number <= 10_000 else { throw ExporterError.serializationFailed("Slide provenance exceeds the supported deck size") }
                    numbered[number, default: []].append(section)
                } else { unnumberedSlides.append([section]) }
            }
            let maximum = numbered.keys.max() ?? 0
            var groups = maximum > 0 ? (1...maximum).map { numbered[$0] ?? [] } : []
            if !unnumberedSlides.isEmpty {
                groups = []
                var emitted: Set<Int> = []
                let orderedNumbers = numbered.keys.sorted()
                var numberedIndex = 0
                var nextGap = 1
                for section in explicit {
                    if let number = section.slideNumber, number > 0 {
                        guard emitted.insert(number).inserted else { continue }
                        // Keep unnumbered section slots, but fill numbered slots
                        // in provenance order, with associated sections together.
                        let orderedNumber = orderedNumbers[numberedIndex]
                        numberedIndex += 1
                        while nextGap < orderedNumber {
                            groups.append([])
                            nextGap += 1
                        }
                        groups.append(numbered[orderedNumber] ?? [])
                        nextGap = orderedNumber + 1
                    } else { groups.append([section]) }
                }
            }
            // Keynote's recovery path may carry text without slide provenance.
            // Keep it as a leading slide rather than losing it when tables exist.
            let unnumbered = result.sections.filter { $0.slideNumber == nil && $0.kind != .slide && $0.kind != .image }
            if !unnumbered.isEmpty {
                if groups.first?.isEmpty == true { groups[0] = unnumbered }
                else { groups.insert(unnumbered, at: 0) }
            }
            guard groups.count <= 10_000 else { throw ExporterError.serializationFailed("Slide count exceeds the supported deck size") }
            return groups.map { sections in
                let title = sections.first(where: { $0.kind == .slide })?.title ?? ""
                var titleInlines: [MarkdownInline]?
                let body = sections.flatMap { section in
                          var visible = section
                          if section.kind == .slide, let originalNotes = section.metadata["notes"] {
                              // Match the same XML-safe text already used for
                              // visible Markdown, including notes cleaned to empty.
                              let notes = OOXMLPackageWriter.xmlSafeText(originalNotes)
                              let suffix = "### Notes\n\n" + notes
                              if visible.markdown == suffix { visible.markdown = "" }
                              else if visible.markdown.hasSuffix("\n\n" + suffix) { visible.markdown.removeLast(suffix.count + 2) }
                          }
                          var blocks = OfficeDocumentBlocks.parse(ConverterResult(sections: [visible]), includeSlideTitles: false)
                          if section.kind == .slide, let title = section.title,
                             case .heading(_, let text)? = blocks.first,
                             MarkdownInlineParser.parse(text).plainText == title {
                              if titleInlines == nil { titleInlines = MarkdownInlineParser.parse(text) }
                              blocks.removeFirst()
                          }
                          return bodyLines(blocks)
                      }
                let noteSections = sections.filter { $0.kind == .slide }.compactMap { section -> DocumentSection? in
                    guard let notes = section.metadata["notes"] else { return nil }
                    return DocumentSection(markdown: OOXMLPackageWriter.xmlSafeText(notes), metadata: ["powerPointWhitespace": section.metadata["powerPointWhitespace"] ?? "0"])
                }
                let notes = noteSections.isEmpty ? nil : bodyLines(OfficeDocumentBlocks.parse(ConverterResult(sections: noteSections), includeSlideTitles: false))
                return Slide(title: title, body: body, titleInlines: titleInlines, notes: notes)
            }
        }

        // Otherwise segment the merged Markdown at top-level headings.
        var slides: [Slide] = []
        var title = ""
        var titleInlines: [MarkdownInline]?
        var body: [Paragraph] = []
        var started = false
        func flush() throws {
            if started {
                guard slides.count < 10_000 else { throw ExporterError.serializationFailed("Slide count exceeds the supported deck size") }
                slides.append(Slide(title: title, body: body, titleInlines: titleInlines))
            }
        }

        for block in OfficeDocumentBlocks.parse(result) {
            if case .heading(let level, let text) = block, level <= 2 {
                try flush()
                // The title placeholder shows visible text, not Markdown syntax
                // (`# **Q4** results` -> "Q4 results"), matching the body lines.
                titleInlines = MarkdownInlineParser.parse(text)
                title = titleInlines?.plainText ?? ""
                body = []
                started = true
            } else {
                started = true
                body += bodyLines([block])
            }
        }
        try flush()
        return slides
    }

    private static func bodyLines(_ blocks: [MarkdownBlock]) -> [Paragraph] {
        var lines: [Paragraph] = []
        for block in blocks {
            switch block {
            case .heading(_, let text):
                var paragraph = Paragraph(markdown: text)
                paragraph.isHeading = true
                lines.append(paragraph)
            case .paragraph(let text):
                lines.append(Paragraph(markdown: text, normalizeLineBreaks: true))
            case .list(let list):
                for item in list.paragraphs() {
                    var paragraph = Paragraph(markdown: item.text, ordered: item.continuation ? nil : item.ordered, number: item.number ?? 1, level: item.level, normalizeLineBreaks: true)
                    paragraph.listContinuation = item.continuation
                    lines.append(paragraph)
                }
            case .code(let code):
                for line in code.components(separatedBy: "\n") { lines.append(Paragraph(text: line, inlines: [.code(line)])) }
            case .blockquote(let quoteLines):
                for line in quoteLines { lines.append(Paragraph(markdown: line)) }
            case .table(let rows):
                for row in rows {
                    var nodes: [MarkdownInline] = []
                    for (index, cell) in row.enumerated() {
                        if index > 0 { nodes.append(.text("\t")) }
                        nodes += MarkdownInlineParser.parse(cell, tableCell: true)
                    }
                    lines.append(Paragraph(text: nodes.plainText, inlines: normalizedBreaks(nodes)))
                }
            case .rule:
                lines.append(Paragraph(text: "---"))
            }
        }
        return lines
    }

    private static func normalizedBreaks(_ nodes: [MarkdownInline]) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        var textBuffer = ""
        func flushText() {
            if !textBuffer.isEmpty { result.append(.text(textBuffer)); textBuffer = "" }
        }
        for node in nodes {
            let normalized: MarkdownInline
            switch node {
            case .lineBreak(let hard): normalized = .text(hard ? "\n" : " ")
            case .strong(let children): normalized = .strong(normalizedBreaks(children))
            case .emphasis(let children): normalized = .emphasis(normalizedBreaks(children))
            case .link(let label, let destination): normalized = .link(label: normalizedBreaks(label), destination: destination)
            default: normalized = node
            }
            if case .text(let text) = normalized { textBuffer.append(contentsOf: text) }
            else { flushText(); result.append(normalized) }
        }
        flushText()
        return result
    }

    // MARK: - Slide part

    private static func slideXML(_ slide: Slide, fragmentSlides: [String: Int], relationships: inout SlideRelationships) throws -> String {
        let titleRuns = "<a:p>\(try runs(slide.titleInlines ?? [.text(slide.title)], fragmentSlides: fragmentSlides, relationships: &relationships))</a:p>"
        let bodyParagraphs: String
        if slide.body.isEmpty {
            bodyParagraphs = "<a:p/>"
        } else {
            bodyParagraphs = try slide.body.map { paragraph in
                let properties: String
                var nodes = paragraph.inlines ?? [.text(paragraph.text)]
                switch paragraph.ordered {
                case true? where !(1...32767).contains(paragraph.number):
                    properties = "<a:pPr lvl=\"\(min(paragraph.level, 8))\"><a:buNone/></a:pPr>"
                    nodes.insert(.text("\(paragraph.number). "), at: 0)
                case true?: properties = "<a:pPr lvl=\"\(min(paragraph.level, 8))\"><a:buAutoNum type=\"arabicPeriod\" startAt=\"\(paragraph.number)\"/></a:pPr>"
                case false?: properties = "<a:pPr lvl=\"\(min(paragraph.level, 8))\"><a:buChar char=\"•\"/></a:pPr>"
                case nil:
                    let provenance = paragraph.listContinuation ? "<a:extLst><a:ext uri=\"https://picomlx.github.io/picodocs/markdown/listContinuation\"><pd:listContinuation xmlns:pd=\"https://picomlx.github.io/picodocs/markdown\"/></a:ext></a:extLst>" : ""
                    properties = "<a:pPr lvl=\"\(min(paragraph.level, 8))\"><a:buNone/>\(provenance)</a:pPr>"
                }
                let runs = try runs(nodes, fragmentSlides: fragmentSlides, relationships: &relationships)
                return "<a:p>\(properties)\(runs)</a:p>"
            }.joined()
        }
        return OOXMLPackageWriter.xmlDeclaration + """
        <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <p:cSld><p:spTree>\
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
        <p:grpSpPr/>\
        <p:sp><p:nvSpPr><p:cNvPr id="2" name="Title 1"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>\
        <p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>\
        <p:spPr><a:xfrm><a:off x="685800" y="457200"/><a:ext cx="7772400" cy="1143000"/></a:xfrm>\
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>\
        <p:txBody><a:bodyPr/><a:lstStyle/>\(titleRuns)</p:txBody></p:sp>\
        <p:sp><p:nvSpPr><p:cNvPr id="3" name="Content 2"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>\
        <p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr>\
        <p:spPr><a:xfrm><a:off x="685800" y="1600200"/><a:ext cx="7772400" cy="4525963"/></a:xfrm>\
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>\
        <p:txBody><a:bodyPr/><a:lstStyle/>\(bodyParagraphs)</p:txBody></p:sp>\
        </p:spTree></p:cSld><p:clrMapOvr><a:overrideClrMapping bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" \
        accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" \
        accent6="accent6" hlink="hlink" folHlink="folHlink"/></p:clrMapOvr></p:sld>
        """
    }

    /// Hyperlinks belong to runs and reference this slide's relationship part.
    private static func runs(_ nodes: [MarkdownInline], bold: Bool = false, italic: Bool = false, link: (id: String, jump: Bool, fragment: String?)? = nil, fragmentSlides: [String: Int], relationships: inout SlideRelationships) throws -> String {
        var output = ""
        for node in nodes {
            switch node {
            case .strong(let children):
                output += try runs(children, bold: true, italic: italic, link: link, fragmentSlides: fragmentSlides, relationships: &relationships)
            case .emphasis(let children):
                output += try runs(children, bold: bold, italic: true, link: link, fragmentSlides: fragmentSlides, relationships: &relationships)
            case .link(let label, let destination):
                guard !destination.isEmpty, DocumentRenderer.isSafeURL(destination, isImage: false) else {
                    output += try runs(label, bold: bold, italic: italic, fragmentSlides: fragmentSlides, relationships: &relationships)
                    continue
                }
                let id: String
                let jump: Bool
                if destination.hasPrefix("#") {
                    let fragment = String(destination.dropFirst())
                    guard let targetSlide = fragmentSlides[fragment.removingPercentEncoding ?? fragment] else {
                        output += try runs(label, bold: bold, italic: italic, fragmentSlides: fragmentSlides, relationships: &relationships)
                        continue
                    }
                    id = try relationships.add(target: "slide\(targetSlide).xml", jump: true)
                    jump = true
                } else {
                    id = try relationships.add(target: OOXMLPackageWriter.relationshipURI(destination), jump: false)
                    jump = false
                }
                output += try runs(label, bold: bold, italic: italic, link: (id, jump, jump ? destination : nil), fragmentSlides: fragmentSlides, relationships: &relationships)
            default:
                let text = [node].plainText
                var attributes = bold ? " b=\"1\"" : ""
                if italic { attributes += " i=\"1\"" }
                let font: String
                if case .code = node { font = "<a:latin typeface=\"Courier New\"/>" } else { font = "" }
                let hyperlink = link.map { link in
                    let provenance = link.fragment.map { "<a:extLst><a:ext uri=\"https://picomlx.github.io/picodocs/markdown/slideFragment\"><pd:slideFragment xmlns:pd=\"https://picomlx.github.io/picodocs/markdown\" val=\"\(OOXMLPackageWriter.escapeAttribute($0))\"/></a:ext></a:extLst>" } ?? ""
                    return "<a:hlinkClick r:id=\"\(link.id)\"\(link.jump ? " action=\"ppaction://hlinksldjump\"" : "")>\(provenance)</a:hlinkClick>"
                } ?? ""
                let properties = attributes.isEmpty && hyperlink.isEmpty && font.isEmpty ? "" : "<a:rPr\(attributes)>\(font)\(hyperlink)</a:rPr>"
                output += text.components(separatedBy: "\n").map {
                    "<a:r>\(properties)<a:t\($0.first?.isWhitespace == true || $0.last?.isWhitespace == true ? " xml:space=\"preserve\"" : "")>\(OOXMLPackageWriter.escape($0))</a:t></a:r>"
                }.joined(separator: "<a:br/>")
            }
        }
        return output
    }

    /// Native presenter notes live in a notes-slide part with a backlink to the
    /// owning slide. External hyperlinks/styles use the same run writer as slides.
    private static func notesXML(_ paragraphs: [Paragraph], relationships: inout SlideRelationships) throws -> String {
        var body = ""
        for paragraph in paragraphs {
            try Task.checkCancellation()
            let properties: String
            if paragraph.ordered == true, (1...32767).contains(paragraph.number) {
                properties = "<a:pPr lvl=\"\(min(paragraph.level, 8))\"><a:buAutoNum type=\"arabicPeriod\" startAt=\"\(paragraph.number)\"/></a:pPr>"
            } else if paragraph.ordered == false {
                properties = "<a:pPr lvl=\"\(min(paragraph.level, 8))\"><a:buChar char=\"•\"/></a:pPr>"
            } else {
                let provenance = paragraph.listContinuation ? "<a:extLst><a:ext uri=\"https://picomlx.github.io/picodocs/markdown/listContinuation\"><pd:listContinuation xmlns:pd=\"https://picomlx.github.io/picodocs/markdown\"/></a:ext></a:extLst>" : ""
                properties = "<a:pPr lvl=\"\(min(paragraph.level, 8))\"><a:buNone/>" + provenance + "</a:pPr>"
            }
            var nodes = paragraph.inlines ?? [.text(paragraph.text)]
            if paragraph.ordered == true, !(1...32767).contains(paragraph.number) { nodes.insert(.text("\(paragraph.number). "), at: 0) }
            body += "<a:p>" + properties + (try runs(nodes, fragmentSlides: [:], relationships: &relationships)) + "</a:p>"
        }
        if body.isEmpty { body = "<a:p/>" }
        return OOXMLPackageWriter.xmlDeclaration + """
        <p:notes xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:cSld><p:spTree>        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>        <p:sp><p:nvSpPr><p:cNvPr id="2" name="Notes"/><p:cNvSpPr/><p:nvPr><p:ph type="body"/></p:nvPr></p:nvSpPr><p:spPr/>        <p:txBody><a:bodyPr/><a:lstStyle/>\(body)</p:txBody></p:sp></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:notes>
        """
    }

    // MARK: - Package parts (dynamic)

    private static let rootRels = OOXMLPackageWriter.xmlDeclaration + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>\
    </Relationships>
    """

    private static func contentTypes(slideCount: Int, noteSlideIDs: Set<Int>) -> String {
        var overrides = """
        <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>\
        <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>\
        <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>\
        <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
        """
        for i in 1...slideCount {
            overrides += "<Override PartName=\"/ppt/slides/slide\(i).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
        }
        for number in noteSlideIDs.sorted() {
            overrides += "<Override PartName=\"/ppt/notesSlides/notesSlide\(number).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.notesSlide+xml\"/>"
        }
        return OOXMLPackageWriter.xmlDeclaration + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\(overrides)</Types>
        """
    }

    private static func presentationXML(slideCount: Int) -> String {
        // sldMasterIdLst uses rId1; slides use rId2... (see presentationRels).
        var sldIds = ""
        for i in 1...slideCount {
            sldIds += "<p:sldId id=\"\(255 + i)\" r:id=\"rId\(i + 1)\"/>"
        }
        return OOXMLPackageWriter.xmlDeclaration + """
        <p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>\
        <p:sldIdLst>\(sldIds)</p:sldIdLst>\
        <p:sldSz cx="9144000" cy="6858000" type="screen4x3"/>\
        <p:notesSz cx="6858000" cy="9144000"/></p:presentation>
        """
    }

    private static func presentationRels(slideCount: Int) -> String {
        var rels = "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/>"
        for i in 1...slideCount {
            rels += "<Relationship Id=\"rId\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\(i).xml\"/>"
        }
        return OOXMLPackageWriter.xmlDeclaration + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)</Relationships>
        """
    }
}
