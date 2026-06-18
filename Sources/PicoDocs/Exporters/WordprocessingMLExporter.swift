//
//  WordprocessingMLExporter.swift
//  PicoDocs
//
//  The primary, all-platform DOCX writer: walks the shared Markdown block + inline
//  IR and emits a minimal-but-valid WordprocessingML package — the inverse of
//  `WordConverter`'s read. It is the round-trip oracle (export -> `WordConverter` ->
//  compare), and deliberately mirrors the exact markers `WordConverter` recognizes:
//  `w:pStyle w:val="Heading{N}"` for headings, `w:numPr` for list items,
//  `w:b`/`w:i` run properties for emphasis, `w:hyperlink r:id` for links, and
//  `a:blip r:embed` drawings for images.
//

import Foundation

public struct WordprocessingMLExporter: DocumentExporter {

    public init() {}

    public func accepts(_ format: ExportableFileType) -> Bool { format == .docx }

    public func write(_ result: ConverterResult, format: ExportableFileType) throws -> Data {
        guard format == .docx else { throw ExporterError.notAccepted }

        let builder = Builder(images: Self.imageIndex(result.sections))
        for block in MarkdownBlockParser.parse(result.markdown()) {
            builder.append(block)
        }
        builder.finishRelationships()

        var pkg = try OOXMLPackageWriter()
        try pkg.addXML("[Content_Types].xml", Self.contentTypes(mediaExtensions: builder.mediaExtensions, hasNumbering: builder.usedNumbering))
        try pkg.addXML("_rels/.rels", Self.rootRels)
        try pkg.addXML("word/document.xml", Self.documentXML(body: builder.body))
        try pkg.addXML("word/_rels/document.xml.rels", Self.documentRels(builder.relationships))
        if builder.usedNumbering {
            try pkg.addXML("word/numbering.xml", Self.numberingXML(usedBullet: builder.usedBullet, orderedNumIds: builder.orderedNumIds))
        }
        for media in builder.media {
            try pkg.addData("word/media/\(media.filename)", media.data)
        }
        return try pkg.data()
    }

    // MARK: - Image index (basename -> bytes), from the .image sections

    private static func imageIndex(_ sections: [DocumentSection]) -> [String: Data] {
        var index: [String: Data] = [:]
        for section in sections where section.kind == .image {
            guard let base64 = section.metadata["base64"], !base64.isEmpty,
                  let data = Data(base64Encoded: base64) else { continue }
            let name = (section.sourcePath as NSString?)?.lastPathComponent ?? section.title
            guard let name, !name.isEmpty else { continue }
            index[name] = data
        }
        return index
    }

    // MARK: - Builder

    /// Accumulates body XML, relationships, and media as blocks are appended.
    /// A reference type because it threads shared id counters through the inline
    /// recursion.
    private final class Builder {
        private(set) var body = ""
        private(set) var relationships: [Relationship] = []
        private(set) var media: [(filename: String, data: Data)] = []
        private(set) var mediaExtensions: Set<String> = []
        private(set) var usedBullet = false
        private(set) var orderedNumIds: [Int] = []

        /// Numbering is needed when any list (bullet or ordered) was emitted.
        var usedNumbering: Bool { usedBullet || !orderedNumIds.isEmpty }

        private let images: [String: Data]
        private var relCounter = 0
        private var numberingRelAdded = false
        private var drawingCounter = 0
        private var emittedMediaRel: [String: String] = [:]   // media filename -> relID
        private var nextOrderedNumId = 2                       // 1 is reserved for bullets

        struct Relationship { let id: String; let type: String; let target: String; let external: Bool }

        init(images: [String: Data]) { self.images = images }

        private func nextRelID() -> String { relCounter += 1; return "rId\(relCounter)" }

        func append(_ block: MarkdownBlock) {
            switch block {
            case .heading(let level, let text):
                let pPr = "<w:pPr><w:pStyle w:val=\"Heading\(min(max(level, 1), 6))\"/></w:pPr>"
                body += paragraph(pPr: pPr, content: inlineRuns(text))

            case .paragraph(let text):
                body += paragraph(pPr: "", content: inlineRuns(text))

            case .code(let code):
                // One paragraph, hard line breaks between lines, monospace runs.
                let lines = code.components(separatedBy: "\n")
                var content = ""
                for (i, line) in lines.enumerated() {
                    if i > 0 { content += "<w:r><w:br/></w:r>" }
                    content += textRun(line, bold: false, italic: false, monospace: true)
                }
                body += paragraph(pPr: "", content: content)

            case .blockquote(let lines):
                let pPr = "<w:pPr><w:pStyle w:val=\"Quote\"/></w:pPr>"
                for line in lines {
                    body += paragraph(pPr: pPr, content: inlineRuns(line))
                }

            case .list(let ordered, let items):
                // Each ordered list gets its own numbering instance so Word restarts
                // it at 1 instead of continuing the previous list; bullets can all
                // share one instance (their marker doesn't accumulate).
                let numId: Int
                if ordered {
                    numId = nextOrderedNumId
                    nextOrderedNumId += 1
                    orderedNumIds.append(numId)
                } else {
                    usedBullet = true
                    numId = 1
                }
                let pPr = "<w:pPr><w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"\(numId)\"/></w:numPr></w:pPr>"
                for item in items {
                    body += paragraph(pPr: pPr, content: inlineRuns(item.replacingOccurrences(of: "\n", with: " ")))
                }

            case .table(let rows):
                body += table(rows)

            case .rule:
                // A bottom-bordered empty paragraph. WordConverter drops empty
                // paragraphs, so a rule simply doesn't survive round-trip (acceptable).
                body += "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"auto\"/></w:pBdr></w:pPr></w:p>"
            }
        }

