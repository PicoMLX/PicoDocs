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

        let slides = Self.slides(from: result)
        let count = max(slides.count, 1)
        let effectiveSlides = slides.isEmpty ? [Slide(title: "", body: [])] : slides

        var pkg = try OOXMLPackageWriter()
        try pkg.addXML("[Content_Types].xml", Self.contentTypes(slideCount: count))
        try pkg.addXML("_rels/.rels", Self.rootRels)
        try pkg.addXML("ppt/presentation.xml", Self.presentationXML(slideCount: count))
        try pkg.addXML("ppt/_rels/presentation.xml.rels", Self.presentationRels(slideCount: count))
        try pkg.addXML("ppt/slideMasters/slideMaster1.xml", PPTXTemplates.slideMaster)
        try pkg.addXML("ppt/slideMasters/_rels/slideMaster1.xml.rels", PPTXTemplates.slideMasterRels)
        try pkg.addXML("ppt/slideLayouts/slideLayout1.xml", PPTXTemplates.slideLayout)
        try pkg.addXML("ppt/slideLayouts/_rels/slideLayout1.xml.rels", PPTXTemplates.slideLayoutRels)
        try pkg.addXML("ppt/theme/theme1.xml", PPTXTemplates.theme)
        for (i, slide) in effectiveSlides.enumerated() {
            try pkg.addXML("ppt/slides/slide\(i + 1).xml", Self.slideXML(slide))
            try pkg.addXML("ppt/slides/_rels/slide\(i + 1).xml.rels", PPTXTemplates.slideRels)
        }
        return try pkg.data()
    }

    // MARK: - Slide model

    struct Slide { let title: String; let body: [String] }

    private static func slides(from result: ConverterResult) -> [Slide] {
        // Explicit slide sections map 1:1.
        let slideSections = result.sections.filter { $0.kind == .slide }
        if !slideSections.isEmpty {
            return slideSections.map { section in
                Slide(title: section.title ?? "", body: bodyLines(MarkdownBlockParser.parse(section.markdown)))
            }
        }

        // Otherwise segment the merged Markdown at top-level headings.
        var slides: [Slide] = []
        var title = ""
        var body: [String] = []
        var started = false
        func flush() { if started { slides.append(Slide(title: title, body: body)) } }

        for block in MarkdownBlockParser.parse(result.markdown()) {
            if case .heading(let level, let text) = block, level <= 2 {
                flush()
                title = text
                body = []
                started = true
            } else {
                started = true
                body += bodyLines([block])
            }
        }
        flush()
        return slides
    }

    private static func bodyLines(_ blocks: [MarkdownBlock]) -> [String] {
        var lines: [String] = []
        for block in blocks {
            switch block {
            case .heading(_, let text):
                lines.append(plain(text))
            case .paragraph(let text):
                for line in text.components(separatedBy: "\n") where !line.isEmpty {
                    lines.append(plain(line))
                }
            case .list(_, let items):
                for item in items { lines.append(plain(item)) }
            case .code(let code):
                for line in code.components(separatedBy: "\n") { lines.append(line) }
            case .blockquote(let quoteLines):
                for line in quoteLines { lines.append(plain(line)) }
            case .table(let rows):
                for row in rows { lines.append(row.map { plain($0) }.joined(separator: "\t")) }
            case .rule:
                continue
            }
        }
        return lines
    }

    private static func plain(_ markdown: String) -> String {
        MarkdownInlineParser.parse(markdown).plainText
    }

    // MARK: - Slide part

    private static func slideXML(_ slide: Slide) -> String {
        let titleRuns = "<a:p><a:r><a:t>\(OOXMLPackageWriter.escape(slide.title))</a:t></a:r></a:p>"
        let bodyParagraphs: String
        if slide.body.isEmpty {
            bodyParagraphs = "<a:p/>"
        } else {
            bodyParagraphs = slide.body.map {
                "<a:p><a:r><a:t>\(OOXMLPackageWriter.escape($0))</a:t></a:r></a:p>"
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
