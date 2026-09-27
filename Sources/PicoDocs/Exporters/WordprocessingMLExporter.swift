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
#if canImport(ImageIO)
import ImageIO
#endif

public struct WordprocessingMLExporter: DocumentExporter {

    public init() {}

    public func accepts(_ format: ExportableFileType) -> Bool { format == .docx }

    public func write(_ result: ConverterResult, format: ExportableFileType) throws -> Data {
        guard format == .docx else { throw ExporterError.notAccepted }
        try OfficeDocumentBlocks.rejectUnsupportedCoverOnlyInput(result)
        let result = PicoDocsEngine.withSynthesizedImageReferences(result)

        let blocks = OfficeDocumentBlocks.parse(result)
        let builder = Builder(images: Self.imageIndex(result.sections), blocks: blocks)
        for block in blocks {
            builder.append(block)
            if let failure = builder.failure { throw failure }
        }
        builder.finishRelationships()

        var pkg = try OOXMLPackageWriter()
        try pkg.addCoreProperties(result)
        try pkg.addXML("[Content_Types].xml", OOXMLPackageWriter.withCoreContentType(Self.contentTypes(mediaExtensions: builder.mediaExtensions, hasNumbering: builder.usedNumbering)))
        try pkg.addXML("_rels/.rels", OOXMLPackageWriter.withCoreRelationship(Self.rootRels))
        try pkg.addXML("word/styles.xml", Self.stylesXML)
        try pkg.addXML("word/document.xml", Self.documentXML(body: builder.body))
        try pkg.addXML("word/_rels/document.xml.rels", Self.documentRels(builder.relationships))
        if builder.usedNumbering {
            try pkg.addXML("word/numbering.xml", Self.numberingXML(usedBullet: builder.usedBullet, orderedNumIds: builder.orderedNumIds, continuationNumID: builder.continuationNumID))
        }
        for media in builder.media {
            try pkg.addData("word/media/\(media.filename)", media.data)
        }
        return try pkg.data()
    }

    static func imageExtents(_ data: Data, metadata: [String: String] = [:]) -> (Int, Int) {
        let maximumWidth = 4_572_000.0, maximumHeight = 3_429_000.0
        func fit(_ width: Double, _ height: Double) -> (Int, Int) {
            let ratio = width / height
            if ratio >= maximumWidth / maximumHeight { return (Int(maximumWidth), max(1, Int((maximumWidth / ratio).rounded()))) }
            return (max(1, Int((maximumHeight * ratio).rounded())), Int(maximumHeight))
        }
        #if canImport(ImageIO)
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
           width.isFinite, height.isFinite, width > 0, height > 0 {
            return fit(width, height)
        }
        #endif
        let declared = Double(metadata["width"] ?? "").flatMap { width in
            Double(metadata["height"] ?? "").flatMap { OfficeImageDimensions.valid(width, $0) }
        }
        if let (width, height) = OfficeImageDimensions.read(data) ?? declared {
            return fit(width, height)
        }
        return (Int(maximumWidth), Int(maximumHeight))
    }

    // MARK: - Image index, from the .image sections

    /// A distinct embedded image: its bytes and the unique media part filename it
    /// will be written under (`word/media/<mediaFilename>`).
    private final class IndexedImage {
        let base64: String
        let mediaFilename: String
        let metadata: [String: String]
        let budget: OfficeMediaDecodeBudget
        private var attemptedDecode = false
        private var cachedData: Data?
        init(base64: String, mediaFilename: String, metadata: [String: String], budget: OfficeMediaDecodeBudget) {
            self.base64 = base64; self.mediaFilename = mediaFilename; self.metadata = metadata; self.budget = budget
        }
        func decodedData() throws -> Data? {
            if !attemptedDecode { cachedData = try budget.decode(base64); attemptedDecode = true }
            return cachedData
        }
    }

    /// Resolves an inline image reference to an embedded carrier. Keyed by full
    /// source path *and* by basename — the basename map only when unambiguous — so
    /// two carriers that share a basename (`charts/logo.png` vs `headers/logo.png`)
    /// stay distinct instead of one overwriting the other.
    private struct ImageIndex {
        let byPath: [String: [IndexedImage]]
        let byBasename: [String: [IndexedImage]]