        /// Allocates the numbering relationship once, after the body is built.
        func finishRelationships() {
            guard usedNumbering, !numberingRelAdded else { return }
            numberingRelAdded = true
            relationships.append(Relationship(
                id: nextRelID(),
                type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering",
                target: "numbering.xml",
                external: false
            ))
        }

        // MARK: Inline

        private func inlineRuns(_ markdown: String) -> String {
            renderRuns(MarkdownInlineParser.parse(markdown), bold: false, italic: false)
        }

        private func renderRuns(_ nodes: [MarkdownInline], bold: Bool, italic: Bool) -> String {
            var out = ""
            for node in nodes {
                switch node {
                case .text(let s):
                    out += textRun(s, bold: bold, italic: italic, monospace: false)
                case .code(let s):
                    out += textRun(s, bold: bold, italic: italic, monospace: true)
                case .strong(let children):
                    out += renderRuns(children, bold: true, italic: italic)
                case .emphasis(let children):
                    out += renderRuns(children, bold: bold, italic: true)
                case .link(let label, let destination):
                    let id = nextRelID()
                    relationships.append(Relationship(
                        id: id,
                        type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink",
                        target: destination,
                        external: true
                    ))
                    out += "<w:hyperlink r:id=\"\(id)\">\(renderRuns(label, bold: bold, italic: italic))</w:hyperlink>"
                case .image(let alt, let source):
                    out += imageRun(alt: alt, source: source) ?? textRun(alt, bold: bold, italic: italic, monospace: false)
                case .footnoteReference(let fid):
                    // No footnote part is generated; preserve the marker as literal text.
                    out += textRun("[^\(fid)]", bold: bold, italic: italic, monospace: false)
                }
            }
            return out
        }

        /// Emits a drawing run for an image whose bytes we hold. Returns nil when the
        /// reference isn't a known image (e.g. an external URL), so the caller falls
        /// back to alt text.
        ///
        /// - Looks the bytes up by the reference, falling back to its basename when
        ///   the source carries a path prefix (e.g. `word/media/pic.png`).
        /// - Packages and relates each distinct media file exactly once, reusing the
        ///   relationship for repeated references so the OOXML package can't end up
        ///   with duplicate `word/media/<file>` parts.
        /// - Writes the Markdown alt text into `wp:docPr/@descr`, which
        ///   `WordConverter.imageAltText` reads first, so meaningful alt text survives
        ///   the round-trip instead of collapsing to the filename.
        private func imageRun(alt: String, source: String) -> String? {
            let basename = (source as NSString).lastPathComponent
            let lookupKey = images[source] != nil ? source : basename
            guard let data = images[lookupKey] else { return nil }

            var filename = basename.isEmpty ? source : basename
            var ext = (filename as NSString).pathExtension.lowercased()
            if ext.isEmpty {
                ext = OfficeMediaType.fileExtension(forMIME: OfficeMediaType.mimeType(forExtension: ext))
                filename += ".\(ext)"
            }

            // One media part + one relationship per distinct file; reuse for repeats.
            let relID: String
            if let existing = emittedMediaRel[filename] {
                relID = existing
            } else {
                mediaExtensions.insert(ext)
                media.append((filename, data))
                relID = nextRelID()
                relationships.append(Relationship(
                    id: relID,
                    type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image",
                    target: "media/\(filename)",
                    external: false
                ))
                emittedMediaRel[filename] = relID
            }

            // Each drawing needs a unique non-visual id, even when reusing media.
            drawingCounter += 1
            let docPrID = drawingCounter
            let name = OOXMLPackageWriter.escapeAttribute(filename.isEmpty ? "image" : filename)
            let descr = alt.isEmpty ? "" : " descr=\"\(OOXMLPackageWriter.escapeAttribute(alt))\""
            // Fixed display size (EMU); WordConverter ignores extents on read.
            let cx = 4572000, cy = 3429000
            return """
            <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">\
            <wp:extent cx="\(cx)" cy="\(cy)"/>\
            <wp:docPr id="\(docPrID)" name="\(name)"\(descr)/>\
            <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
            <pic:pic><pic:nvPicPr><pic:cNvPr id="\(docPrID)" name="\(name)"/><pic:cNvPicPr/></pic:nvPicPr>\
            <pic:blipFill><a:blip r:embed="\(relID)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
            <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm>\
            <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>\
            </a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
            """
        }

