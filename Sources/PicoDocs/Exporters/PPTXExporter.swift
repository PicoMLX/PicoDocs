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
        try OfficeDocumentBlocks.rejectUnsupportedCoverOnlyInput(result)
        let result = PicoDocsEngine.withSynthesizedImageReferences(result)

        let slides = try Self.slides(from: result)
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
        try pkg.addXML("[Content_Types].xml", OOXMLPackageWriter.withCoreContentType(Self.contentTypes(slideCount: count)))
        try pkg.addXML("_rels/.rels", OOXMLPackageWriter.withCoreRelationship(Self.rootRels))
        try pkg.addXML("ppt/presentation.xml", Self.presentationXML(slideCount: count))
        try pkg.addXML("ppt/_rels/presentation.xml.rels", Self.presentationRels(slideCount: count))
        try pkg.addXML("ppt/slideMasters/slideMaster1.xml", PPTXTemplates.slideMaster)
        try pkg.addXML("ppt/slideMasters/_rels/slideMaster1.xml.rels", PPTXTemplates.slideMasterRels)
        try pkg.addXML("ppt/slideLayouts/slideLayout1.xml", PPTXTemplates.slideLayout)
        try pkg.addXML("ppt/slideLayouts/_rels/slideLayout1.xml.rels", PPTXTemplates.slideLayoutRels)
        try pkg.addXML("ppt/theme/theme1.xml", PPTXTemplates.theme)
        for (i, slide) in effectiveSlides.enumerated() {
            var relationships: [String] = []
            try pkg.addXML("ppt/slides/slide\(i + 1).xml", Self.slideXML(slide, fragmentSlides: fragmentSlides, relationships: &relationships))
            let rels = PPTXTemplates.slideRels.replacingOccurrences(of: "</Relationships>", with: relationships.joined() + "</Relationships>")
            try pkg.addXML("ppt/slides/_rels/slide\(i + 1).xml.rels", rels)
        }
        return try pkg.data()
    }

    // MARK: - Slide model

    struct Paragraph {
        let text: String
        var ordered: Bool? = nil
        var number: Int = 1
        var level: Int = 0
        var inlines: [MarkdownInline]? = nil
        var isHeading = false

        init(text: String, ordered: Bool? = nil, number: Int = 1, level: Int = 0, inlines: [MarkdownInline]? = nil) {
            self.text = text; self.ordered = ordered; self.number = number; self.level = level; self.inlines = inlines
        }
        init(markdown: String, ordered: Bool? = nil, number: Int = 1, level: Int = 0, normalizeLineBreaks: Bool = false) {
            let parsed = MarkdownInlineParser.parse(markdown)
            let nodes = normalizeLineBreaks ? normalizedBreaks(parsed) : parsed
            self.init(text: nodes.plainText, ordered: ordered, number: number, level: level, inlines: nodes)
        }
    }
    struct Slide { let title: String; let body: [Paragraph]; var titleInlines: [MarkdownInline]? = nil }

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
            groups += unnumberedSlides
            // Keynote's recovery path may carry text without slide provenance.
            // Keep it as a leading slide rather than losing it when tables exist.
            let unnumbered = result.sections.filter { $0.slideNumber == nil && $0.kind != .slide && $0.kind != .image }
            if !unnumbered.isEmpty {
                if groups.first?.isEmpty == true { groups[0] = unnumbered }
                else { groups.insert(unnumbered, at: 0) }
            }
            guard groups.count <= 10_000 else { throw ExporterError.serializationFailed("Slide count exceeds the supported deck size") }
            return groups.map { sections in
                Slide(title: sections.first(where: { $0.kind == .slide })?.title ?? "",
                      body: sections.flatMap { section in
                          var blocks = OfficeDocumentBlocks.parse(ConverterResult(sections: [section]), includeSlideTitles: false)
                          if section.kind == .slide, let title = section.title,
                             case .heading(_, let text)? = blocks.first,
                             MarkdownInlineParser.parse(text).plainText == title {
                              blocks.removeFirst()
                          }
                          return bodyLines(blocks)
                      })
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
                    lines.append(Paragraph(markdown: item.text, ordered: item.continuation ? nil : item.ordered, number: item.number ?? 1, level: item.level, normalizeLineBreaks: true))
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
                continue
            }
        }
        return lines
    }

    private static func normalizedBreaks(_ nodes: [MarkdownInline]) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        for node in nodes {
            let normalized: MarkdownInline
            switch node {
            case .lineBreak(let hard): normalized = .text(hard ? "\n" : " ")
            case .strong(let children): normalized = .strong(normalizedBreaks(children))
            case .emphasis(let children): normalized = .emphasis(normalizedBreaks(children))
            case .link(let label, let destination): normalized = .link(label: normalizedBreaks(label), destination: destination)
            default: normalized = node
            }
            if case .text(let text) = normalized, case .text(let previous)? = result.last {
                result[result.count - 1] = .text(previous + text)
            } else { result.append(normalized) }
        }
        return result
    }

    // MARK: - Slide part

    private static func slideXML(_ slide: Slide, fragmentSlides: [String: Int], relationships: inout [String]) -> String {
        let titleRuns = "<a:p>\(runs(slide.titleInlines ?? [.text(slide.title)], fragmentSlides: fragmentSlides, relationships: &relationships))</a:p>"
        let bodyParagraphs: String
        if slide.body.isEmpty {
            bodyParagraphs = "<a:p/>"
        } else {
            bodyParagraphs = slide.body.map { paragraph in
                let properties: String
                var nodes = paragraph.inlines ?? [.text(paragraph.text)]
                switch paragraph.ordered {
                case true? where !(1...32767).contains(paragraph.number):
                    properties = "<a:pPr lvl=\"\(min(paragraph.level, 8))\"><a:buNone/></a:pPr>"
                    nodes.insert(.text("\(paragraph.number). "), at: 0)
                case true?: properties = "<a:pPr lvl=\"\(min(paragraph.level, 8))\"><a:buAutoNum type=\"arabicPeriod\" startAt=\"\(paragraph.number)\"/></a:pPr>"
                case false?: properties = "<a:pPr lvl=\"\(min(paragraph.level, 8))\"><a:buChar char=\"•\"/></a:pPr>"
                case nil: properties = "<a:pPr lvl=\"\(min(paragraph.level, 8))\"><a:buNone/></a:pPr>"
                }
                let runs = runs(nodes, fragmentSlides: fragmentSlides, relationships: &relationships)
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
    private static func runs(_ nodes: [MarkdownInline], bold: Bool = false, italic: Bool = false, link: (id: String, jump: Bool)? = nil, fragmentSlides: [String: Int], relationships: inout [String]) -> String {
        var output = ""
        for node in nodes {
            switch node {
            case .strong(let children):
                output += runs(children, bold: true, italic: italic, link: link, fragmentSlides: fragmentSlides, relationships: &relationships)
            case .emphasis(let children):
                output += runs(children, bold: bold, italic: true, link: link, fragmentSlides: fragmentSlides, relationships: &relationships)
            case .link(let label, let destination):
                let id = "hyperlink\(relationships.count + 1)"
                let jump: Bool
                if destination.hasPrefix("#") {
                    let fragment = String(destination.dropFirst())
                    guard let targetSlide = fragmentSlides[fragment.removingPercentEncoding ?? fragment] else {
                        output += runs(label, bold: bold, italic: italic, fragmentSlides: fragmentSlides, relationships: &relationships)
                        continue
                    }
                    relationships.append("<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slide\(targetSlide).xml\"/>")
                    jump = true
                } else {
                    let target = OOXMLPackageWriter.relationshipURI(destination)
                    relationships.append("<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(OOXMLPackageWriter.escapeAttribute(target))\" TargetMode=\"External\"/>")
                    jump = false
                }
                output += runs(label, bold: bold, italic: italic, link: (id, jump), fragmentSlides: fragmentSlides, relationships: &relationships)
            default:
                let text = [node].plainText
                var attributes = bold ? " b=\"1\"" : ""
                if italic { attributes += " i=\"1\"" }
                let font: String
                if case .code = node { font = "<a:latin typeface=\"Courier New\"/>" } else { font = "" }
                let hyperlink = link.map { "<a:hlinkClick r:id=\"\($0.id)\"\($0.jump ? " action=\"ppaction://hlinksldjump\"" : "")/>" } ?? ""
                let properties = attributes.isEmpty && hyperlink.isEmpty && font.isEmpty ? "" : "<a:rPr\(attributes)>\(font)\(hyperlink)</a:rPr>"
                output += text.components(separatedBy: "\n").map {
                    "<a:r>\(properties)<a:t\($0.first?.isWhitespace == true || $0.last?.isWhitespace == true ? " xml:space=\"preserve\"" : "")>\(OOXMLPackageWriter.escape($0))</a:t></a:r>"
                }.joined(separator: "<a:br/>")
            }
        }
        return output
    }

    // MARK: - Package parts (dynamic)

    private static let rootRels = OOXMLPackageWriter.xmlDeclaration + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>\
    </Relationships>
    """

    private static func contentTypes(slideCount: Int) -> String {
        var overrides = """
        <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>\
        <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>\
        <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>\
        <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
        """
        for i in 1...slideCount {
            overrides += "<Override PartName=\"/ppt/slides/slide\(i).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
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