        func lookup(_ source: String) throws -> IndexedImage? {
            if let image = try byPath[source]?.last(where: { try $0.decodedData() != nil }) { return image }
            let candidates = try byBasename[WordprocessingMLExporter.portableBasename(source)]?.filter { try $0.decodedData() != nil } ?? []
            return candidates.count == 1 ? candidates[0] : nil
        }
    }

    private static func portableBasename(_ path: String) -> String {
        (path.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
    }

    private static func imageIndex(_ sections: [DocumentSection]) -> ImageIndex {
        var byPath: [String: [IndexedImage]] = [:]
        var byBasename: [String: [IndexedImage]] = [:]
        var usedFilenames: Set<String> = []
        var nextFilenameSuffix: [String: Int] = [:]
        let budget = OfficeMediaDecodeBudget()

        for section in sections where section.kind == .image {
            guard let base64 = section.metadata["base64"], !base64.isEmpty else { continue }

            // The carrier's display name (basename of the source path, else title).
            let name = [section.sourcePath, section.title].compactMap { $0 }.first { !$0.isEmpty }.map(portableBasename)
            // Pick a stem + extension; fall back to the declared MIME for the
            // extension so a name like "logo" (or no name) still gets a type Office
            // recognizes rather than `.bin`/octet-stream.
            let mime = section.metadata["mimeType"]
            var ext = (name as NSString?)?.pathExtension.lowercased() ?? ""
            if OfficeMediaType.mimeType(forExtension: ext) == "application/octet-stream" { ext = OfficeMediaType.fileExtension(forMIME: mime ?? "") }
            let stem = (name as NSString?)?.deletingPathExtension ?? ""

            // Allocate a unique media filename (suffix on basename collisions) so
            // distinct images never share one `word/media/<file>` part.
            let invalidFilename = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: ":\\/?*<>|\""))
            let safeStem = String(stem.unicodeScalars.map { invalidFilename.contains($0) ? "_" : Character($0) }).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let base = safeStem.isEmpty ? "image\(usedFilenames.count + 1)" : safeStem
            if ext.unicodeScalars.contains(where: invalidFilename.contains) { ext = OfficeMediaType.fileExtension(forMIME: mime ?? "") }
            var mediaFilename = "\(base).\(ext)"
            let identity = mediaFilename.lowercased()
            var n = nextFilenameSuffix[identity, default: 2]
            while usedFilenames.contains(mediaFilename.lowercased()) {
                mediaFilename = "\(base)-\(n).\(ext)"
                n += 1
            }
            nextFilenameSuffix[identity] = n
            usedFilenames.insert(mediaFilename.lowercased())

            let image = IndexedImage(base64: base64, mediaFilename: mediaFilename, metadata: section.metadata, budget: budget)
            if let identity = [section.sourcePath, section.title].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
                byPath[identity, default: []].append(image)
            }
            if let name, !name.isEmpty {
                byBasename[name, default: []].append(image)
            }
        }
        return ImageIndex(byPath: byPath, byBasename: byBasename)
    }

    // MARK: - Builder

    /// Accumulates body XML, relationships, and media as blocks are appended.
    /// A reference type because it threads shared id counters through the inline
    /// recursion.
    private final class Builder {
        private(set) var body = ""
        private(set) var failure: Error?
        private(set) var relationships: [Relationship] = []
        private(set) var media: [(filename: String, data: Data)] = []
        private(set) var mediaExtensions: Set<String> = []
        private(set) var usedBullet = false
        private(set) var continuationNumID: Int?
        private(set) var orderedNumIds: [(id: Int, level: Int, start: Int)] = []

        /// Numbering is needed when any list (bullet or ordered) was emitted.
        var usedNumbering: Bool { usedBullet || !orderedNumIds.isEmpty }

        private let images: ImageIndex
        private var relCounter = 0
        private var numberingRelAdded = false
        private var drawingCounter = 0
        private var emittedMediaRel: [String: String] = [:]   // media filename -> relID
        private var nextOrderedNumId = 2                       // 1 is reserved for bullets

        struct Relationship { let id: String; let type: String; let target: String; let external: Bool }

        private var headingBookmarks: [String] = []
        private var fragmentBookmarks: [String: String] = [:]
        private var headingIndex = 0

        init(images: ImageIndex, blocks: [MarkdownBlock]) {
            self.images = images
            let titles = blocks.compactMap { block -> String? in
                guard case .heading(_, let text) = block else { return nil }
                return MarkdownInlineParser.parse(text).plainText
            }
            for slug in MarkdownHeadingAnchors.slugs(titles) {
                // Generated names are short and valid even for Unicode headings.
                let name = "heading_\(headingBookmarks.count + 1)"
                headingBookmarks.append(name)
                fragmentBookmarks[slug] = name
            }
        }

        private func nextRelID() -> String { relCounter += 1; return "rId\(relCounter)" }

        func append(_ block: MarkdownBlock) {
            switch block {
            case .heading(let level, let text):
                let pPr = "<w:pPr><w:pStyle w:val=\"Heading\(min(max(level, 1), 6))\"/></w:pPr>"
                let bookmark = headingBookmarks[headingIndex]
                let id = headingIndex
                headingIndex += 1
                body += paragraph(pPr: pPr, content: "<w:bookmarkStart w:id=\"\(id)\" w:name=\"\(bookmark)\"/>" + inlineRuns(text) + "<w:bookmarkEnd w:id=\"\(id)\"/>")

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
                body += paragraph(pPr: "<w:pPr><w:pStyle w:val=\"PicoCodeBlock\"/></w:pPr>", content: content)

            case .blockquote(let lines):
                let pPr = "<w:pPr><w:pStyle w:val=\"Quote\"/></w:pPr>"
                let content = lines.map(inlineRuns).joined(separator: "<w:r><w:br/></w:r>")
                body += paragraph(pPr: pPr, content: content)

            case .list(let list):
                appendList(list)

            case .table(let rows):
                body += table(rows)

            case .rule:
                // A bottom-bordered empty paragraph. WordConverter drops empty
                // paragraphs, so a rule simply doesn't survive round-trip (acceptable).
                body += "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"auto\"/></w:pBdr></w:pPr></w:p>"
            }
        }

        private func appendList(_ list: MarkdownList, level: Int = 0) {
            let level = min(level, 8)
            var numId = 1
            var expected = list.items.first?.number ?? 1
            func allocate(_ start: Int) -> Int {
                let id = nextOrderedNumId
                nextOrderedNumId += 1
                orderedNumIds.append((id, level, start))
                return id
            }
            if list.ordered { numId = allocate(expected) } else { usedBullet = true }
            for item in list.items {
                if let number = item.number, number != expected { numId = allocate(number) }
                if let number = item.number { expected = min(number, Int.max - 1) + 1 }
                for (index, content) in item.content.enumerated() {
                    switch content {
                    case .text(let text):
                        if index > 0, continuationNumID == nil {
                            continuationNumID = nextOrderedNumId
                            nextOrderedNumId += 1
                        }
                        let pPr = index == 0
                            ? "<w:pPr><w:numPr><w:ilvl w:val=\"\(level)\"/><w:numId w:val=\"\(numId)\"/></w:numPr></w:pPr>"
                            : "<w:pPr><w:pStyle w:val=\"PicoListContinuation\"/><w:numPr><w:ilvl w:val=\"\(level)\"/><w:numId w:val=\"\(continuationNumID!)\"/></w:numPr><w:ind w:left=\"\((level + 1) * 720)\"/></w:pPr>"
                        body += paragraph(pPr: pPr, content: inlineRuns(text))
                    case .list(let child): appendList(child, level: level + 1)
                    }
                }
            }
        }

        /// Allocates the numbering relationship once, after the body is built.
        func finishRelationships() {
            relationships.append(Relationship(id: nextRelID(), type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles", target: "styles.xml", external: false))
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
                case .lineBreak(let hard):
                    out += hard ? "<w:r><w:br/></w:r>" : textRun(" ", bold: bold, italic: italic, monospace: false)
                case .code(let s):
                    out += textRun(s, bold: bold, italic: italic, monospace: true)
                case .strong(let children):
                    out += renderRuns(children, bold: true, italic: italic)
                case .emphasis(let children):
                    out += renderRuns(children, bold: bold, italic: true)
                case .link(let label, let destination):
                    if destination.hasPrefix("#") {
                        let fragment = String(destination.dropFirst())
                        if let bookmark = fragmentBookmarks[fragment.removingPercentEncoding ?? fragment] {
                            out += "<w:hyperlink w:anchor=\"\(bookmark)\">\(renderRuns(label, bold: bold, italic: italic))</w:hyperlink>"
                        } else {
                            // A missing local target cannot become an external URI.
                            out += renderRuns(label, bold: bold, italic: italic)
                        }
                        continue
                    }
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
                    // Keep textual footnotes paired using explicit marker provenance.
                    let id = fid.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "]", with: "\\]")
                    out += "<w:r><w:rPr><w:rStyle w:val=\"PicoFootnoteMarker\"/></w:rPr><w:t xml:space=\"preserve\">\(OOXMLPackageWriter.escape("[^" + id + "]"))</w:t></w:r>"
                }
            }
            return out
        }

        /// Emits a drawing run for an image whose bytes we hold. Returns nil when the
        /// reference isn't a known image (e.g. an external URL), so the caller falls
        /// back to alt text.
        ///
        /// - Resolves the carrier via the index (full path, else unambiguous basename),
        ///   which already assigned it a unique, correctly-typed media filename.
        /// - Packages and relates each distinct media file exactly once, reusing the
        ///   relationship for repeated references so the OOXML package can't end up
        ///   with duplicate `word/media/<file>` parts.
        /// - Writes the Markdown alt text into `wp:docPr/@descr`, which
        ///   `WordConverter.imageAltText` reads first, so meaningful alt text survives
        ///   the round-trip instead of collapsing to the filename.
        private func imageRun(alt: String, source: String) -> String? {
            guard failure == nil else { return nil }
            do { return try checkedImageRun(alt: alt, source: source) }
            catch { failure = error; return nil }
        }

        private func checkedImageRun(alt: String, source: String) throws -> String? {
            guard let image = try images.lookup(source), let data = try image.decodedData() else { return nil }
            let filename = image.mediaFilename
            let ext = (filename as NSString).pathExtension.lowercased()

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
                    target: "media/\(filename.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? filename)",
                    external: false
                ))
                emittedMediaRel[filename] = relID
            }

            // Each drawing needs a unique non-visual id, even when reusing media.
            drawingCounter += 1
            let docPrID = drawingCounter
            let name = OOXMLPackageWriter.escapeAttribute(filename)
            let descr = alt.isEmpty ? "" : " descr=\"\(OOXMLPackageWriter.escapeAttribute(alt))\""
            // Fit the intrinsic aspect ratio inside the existing 5 × 3.75-inch box.
            let (cx, cy) = WordprocessingMLExporter.imageExtents(data, metadata: image.metadata)
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
            let content = renderRuns(MarkdownInlineParser.parse(cell, tableCell: true), bold: false, italic: false)
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
            if monospace { inner += "<w:rStyle w:val=\"PicoCode\"/><w:rFonts w:ascii=\"Consolas\" w:hAnsi=\"Consolas\" w:cs=\"Consolas\"/>" }
            if bold { inner += "<w:b/>" }
            if italic { inner += "<w:i/>" }
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
        for ext in mediaExtensions.sorted() where ext != "xml" && ext != "rels" {
            defaults += "<Default Extension=\"\(OOXMLPackageWriter.escapeAttribute(ext))\" ContentType=\"\(OfficeMediaType.mimeType(forExtension: ext))\"/>"
        }
        var overrides = "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
        overrides += "<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/>"
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
            let target = rel.external ? Self.relationshipURI(rel.target) : rel.target
            rels += "<Relationship Id=\"\(rel.id)\" Type=\"\(rel.type)\" Target=\"\(OOXMLPackageWriter.escapeAttribute(target))\"\(mode)/>"
        }
        return OOXMLPackageWriter.xmlDeclaration + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)</Relationships>
        """
    }

    private static func relationshipURI(_ target: String) -> String {
        OOXMLPackageWriter.relationshipURI(target)
    }

    private static var stylesXML: String {
        var styles = "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/></w:style>"
        for level in 1...6 {
            styles += "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(level)\"><w:name w:val=\"heading \(level)\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:keepNext/><w:spacing w:before=\"240\" w:after=\"120\"/><w:outlineLvl w:val=\"\(level - 1)\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"\(40 - level * 2)\"/></w:rPr></w:style>"
        }
        styles += "<w:style w:type=\"paragraph\" w:styleId=\"PicoListContinuation\"><w:name w:val=\"List Continuation\"/><w:basedOn w:val=\"Normal\"/></w:style>"
        styles += "<w:style w:type=\"paragraph\" w:styleId=\"Quote\"><w:name w:val=\"Quote\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:ind w:left=\"720\" w:right=\"720\"/></w:pPr><w:rPr><w:i/></w:rPr></w:style>"
        styles += "<w:style w:type=\"paragraph\" w:styleId=\"PicoCodeBlock\"><w:name w:val=\"Code Block\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:spacing w:before=\"0\" w:after=\"0\"/></w:pPr><w:rPr><w:rFonts w:ascii=\"Consolas\" w:hAnsi=\"Consolas\"/></w:rPr></w:style>"
        styles += "<w:style w:type=\"character\" w:styleId=\"PicoFootnoteMarker\"><w:name w:val=\"Footnote Marker\"/></w:style>"
        styles += "<w:style w:type=\"character\" w:styleId=\"PicoCode\"><w:name w:val=\"Inline Code\"/><w:rPr><w:rFonts w:ascii=\"Consolas\" w:hAnsi=\"Consolas\"/></w:rPr></w:style>"
        return OOXMLPackageWriter.xmlDeclaration + "<w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">\(styles)</w:styles>"
    }

    /// Builds `numbering.xml` for the lists that were actually emitted. Bullets map
    /// to a single shared instance (`numId` 1); every ordered list gets its own
    /// `numId` over a shared decimal abstract definition, each with a `startOverride`
    /// of 1 so Word restarts separate lists instead of continuing the count.
    private static func numberingXML(usedBullet: Bool, orderedNumIds: [(id: Int, level: Int, start: Int)], continuationNumID: Int?) -> String {
        func levels(ordered: Bool) -> String {
            (0..<9).map { level in
                "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(ordered ? "decimal" : "bullet")\"/><w:lvlText w:val=\"\(ordered ? "%\(level + 1)." : "•")\"/><w:pPr><w:ind w:left=\"\((level + 1) * 720)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
            }.joined()
        }
        var definitions = "", instances = ""
        if usedBullet { definitions += "<w:abstractNum w:abstractNumId=\"0\">\(levels(ordered: false))</w:abstractNum>"; instances += "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num>" }
        if !orderedNumIds.isEmpty {
            definitions += "<w:abstractNum w:abstractNumId=\"1\">\(levels(ordered: true))</w:abstractNum>"
            for instance in orderedNumIds {
                instances += "<w:num w:numId=\"\(instance.id)\"><w:abstractNumId w:val=\"1\"/><w:lvlOverride w:ilvl=\"\(instance.level)\"><w:startOverride w:val=\"\(instance.start)\"/></w:lvlOverride></w:num>"
            }
        }
        if let continuationNumID {
            let markerless = (0..<9).map { level in
                "<w:lvl w:ilvl=\"\(level)\"><w:numFmt w:val=\"none\"/><w:lvlText w:val=\"\"/><w:pPr><w:ind w:left=\"\((level + 1) * 720)\"/></w:pPr></w:lvl>"
            }.joined()
            definitions += "<w:abstractNum w:abstractNumId=\"2\">\(markerless)</w:abstractNum>"
            instances += "<w:num w:numId=\"\(continuationNumID)\"><w:abstractNumId w:val=\"2\"/></w:num>"
        }
        return OOXMLPackageWriter.xmlDeclaration + "<w:numbering xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">\(definitions)\(instances)</w:numbering>"
    }
}