        // MARK: Table

        private func table(_ rows: [[String]]) -> String {
            guard !rows.isEmpty else { return "" }
            let columns = rows.map(\.count).max() ?? 0
            guard columns > 0 else { return "" }
            let borders = """
            <w:tblBorders>\
            <w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
            <w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
            <w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
            <w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
            <w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
            <w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
            </w:tblBorders>
            """
            let grid = String(repeating: "<w:gridCol w:w=\"2000\"/>", count: columns)
            var out = "<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/>\(borders)</w:tblPr><w:tblGrid>\(grid)</w:tblGrid>"
            for row in rows {
                out += "<w:tr>"
                for col in 0..<columns {
                    let cell = col < row.count ? row[col] : ""
                    out += "<w:tc><w:tcPr><w:tcW w:w=\"0\" w:type=\"auto\"/></w:tcPr>\(cellParagraph(cell))</w:tc>"
                }
                out += "</w:tr>"
            }
            out += "</w:tbl>"
            return out
        }

        /// A table cell paragraph. `<br>` separators become hard line breaks; each
        /// segment is parsed for inline emphasis/links so `**x**` etc. round-trip.
        private func cellParagraph(_ cell: String) -> String {
            let segments = cell.components(separatedBy: "<br>")
            var content = ""
            for (i, segment) in segments.enumerated() {
                if i > 0 { content += "<w:r><w:br/></w:r>" }
                content += inlineRuns(segment)
            }
            return "<w:p>\(content)</w:p>"
        }

        // MARK: Run/paragraph primitives

        private func paragraph(pPr: String, content: String) -> String {
            "<w:p>\(pPr)\(content)</w:p>"
        }

        private func textRun(_ text: String, bold: Bool, italic: Bool, monospace: Bool) -> String {
            "<w:r>\(runProperties(bold: bold, italic: italic, monospace: monospace))<w:t xml:space=\"preserve\">\(OOXMLPackageWriter.escape(text))</w:t></w:r>"
        }

        private func runProperties(bold: Bool, italic: Bool, monospace: Bool) -> String {
            var inner = ""
            if bold { inner += "<w:b/>" }
            if italic { inner += "<w:i/>" }
            if monospace { inner += "<w:rFonts w:ascii=\"Consolas\" w:hAnsi=\"Consolas\" w:cs=\"Consolas\"/>" }
            return inner.isEmpty ? "" : "<w:rPr>\(inner)</w:rPr>"
        }
    }

    // MARK: - Package parts

    private static let rootRels = OOXMLPackageWriter.xmlDeclaration + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
    </Relationships>
    """

    private static func contentTypes(mediaExtensions: Set<String>, hasNumbering: Bool) -> String {
        var defaults = """
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>
        """
        for ext in mediaExtensions.sorted() {
            defaults += "<Default Extension=\"\(ext)\" ContentType=\"\(OfficeMediaType.mimeType(forExtension: ext))\"/>"
        }
        var overrides = "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
        if hasNumbering {
            overrides += "<Override PartName=\"/word/numbering.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml\"/>"
        }
        return OOXMLPackageWriter.xmlDeclaration + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\(defaults)\(overrides)</Types>
        """
    }

    private static func documentXML(body: String) -> String {
        OOXMLPackageWriter.xmlDeclaration + """
        <w:document \
        xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">\
        <w:body>\(body)<w:sectPr/></w:body></w:document>
        """
    }

    private static func documentRels(_ relationships: [Builder.Relationship]) -> String {
        var rels = ""
        for rel in relationships {
            let mode = rel.external ? " TargetMode=\"External\"" : ""
            rels += "<Relationship Id=\"\(rel.id)\" Type=\"\(rel.type)\" Target=\"\(OOXMLPackageWriter.escapeAttribute(rel.target))\"\(mode)/>"
        }
        return OOXMLPackageWriter.xmlDeclaration + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)</Relationships>
        """
    }

    /// Builds `numbering.xml` for the lists that were actually emitted. Bullets map
    /// to a single shared instance (`numId` 1); every ordered list gets its own
    /// `numId` over a shared decimal abstract definition, each with a `startOverride`
    /// of 1 so Word restarts separate lists instead of continuing the count.
    private static func numberingXML(usedBullet: Bool, orderedNumIds: [Int]) -> String {
        var abstracts = ""
        if usedBullet {
            abstracts += """
            <w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/><w:lvlText w:val="•"/>\
            <w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum>
            """
        }
        if !orderedNumIds.isEmpty {
            abstracts += """
            <w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/>\
            <w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum>
            """
        }
        var nums = ""
        if usedBullet {
            nums += "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num>"
        }
        for numId in orderedNumIds {
            nums += """
            <w:num w:numId="\(numId)"><w:abstractNumId w:val="1"/>\
            <w:lvlOverride w:ilvl="0"><w:startOverride w:val="1"/></w:lvlOverride></w:num>
            """
        }
        return OOXMLPackageWriter.xmlDeclaration + """
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\(abstracts)\(nums)</w:numbering>
        """
    }
}
