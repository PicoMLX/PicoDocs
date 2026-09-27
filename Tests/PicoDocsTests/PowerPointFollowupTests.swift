import Foundation
import Testing
import ZIPFoundation
import SwiftSoup
@testable import PicoDocs

struct PowerPointFollowupTests {
    @Test func renderBudgetRejectsExpansionBeforeRetainingRuns() throws {
        typealias B = PowerPointConverterTests
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Title"))])
        func render(_ body: String, limit: Int) throws -> (String, PowerPointConverter.RenderBudget) {
            let package = PowerPointPackage(archive: try #require(Archive(data: data, accessMode: .read)))
            let budget = PowerPointConverter.RenderBudget(maximumBytes: limit, archive: package)
            var context = PowerPointConverter.SlideContext(archive: package, partPath: "ppt/slides/s.xml", relationships: [:], images: .init())
            context.renderBudget = budget
            let xml = try SwiftSoup.parse("<a:p>" + body + "</a:p>", "", SwiftSoup.Parser.xmlParser())
            let paragraph = try #require(xml.getElementsByTag("a:p").first())
            return (PowerPointConverter.renderRuns(paragraph, context: &context), budget)
        }
        let escaped = "<a:r><a:t>" + String(repeating: "*", count: 100) + "</a:t></a:r>"
        let exact = try render(escaped, limit: 200)
        #expect(exact.0 == String(repeating: "\\*", count: 100)); #expect(!exact.1.failed)
        let rejected = try render(escaped, limit: 199)
        #expect(rejected.0.isEmpty); #expect(rejected.1.failed)
        let plain = "<a:r><a:t>" + String(repeating: "x", count: 100) + "</a:t></a:r>"
        let cumulative = try render(plain + plain, limit: 199)
        #expect(cumulative.0.isEmpty); #expect(cumulative.1.failed)
    }

    @Test func renderBudgetBoundsJoinsAndNewlineExpansion() throws {
        typealias B = PowerPointConverterTests
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Title"))])
        func budget(_ bytes: Int) throws -> PowerPointConverter.RenderBudget {
            let package = PowerPointPackage(archive: try #require(Archive(data: data, accessMode: .read)))
            return .init(maximumBytes: bytes, archive: package)
        }
        let join = try budget(5)
        #expect(join.join(["aa", "bb"], separator: " ") == "aa bb")
        #expect(join.join(["aaa", "bb"], separator: " ").isEmpty); #expect(join.failed)
        let lines = try budget(4)
        #expect(lines.replaceNewlines("a\nb", with: "  \n").isEmpty); #expect(lines.failed)
        let rule = try budget(5)
        #expect(PowerPointConverter.escapeBlockMarkers("---", budget: rule).isEmpty); #expect(rule.failed)
    }

    @Test func punctuationHeavySlidesFailInsideRenderingAtSmallLimits() async throws {
        typealias B = PowerPointConverterTests
        let run = "<a:p><a:r><a:t>" + String(repeating: "*", count: 1024) + "</a:t></a:r></a:p>"
        let shape = B.shape(placeholder: nil, paragraphs: [run])
        let data = B.deck(slides: [.init(file: "s.xml", shapes: shape)])
        await #expect(throws: PicoDocsError.fileCorrupted) {
            try await PowerPointConverter(maximumRenderedBytes: 1536).convert(data, info: StreamInfo(detectedFormat: .pptx))
        }
        let result = try await PowerPointConverter(maximumRenderedBytes: 4096).convert(data, info: StreamInfo(detectedFormat: .pptx))
        #expect(result.markdown() == String(repeating: "\\*", count: 1024))
    }


    @Test func strictGraphicPayloadURIsRetainTablesAndOLEPreviews() async throws {
        typealias B = PowerPointConverterTests
        let picture = #"<p:pic><p:nvPicPr><p:cNvPr name="Preview"/></p:nvPicPr><p:blipFill><a:blip r:embed="image"/></p:blipFill></p:pic>"#
        let table = "<a:tbl><a:tr><a:tc><a:txBody><a:p><a:r><a:t>Table cell</a:t></a:r></a:p></a:txBody></a:tc></a:tr></a:tbl>"
        for (uri, payload) in [("http://purl.oclc.org/ooxml/drawingml/table", table), ("http://purl.oclc.org/ooxml/presentationml/ole", "<p:oleObj>" + picture + "</p:oleObj>")] {
            let frame = "<p:graphicFrame xmlns:p='http://purl.oclc.org/ooxml/presentationml/main' xmlns:a='http://purl.oclc.org/ooxml/drawingml/main'><a:graphic><a:graphicData uri='\(uri)'>\(payload)</a:graphicData></a:graphic></p:graphicFrame>"
            let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Title") + frame, relationships: [("image", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", "../media/preview.png")])], extraParts: [("ppt/media/preview.png", [1,2,3])])
            let result = try await PicoDocsEngine.convert(data: data, filename: "strict.pptx")
            #expect(result.markdown().contains(uri.hasSuffix("/table") ? "Table cell" : "Preview"))
            #expect(result.sections.contains { $0.kind == .image } == uri.hasSuffix("/ole"))
        }
    }

    @Test func recognizedGraphicPayloadsEnforceRequiredExtensions() async throws {
        typealias B = PowerPointConverterTests
        for uri in ["http://schemas.openxmlformats.org/drawingml/2006/table", "http://purl.oclc.org/ooxml/drawingml/table", "http://schemas.openxmlformats.org/presentationml/2006/ole", "http://purl.oclc.org/ooxml/presentationml/ole", "urn:opaque"] {
            for ignorable in [false, true] {
                let ignored = ignorable ? " mc:Ignorable='u'" : ""
                let payload = uri.hasSuffix("/table") ? "<a:tbl/>" : "<p:oleObj/>"
                let frame = "<p:graphicFrame><a:graphic><a:graphicData xmlns:u='urn:unsupported'\(ignored) uri='\(uri)'><u:required/>\(payload)</a:graphicData></a:graphic></p:graphicFrame>"
                let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Title") + frame)])
                if ignorable || uri == "urn:opaque" {
                    #expect(try await PicoDocsEngine.convert(data: data, filename: "extension.pptx").markdown().contains("Title"))
                } else {
                    await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: data, filename: "extension.pptx") }
                }
            }
        }
    }


    @Test func opaqueGraphicDataCannotExposeAnOLEPreview() async throws {
        typealias B = PowerPointConverterTests
        let picture = #"<p:pic><p:nvPicPr><p:cNvPr name="Preview"/></p:nvPicPr><p:blipFill><a:blip r:embed="image"/></p:blipFill></p:pic>"#
        for uri in ["http://schemas.openxmlformats.org/presentationml/2006/ole", "http://schemas.openxmlformats.org/drawingml/2006/chart", "urn:unsupported", ""] {
            let attribute = uri.isEmpty ? "" : " uri='\(uri)'"
            let frame = "<p:graphicFrame><a:graphic><a:graphicData\(attribute)><p:oleObj>" + picture + "</p:oleObj></a:graphicData></a:graphic></p:graphicFrame>"
            let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Title") + frame, relationships: [("image", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", "../media/preview.png")])], extraParts: [("ppt/media/preview.png", [1,2,3])])
            let result = try await PicoDocsEngine.convert(data: data, filename: "ole.pptx")
            #expect(result.sections.contains { $0.kind == .image } == uri.hasSuffix("/ole"))
            #expect(result.markdown().contains("Preview") == uri.hasSuffix("/ole"))
        }
    }

    @Test func renderedSlidesShareACumulativeByteBudget() async throws {
        typealias B = PowerPointConverterTests
        let shape = B.shape(placeholder: nil, paragraphs: ["<a:p><a:r><a:t>**literal**</a:t></a:r></a:p>"])
        let one = B.deck(slides: [.init(file: "s.xml", shapes: shape)])
        let info = StreamInfo(detectedFormat: .pptx)
        let result = try await PowerPointConverter().convert(one, info: info)
        var cost = (result.title?.utf8.count ?? 0) + (result.author?.utf8.count ?? 0)
        for section in result.sections {
            cost += section.markdown.utf8.count
            cost += section.title?.utf8.count ?? 0
            cost += section.sourcePath?.utf8.count ?? 0
            for (key, value) in section.metadata where key != "base64" {
                cost += key.utf8.count
                cost += value.utf8.count
            }
        }
        _ = try await PowerPointConverter(maximumRenderedBytes: cost).convert(one, info: info)
        await #expect(throws: PicoDocsError.fileCorrupted) { try await PowerPointConverter(maximumRenderedBytes: cost - 1).convert(one, info: info) }
        let two = B.deck(slides: [.init(file: "s.xml", shapes: shape), .init(file: "t.xml", shapes: shape)])
        await #expect(throws: PicoDocsError.fileCorrupted) { try await PowerPointConverter(maximumRenderedBytes: cost).convert(two, info: info) }
    }

    @Test func embeddedImageReferencesCannotOccupyAURLScheme() async throws {
        typealias B = PowerPointConverterTests
        let picture = #"<p:pic><p:nvPicPr><p:cNvPr name="Preview"/></p:nvPicPr><p:blipFill><a:blip r:embed="image"/></p:blipFill></p:pic>"#
        for filename in ["javascript:preview.png", "data:preview.png", "file:preview.png"] {
            let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Title") + picture, relationships: [("image", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", "../media/" + filename)])], extraParts: [("ppt/media/" + filename, [1,2,3])])
            let result = try await PicoDocsEngine.convert(data: data, filename: "images.pptx")
            let carrier = try #require(result.sections.first { $0.kind == .image })
            #expect(carrier.metadata["markdownReference"]?.hasPrefix("./") == true)
            #expect(try DocumentRenderer.render(result, to: .html).contains("data:image/png;base64,AQID"))
        }
    }


    @Test func opaqueGraphicDataCannotExposeATable() async throws {
        typealias B = PowerPointConverterTests
        for uri in ["http://schemas.openxmlformats.org/drawingml/2006/table", "http://schemas.openxmlformats.org/drawingml/2006/chart", "urn:unsupported", ""] {
            let attribute = uri.isEmpty ? "" : " uri='\(uri)'"
            let table = "<p:graphicFrame><a:graphic><a:graphicData\(attribute)><a:tbl><a:tr><a:tc><a:txBody><a:p><a:r><a:t>Cell payload</a:t></a:r></a:p></a:txBody></a:tc></a:tr></a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
            let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Title") + table)])
            let result = try await PicoDocsEngine.convert(data: data, filename: "opaque.pptx")
            #expect(result.markdown().contains("Cell payload") == uri.hasSuffix("/table"))
            #expect(result.markdown().contains("Title"))
        }
    }


    @Test func retainedImagePayloadsHaveAnEncodedByteBudget() throws {
        let manifest = #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="png" ContentType="image/png"/></Types>"#
        let data = PagesConverterTests.makeZip([("[Content_Types].xml", Array(manifest.utf8)), ("a.png", [1,2,3]), ("b.png", [4,5,6]), ("c.png", [7])])
        let package = PowerPointPackage(archive: try #require(Archive(data: data, accessMode: .read)))
        let collector = PowerPointConverter.ImageCollector(maximumEncodedBytes: 8)
        #expect(collector.add(path: "a.png", filename: "a.png", archive: package) == "a.png")
        #expect(collector.add(path: "b.png", filename: "b.png", archive: package) == "b.png")
        #expect(collector.add(path: "a.png", filename: "a.png", archive: package) == "a.png")
        try package.check()
        #expect(collector.sections.compactMap { $0.metadata["base64"] }.reduce(0) { $0 + $1.utf8.count } == 8)
        #expect(collector.add(path: "c.png", filename: "c.png", archive: package) == nil)
        #expect(throws: PicoDocsError.fileCorrupted) { try package.check() }
        #expect(collector.sections.count == 2)
    }

    @Test func selectedSearchDoesNotEnterStandardExtensionMetadata() throws {
        for extensionTag in ["p:ext", "a:ext"] {
            for name in ["a:tbl", "p:oleobj", "a:blip"] {
                let source = "<root><\(extensionTag)><\(name) id='hidden'/></\(extensionTag)><\(name) id='visible'/></root>"
                let root = try #require(SwiftSoup.parse(source, "", Parser.xmlParser()).children().first())
                #expect(try PowerPointConverter.selectedDescendant(in: root, named: name)?.attr("id") == "visible")
            }
        }
    }

    @Test func canonicalAttributeAliasesCannotCollide() {
        let source = "<root xmlns:r1='http://schemas.openxmlformats.org/officeDocument/2006/relationships' xmlns:r2='http://purl.oclc.org/ooxml/officeDocument/relationships' r1:embed='first' r2:embed='second'/>"
        #expect(PowerPointXML.normalize(Data(source.utf8)) == nil)
        #expect(PowerPointXML.normalize(Data(source.replacingOccurrences(of: "r2:embed=", with: "r2:link=").utf8)) != nil)
    }

    @Test func XMLAttributesHavePerElementAndCumulativeByteLimits() {
        func attrs(_ count: Int) -> Data { Data(("<root " + (0..<count).map { "a\($0)='x'" }.joined(separator: " ") + "/>").utf8) }
        #expect(PowerPointXML.normalize(attrs(256)) != nil)
        #expect(PowerPointXML.normalize(attrs(257)) == nil)
        let source = Data("<root a='12'><child b='34'/></root>".utf8)
        #expect(PowerPointXML.normalize(source, maximumAttributeBytes: 6) != nil)
        #expect(PowerPointXML.normalize(source, maximumAttributeBytes: 5) == nil)
        #expect(PowerPointXML.normalize(Data(("<root a='" + String(repeating: "x", count: 64 * 1024) + "'/>").utf8)) == nil)
        let budget = PowerPointXML.Budget(attributeBytes: 6)
        let small = Data("<root a='12'/>".utf8)
        #expect(PowerPointXML.normalize(small, budget: budget) != nil)
        #expect(PowerPointXML.normalize(small, budget: budget) != nil)
        #expect(PowerPointXML.normalize(small, budget: budget) == nil)
    }

    @Test func craftedBreakSentinelsRemainLiteralWithoutCollisionSearch() throws {
        var source = ""
        for count in 0..<1000 { source += "\u{E042}" + String(repeating: "\u{E043}", count: count) }
        source += "\u{E042}\u{E044}\u{E040}\u{E041}"
        #expect(MarkdownTableCell.inlineText(source + "<br>tail", inline: { $0 }) == source + "\ntail")
        let list = ConverterResult(sections: [.init(markdown: "- " + source + "  \n  tail")])
        let plain = try DocumentRenderer.render(list, to: .plaintext)
        #expect(plain.contains(source)); #expect(plain.contains("\n  tail"))
        let html = try DocumentRenderer.render(list, to: .html)
        #expect(html.contains(source)); #expect(html.contains("<br>tail"))
    }

    @Test func tableCellsInheritPresentationTextStyleAndLocalOverrides() async throws {
        typealias B = PowerPointConverterTests
        for local in [false, true] {
            let style = local ? #"<a:lstStyle><a:lvl1pPr><a:buNone/><a:defRPr b="0"/></a:lvl1pPr></a:lstStyle>"# : ""
            let table = "<p:graphicFrame><a:tbl><a:tr><a:tc><a:txBody>\(style)<a:p><a:r><a:t>Cell</a:t></a:r></a:p></a:txBody></a:tc></a:tr></a:tbl></p:graphicFrame>"
            let data = B.deck(slides: [.init(file: "s.xml", shapes: table)])
            let archive = try #require(Archive(data: data, accessMode: .read))
            var entries: [(String, [UInt8])] = []
            for entry in archive {
                var bytes = Data(); _ = try archive.extract(entry) { bytes.append($0) }
                if entry.path == "ppt/presentation.xml" {
                    let defaults = #"<p:defaultTextStyle><a:lvl1pPr><a:buAutoNum type="arabicPeriod" startAt="4"/><a:defRPr b="1" i="1"/></a:lvl1pPr></p:defaultTextStyle>"#
                    bytes = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "</p:presentation>", with: defaults + "</p:presentation>").utf8)
                }
                entries.append((entry.path, Array(bytes)))
            }
            let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip(entries), filename: "defaults.pptx")
            #expect(result.markdown().contains(local ? "| *Cell* |" : "| 4. ***Cell*** |"))
        }
    }


    @Test func largeWordAndSpreadsheetLiteralsUseScalarEscapes() async throws {
        let source = String(repeating: "*\u{0301}x*\u{0301} ", count: 30_000).trimmingCharacters(in: .whitespaces)
        let document = "<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body><w:p><w:r><w:t>\(source)</w:t></w:r></w:p></w:body></w:document>"
        let worksheet = "<worksheet xmlns='http://schemas.openxmlformats.org/spreadsheetml/2006/main'><sheetData><row r='1'><c r='A1' t='inlineStr'><is><t>\(source)</t></is></c></row></sheetData></worksheet>"
        let inputs = [("literal.docx", PagesConverterTests.makeZip([("word/document.xml", Array(document.utf8))])), ("literal.xlsx", ConverterTests.xlsx(sheetXML: worksheet))]
        for (filename, data) in inputs {
            let result = try await PicoDocsEngine.convert(data: data, filename: filename)
            #expect(try DocumentRenderer.render(result, to: .plaintext).contains(source))
            let html = try DocumentRenderer.render(result, to: .html)
            #expect(html.contains(source)); #expect(!html.contains("<em>"))
        }
    }

    @Test func largePagesCellPreservesLiteralPunctuationAndCleanup() throws {
        let source = String(repeating: "*\u{0301}x*\u{0301} | ", count: 30_000).trimmingCharacters(in: .whitespaces)
        let escaped = IWATable.cleanCell("\u{0001}" + source + "\u{FFFC}\r\n\t")
        let result = ConverterResult(sections: [.init(kind: .table, markdown: "| " + escaped + " |\n| --- |")])
        #expect(try DocumentRenderer.render(result, to: .plaintext).contains(source))
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains(source)); #expect(!html.contains("<em>"))
    }

    @Test func retainedRelationshipMapsShareCountAndByteBudgets() throws {
        typealias B = PowerPointConverterTests
        let type = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
        let relationXML = B.relationshipsXML([("image", type, "../media/a.png")])
        let paths = ["ppt/slides/a.xml", "ppt/slides/b.xml", "ppt/slides/c.xml"]
        let entries = paths.map { path in ("ppt/slides/_rels/" + (path as NSString).lastPathComponent + ".rels", Array(relationXML.utf8)) }
        let archive = try #require(Archive(data: PagesConverterTests.makeZip(entries), accessMode: .read))
        let counted = PowerPointPackage(archive: archive, maximumRelationships: 2)
        for path in paths.prefix(2) { #expect(PowerPointConverter.relationships(counted, forPart: path).count == 1) }
        #expect(PowerPointConverter.relationships(counted, forPart: paths[0]).count == 1)
        try counted.check()
        #expect(PowerPointConverter.relationships(counted, forPart: paths[2]).isEmpty)
        #expect(throws: PicoDocsError.fileCorrupted) { try counted.check() }
        let cost = paths[0].utf8.count + 64 + "image".utf8.count + type.utf8.count + "../media/a.png".utf8.count + 96
        let bytes = PowerPointPackage(archive: archive, maximumRelationshipBytes: cost)
        #expect(PowerPointConverter.relationships(bytes, forPart: paths[0]).count == 1)
        try bytes.check()
        #expect(PowerPointConverter.relationships(bytes, forPart: paths[1]).isEmpty)
        #expect(throws: PicoDocsError.fileCorrupted) { try bytes.check() }
        let empty = PowerPointPackage(archive: archive, maximumRelationshipBytes: 64)
        _ = PowerPointConverter.relationships(empty, forPart: "")
        try empty.check()
        _ = PowerPointConverter.relationships(empty, forPart: "missing")
        #expect(throws: PicoDocsError.fileCorrupted) { try empty.check() }
    }

    @Test func packageRejectsSymlinksRegardlessOfDuplicateOrder() throws {
        for types in [[Entry.EntryType.symlink], [.symlink, .file], [.file, .symlink]] {
            let archive = try #require(Archive(data: Data(), accessMode: .create))
            for type in types {
                try archive.addEntry(with: "ppt/presentation.xml", type: type, uncompressedSize: Int64(1)) { _, _ in Data([65]) }
            }
            #expect(throws: PicoDocsError.fileCorrupted) { try PowerPointPackage(archive: archive).check() }
        }
        let directory = try #require(Archive(data: Data(), accessMode: .create))
        try directory.addEntry(with: "ppt/", type: .directory, uncompressedSize: Int64(0)) { _, _ in Data() }
        try PowerPointPackage(archive: directory).check()
    }


    @Test func sharedDOMCacheChargesNodesAttributesAndNormalizedBytes() throws {
        typealias B = PowerPointConverterTests
        let source = "<p:sldLayout \(B.namespaces)><p:cSld><p:spTree/></p:cSld></p:sldLayout>"
        let bytes = try #require(PowerPointXML.normalize(Data(source.utf8))).utf8.count
        let observed = PowerPointXML.Budget()
        #expect(PowerPointXML.normalize(Data(source.utf8), budget: observed) != nil)
        let attributes = 500_000 - observed.attributes
        let data = PagesConverterTests.makeZip([("a.xml", Array(source.utf8)), ("b.xml", Array(source.utf8)), ("c.xml", Array(source.utf8))])
        for budget in [PowerPointXML.Budget(nodes: 6), .init(attributes: 2 * attributes), .init(bytes: 2 * bytes)] {
            let package = PowerPointPackage(archive: try #require(Archive(data: data, accessMode: .read)))
            var cache = PowerPointConverter.PartCache(archive: package, budget: budget)
            let first = cache.document("a.xml", root: "p:sldlayout")
            #expect(first != nil)
            #expect(cache.document("b.xml", root: "p:sldlayout") != nil)
            #expect(cache.document("a.xml", root: "p:sldlayout") === first)
            #expect(cache.document("c.xml", root: "p:sldlayout") == nil)
            #expect(throws: PicoDocsError.fileCorrupted) { try package.check() }
        }
    }

    @Test func largeHTMLTextNodesUseScalarEscaping() async throws {
        let literal = String(repeating: "*\u{0301}x*\u{0301} ", count: 30_000).trimmingCharacters(in: .whitespaces)
        let result = try await PicoDocsEngine.convert(data: Data(("<p>" + literal + "</p>").utf8), filename: "large.html")
        #expect(try DocumentRenderer.render(result, to: .plaintext) == literal)
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains(literal)); #expect(!html.contains("<em>"))
    }

    @Test func newlineDenseBlockEscapingStreamsLineBoundaries() {
        let prefix = String(repeating: "\n", count: 100_000)
        let source = prefix + "  1. item\n  |cell\n---\n# Heading\nordinary\r\n"
        let expected = prefix + "  1\\. item\n  \\|cell\n\\-\\-\\-\n\\# Heading\nordinary\r\n"
        #expect(PowerPointConverter.escapeBlockMarkers(source) == expected)
        #expect(PowerPointConverter.escapeBlockMarkers("|\u{0301}cell") == "\\|\u{0301}cell")
    }

    @Test func externalImageReferencesCannotClaimEmbeddedCarrierBytes() async throws {
        typealias B = PowerPointConverterTests
        func picture(_ id: String, external: Bool) -> String {
            "<p:pic><p:blipFill><a:blip r:\(external ? "link" : "embed")='\(id)'/></p:blipFill></p:pic>"
        }
        let embedded = B.Slide(file: "embedded.xml", shapes: picture("image", external: false), relationships: [("image", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", "../media/image.png")])
        let external = B.Slide(file: "external.xml", shapes: picture("outside", external: true) + picture("reserved", external: true), relationships: [
            ("outside", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", "image.png\" TargetMode=\"External"),
            ("reserved", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", "picodocs-embedded/1/image.png\" TargetMode=\"External")])
        for slides in [[embedded, external], [external, embedded]] {
            let result = try await PicoDocsEngine.convert(data: B.deck(slides: slides, extraParts: [("ppt/media/image.png", [1,2,3])]), filename: "images.pptx")
            let html = try SwiftSoup.parse(DocumentRenderer.render(result, to: .html))
            let sources = try html.getElementsByTag("img").array().map { try $0.attr("src") }
            #expect(sources.filter { $0 == "data:image/png;base64,AQID" }.count == 1)
            #expect(sources.contains("image.png")); #expect(sources.contains("picodocs-embedded/1/image.png"))
            #expect(result.sections.first { $0.kind == .image }?.metadata["markdownReference"] == "picodocs-embedded/2/image.png")
        }
    }


    @Test func titleWhitespaceNormalizationStreamsLargeInputs() async throws {
        let words = Array(repeating: "word", count: 100_000).joined(separator: " \t ")
        let expected = Array(repeating: "word", count: 100_000).joined(separator: " ")
        #expect(PowerPointConverter.normalizedWhitespace(" \n" + words + "\u{2003}") == expected)
        typealias B = PowerPointConverterTests
        let result = try await PicoDocsEngine.convert(data: B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("  First \t second\nthird  "))]), filename: "title.pptx")
        #expect(result.sections.first?.title == "First second third")
        #expect(result.markdown() == "## First second third")
    }

    @Test func resolvedSlidePathsShareACumulativeBudget() throws {
        typealias B = PowerPointConverterTests
        let data = B.deck(slides: [.init(file: "s.xml", shapes: "")], order: ["s.xml", "s.xml"])
        let package = PowerPointPackage(archive: try #require(Archive(data: data, accessMode: .read)))
        let presentation = try #require(PowerPointConverter.xml(package, path: "ppt/presentation.xml"))
        let path = "ppt/slides/s.xml"
        #expect(try PowerPointConverter.slidePaths(presentation, archive: package, maximumPathBytes: 2 * path.utf8.count) == [path, path])
        #expect(throws: PicoDocsError.fileCorrupted) { try PowerPointConverter.slidePaths(presentation, archive: package, maximumPathBytes: 2 * path.utf8.count - 1) }
    }

    @Test func supportedMetadataNamespacesSelectTheirChoice() async throws {
        typealias B = PowerPointConverterTests
        let core = #"<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"><mc:AlternateContent><mc:Choice Requires="dc cp"><dc:title>Chosen</dc:title><dc:creator>Ada</dc:creator></mc:Choice><mc:Fallback><dc:title>Wrong</dc:title></mc:Fallback></mc:AlternateContent></cp:coreProperties>"#
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Slide"))], extraParts: [("docProps/core.xml", Array(core.utf8))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "metadata.pptx")
        #expect(result.title == "Chosen"); #expect(result.author == "Ada")
    }

    @Test func slideContextsShareOneImageCollector() throws {
        let manifest = #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="png" ContentType="image/png"/></Types>"#
        let data = PagesConverterTests.makeZip([("[Content_Types].xml", Array(manifest.utf8)), ("a.png", [1,2,3]), ("b.png", [4,5,6])])
        let package = PowerPointPackage(archive: try #require(Archive(data: data, accessMode: .read)))
        let collector = PowerPointConverter.ImageCollector()
        let first = PowerPointConverter.SlideContext(archive: package, partPath: "one", relationships: [:], images: collector)
        let second = PowerPointConverter.SlideContext(archive: package, partPath: "two", relationships: [:], images: collector)
        first.images.add(path: "a.png", filename: "a.png", archive: package)
        second.images.add(path: "b.png", filename: "b.png", archive: package)
        second.images.add(path: "a.png", filename: "a.png", archive: package)
        #expect(first.images === second.images)
        #expect(collector.sections.map(\.sourcePath) == ["a.png", "b.png"])
        try package.check()
    }

    @Test func cancelledDescendantSearchStopsBeforeReturningAMatch() async throws {
        let found = try await Task {
            let document = try SwiftSoup.parse("<root><a:tbl/></root>", "", SwiftSoup.Parser.xmlParser())
            let root = try #require(document.children().first())
            withUnsafeCurrentTask { $0?.cancel() }
            return PowerPointConverter.selectedDescendant(in: root, named: "a:tbl") != nil
        }.value
        #expect(!found)
    }

    @Test func largeCSVLiteralFieldsUseStreamingEscapes() async throws {
        let field = String(repeating: #"a\*_[x]<y>`|"#, count: 20_000)
        let result = try await PicoDocsEngine.convert(data: Data(CSVConverter.serializeCSV([[field]]).utf8), filename: "large.csv")
        #expect(try DocumentRenderer.render(result, to: .plaintext) == field)
        #expect(try DocumentRenderer.render(result, to: .csv) == field)
    }

    @Test func codeSpanScanningNeedsNoPerCharacterOrRunIndex() {
        let plain = String(repeating: "a", count: 1_000_000)
        #expect(MarkdownTableCell.mapCodeSpans(plain, code: { _ in "wrong" }, plain: { $0 }) == plain)
        let many = String(repeating: "`x` ", count: 50_000)
        #expect(MarkdownTableCell.mapCodeSpans(many, keepDelimiters: false, code: { $0.uppercased() }, plain: { $0 }) == String(repeating: "X ", count: 50_000))
        let unmatched = (1...1000).map { String(repeating: "`", count: $0) + "x " }.joined()
        #expect(MarkdownTableCell.mapCodeSpans(unmatched, code: { _ in "wrong" }, plain: { $0 }) == unmatched)
        #expect(MarkdownTableCell.mapCodeSpans(#"\``x`"#, keepDelimiters: false, code: { $0.uppercased() }, plain: { $0 }) == #"\`X"#)
    }

    @Test func fixedWidthEscapeTokensPreserveLiteralSentinels() throws {
        let literal = "\u{E006}\u{E15B}\u{E006}\u{E006}\u{E007}"
        let result = ConverterResult(sections: [.init(markdown: literal + " " + String(repeating: #"\*"#, count: 100_000))])
        let expected = literal + " " + String(repeating: "*", count: 100_000)
        #expect(try DocumentRenderer.render(result, to: .plaintext) == expected)
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains(expected)); #expect(!html.contains("<em>"))
        let combining = ConverterResult(sections: [.init(markdown: "\\*\u{0301}x")])
        #expect(try DocumentRenderer.render(combining, to: .plaintext) == "*\u{0301}x")
    }

    @Test func siblingUnknownNamespacesHaveCumulativeIdentityLimits() {
        func source(_ count: Int, length: Int = 0) -> Data {
            let common = String(repeating: "x", count: length)
            let children = (0..<count).map { "<e:x xmlns:e='urn:\(common)\($0)' mc:Ignorable='e'/>" }.joined()
            return Data(("<root xmlns:mc='http://schemas.openxmlformats.org/markup-compatibility/2006'>" + children + "</root>").utf8)
        }
        #expect(PowerPointXML.normalize(source(1024)) != nil)
        #expect(PowerPointXML.normalize(source(1025)) == nil)
        #expect(PowerPointXML.normalize(source(20, length: 60_000)) == nil)
    }


    @Test func repeatedSlideReferencesHaveARenderLimit() throws {
        typealias B = PowerPointConverterTests
        for count in [10_000, 10_001] {
            let data = B.deck(slides: [.init(file: "s.xml", shapes: "")], order: Array(repeating: "s.xml", count: count))
            let package = PowerPointPackage(archive: try #require(Archive(data: data, accessMode: .read)))
            let presentation = try #require(PowerPointConverter.xml(package, path: "ppt/presentation.xml"))
            if count == 10_000 { #expect(try PowerPointConverter.slidePaths(presentation, archive: package).count == count) }
            else { #expect(throws: PicoDocsError.fileCorrupted) { try PowerPointConverter.slidePaths(presentation, archive: package) } }
        }
    }

    @Test func notesDOMIsReleasedWhileSharedMastersAreCached() throws {
        typealias B = PowerPointConverterTests
        let note = "<p:notes \(B.namespaces)><p:cSld><p:spTree/></p:cSld></p:notes>"
        let master = note.replacingOccurrences(of: "p:notes", with: "p:notesMaster")
        let data = PagesConverterTests.makeZip([("note.xml", Array(note.utf8)), ("master.xml", Array(master.utf8))])
        let package = PowerPointPackage(archive: try #require(Archive(data: data, accessMode: .read)))
        var cache = PowerPointConverter.PartCache(archive: package)
        weak var released: Document?
        do {
            let parsed = cache.document("note.xml", root: "p:notes", cache: false)
            let document = try #require(parsed)
            released = document
        }
        #expect(released == nil)
        let parsedMaster = cache.document("master.xml", root: "p:notesmaster")
        let first = try #require(parsedMaster)
        #expect(cache.document("master.xml", root: "p:notesmaster") === first)
        try package.check()
    }

    @Test func cancelledPlaceholderIndexIsNotInstalled() async throws {
        let count = try await Task {
            typealias B = PowerPointConverterTests
            let document = try SwiftSoup.parse("<p:sldLayout \(B.namespaces)><p:cSld><p:spTree>" + B.shape(placeholder: #"<p:ph type="body"/>"#, paragraphs: []) + "</p:spTree></p:cSld></p:sldLayout>", "", SwiftSoup.Parser.xmlParser())
            let cache = PowerPointConverter.PlaceholderCache()
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(cache.match(in: document, type: "body", index: "") == nil)
            return cache.buildCount
        }.value
        #expect(count == 0)
    }

    @Test func compatibilityAttributesHaveTokenAndByteLimits() {
        let declarations = #"xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main""#
        for key in ["mc:Ignorable", "mc:ProcessContent", "mc:MustUnderstand", "Requires"] {
            let token = key == "mc:ProcessContent" ? "a:p" : "a"
            for count in [256, 257] {
                let value = Array(repeating: token, count: count).joined(separator: " ")
                #expect((PowerPointXML.normalize(Data("<root \(declarations) \(key)='\(value)'/>".utf8)) != nil) == (count == 256))
            }
            let huge = String(repeating: "a", count: 16 * 1024 + 1)
            #expect(PowerPointXML.normalize(Data("<root \(declarations) \(key)='\(huge)'/>".utf8)) == nil)
        }
    }

    @Test func namespaceScopeHasCountAndByteLimits() {
        func declarations(_ count: Int) -> String { (0..<count).map { " xmlns:n\($0)='urn:\($0)'" }.joined() }
        let allowed = "<root" + declarations(256) + "><child xmlns:n0='urn:rebound'/></root>"
        #expect(PowerPointXML.normalize(Data(allowed.utf8)) != nil)
        #expect(PowerPointXML.normalize(Data(("<root" + declarations(256) + "><child xmlns:extra='urn:new'/></root>").utf8)) == nil)
        #expect(PowerPointXML.normalize(Data(("<root xmlns:n='" + String(repeating: "x", count: 64 * 1024) + "'/>").utf8)) == nil)
    }

    @Test func relationshipTargetLengthIsCheckedBeforeSplitting() throws {
        typealias B = PowerPointConverterTests
        for count in [16_384, 16_385] {
            let target = String(repeating: "a/", count: count)
            let rels = B.relationshipsXML([("r", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide", target)])
            let data = PagesConverterTests.makeZip([("_rels/.rels", Array(rels.utf8))])
            let package = PowerPointPackage(archive: try #require(Archive(data: data, accessMode: .read)))
            let values = PowerPointConverter.relationships(package, forPart: "")
            if count == 16_384 { #expect(values["r"]?.target == target); try package.check() }
            else { #expect(values.isEmpty); #expect(throws: PicoDocsError.fileCorrupted) { try package.check() } }
        }
    }

    @Test func masterTextStylesReadOnlySelectedBranches() async throws {
        typealias B = PowerPointConverterTests
        let wrong = #"<p:bodyStyle><a:lvl1pPr><a:buChar char="•"/><a:defRPr b="1"/></a:lvl1pPr></p:bodyStyle>"#
        let right = #"<p:bodyStyle><a:lvl1pPr><a:buNone/><a:defRPr i="1"/></a:lvl1pPr></p:bodyStyle>"#
        let alternate = "<mc:AlternateContent xmlns:u='urn:unsupported'><mc:Choice Requires='u'>\(wrong)</mc:Choice><mc:Fallback>\(right)</mc:Fallback></mc:AlternateContent>"
        let master = "<p:sldMaster \(B.namespaces)><p:cSld><p:spTree/></p:cSld><p:txStyles>\(alternate)</p:txStyles></p:sldMaster>"
        let layout = "<p:sldLayout \(B.namespaces)><p:cSld><p:spTree/></p:cSld></p:sldLayout>"
        let layoutRels = B.relationshipsXML([("master", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster", "../slideMasters/m.xml")])
        let shape = B.shape(placeholder: #"<p:ph type="body"/>"#, paragraphs: ["<a:p><a:r><a:t>Selected</a:t></a:r></a:p>"])
        let data = B.deck(slides: [.init(file: "s.xml", shapes: shape, relationships: [("layout", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout", "../slideLayouts/l.xml")])], extraParts: [("ppt/slideLayouts/l.xml", Array(layout.utf8)), ("ppt/slideLayouts/_rels/l.xml.rels", Array(layoutRels.utf8)), ("ppt/slideMasters/m.xml", Array(master.utf8))])
        #expect(try await PicoDocsEngine.convert(data: data, filename: "styles.pptx").markdown() == "*Selected*")
    }

    @Test func formattedWordTableBreaksStayInsideTheFormattedRun() async throws {
        let xml = #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:tbl><w:tr><w:tc><w:p><w:r><w:rPr><w:b/></w:rPr><w:t>first</w:t><w:br/><w:t>second</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>"#
        let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([("word/document.xml", Array(xml.utf8))]), filename: "break.docx")
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("<strong>first  <br>second</strong>"))
        for format in [ExportFileType.plaintext, .csv] {
            let text = try DocumentRenderer.render(result, to: format)
            #expect(text.contains("first  \nsecond")); #expect(!text.contains("**"))
        }
        let literal = ConverterResult(sections: [.init(markdown: "| **first<br>second** | `a<br>b` | \\<br> | \u{E042} |\n| --- | --- | --- | --- |")])
        let output = try DocumentRenderer.render(literal, to: .html)
        #expect(output.contains("<strong>first<br>second</strong>"))
        #expect(output.contains("<code>a&lt;br&gt;b</code>")); #expect(output.contains("&lt;br&gt;")); #expect(output.contains("\u{E042}"))
    }

    @Test func imageMIMEParametersDoNotCorruptDataURLPayload() async throws {
        typealias B = PowerPointConverterTests
        let picture = #"<p:pic><p:blipFill><a:blip r:embed="image"/></p:blipFill></p:pic>"#
        let manifest = #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="png" ContentType="image/png;name=&quot;a,b;c&quot;"/></Types>"#
        let data = B.deck(slides: [.init(file: "s.xml", shapes: picture, relationships: [("image", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", "../media/a.png")])], extraParts: [("ppt/media/a.png", [1,2,3]), ("[Content_Types].xml", Array(manifest.utf8))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "mime.pptx")
        #expect(result.sections.first { $0.kind == .image }?.metadata["mimeType"] == "image/png;name=\"a,b;c\"")
        #expect(try DocumentRenderer.render(result, to: .html).contains("src=\"data:image/png;base64,AQID\""))
    }

    @Test func coreMetadataUsesOnlySelectedBranches() async throws {
        typealias B = PowerPointConverterTests
        let core = #"<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:u="urn:unknown"><mc:AlternateContent><mc:Choice Requires="u"><dc:title>Wrong</dc:title><dc:creator>Wrong</dc:creator></mc:Choice><mc:Fallback><dc:title>Selected</dc:title><dc:creator>Ada</dc:creator></mc:Fallback></mc:AlternateContent></cp:coreProperties>"#
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Slide"))], extraParts: [("docProps/core.xml", Array(core.utf8))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "core.pptx")
        #expect(result.title == "Selected"); #expect(result.author == "Ada")
    }

    @Test func requiredUnknownAttributesRespectProcessedTreeAndExtensions() async throws {
        typealias B = PowerPointConverterTests
        let bad = "<p:sp xmlns:u='urn:unknown' u:required='true'/>"
        let ignored = "<p:sp xmlns:u='urn:unknown' mc:Ignorable='u' u:optional='true'/>"
        let opaque = "<p:extLst><p:ext uri='urn:payload'>\(bad)</p:ext></p:extLst>"
        let unselected = "<mc:AlternateContent xmlns:u='urn:unknown'><mc:Choice Requires='u'>\(bad)</mc:Choice><mc:Fallback/></mc:AlternateContent>"
        for content in [bad, ignored, opaque, unselected] {
            let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Visible") + content)])
            if content == bad { await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: data, filename: "attributes.pptx") } }
            else { #expect(try await PicoDocsEngine.convert(data: data, filename: "attributes.pptx").markdown() == "## Visible") }
        }
    }


    @Test func titleMetadataUsesOnlySelectedRunText() async throws {
        typealias B = PowerPointConverterTests
        let run = "<a:r>" + selectedWrapper("<a:t>Selected</a:t>", fallback: "<a:t>Wrong</a:t>") + "</a:r>"
        let shape = B.shape(placeholder: #"<p:ph type="title"/>"#, paragraphs: ["<a:p>" + run + "</a:p>"])
        let result = try await PicoDocsEngine.convert(data: B.deck(slides: [.init(file: "s.xml", shapes: shape)]), filename: "title.pptx")
        #expect(result.sections.first?.title == "Selected")
        #expect(result.markdown() == "## Selected")
    }

    @Test func nativeLoneListMarkersRemainLiteralProse() async throws {
        for value in ["-", "+", "1.", "123."] {
            let xml = "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>\(value)</w:t></w:r></w:p></w:body></w:document>"
            let word = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([("word/document.xml", Array(xml.utf8))]), filename: "marker.docx")
            let html = try await PicoDocsEngine.convert(data: Data("<p>\(value)</p>".utf8), filename: "marker.html")
            for result in [word, html] {
                #expect(try DocumentRenderer.render(result, to: .plaintext) == value)
                let output = try DocumentRenderer.render(result, to: .html)
                #expect(!output.contains("<ul>")); #expect(!output.contains("<ol"))
                #expect(output.contains("<p>\(value)</p>"))
            }
        }
        let emptyList = ConverterResult(sections: [.init(markdown: "-\n- item")])
        #expect(try DocumentRenderer.render(emptyList, to: .html).contains("<li></li>"))
        let nativeList = try await PicoDocsEngine.convert(data: Data("<ul><li>item</li></ul>".utf8), filename: "actual-list.html")
        #expect(try DocumentRenderer.render(nativeList, to: .html).contains("<li>item</li>"))
    }

    @Test func percentEncodedImageReferencesStillEmbedTheirCarriers() async throws {
        typealias B = PowerPointConverterTests
        for filename in ["chart(1).png", "chart[1].png", "chart one.png"] {
            let picture = #"<p:pic><p:nvPicPr><p:cNvPr descr="Chart"/></p:nvPicPr><p:blipFill><a:blip r:embed="image"/></p:blipFill></p:pic>"#
            let target = "../media/" + filename
            let data = B.deck(slides: [.init(file: "s.xml", shapes: picture, relationships: [("image", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", target)])], extraParts: [("ppt/media/" + filename, [1, 2, 3])])
            let result = try await PicoDocsEngine.convert(data: data, filename: "image.pptx")
            let html = try DocumentRenderer.render(result, to: .html)
            #expect(html.contains("src=\"data:image/png;base64,AQID\""))
        }
        let ambiguous = ConverterResult(sections: [.init(markdown: "![Chart](chart%281%29.png)"), .init(kind: .image, markdown: "", sourcePath: "chart(1).png", metadata: ["base64": "AQID", "mimeType": "image/png", "markdownReference": "chart%281%29.png"]), .init(kind: .image, markdown: "", sourcePath: "chart%281%29.png", metadata: ["base64": "BAUG", "mimeType": "image/png"])])
        #expect(!(try DocumentRenderer.render(ambiguous, to: .html)).contains("data:image"))
    }


    @Test func graphicDataAcceptsOpaqueNamespacesAtItsSchemaExtensionPoint() async throws {
        typealias B = PowerPointConverterTests
        let opaque = "<c:chart xmlns:c=\"http://schemas.openxmlformats.org/drawingml/2006/chart\">" + B.titleShape("Hidden") + "</c:chart>"
        for content in [opaque, selectedWrapper(opaque)] {
            let frame = "<p:graphicFrame><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/chart\">" + content + "</a:graphicData></a:graphic></p:graphicFrame>"
            let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Visible") + frame)])
            let result = try await PicoDocsEngine.convert(data: data, filename: "opaque-chart.pptx")
            #expect(result.markdown() == "## Visible")
        }
    }

    @Test func XMLNodeAndAttributeBudgetsRejectBeforeDOMConstruction() {
        let siblings = Data("<root><a/><b/><c/></root>".utf8)
        #expect(PowerPointXML.normalize(siblings, maximumNodes: 4) != nil)
        #expect(PowerPointXML.normalize(siblings, maximumNodes: 3) == nil)
        #expect(PowerPointXML.normalize(Data("<root>text<a/>tail</root>".utf8), maximumNodes: 3) == nil)
        let attributes = Data("<root a='1'><x b='2' c='3'/></root>".utf8)
        #expect(PowerPointXML.normalize(attributes, maximumAttributes: 3) != nil)
        #expect(PowerPointXML.normalize(attributes, maximumAttributes: 2) == nil)
        #expect(PowerPointXML.normalize(Data(("<root>" + String(repeating: "<n/>", count: 250_000) + "</root>").utf8)) == nil)
    }

    @Test func archiveIndexHasEntryAndFilenameBudgets() throws {
        let archive = try #require(Archive(data: PagesConverterTests.makeZip([("first", []), ("second", [])]), accessMode: .read))
        try PowerPointPackage(archive: archive, maximumEntries: 2, maximumNameBytes: 11).check()
        #expect(throws: PicoDocsError.fileCorrupted) { try PowerPointPackage(archive: archive, maximumEntries: 1).check() }
        #expect(throws: PicoDocsError.fileCorrupted) { try PowerPointPackage(archive: archive, maximumNameBytes: 10).check() }
    }

    @Test func selectedParagraphAndRunPropertiesRetainFormattingAndLinks() async throws {
        typealias B = PowerPointConverterTests
        let ppr = selectedWrapper("<a:pPr lvl=\"0\">" + selectedWrapper(#"<a:buAutoNum type="arabicPeriod" startAt="5"/>"#) + selectedWrapper(#"<a:defRPr b="1"/>"#) + "</a:pPr>")
        let rpr = selectedWrapper("<a:rPr i=\"1\">" + selectedWrapper(#"<a:hlinkClick r:id="link"/>"#) + "</a:rPr>")
        let paragraph = "<a:p>" + ppr + "<a:r>" + rpr + selectedWrapper("<a:t>Selected</a:t>") + "</a:r></a:p>"
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.shape(placeholder: nil, paragraphs: [paragraph]), relationships: [("link", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", "https://example.com\" TargetMode=\"External")])])
        let result = try await PicoDocsEngine.convert(data: data, filename: "properties.pptx")
        #expect(result.markdown().contains("5. [***Selected***](https://example.com)"))
    }

    @Test func generatedTableBackslashesDecodeExactlyOnce() async throws {
        let value = #"C:\Users\name | \\server\share"#
        let escaped = value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let wordXML = "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:tbl><w:tr><w:tc><w:p><w:r><w:t>\(escaped)</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>"
        let word = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([("word/document.xml", Array(wordXML.utf8))]), filename: "paths.docx")
        let html = try await PicoDocsEngine.convert(data: Data("<table><tr><th>\(escaped)</th></tr></table>".utf8), filename: "paths.html")
        typealias B = PowerPointConverterTests
        let table = "<p:graphicFrame><a:graphic><a:graphicData uri='http://schemas.openxmlformats.org/drawingml/2006/table'><a:tbl><a:tr><a:tc><a:txBody><a:p><a:r><a:t>\(escaped)</a:t></a:r></a:p></a:txBody></a:tc></a:tr></a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
        let pptx = try await PicoDocsEngine.convert(data: B.deck(slides: [.init(file: "s.xml", shapes: table)]), filename: "paths.pptx")
        for result in [word, html, pptx, ConverterResult(sections: [.init(markdown: "| " + MarkdownTableCell.escapeDelimiters(value) + " |\n| --- |")])] {
            for format in [ExportFileType.html, .plaintext, .csv] {
                let rendered = try DocumentRenderer.render(result, to: format)
                #expect(rendered.contains(value))
            }
        }
    }

    @Test func externalTargetsCannotInjectMarkdownSyntax() async throws {
        typealias B = PowerPointConverterTests
        let shape = B.shape(placeholder: nil, paragraphs: [#"<a:p><a:r><a:rPr><a:hlinkClick r:id="link"/></a:rPr><a:t>Label</a:t></a:r></a:p>"#])
        for target in ["https://example.com/a&gt;![inject](https://evil.example/image)", "https://example.com/&#10;&gt;![inject](https://evil.example/image)", "https://example.com/a b(c)&lt;d&gt;", "https://example.com/&#9;tab"] {
            let rels = "<Relationships><Relationship Id=\"link\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(target)\" TargetMode=\"External\"/></Relationships>"
            let result = try await PicoDocsEngine.convert(data: B.deck(slides: [.init(file: "s.xml", shapes: shape)], extraParts: [("ppt/slides/_rels/s.xml.rels", Array(rels.utf8))]), filename: "links.pptx")
            let markdown = result.markdown()
            #expect(!markdown.contains("![inject]"))
            #expect(!(try DocumentRenderer.render(result, to: .html)).contains("<img"))
            if target.contains("&#") { #expect(markdown == "Label") }
            else { #expect(markdown.contains("%3E")) }
        }
    }

    @Test func notesGroupsInheritAndOverrideLinksWithoutSiblingLeakage() async throws {
        typealias B = PowerPointConverterTests
        func note(_ text: String, click: String? = nil) -> String {
            let shape = B.shape(placeholder: #"<p:ph type="body"/>"#, paragraphs: ["<a:p><a:r><a:t>\(text)</a:t></a:r></a:p>"])
            guard let click else { return shape }
            return shape.replacingOccurrences(of: #"<p:cNvPr id="2" name="Shape"/>"#, with: "<p:cNvPr><a:hlinkClick r:id=\"\(click)\"/></p:cNvPr>")
        }
        let group = "<p:grpSp><p:nvGrpSpPr><p:cNvPr><a:hlinkClick r:id=\"group\"/></p:cNvPr></p:nvGrpSpPr>" + note("Inherited") + selectedWrapper("<p:grpSp>" + note("Nested") + "</p:grpSp>") + note("Override", click: "child") + note("Unsafe", click: "unsafe") + "</p:grpSp>" + note("Outside")
        let notes = "<p:notes \(B.namespaces)><p:cSld><p:spTree>\(group)</p:spTree></p:cSld></p:notes>"
        let rels = B.relationshipsXML([("group", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", "https://example.com/group\" TargetMode=\"External"), ("child", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", "https://example.com/child\" TargetMode=\"External"), ("unsafe", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", "javascript:bad\" TargetMode=\"External")])
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Slide"), relationships: [("notes", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide", "../notesSlides/n.xml")])], extraParts: [("ppt/notesSlides/n.xml", Array(notes.utf8)), ("ppt/notesSlides/_rels/n.xml.rels", Array(rels.utf8))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "notes-groups.pptx")
        let text = try #require(result.sections.first?.metadata["notes"])
        #expect(text.contains("[Inherited](https://example.com/group)"))
        #expect(text.contains("[Nested](https://example.com/group)"))
        #expect(text.contains("[Override](https://example.com/child)"))
        #expect(!text.contains("[Unsafe]"))
        #expect(!text.contains("[Outside]"))
    }

    @Test func pictureAlternativeTextPrefersDescriptionThenTitleThenName() async throws {
        typealias B = PowerPointConverterTests
        for (attrs, expected) in [(#"descr="Description" title="Title" name="Picture 1""#, "Description"), (#"title="Title" name="Picture 1""#, "Title"), (#"descr=" " title="Title" name="Picture 1""#, "Title"), (#"name="Picture 1""#, "Picture 1")] {
            let picture = "<p:pic><p:nvPicPr><p:cNvPr \(attrs)/></p:nvPicPr><p:blipFill><a:blip r:embed=\"image\"/></p:blipFill></p:pic>"
            let data = B.deck(slides: [.init(file: "s.xml", shapes: picture, relationships: [("image", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", "../media/p.png")])], extraParts: [("ppt/media/p.png", [1,2,3])])
            let result = try await PicoDocsEngine.convert(data: data, filename: "alt.pptx")
            #expect(result.markdown().contains("![\(expected)]"))
            #expect(try DocumentRenderer.render(result, to: .html).contains("alt=\"\(expected)\""))
            #expect(try DocumentRenderer.render(result, to: .plaintext).contains(expected))
        }
    }

    @Test func unsupportedRequiredWrappersFailButIgnoredAndExtensionContentDoNot() async throws {
        typealias B = PowerPointConverterTests
        let wrapped = "<e:wrapper xmlns:e=\"urn:vendor\">" + B.titleShape("Hidden") + "</e:wrapper>"
        let visible = B.titleShape("Visible")
        let invalid = B.deck(slides: [.init(file: "s.xml", shapes: wrapped + visible)])
        await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: invalid, filename: "required.pptx") }
        for wrapper in [wrapped.replacingOccurrences(of: "<e:wrapper ", with: "<e:wrapper mc:Ignorable=\"e\" "), "<p:extLst><p:ext uri=\"vendor\">" + wrapped + "</p:ext></p:extLst>", "<mc:AlternateContent xmlns:e=\"urn:vendor\"><mc:Choice Requires=\"e\">" + wrapped + "</mc:Choice><mc:Fallback/></mc:AlternateContent>"] {
            let result = try await PicoDocsEngine.convert(data: B.deck(slides: [.init(file: "s.xml", shapes: wrapper + visible)]), filename: "ignored.pptx")
            #expect(result.markdown() == "## Visible")
        }
    }

    @Test func streamingDTDScanHandlesLongTextAndAllLiteralContainers() {
        let padding = String(repeating: "x", count: 100_000)
        for wrapper in ["<!-- <!DOCTYPE ignored> -->", "<?pi <!DOCTYPE ignored> ?>", "<x><![CDATA[<!DOCTYPE literal>]]></x>"] {
            let source = "<root>" + padding + wrapper + padding + "</root>"
            #expect(PowerPointXML.normalize(Data(source.utf8)) != nil)
        }
        #expect(PowerPointXML.normalize(Data(("<?xml version=\"1.0\"?>" + "<!-- ignored -->" + "<!DOCTYPE x><x/>").utf8)) == nil)
    }


    @Test func relatedPartsUseExactTransitionalAndStrictRelationshipTypes() throws {
        let archive = try #require(Archive(data: PagesConverterTests.makeZip([("placeholder", [0])]), accessMode: .read))
        for suffix in ["/slideLayout", "/slideMaster", "/notesMaster", "/notesSlide", "/slide", "/image", "/hyperlink"] {
            let vendor = PowerPointConverter.Relationship(type: "https://vendor.example" + suffix, target: "missing.xml")
            for base in ["http://schemas.openxmlformats.org/officeDocument/2006/relationships", "http://purl.oclc.org/ooxml/officeDocument/relationships"] {
                let standard = PowerPointConverter.Relationship(type: base + suffix, target: "real.xml")
                let package = PowerPointPackage(archive: archive)
                #expect(PowerPointConverter.relatedPart(of: "ppt/slides/s.xml", type: suffix, relationships: ["vendor": vendor, "standard": standard], archive: package) == "ppt/slides/real.xml")
                try package.check()
                #expect(!vendor.isType(suffix)); #expect(standard.isType(suffix))
            }
            let package = PowerPointPackage(archive: archive)
            #expect(PowerPointConverter.relatedPart(of: "ppt/slides/s.xml", type: suffix, relationships: ["vendor": vendor], archive: package) == nil)
            try package.check()
        }
    }

    @Test func selectedPlaceholderWrappersRetainClassificationAndInheritance() async throws {
        typealias B = PowerPointConverterTests
        func wrap(_ shape: String, level: String) -> String {
            if level == "p:ph" {
                return shape.replacingOccurrences(of: #"<p:ph type="title"/>"#, with: selectedWrapper(#"<p:ph type="title"/>"#, fallback: #"<p:ph type="ftr"/>"#))
                    .replacingOccurrences(of: #"<p:ph type="ftr"/>"#, with: selectedWrapper(#"<p:ph type="ftr"/>"#))
            }
            return shape.replacingOccurrences(of: "<" + level + ">", with: "<mc:AlternateContent><mc:Choice Requires=\"a\"><" + level + ">")
                .replacingOccurrences(of: "</" + level + ">", with: "</" + level + "></mc:Choice><mc:Fallback/></mc:AlternateContent>")
        }
        for level in ["p:nvSpPr", "p:nvPr", "p:ph"] {
            let title = wrap(B.titleShape("Title"), level: level)
            let footer = wrap(B.shape(placeholder: #"<p:ph type="ftr"/>"#, paragraphs: ["<a:p><a:r><a:t>Hidden footer</a:t></a:r></a:p>"]), level: level)
            let result = try await PicoDocsEngine.convert(data: B.deck(slides: [.init(file: "s.xml", shapes: title + footer)]), filename: "placeholders.pptx")
            #expect(result.sections.first?.title == "Title"); #expect(!result.markdown().contains("footer"))
        }
        let ph = selectedWrapper(#"<p:ph type="body" idx="1"/>"#)
        let shape = B.shape(placeholder: ph, paragraphs: ["<a:p><a:r><a:t>Inherited</a:t></a:r></a:p>"])
        let layoutShape = B.shape(placeholder: ph, paragraphs: []).replacingOccurrences(of: "<a:bodyPr/>", with: #"<a:bodyPr/><a:lstStyle><a:lvl1pPr><a:buNone/><a:defRPr b="1"/></a:lvl1pPr></a:lstStyle>"#)
        let layout = "<p:sldLayout \(B.namespaces)><p:cSld><p:spTree>" + layoutShape + "</p:spTree></p:cSld></p:sldLayout>"
        let data = B.deck(slides: [.init(file: "s.xml", shapes: shape, relationships: [("layout", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout", "../slideLayouts/l.xml")])], extraParts: [("ppt/slideLayouts/l.xml", Array(layout.utf8))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "inherited-placeholder.pptx")
        #expect(result.markdown() == "**Inherited**")
    }

    @Test func pictureAlternativeTextCannotIntroduceMarkdownBlocks() async throws {
        typealias B = PowerPointConverterTests
        for attribute in ["descr", "name"] {
            for newline in ["&#10;", "&#13;", "&#13;&#10;"] {
                let properties = "<p:nvPicPr>" + selectedWrapper("<p:cNvPr \(attribute)=\"Line\(newline)# Heading\"/>") + "</p:nvPicPr>"
                let picture = "<p:pic>" + selectedWrapper(properties) + "<p:blipFill><a:blip r:embed=\"image\"/></p:blipFill></p:pic>"
                let data = B.deck(slides: [.init(file: "s.xml", shapes: picture, relationships: [("image", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", "../media/p.png")])], extraParts: [("ppt/media/p.png", [1,2,3])])
                let result = try await PicoDocsEngine.convert(data: data, filename: "alt.pptx")
                #expect(result.markdown() == "![Line # Heading](p.png)")
                #expect(try DocumentRenderer.render(result, to: .html).contains("<img "))
                #expect(try DocumentRenderer.render(result, to: .plaintext).contains("Line # Heading"))
            }
        }
    }

    @Test func hiddenNotePlaceholdersAndGroupsAreExcluded() async throws {
        typealias B = PowerPointConverterTests
        func note(_ text: String) -> String { B.shape(placeholder: #"<p:ph type="body"/>"#, paragraphs: ["<a:p><a:r><a:t>\(text)</a:t></a:r></a:p>"]) }
        let hidden = note("Hidden shape").replacingOccurrences(of: "<p:cNvPr ", with: "<p:cNvPr hidden=\"1\" ")
        let group = "<p:grpSp><p:nvGrpSpPr><p:cNvPr hidden=\"true\"/></p:nvGrpSpPr>" + selectedWrapper(note("Hidden group")) + "</p:grpSp>"
        let notes = "<p:notes \(B.namespaces)><p:cSld><p:spTree>" + hidden + group + note("Visible") + "</p:spTree></p:cSld></p:notes>"
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Slide"), relationships: [("notes", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide", "../notesSlides/n.xml")])], extraParts: [("ppt/notesSlides/n.xml", Array(notes.utf8))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "hidden-notes.pptx")
        #expect(result.sections.first?.metadata["notes"] == "- Visible")
        #expect(!result.markdown().contains("Hidden"))
    }

    @Test func ignoredExtensionsCannotSupplyPicturesOrTables() async throws {
        typealias B = PowerPointConverterTests
        let picture = #"<p:pic xmlns:e="urn:extension" mc:Ignorable="e"><p:blipFill><e:ignored><a:blip r:embed="missing"/></e:ignored><a:blip r:embed="real"/></p:blipFill></p:pic>"#
        let cell = "<a:tbl><a:tr><a:tc><a:txBody><a:p><a:r><a:t>Visible cell</a:t></a:r></a:p></a:txBody></a:tc></a:tr></a:tbl>"
        let table = "<p:graphicFrame xmlns:e=\"urn:extension\" mc:Ignorable=\"e\"><e:ignored>" + cell.replacingOccurrences(of: "Visible", with: "Hidden") + "</e:ignored><a:graphic><a:graphicData uri='http://schemas.openxmlformats.org/drawingml/2006/table'>" + cell + "</a:graphicData></a:graphic></p:graphicFrame>"
        let data = B.deck(slides: [.init(file: "s.xml", shapes: picture + table, relationships: [("real", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", "../media/real.png")])], extraParts: [("ppt/media/real.png", [1,2,3])])
        let result = try await PicoDocsEngine.convert(data: data, filename: "ignored.pptx")
        #expect(result.markdown().contains("real.png")); #expect(result.markdown().contains("Visible cell")); #expect(!result.markdown().contains("Hidden"))
    }

    @Test func rootOfficeRelationshipUsesSupportedURIIdentity() async throws {
        typealias B = PowerPointConverterTests
        let base = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Slide"))])
        for type in ["http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument", "http://purl.oclc.org/ooxml/officeDocument/relationships/officeDocument", "https://vendor.example/officeDocument"] {
            let rels = B.relationshipsXML([("office", type, "ppt/presentation.xml"), ("vendor", "https://vendor.example/officeDocument", "missing.xml")])
            let parts = try entries(base).filter { $0.name != "_rels/.rels" } + [("_rels/.rels", Array(rels.utf8))]
            let data = PagesConverterTests.makeZip(parts)
            if type.hasPrefix("https://vendor") {
                await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: data, filename: "vendor.pptx") }
            } else {
                let result = try await PicoDocsEngine.convert(data: data, filename: "uri.pptx")
                #expect(result.markdown() == "## Slide")
            }
        }
    }

    @Test func mustUnderstandChecksOnlyProcessedNamespaceDeclarations() async throws {
        typealias B = PowerPointConverterTests
        let base = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Visible"))])
        for required in ["a", "alias", "e", "undeclared"] {
            let parts = try entries(base).map { entry -> (name: String, data: [UInt8]) in
                guard entry.name == "ppt/slides/s.xml" else { return entry }
                let xml = String(decoding: entry.data, as: UTF8.self).replacingOccurrences(of: "<p:sld ", with: "<p:sld xmlns:e=\"urn:unsupported\" xmlns:alias=\"http://schemas.openxmlformats.org/drawingml/2006/main\" mc:MustUnderstand=\"\(required)\" ")
                return (entry.name, Array(xml.utf8))
            }
            let data = PagesConverterTests.makeZip(parts)
            if required == "a" || required == "alias" {
                let result = try await PicoDocsEngine.convert(data: data, filename: "understood.pptx")
                #expect(result.markdown() == "## Visible")
            } else { await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: data, filename: "unsupported.pptx") } }
        }
        let alternate = "<mc:AlternateContent xmlns:e=\"urn:unsupported\"><mc:Choice Requires=\"e\" mc:MustUnderstand=\"e\">" + B.titleShape("Wrong") + "</mc:Choice><mc:Fallback>" + B.titleShape("Fallback") + "</mc:Fallback></mc:AlternateContent>"
        let result = try await PicoDocsEngine.convert(data: B.deck(slides: [.init(file: "s.xml", shapes: alternate)]), filename: "unselected.pptx")
        #expect(result.markdown() == "## Fallback")
    }

    @Test func parameterizedContentTypesPreserveValuesAndRejectMalformedParameters() async throws {
        typealias B = PowerPointConverterTests
        let valid = ["application/xml;charset=utf-8", "application/custom ; name=\"semi;colon\";quoted=\"a\\\"b\"", "application/x;empty=\"\""]
        for mime in valid + ["application/xml;", "application/xml;name=", "application/xml;name=\"unterminated", "application/xml;name=a b", "application/xml;name =value"] {
            let escaped = mime.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            let manifest = "<Types><Default Extension=\"custom\" ContentType=\"\(escaped)\"/></Types>"
            let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Visible"))], extraParts: [("[Content_Types].xml", Array(manifest.utf8))])
            if valid.contains(mime) {
                let result = try await PicoDocsEngine.convert(data: data, filename: "parameters.pptx")
                #expect(result.markdown() == "## Visible")
                let package = PowerPointPackage(archive: try #require(Archive(data: data, accessMode: .read)))
                #expect(PowerPointConverter.contentType("part.custom", archive: package) == mime)
            } else {
                await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: data, filename: "bad-parameters.pptx") }
            }
        }
    }

    @Test func relationshipTargetModesUseExactEnumeration() throws {
        for mode: String? in [nil, "Internal", "External", "Bogus", "", "external"] {
            let attribute = mode.map { " TargetMode=\"\($0)\"" } ?? ""
            let xml = "<Relationships><Relationship Id=\"link\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"https://example.com\"\(attribute)/></Relationships>"
            let data = PagesConverterTests.makeZip([("ppt/slides/_rels/s.xml.rels", Array(xml.utf8))])
            let package = PowerPointPackage(archive: try #require(Archive(data: data, accessMode: .read)))
            let relationships = PowerPointConverter.relationships(package, forPart: "ppt/slides/s.xml")
            if mode == nil || mode == "Internal" || mode == "External" {
                try package.check()
                #expect(relationships["link"]?.external == (mode == "External"))
            } else { #expect(throws: PicoDocsError.fileCorrupted) { try package.check() } }
        }
    }

    @Test func explicitDecreasingRestartsSurviveEveryTextExport() throws {
        let source = "10. A\n11. B\n12. C\n3. D\n4. E"
        let result = ConverterResult(sections: [.init(markdown: source)])
        #expect(try DocumentRenderer.render(result, to: .plaintext) == source)
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("<ol start=\"10\">"))
        #expect(html.contains("<li value=\"3\">D</li>"))
        #expect(html.contains("<li>E</li>"))
    }

    @Test func processContentUsesInheritedNamespaceIdentities() async throws {
        typealias B = PowerPointConverterTests
        let visible = B.titleShape("Visible")
        let hidden = B.titleShape("Hidden")
        let base = B.deck(slides: [.init(file: "s.xml", shapes: "")])
        let shapes = "<alias:wrapper><e:wrapper>\(visible)</e:wrapper></alias:wrapper><e:other>\(hidden)</e:other><e:wrapper xmlns:e=\"urn:different\" mc:Ignorable=\"e\">\(hidden)</e:wrapper>"
        let xml = "<p:sld \(B.namespaces) xmlns:e=\"urn:extension\" xmlns:alias=\"urn:extension\" mc:Ignorable=\"e\" mc:ProcessContent=\"e:wrapper\"><e:wrapper><p:cSld><p:spTree>\(shapes)</p:spTree></p:cSld></e:wrapper></p:sld>"
        let parts = try entries(base).filter { $0.name != "ppt/slides/s.xml" } + [("ppt/slides/s.xml", Array(xml.utf8))]
        let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip(parts), filename: "process-content.pptx")
        #expect(result.markdown() == "## Visible")
    }

    @Test func OLEFramesKeepTheirVisiblePreviewPictures() async throws {
        typealias B = PowerPointConverterTests
        let picture = #"<p:pic><p:nvPicPr><p:cNvPr name="Preview"/></p:nvPicPr><p:blipFill><a:blip r:embed="image"/></p:blipFill></p:pic>"#
        let frame = "<p:graphicFrame><a:graphic><a:graphicData uri='http://schemas.openxmlformats.org/presentationml/2006/ole'><p:oleObj r:id=\"ole\">" + picture + "</p:oleObj></a:graphicData></a:graphic></p:graphicFrame>"
        let bytes: [UInt8] = [0x89, 0x50, 0x4e, 0x47]
        let data = B.deck(slides: [.init(file: "s.xml", shapes: frame, relationships: [("image", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", "../media/preview.png")])], extraParts: [("ppt/media/preview.png", bytes)])
        let result = try await PicoDocsEngine.convert(data: data, filename: "ole.pptx")
        #expect(result.markdown() == "![Preview](preview.png)")
        #expect(result.sections.first { $0.kind == .image }?.metadata["base64"] == Data(bytes).base64EncodedString())
    }

    @Test func multilineListLinksCodeAndHardBreaksRemainDistinct() throws {
        let result = ConverterResult(sections: [.init(markdown: "- [hello\n  world](https://example.com)\n- `code  \n  span`\n- hard  \n  break")])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("<a href=\"https://example.com\">hello world</a>"))
        #expect(html.contains("<code>code   span</code>"))
        #expect(html.contains("hard<br>break"))
        #expect(try DocumentRenderer.render(result, to: .plaintext) == "- hello world\n- code   span\n- hard\n  break")
    }

    @Test func groupHyperlinksInheritOverrideAndStayWithinTheGroup() async throws {
        typealias B = PowerPointConverterTests
        func text(_ value: String, click: String? = nil) -> String {
            let shape = B.shape(placeholder: nil, paragraphs: ["<a:p><a:r><a:t>\(value)</a:t></a:r></a:p>"])
            guard let click else { return shape }
            return shape.replacingOccurrences(of: "<p:cNvPr id=\"2\" name=\"Shape\"/>", with: "<p:cNvPr id=\"2\" name=\"Shape\"><a:hlinkClick r:id=\"\(click)\"/></p:cNvPr>")
        }
        let picture = #"<p:pic><p:nvPicPr><p:cNvPr name="Picture"/></p:nvPicPr><p:blipFill><a:blip r:embed="image"/></p:blipFill></p:pic>"#
        let group = "<p:grpSp><p:nvGrpSpPr><p:cNvPr><a:hlinkClick r:id=\"group\"/></p:cNvPr></p:nvGrpSpPr>" + text("Inherited") + text("Override", click: "child") + text("Unsafe", click: "unsafe") + "<p:grpSp>" + text("Nested") + picture + "</p:grpSp></p:grpSp>" + text("Outside")
        let rels = #"<Relationships><Relationship Id="group" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://example.com/group" TargetMode="External"/><Relationship Id="child" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://example.com/child" TargetMode="External"/><Relationship Id="unsafe" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="javascript:alert(1)" TargetMode="External"/><Relationship Id="image" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image.png"/></Relationships>"#
        let data = B.deck(slides: [.init(file: "s.xml", shapes: group)], extraParts: [("ppt/slides/_rels/s.xml.rels", Array(rels.utf8)), ("ppt/media/image.png", [1,2,3])])
        let result = try await PicoDocsEngine.convert(data: data, filename: "group.pptx")
        let markdown = result.markdown()
        #expect(markdown.contains("[Inherited](https://example.com/group)"))
        #expect(markdown.contains("[Override](https://example.com/child)"))
        #expect(markdown.contains("[Nested](https://example.com/group)"))
        #expect(markdown.contains("[![Picture](image.png)](https://example.com/group)"))
        #expect(!markdown.contains("[Outside]")); #expect(!markdown.contains("[Unsafe]"))
    }

    @Test func structuralCompatibilityWrappersPreserveSlidesAndNotes() async throws {
        typealias B = PowerPointConverterTests
        let noteShape = B.shape(placeholder: #"<p:ph type="body"/>"#, paragraphs: ["<a:p><a:r><a:t>Notes text</a:t></a:r></a:p>"])
        let notes = "<p:notes \(B.namespaces)><p:cSld><p:spTree>" + noteShape + "</p:spTree></p:cSld></p:notes>"
        let base = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Visible"), relationships: [("notes", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide", "../notesSlides/n.xml")])], extraParts: [("ppt/notesSlides/n.xml", Array(notes.utf8))])
        for node in ["p:cSld", "p:spTree"] {
            for fallback in [false, true] {
                let parts = try entries(base).map { entry -> (name: String, data: [UInt8]) in
                    guard entry.name == "ppt/slides/s.xml" || entry.name == "ppt/notesSlides/n.xml" else { return entry }
                    let open = fallback ? "<mc:AlternateContent><mc:Choice Requires=\"p14\"/><mc:Fallback>" : "<mc:AlternateContent><mc:Choice Requires=\"a\">"
                    let close = fallback ? "</mc:Fallback></mc:AlternateContent>" : "</mc:Choice><mc:Fallback/></mc:AlternateContent>"
                    let xml = String(decoding: entry.data, as: UTF8.self).replacingOccurrences(of: "<" + node + ">", with: open + "<" + node + ">").replacingOccurrences(of: "</" + node + ">", with: "</" + node + ">" + close)
                    return (entry.name, Array(xml.utf8))
                }
                let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip(parts), filename: "structure.pptx")
                #expect(result.sections.first?.title == "Visible")
                #expect(result.sections.first?.metadata["notes"] == "- Notes text")
            }
        }
    }

    @Test func wrappedLayoutAndMasterStructureRetainsPlaceholderInheritance() async throws {
        typealias B = PowerPointConverterTests
        let ph = #"<p:ph type="body" idx="1"/>"#
        let shape = B.shape(placeholder: ph, paragraphs: ["<a:p><a:r><a:t>Inherited</a:t></a:r></a:p>"])
        let layoutShape = B.shape(placeholder: ph, paragraphs: []).replacingOccurrences(of: "<a:bodyPr/>", with: #"<a:bodyPr/><a:lstStyle><a:lvl1pPr><a:buNone/><a:defRPr b="1"/></a:lvl1pPr></a:lstStyle>"#)
        let layout = "<p:sldLayout \(B.namespaces)>" + selectedWrapper("<p:cSld>" + selectedWrapper("<p:spTree>" + layoutShape + "</p:spTree>") + "</p:cSld>") + "</p:sldLayout>"
        let master = "<p:sldMaster \(B.namespaces)>" + selectedWrapper("<p:cSld>" + selectedWrapper("<p:spTree/>") + "</p:cSld>") + "</p:sldMaster>"
        let rels = B.relationshipsXML([("master", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster", "../slideMasters/m.xml")])
        let data = B.deck(slides: [.init(file: "s.xml", shapes: shape, relationships: [("layout", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout", "../slideLayouts/l.xml")])], extraParts: [("ppt/slideLayouts/l.xml", Array(layout.utf8)), ("ppt/slideLayouts/_rels/l.xml.rels", Array(rels.utf8)), ("ppt/slideMasters/m.xml", Array(master.utf8))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "inherit.pptx")
        #expect(result.markdown() == "**Inherited**")
    }


    private func selectedWrapper(_ selected: String, fallback: String = "") -> String {
        "<mc:AlternateContent><mc:Choice Requires=\"a\">" + selected + "</mc:Choice><mc:Fallback>" + fallback + "</mc:Fallback></mc:AlternateContent>"
    }

    @Test func selectedTextBodyAndTableRowsSurviveWrappers() async throws {
        typealias B = PowerPointConverterTests
        let body = "<p:txBody><a:p><a:r><a:t>Selected title</a:t></a:r></a:p></p:txBody>"
        let title = B.titleShape("unused").replacingOccurrences(of: "<p:txBody><a:bodyPr/><a:p><a:r><a:t>unused</a:t></a:r></a:p></p:txBody>", with: selectedWrapper(body, fallback: body.replacingOccurrences(of: "Selected", with: "Wrong")))
        let cell = "<a:tc><a:txBody><a:p><a:r><a:t>Selected cell</a:t></a:r></a:p></a:txBody></a:tc>"
        let table = "<p:graphicFrame><a:graphic><a:graphicData uri='http://schemas.openxmlformats.org/drawingml/2006/table'><a:tbl>" + selectedWrapper("<a:tr>" + selectedWrapper(cell) + "</a:tr>") + "</a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
        let result = try await PicoDocsEngine.convert(data: B.deck(slides: [.init(file: "s.xml", shapes: title + table)]), filename: "wrapped.pptx")
        #expect(result.sections.first?.title == "Selected title")
        #expect(result.markdown().contains("| Selected cell |")); #expect(!result.markdown().contains("Wrong"))
    }

    @Test func selectedSlideIDListsIgnoreUnselectedBranches() async throws {
        typealias B = PowerPointConverterTests
        let base = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Selected"))])
        for wrapList in [false, true] {
            let id = #"<p:sldId id="256" r:id="rIdSlide0"/>"#
            let list = "<p:sldIdLst>" + selectedWrapper(id, fallback: id.replacingOccurrences(of: "rIdSlide0", with: "missing")) + "</p:sldIdLst>"
            let presentation = "<p:presentation \(B.namespaces)>" + (wrapList ? selectedWrapper(list, fallback: "<p:sldIdLst>" + id + "</p:sldIdLst>") : list) + "</p:presentation>"
            let parts = try entries(base).filter { $0.name != "ppt/presentation.xml" } + [("ppt/presentation.xml", Array(presentation.utf8))]
            let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip(parts), filename: "ids.pptx")
            #expect(result.sections.first?.title == "Selected")
        }
    }

    @Test func misplacedOptionalRelationshipsFailInsteadOfDroppingContent() async throws {
        typealias B = PowerPointConverterTests
        let base = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Visible"))])
        for declaration in ["<wrapper><Relationship Id=\"n\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide\" Target=\"n.xml\"/></wrapper>", "<Relationship Id=\"n\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide\" Target=\"n.xml\"><Relationship Id=\"nested\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout\" Target=\"l.xml\"/></Relationship>"] {
            let parts = try entries(base) + [("ppt/slides/_rels/s.xml.rels", Array(("<Relationships>" + declaration + "</Relationships>").utf8))]
            await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip(parts), filename: "rels.pptx") }
        }
    }

    @Test func hiddenDrawingObjectsDoNotContributeContentOrImages() async throws {
        typealias B = PowerPointConverterTests
        let hiddenShape = B.titleShape("Secret title").replacingOccurrences(of: "<p:cNvPr ", with: "<p:cNvPr hidden=\"1\" ")
        let hiddenGroup = "<p:grpSp><p:nvGrpSpPr><p:cNvPr hidden=\"true\"/></p:nvGrpSpPr>" + B.titleShape("Secret group") + "</p:grpSp>"
        let hiddenPicture = "<p:pic><p:nvPicPr><p:cNvPr hidden=\"1\"/></p:nvPicPr><p:blipFill><a:blip r:embed=\"missing\"/></p:blipFill></p:pic>"
        let hiddenTable = "<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr hidden=\"true\"/></p:nvGraphicFramePr><a:tbl><a:tr><a:tc><a:txBody><a:p><a:r><a:t>Secret table</a:t></a:r></a:p></a:txBody></a:tc></a:tr></a:tbl></p:graphicFrame>"
        let result = try await PicoDocsEngine.convert(data: B.deck(slides: [.init(file: "s.xml", shapes: hiddenShape + hiddenGroup + hiddenPicture + hiddenTable + B.titleShape("Visible"))]), filename: "hidden.pptx")
        #expect(result.markdown() == "## Visible"); #expect(!result.sections.contains { $0.kind == .image })
    }

    @Test func linkOnlyPicturesKeepSafeSourcesAndPreferEmbeddedData() async throws {
        typealias B = PowerPointConverterTests
        let picture = #"<p:pic><p:nvPicPr><p:cNvPr name="Linked"/></p:nvPicPr><p:blipFill><a:blip r:link="remote"/></p:blipFill></p:pic>"#
        for target in ["https://example.com/image.png", "javascript:alert(1)"] {
            let rels = "<Relationships><Relationship Id=\"remote\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" TargetMode=\"External\" Target=\"\(target)\"/></Relationships>"
            let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Slide") + picture)], extraParts: [("ppt/slides/_rels/s.xml.rels", Array(rels.utf8))])
            let result = try await PicoDocsEngine.convert(data: data, filename: "linked.pptx")
            #expect(result.markdown().contains("![Linked](https://example.com/image.png)") == target.hasPrefix("https:"))
            #expect(!result.markdown().contains("javascript:")); #expect(!result.sections.contains { $0.kind == .image })
        }
        let rels = #"<Relationships><Relationship Id="embedded" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/p.png"/><Relationship Id="remote" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" TargetMode="External" Target="https://example.com/remote.png"/></Relationships>"#
        let data = B.deck(slides: [.init(file: "s.xml", shapes: picture.replacingOccurrences(of: "r:link=", with: "r:embed=\"embedded\" r:link="))], extraParts: [("ppt/slides/_rels/s.xml.rels", Array(rels.utf8)), ("ppt/media/p.png", [1, 2, 3])])
        let result = try await PicoDocsEngine.convert(data: data, filename: "both.pptx")
        #expect(result.markdown().contains("![Linked](p.png)")); #expect(!result.markdown().contains("remote.png"))
    }

    @Test func cancelledXMLNormalizationStopsBeforeParsingLargeProlog() async {
        let value = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return PowerPointXML.normalize(Data((String(repeating: " ", count: 1_000_000) + "<root/>").utf8))
        }.value
        #expect(value == nil)
    }


    private func entries(_ data: Data) throws -> [(name: String, data: [UInt8])] {
        let archive = try #require(Archive(data: data, accessMode: .read))
        return try archive.map { entry in
            var bytes = Data(); _ = try archive.extract(entry) { bytes.append($0) }
            return (entry.path, Array(bytes))
        }
    }

    @Test func relocatedCorePropertiesUseThePackageRelationship() async throws {
        typealias B = PowerPointConverterTests
        let core = #"<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Relocated title</dc:title><dc:creator>Ada</dc:creator></cp:coreProperties>"#
        let base = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Slide"))])
        var parts = try entries(base).filter { $0.name != "_rels/.rels" }
        parts.append(("metadata/properties.xml", Array(core.utf8)))
        let office = #"<Relationship Id="office" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>"#
        let relation = #"<Relationship Id="core" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="metadata/properties.xml"/>"#
        for extra in [relation, relation + relation.replacingOccurrences(of: "Id=\"core\"", with: "Id=\"other\""), relation.replacingOccurrences(of: "Target=", with: "TargetMode=\"External\" Target="), relation.replacingOccurrences(of: "properties.xml", with: "missing.xml")] {
            let data = PagesConverterTests.makeZip(parts + [("_rels/.rels", Array(("<Relationships>" + office + extra + "</Relationships>").utf8))])
            if extra == relation {
                let result = try await PicoDocsEngine.convert(data: data, filename: "relocated.pptx")
                #expect(result.title == "Relocated title"); #expect(result.author == "Ada")
            } else {
                await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: data, filename: "invalid.pptx") }
            }
        }
    }

    @Test func selectedRunWrappersPreserveTextFieldsBreaksAndTitleMetadata() async throws {
        typealias B = PowerPointConverterTests
        let wrapped = #"<a:p><mc:AlternateContent><mc:Choice Requires="a"><a:r><a:rPr b="1"/><a:t>Choice</a:t></a:r><a:br/><a:fld><a:t>Field</a:t></a:fld></mc:Choice><mc:Fallback><a:r><a:t>Unselected</a:t></a:r></mc:Fallback></mc:AlternateContent></a:p>"#
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.shape(placeholder: #"<p:ph type="title"/>"#, paragraphs: [wrapped]))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "runs.pptx")
        #expect(result.sections.first?.title == "Choice Field")
        #expect(result.markdown().contains("**Choice** Field")); #expect(!result.markdown().contains("Unselected"))
    }

    @Test func selectedNotesShapesTraverseGroupsAndCompatibilityWrappers() async throws {
        typealias B = PowerPointConverterTests
        let body = B.shape(placeholder: #"<p:ph type="body"/>"#, paragraphs: ["<a:p><a:r><a:t>Selected notes</a:t></a:r></a:p>"])
        let note = "<p:notes \(B.namespaces)><p:cSld><p:spTree><mc:AlternateContent><mc:Choice Requires=\"a\"><p:grpSp>" + body + "</p:grpSp></mc:Choice><mc:Fallback>" + body.replacingOccurrences(of: "Selected", with: "Unselected") + "</mc:Fallback></mc:AlternateContent></p:spTree></p:cSld></p:notes>"
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Slide"), relationships: [("notes", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide", "../notesSlides/n.xml")])], extraParts: [("ppt/notesSlides/n.xml", Array(note.utf8))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "notes.pptx")
        #expect(result.sections.first?.metadata["notes"] == "- Selected notes")
        #expect(!result.markdown().contains("Unselected"))
    }

    @Test func HTMLCodeTablePipesPreserveSlashRuns() async throws {
        for count in 0...3 {
            let expected = "a" + String(repeating: "\\", count: count) + "|b"
            let source = "<table><tr><td><code>" + expected + "</code></td></tr></table>"
            let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "pipes.html")
            let html = try DocumentRenderer.render(result, to: .html)
            #expect(html.components(separatedBy: "<th>").count == 2)
            #expect(html.contains("<code>" + expected + "</code>"))
            for format in [ExportFileType.plaintext, .csv] { #expect(try DocumentRenderer.render(result, to: format) == expected) }
        }
    }

    @Test func rootPartMalformedRelationshipsArePresentCorruption() throws {
        let data = PagesConverterTests.makeZip([(name: "_rels/slide.xml.rels", data: Array("<broken>".utf8))])
        let package = PowerPointPackage(archive: try #require(Archive(data: data, accessMode: .read)))
        _ = PowerPointConverter.relationships(package, forPart: "slide.xml")
        #expect(throws: PicoDocsError.fileCorrupted) { try package.check() }
    }

    @Test func duplicatePhysicalPartsAreRejectedBeforeLookup() async throws {
        typealias B = PowerPointConverterTests
        let parts = try entries(B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Slide"))], extraParts: [("ppt/media/image.png", [1, 2, 3])]))
        for path in ["[Content_Types].xml", "ppt/slides/s.xml", "_rels/.rels", "ppt/media/image.png"] {
            let duplicate = try #require(parts.first { $0.name == path })
            let data = PagesConverterTests.makeZip(parts + [duplicate])
            await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: data, filename: "duplicates.pptx") }
        }
    }

    @Test func listBoundariesUseASCIIDigitsAndActualMarkerPadding() throws {
        let prose = ConverterResult(sections: [.init(markdown: "Intro\n٢. literal\nTail")])
        let html = try DocumentRenderer.render(prose, to: .html)
        #expect(html.components(separatedBy: "<p>").count == 2)
        for spaces in 2...4 {
            let source = "-" + String(repeating: " ", count: spaces) + "parent\n  - sibling"
            var index = 0
            let list = try #require(MarkdownList.parse(source.components(separatedBy: "\n"), index: &index))
            #expect(list.items.count == 2); #expect(list.items.first?.text == "parent")
            #expect(list.items.allSatisfy { $0.children.isEmpty })
        }
    }

    @Test func explicitMissingPlaceholderIndexDoesNotSelectAnotherBody() throws {
        typealias B = PowerPointConverterTests
        let source = "<p:sldLayout \(B.namespaces)><p:cSld><p:spTree>" + B.shape(placeholder: #"<p:ph type="body" idx="1"/>"#, paragraphs: []) + B.shape(placeholder: #"<p:ph type="body" idx="2"/>"#, paragraphs: []) + "</p:spTree></p:cSld></p:sldLayout>"
        let document = try SwiftSoup.parse(source, "", SwiftSoup.Parser.xmlParser())
        let cache = PowerPointConverter.PlaceholderCache()
        #expect(cache.match(in: document, type: "body", index: "3") == nil)
        #expect(cache.match(in: document, type: "body", index: "1") != nil)
        #expect(cache.match(in: document, type: "body", index: "") != nil)
    }

    @Test func pictureClicksBecomeLinkedImagesAndValidateRelationships() async throws {
        typealias B = PowerPointConverterTests
        let picture = #"<p:pic><p:nvPicPr><p:cNvPr descr="Picture"><a:hlinkClick r:id="click"/></p:cNvPr></p:nvPicPr><p:blipFill><a:blip r:embed="image"/></p:blipFill></p:pic>"#
        let image = ("image", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", "../media/p.png")
        let click = ("click", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", "https://example.com\" TargetMode=\"External")
        let data = B.deck(slides: [.init(file: "s.xml", shapes: picture, relationships: [image, click])], extraParts: [("ppt/media/p.png", [1, 2, 3])])
        let result = try await PicoDocsEngine.convert(data: data, filename: "picture.pptx")
        #expect(result.markdown() == "[![Picture](p.png)](https://example.com)")
        #expect(try DocumentRenderer.render(result, to: .html).contains(#"<a href="https://example.com"><img src="data:image/png;base64,AQID" alt="Picture"></a>"#))
        #expect(try DocumentRenderer.render(result, to: .plaintext) == "Picture")
        let invalid = B.deck(slides: [.init(file: "s.xml", shapes: picture, relationships: [image])], extraParts: [("ppt/media/p.png", [1, 2, 3])])
        await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: invalid, filename: "invalid.pptx") }
    }

    @Test func selectedAlternateParagraphsReachTitlesTablesAndNotes() async throws {
        typealias B = PowerPointConverterTests
        let alternate = #"<mc:AlternateContent><mc:Choice Requires="a"><a:p><a:r><a:t>Selected</a:t></a:r></a:p></mc:Choice><mc:Fallback><a:p><a:r><a:t>Unselected</a:t></a:r></a:p></mc:Fallback></mc:AlternateContent>"#
        let table = "<p:graphicFrame><a:tbl><a:tr><a:tc><a:txBody>" + alternate + "</a:txBody></a:tc></a:tr></a:tbl></p:graphicFrame>"
        let notes = "<p:notes \(B.namespaces)><p:cSld><p:spTree>" + B.shape(placeholder: #"<p:ph type="body"/>"#, paragraphs: [alternate]) + "</p:spTree></p:cSld></p:notes>"
        let shapes = B.shape(placeholder: #"<p:ph type="title"/>"#, paragraphs: [alternate]) + B.shape(placeholder: nil, paragraphs: [alternate]) + table
        let data = B.deck(slides: [.init(file: "s.xml", shapes: shapes, relationships: [("notes", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide", "../notesSlides/n.xml")])], extraParts: [("ppt/notesSlides/n.xml", Array(notes.utf8))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "alternate.pptx")
        #expect(result.sections.first?.title == "Selected")
        #expect(result.markdown().components(separatedBy: "Selected").count == 5)
        #expect(!result.markdown().contains("Unselected"))
    }

    @Test func tableCodePipesRemoveOnlyTheTableEscapeLayer() throws {
        for (source, expected) in [(#"`a\|b`"#, "a|b"), (#"`a\\\|b`"#, #"a\|b"#), (#"`a\*b<br>`"#, #"a\*b<br>"#)] {
            let result = ConverterResult(sections: [.init(markdown: "| " + source + " |\n| --- |")])
            for format in [ExportFileType.html, .plaintext, .csv] {
                let rendered = try DocumentRenderer.render(result, to: format)
                #expect(rendered.contains(format == .html ? expected.replacingOccurrences(of: "<br>", with: "&lt;br&gt;") : expected))
            }
        }
    }

    @Test func packageRelationshipLocatesMovedPresentation() async throws {
        typealias B = PowerPointConverterTests
        let source = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Moved"))])
        let archive = try #require(Archive(data: source, accessMode: .read))
        var entries: [(name: String, data: [UInt8])] = []
        for entry in archive {
            var bytes = Data(); _ = try archive.extract(entry) { bytes.append($0) }
            var name = entry.path
            if name == "_rels/.rels" { continue }
            if name == "ppt/presentation.xml" { name = "custom/deck.xml" }
            if name == "ppt/_rels/presentation.xml.rels" {
                name = "custom/_rels/deck.xml.rels"
                bytes = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "slides/s.xml", with: "../ppt/slides/s.xml").utf8)
            }
            entries.append((name, Array(bytes)))
        }
        let relation = #"<Relationship Id="office" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="custom/deck.xml"/>"#
        for body: String? in [nil, "", relation, relation + relation.replacingOccurrences(of: "office\"", with: "second\""), relation.replacingOccurrences(of: "Target=", with: "TargetMode=\"External\" Target=")] {
            let parts = entries + (body.map { [("_rels/.rels", Array(("<Relationships>" + $0 + "</Relationships>").utf8))] } ?? [])
            if body == relation {
                let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip(parts), filename: "moved.pptx")
                #expect(result.markdown() == "## Moved")
                #expect(result.sections.first?.sourcePath == "ppt/slides/s.xml")
            } else {
                await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip(parts), filename: "invalid.pptx") }
            }
        }
    }

    @Test func emptyMarkdownItemsAndLiteralPowerPointMarkers() async throws {
        typealias B = PowerPointConverterTests
        for marker in ["-", "*", "+", "1."] {
            let html = try DocumentRenderer.render(ConverterResult(sections: [.init(markdown: marker)]), to: .html)
            #expect(html.contains("<li></li>"))
            let shape = B.shape(placeholder: nil, paragraphs: ["<a:p><a:r><a:t>\(marker)</a:t></a:r></a:p>"])
            let result = try await PicoDocsEngine.convert(data: B.deck(slides: [.init(file: "s.xml", shapes: shape)]), filename: "markers.pptx")
            #expect(try DocumentRenderer.render(result, to: .plaintext) == marker)
            #expect(try !DocumentRenderer.render(result, to: .html).contains("<li>"))
        }
    }

    @Test func leadingTablePipesKeepOneColumn() async throws {
        typealias B = PowerPointConverterTests
        for value in ["|value", "| value", #"\|value"#, #"\\| value"#, "a|b"] {
            let table = "<p:graphicFrame><a:tbl><a:tr><a:tc><a:txBody><a:p><a:r><a:t>\(value)</a:t></a:r></a:p></a:txBody></a:tc></a:tr></a:tbl></p:graphicFrame>"
            let result = try await PicoDocsEngine.convert(data: B.deck(slides: [.init(file: "s.xml", shapes: table)]), filename: "pipes.pptx")
            let html = try DocumentRenderer.render(result, to: .html)
            #expect(html.contains("<th>\(value)</th>"))
            #expect(html.components(separatedBy: "<th>").count == 2)
            #expect(try DocumentRenderer.render(result, to: .plaintext) == value)
            #expect(try DocumentRenderer.render(result, to: .csv).trimmingCharacters(in: .whitespacesAndNewlines) == value)
        }
    }

    @Test func optionalCorePropertiesValidatePresentParts() async throws {
        typealias B = PowerPointConverterTests
        for core: String? in [nil, "<broken>", "<other/>", #"<x:coreProperties xmlns:x="urn:wrong"/>"#,
            #"<x:coreProperties xmlns:x="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:d="http://purl.org/dc/elements/1.1/"><d:title>Title</d:title></x:coreProperties>"#] {
            let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Slide"))], extraParts: core.map { [("docProps/core.xml", Array($0.utf8))] } ?? [])
            if core == nil || core!.contains("<d:title>") {
                let result = try await PicoDocsEngine.convert(data: data, filename: "core.pptx")
                if core != nil { #expect(result.title == "Title") }
            } else {
                await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: data, filename: "core.pptx") }
            }
        }
    }

    @Test func contentTypesAcceptEveryTokenPunctuation() async throws {
        typealias B = PowerPointConverterTests
        for punctuation in "!#$%&'*+-.^_`|~" {
            let mime = "application/x\(punctuation)custom"
            let escaped = mime.replacingOccurrences(of: "&", with: "&amp;")
            let manifest = "<Types><Default Extension=\"custom\" ContentType=\"\(escaped)\"/></Types>"
            let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Slide"))], extraParts: [("[Content_Types].xml", Array(manifest.utf8))])
            let result = try await PicoDocsEngine.convert(data: data, filename: "types.pptx")
            #expect(result.markdown().contains("Slide"))
        }
    }

    @Test func extraSlideIDsAreRejectedAlongsideAValidDirectList() throws {
        typealias B = PowerPointConverterTests
        let deck = B.deck(slides:[.init(file:"s.xml",shapes:B.titleShape("Slide"))])
        let package = PowerPointPackage(archive:try #require(Archive(data:deck,accessMode:.read)))
        let source = "<p:presentation \(B.namespaces)><p:sldIdLst><p:sldId r:id=\"rIdSlide0\"/></p:sldIdLst><p:extLst><p:sldId r:id=\"rIdSlide0\"/></p:extLst></p:presentation>"
        let document = try SwiftSoup.parse(source,"",SwiftSoup.Parser.xmlParser())
        #expect(throws:PicoDocsError.fileCorrupted) { try PowerPointConverter.slidePaths(document,archive:package) }
    }

    @Test func unresolvedClicksAndIncompleteRelationshipsAreCorruption() async throws {
        typealias B = PowerPointConverterTests
        let run = B.shape(placeholder:nil,paragraphs:[#"<a:p><a:r><a:rPr><a:hlinkClick r:id="missing"/></a:rPr><a:t>Text</a:t></a:r></a:p>"#])
        let shape = B.shape(placeholder:nil,paragraphs:["<a:p><a:r><a:t>Text</a:t></a:r></a:p>"]).replacingOccurrences(of:#"<p:cNvPr id="2" name="Shape"/>"#,with:#"<p:cNvPr id="2" name="Shape"><a:hlinkClick r:id="missing"/></p:cNvPr>"#)
        for content in [run,shape] {
            await #expect(throws:PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data:B.deck(slides:[.init(file:"s.xml",shapes:content)]),filename:"unresolved.pptx") }
        }
        for attributes in [#"Id="x" Type="type""#, #"Target="target" Type="type""#, #"Id="x" Target="target""#] {
            let xml = "<Relationships><Relationship " + attributes + "/></Relationships>"
            let data = PagesConverterTests.makeZip([(name:"ppt/slides/_rels/s.xml.rels",data:Array(xml.utf8))])
            let package = PowerPointPackage(archive:try #require(Archive(data:data,accessMode:.read)))
            #expect(PowerPointConverter.relationships(package,forPart:"ppt/slides/s.xml").isEmpty)
            #expect(throws:PicoDocsError.fileCorrupted) { try package.check() }
        }
    }

    @Test func invalidOrAbsentContentTypesFailValidation() throws {
        let cases: [String?] = [nil,"<Types>","<Other/>",#"<Types><Wrapper><Default Extension="png" ContentType="image/png"/></Wrapper></Types>"#,#"<Types><Default Extension="png"/></Types>"#,#"<Types><Default Extension="png" ContentType="image/png&quot; onerror=&quot;x"/></Types>"#]
        for source in cases {
            var entries: [(name:String,data:[UInt8])] = [("dummy",[1])]
            if let source { entries.append(("[Content_Types].xml",Array(source.utf8))) }
            let package = PowerPointPackage(archive:try #require(Archive(data:PagesConverterTests.makeZip(entries),accessMode:.read)))
            #expect(PowerPointConverter.contentType("ppt/media/a.bin",archive:package) == nil)
            #expect(throws:PicoDocsError.fileCorrupted) { try package.check() }
        }
    }

    @Test func placeholderIndexesAreReusedAcrossSharedPartLookups() throws {
        typealias B = PowerPointConverterTests
        let shape = B.shape(placeholder:#"<p:ph type="body" idx="1"/>"#,paragraphs:[])
        let source = "<p:sldLayout \(B.namespaces)><p:cSld><p:spTree>" + shape + "</p:spTree></p:cSld></p:sldLayout>"
        let data = PagesConverterTests.makeZip([(name:"l.xml",data:Array(source.utf8))])
        let package = PowerPointPackage(archive:try #require(Archive(data:data,accessMode:.read)))
        var cache = PowerPointConverter.PartCache(archive:package)
        let firstResult = cache.document("l.xml",root:"p:sldlayout")
        let first = try #require(firstResult)
        for _ in 0..<100 { #expect(cache.placeholders.match(in:first,type:"body",index:"1") != nil) }
        let secondResult = cache.document("l.xml",root:"p:sldlayout")
        let second = try #require(secondResult)
        #expect(cache.placeholders.match(in:second,type:"obj",index:"") != nil)
        #expect(cache.placeholders.buildCount == 1)
    }

    @Test func externalClicksRequireHyperlinkRelationships() async throws {
        typealias B = PowerPointConverterTests
        let type = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
        let run = B.shape(placeholder:nil,paragraphs:[#"<a:p><a:r><a:rPr><a:hlinkClick r:id="link"/></a:rPr><a:t>Text</a:t></a:r></a:p>"#])
        let shape = B.shape(placeholder:nil,paragraphs:["<a:p><a:r><a:t>Text</a:t></a:r></a:p>"]).replacingOccurrences(of:#"<p:cNvPr id="2" name="Shape"/>"#,with:#"<p:cNvPr id="2" name="Shape"><a:hlinkClick r:id="link"/></p:cNvPr>"#)
        for content in [run,shape] {
            let data = B.deck(slides:[.init(file:"s.xml",shapes:content,relationships:[("link",type + "image","https://example.com\" TargetMode=\"External")])])
            await #expect(throws:PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data:data,filename:"wrong-type.pptx") }
        }
    }

    @Test func placeholderInheritanceUsesSelectedAlternateContent() async throws {
        typealias B = PowerPointConverterTests
        let ph = #"<p:ph type="body" idx="1"/>"#
        let slide = B.shape(placeholder:ph,paragraphs:["<a:p><a:r><a:t>Inherited</a:t></a:r></a:p>"])
        func styled(_ properties: String) -> String {
            B.shape(placeholder:ph,paragraphs:[]).replacingOccurrences(of:"<a:bodyPr/>",with:"<a:bodyPr/><a:lstStyle><a:lvl1pPr>" + properties + "</a:lvl1pPr></a:lstStyle>")
        }
        let choices = "<mc:AlternateContent><mc:Choice Requires=\"p14\">" + styled("<a:buChar char=\"•\"/><a:defRPr i=\"1\"/>") + "</mc:Choice><mc:Fallback>" + styled("<a:buNone/><a:defRPr b=\"1\"/>") + "</mc:Fallback></mc:AlternateContent>"
        let layout = "<p:sldLayout \(B.namespaces)><p:cSld><p:spTree>" + choices + "</p:spTree></p:cSld></p:sldLayout>"
        let data = B.deck(slides:[.init(file:"s.xml",shapes:slide,relationships:[("layout","http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout","../slideLayouts/l.xml")])],extraParts:[("ppt/slideLayouts/l.xml",Array(layout.utf8))])
        let result = try await PicoDocsEngine.convert(data:data,filename:"fallback.pptx")
        #expect(result.markdown().contains("**Inherited**")); #expect(!result.markdown().contains("- ")); #expect(!result.markdown().contains("***"))
    }

    @Test func internalTargetsCannotTraverseAbovePackageRoot() async throws {
        typealias B = PowerPointConverterTests
        // Builder prefixes slides/, requiring three parent components to underflow ppt/slides.
        let data = B.deck(slides:[.init(file:"s.xml",shapes:B.titleShape("Slide"))],order:["../../../ppt/slides/s.xml"])
        await #expect(throws:PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data:data,filename:"escape.pptx") }
        let valid = B.deck(slides:[.init(file:"s.xml",shapes:B.titleShape("Slide"))],order:["../../ppt/slides/s.xml"])
        #expect(try await PicoDocsEngine.convert(data:valid,filename:"inside.pptx").markdown().contains("Slide"))
    }

    @Test func codeAndDestinationsProtectTableBreakMarkers() throws {
        for cell in ["`<br>`", "``<br>``"] {
            let result = ConverterResult(sections:[.init(markdown:"| " + cell + " |\n| --- |")])
            #expect(try DocumentRenderer.render(result,to:.plaintext).contains("<br>"))
            #expect(try DocumentRenderer.render(result,to:.html).contains("<code>&lt;br&gt;</code>"))
            #expect(try DocumentRenderer.render(result,to:.csv).contains("<br>"))
        }
        #expect(MarkdownTableCell.decodeBreaks("`<br>` [link](https://example.com/<br>)<br>tail") == "`<br>` [link](https://example.com/<br>)\ntail")
        for cell in [#"\-\-\-"#, "*---*", "`---`"] {
            let result = ConverterResult(sections:[.init(markdown:"| Header |\n| " + cell + " |")])
            #expect(try DocumentRenderer.render(result,to:.csv).contains("---"))
        }
    }

    @Test func graphicFrameTablesSelectSupportedFallbacks() async throws {
        typealias B = PowerPointConverterTests
        func table(_ text: String) -> String { "<a:tbl><a:tr><a:tc><a:txBody><a:p><a:r><a:t>" + text + "</a:t></a:r></a:p></a:txBody></a:tc></a:tr></a:tbl>" }
        let shape = "<p:graphicFrame><a:graphic><mc:AlternateContent><mc:Choice Requires=\"p14\">" + table("Wrong") + "</mc:Choice><mc:Fallback>" + table("Right") + "</mc:Fallback></mc:AlternateContent></a:graphic></p:graphicFrame>"
        let result = try await PicoDocsEngine.convert(data:B.deck(slides:[.init(file:"s.xml",shapes:shape)]),filename:"table-choice.pptx")
        #expect(result.markdown().contains("Right")); #expect(!result.markdown().contains("Wrong"))
    }

    @Test func externalInheritancePartsAreRejected() throws {
        typealias B = PowerPointConverterTests
        let data = PagesConverterTests.makeZip([(name:"ppt/layout.xml",data:Array("<p:sldLayout \(B.namespaces)><p:cSld><p:spTree/></p:cSld></p:sldLayout>".utf8))])
        for suffix in ["/slideLayout", "/slideMaster"] {
            let package = PowerPointPackage(archive:try #require(Archive(data:data,accessMode:.read)))
            let relationships = ["external":PowerPointConverter.Relationship(type:"http://schemas.openxmlformats.org/officeDocument/2006/relationships" + suffix,target:"../layout.xml",external:true)]
            #expect(PowerPointConverter.relatedPart(of:"ppt/slides/s.xml",type:suffix,relationships:relationships,archive:package) == nil)
            #expect(throws:PicoDocsError.fileCorrupted) { try package.check() }
        }
    }

    @Test func notesRequireOneConsistentInternalBacklink() async throws {
        typealias B = PowerPointConverterTests
        let type = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
        let notes = "<p:notes \(B.namespaces)><p:cSld><p:spTree>" + B.shape(placeholder:#"<p:ph type="body"/>"#,paragraphs:["<a:p><a:r><a:t>Note</a:t></a:r></a:p>"]) + "</p:spTree></p:cSld></p:notes>"
        let variants: [[(id:String,type:String,target:String)]] = [[],[("back",type + "slide","../slides/other.xml")],[("back",type + "slide","../slides/s.xml\" TargetMode=\"External")],[("back",type + "slide","../slides/s.xml"),("again",type + "slide","../slides/s.xml")]]
        for backlinks in variants {
            let parts = [(name:"ppt/notesSlides/n.xml",data:Array(notes.utf8)),(name:"ppt/notesSlides/_rels/n.xml.rels",data:Array(B.relationshipsXML(backlinks).utf8))]
            let data = B.deck(slides:[.init(file:"s.xml",shapes:B.titleShape("Slide"),relationships:[("notes",type + "notesSlide","../notesSlides/n.xml")])],extraParts:parts,notesBacklinks:false)
            await #expect(throws:PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data:data,filename:"bad-backlink.pptx") }
        }
        let duplicated = B.deck(slides:[.init(file:"s.xml",shapes:B.titleShape("Slide"),relationships:[("first",type + "notesSlide","../notesSlides/n.xml"),("second",type + "notesSlide","../notesSlides/n.xml")])],extraParts:[("ppt/notesSlides/n.xml",Array(notes.utf8))])
        await #expect(throws:PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data:duplicated,filename:"two-notes.pptx") }
    }

    @Test func HTMLTableTextKeepsLiteralInlinePunctuation() async throws {
        let source = "<table><tr><td>Value</td></tr><tr><td>*stars* `code` [label](target) <strong>Bold</strong></td></tr></table>"
        let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "literal.html")
        for format in [ExportFileType.plaintext, .csv] {
            #expect(try DocumentRenderer.render(result, to: format).contains("*stars* `code` [label](target) Bold"))
        }
    }

    @Test func mixedOrderedMarkersAdvanceAndLooseListsKeepBoundaries() throws {
        let result = ConverterResult(sections: [.init(markdown: "1. First\n1. Second\n2. Third\n10. Gap\n\n11. Separate")])
        #expect(try DocumentRenderer.render(result, to: .plaintext) == "1. First\n2. Second\n3. Third\n10. Gap\n\n11. Separate")
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.components(separatedBy: "<ol").count - 1 == 2)
        #expect(!html.contains(#"value="2""#))
    }

    @Test func numberingSchemeChangesClearStartTracking() async throws {
        typealias B = PowerPointConverterTests
        let specs = [("arabicPeriod", " startAt=\"5\""), ("alphaLcPeriod", ""), ("alphaLcPeriod", " startAt=\"5\"")]
        let paragraphs = specs.enumerated().map { index, pair in
            "<a:p><a:pPr><a:buAutoNum type=\"\(pair.0)\"\(pair.1)/></a:pPr><a:r><a:t>Item \(index)</a:t></a:r></a:p>"
        }
        let result = try await PicoDocsEngine.convert(data: B.deck(slides: [.init(file:"s.xml",shapes:B.shape(placeholder:nil,paragraphs:paragraphs))]), filename:"schemes.pptx")
        #expect(result.markdown().contains("- e. Item 2"))
    }

    @Test func XMLRejectsDTDsAcrossEncodingsAndRetainsLiteralMentions() {
        for source in ["<!DOCTYPE x [<!ENTITY a 'text'>]><x>&a;</x>", "<!DOCTYPE x SYSTEM 'https://invalid.example/x'><x/>", "<!DOCTYPE x><x/>"] {
            for encoding in [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian] {
                #expect(PowerPointXML.normalize(source.data(using: encoding)!) == nil)
            }
        }
        #expect(PowerPointXML.normalize(Data("<!-- <!DOCTYPE ignored> --><x><![CDATA[<!DOCTYPE literal>]]></x>".utf8)) == "<x>&lt;!DOCTYPE literal&gt;</x>")
    }

    @Test func cachedLayoutAndMasterTreesAndDuplicateRelationshipsAreValidated() throws {
        typealias B = PowerPointConverterTests
        for root in ["sldLayout", "sldMaster", "notesMaster"] {
            let data = PagesConverterTests.makeZip([(name:"part.xml",data:Array("<p:\(root) \(B.namespaces)/>".utf8))])
            let package = PowerPointPackage(archive: try #require(Archive(data:data,accessMode:.read)))
            var cache = PowerPointConverter.PartCache(archive:package)
            #expect(cache.document("part.xml",root:"p:" + root.lowercased()) == nil)
            #expect(throws:PicoDocsError.fileCorrupted) { try package.check() }
        }
        let rels = B.relationshipsXML([("same","http://schemas.openxmlformats.org/officeDocument/2006/relationships/image","a.png"),("same","http://schemas.openxmlformats.org/officeDocument/2006/relationships/image","b.png")])
        let package = PowerPointPackage(archive:try #require(Archive(data:PagesConverterTests.makeZip([(name:"ppt/slides/_rels/s.xml.rels",data:Array(rels.utf8))]),accessMode:.read)))
        #expect(PowerPointConverter.relationships(package,forPart:"ppt/slides/s.xml").isEmpty)
        #expect(throws:PicoDocsError.fileCorrupted) { try package.check() }
    }

    @Test func pictureRelationshipsAndAlternateBranchesAreValidated() async throws {
        typealias B = PowerPointConverterTests
        let fill = "<mc:AlternateContent><mc:Choice Requires=\"p14\"><a:blip r:embed=\"wrong\"/></mc:Choice><mc:Fallback><a:blip r:embed=\"image\"/></mc:Fallback></mc:AlternateContent>"
        let picture = "<p:pic><p:nvPicPr><p:cNvPr descr=\"Photo\"/></p:nvPicPr><p:blipFill>" + fill + "</p:blipFill></p:pic>"
        let type = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
        for imageType in ["image", "slide"] {
            let data = B.deck(slides:[.init(file:"s.xml",shapes:B.titleShape("Slide") + picture,relationships:[("image",type + imageType,"../media/good.png")])],extraParts:[("ppt/media/good.png",[1,2,3])])
            if imageType == "image" {
                let result = try await PicoDocsEngine.convert(data:data,filename:"fallback.pptx")
                #expect(result.sections.contains { $0.kind == .image && $0.metadata["base64"] == "AQID" })
            } else {
                await #expect(throws:PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data:data,filename:"bad-type.pptx") }
            }
        }
    }

    @Test func normalizedXMLHasAnOutputBudget() {
        let quotes = "<root>" + String(repeating: "\"", count: 100) + "</root>"
        #expect(PowerPointXML.normalize(Data(quotes.utf8), maximumOutputBytes: 113) == quotes)
        for source in ["<root><![CDATA[" + String(repeating: "<", count: 50) + "]]></root>", "<root value='" + String(repeating: "\"", count: 50) + "'/>"] {
            #expect(PowerPointXML.normalize(Data(source.utf8), maximumOutputBytes: 128) == nil)
        }
    }

    @Test func tableLiteralBreakMarkersRemainVisible() async throws {
        for (name, source) in [("table.csv", "Value\nfirst<br>second"), ("table.html", "<table><tr><td>Value</td></tr><tr><td>first&lt;br&gt;second</td></tr></table>")] {
            let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: name)
            #expect(try DocumentRenderer.render(result, to: .plaintext).contains("first<br>second"))
            #expect(try DocumentRenderer.render(result, to: .html).contains("first&lt;br&gt;second"))
            #expect(try DocumentRenderer.render(result, to: .csv).contains("first<br>second"))
        }
    }

    @Test func unorderedRunsKeepTheirBlankBoundary() throws {
        let result = ConverterResult(sections: [.init(markdown: "- First\n- Second\n\n- Separate\n  - Child")])
        #expect(try DocumentRenderer.render(result, to: .plaintext) == "- First\n- Second\n\n- Separate\n  - Child")
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.components(separatedBy: "<ul>").count - 1 == 3)
    }

    @Test func misplacedSlideIDsAndNotesTreesAreRejected() async throws {
        typealias B = PowerPointConverterTests
        let notes = "<p:notes \(B.namespaces)><p:extLst><p:cSld><p:spTree>" + B.shape(placeholder: #"<p:ph type="body"/>"#, paragraphs: ["<a:p><a:r><a:t>Wrong</a:t></a:r></a:p>"]) + "</p:spTree></p:cSld></p:extLst></p:notes>"
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Slide"), relationships: [("notes", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide", "../notesSlides/n.xml")])], extraParts: [("ppt/notesSlides/n.xml", Array(notes.utf8))])
        await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: data, filename: "bad-notes.pptx") }
        let ordinary = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Slide"))])
        let archive = try #require(Archive(data: ordinary, accessMode: .read))
        var entries: [(name: String, data: [UInt8])] = []
        for entry in archive {
            var bytes = Data(); _ = try archive.extract(entry) { bytes.append($0) }
            if entry.path == "ppt/presentation.xml" {
                let text = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "<p:sldIdLst>", with: "<p:extLst><p:sldIdLst>").replacingOccurrences(of: "</p:sldIdLst>", with: "</p:sldIdLst></p:extLst>")
                bytes = Data(text.utf8)
            }
            entries.append((entry.path, Array(bytes)))
        }
        await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip(entries), filename: "bad-order.pptx") }
    }

    @Test func repeatedMarkersContinueWithinOneMarkdownList() throws {
        let result = ConverterResult(sections: [.init(markdown: "1. First\n1. Second\n1. Third\n10. Gap\n10. Next")])
        #expect(try DocumentRenderer.render(result, to: .plaintext) == "1. First\n2. Second\n3. Third\n10. Gap\n11. Next")
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(!html.contains(#"value="1""#)); #expect(html.contains(#"value="10""#))
        let restarted = ConverterResult(sections: [.init(markdown: "1. First\n1. Second\n\n1. Restart")])
        #expect(try DocumentRenderer.render(restarted, to: .plaintext) == "1. First\n2. Second\n\n1. Restart")
    }

    @Test func missingOrMisplacedShapeTreesAreCorrupt() async throws {
        typealias B = PowerPointConverterTests
        let data = B.deck(slides: [.init(file: "one.xml", shapes: B.titleShape("Good")), .init(file: "two.xml", shapes: "")])
        let archive = try #require(Archive(data: data, accessMode: .read))
        for content in ["", "<p:extLst><p:cSld><p:spTree/></p:cSld></p:extLst>"] {
            var entries: [(name: String,data: [UInt8])] = []
            for entry in archive {
                var bytes = Data(); _ = try archive.extract(entry) { bytes.append($0) }
                entries.append((entry.path, entry.path == "ppt/slides/two.xml" ? Array("<p:sld \(B.namespaces)>\(content)</p:sld>".utf8) : Array(bytes)))
            }
            await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip(entries), filename: "bad-tree.pptx") }
        }
        let valid = try await PicoDocsEngine.convert(data: data, filename: "empty-slide.pptx")
        #expect(valid.sections.count == 1)
    }

    @Test func cellsAndOtherPlaceholdersInheritTheirOwnListStyles() async throws {
        typealias B = PowerPointConverterTests
        let table = #"<p:graphicFrame><a:graphic><a:graphicData uri='http://schemas.openxmlformats.org/drawingml/2006/table'><a:tbl><a:tr><a:tc><a:txBody><a:lstStyle><a:lvl1pPr><a:buAutoNum type="arabicPeriod" startAt="4"/><a:defRPr b="1" i="1"/></a:lvl1pPr></a:lstStyle><a:p><a:r><a:t>Cell</a:t></a:r></a:p></a:txBody></a:tc><a:tc><a:txBody><a:p><a:r><a:t>Plain</a:t></a:r></a:p></a:txBody></a:tc></a:tr></a:tbl></a:graphicData></a:graphic></p:graphicFrame>"#
        let shape = B.shape(placeholder: #"<p:ph type="chart"/>"#, paragraphs: ["<a:p><a:r><a:t>Caption</a:t></a:r></a:p>"])
        let layout = "<p:sldLayout \(B.namespaces)><p:cSld><p:spTree/></p:cSld></p:sldLayout>"
        let master = "<p:sldMaster \(B.namespaces)><p:cSld><p:spTree/></p:cSld><p:txStyles><p:otherStyle><a:lvl1pPr><a:buAutoNum type=\"arabicPeriod\" startAt=\"7\"/></a:lvl1pPr></p:otherStyle></p:txStyles></p:sldMaster>"
        let rels = B.relationshipsXML([("master","http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster","../slideMasters/m.xml")])
        let data = B.deck(slides: [.init(file: "s.xml", shapes: table + shape, relationships: [("layout","http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout","../slideLayouts/l.xml")])], extraParts: [("ppt/slideLayouts/l.xml",Array(layout.utf8)),("ppt/slideLayouts/_rels/l.xml.rels",Array(rels.utf8)),("ppt/slideMasters/m.xml",Array(master.utf8))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "styles.pptx")
        #expect(result.markdown().contains("| 4. ***Cell*** | Plain |"))
        #expect(result.markdown().contains("7. Caption"))
    }

    @Test func changedExplicitStartsRestartWhileOmittedStartsContinue() async throws {
        typealias B = PowerPointConverterTests
        let starts: [Int?] = [1,1,10,nil,10,3,3]
        let paragraphs = starts.enumerated().map { index, start in
            let attribute = start.map { " startAt=\"\($0)\"" } ?? ""
            return "<a:p><a:pPr><a:buAutoNum type=\"arabicPeriod\"\(attribute)/></a:pPr><a:r><a:t>Item \(index)</a:t></a:r></a:p>"
        }
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.shape(placeholder: nil, paragraphs: paragraphs))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "starts.pptx")
        #expect(result.markdown() == "1. Item 0\n2. Item 1\n10. Item 2\n11. Item 3\n12. Item 4\n3. Item 5\n4. Item 6")
    }

    @Test func relationshipPartsRequireTheirOwnRoot() throws {
        for source in ["<root/>", #"<root><Relationships><Relationship Id="x" Target="foo" Type="bar"/></Relationships></root>"#] {
            let data = PagesConverterTests.makeZip([(name: "ppt/slides/_rels/s.xml.rels", data: Array(source.utf8))])
            let package = PowerPointPackage(archive: try #require(Archive(data: data, accessMode: .read)))
            #expect(PowerPointConverter.relationships(package, forPart: "ppt/slides/s.xml").isEmpty)
            #expect(throws: PicoDocsError.fileCorrupted) { try package.check() }
        }
    }

    @Test func exactSlideRootAndPresentationDefaults() async throws {
        typealias B = PowerPointConverterTests
        let shape = B.shape(placeholder: nil, paragraphs: ["<a:p><a:r><a:t>Defaulted</a:t></a:r></a:p>"])
        let data = B.deck(slides: [.init(file: "s.xml", shapes: shape)])
        let archive = try #require(Archive(data: data, accessMode: .read))
        func changed(_ path: String, _ transform: (String) -> String) throws -> Data {
            var entries: [(name: String, data: [UInt8])] = []
            for entry in archive {
                var bytes = Data(); _ = try archive.extract(entry) { bytes.append($0) }
                entries.append((entry.path, entry.path == path ? Array(transform(String(decoding: bytes, as: UTF8.self)).utf8) : Array(bytes)))
            }
            return PagesConverterTests.makeZip(entries)
        }
        let corrupt = try changed("ppt/slides/s.xml") { $0.replacingOccurrences(of: "<p:sld ", with: "<root><p:sld ").replacingOccurrences(of: "</p:sld>", with: "</p:sld></root>") }
        await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: corrupt, filename: "bad.pptx") }
        let defaults = try changed("ppt/presentation.xml") { $0.replacingOccurrences(of: "</p:presentation>", with: #"<p:defaultTextStyle><a:lvl1pPr><a:buAutoNum type="arabicPeriod" startAt="4"/><a:defRPr b="1" i="1"/></a:lvl1pPr></p:defaultTextStyle></p:presentation>"#) }
        let result = try await PicoDocsEngine.convert(data: defaults, filename: "defaults.pptx")
        #expect(result.markdown() == "4. ***Defaulted***")
    }

    @Test func notesStyleSuppliesBulletsAndRunDefaults() throws {
        typealias B = PowerPointConverterTests
        let notes = "<p:notes \(B.namespaces)><p:cSld><p:spTree>" + B.shape(placeholder: #"<p:ph type="body"/>"#, paragraphs: ["<a:p><a:r><a:t>Note</a:t></a:r></a:p>"]) + "</p:spTree></p:cSld></p:notes>"
        let master = "<p:notesMaster \(B.namespaces)><p:cSld><p:spTree/></p:cSld>" + #"<p:notesStyle><a:lvl1pPr><a:buAutoNum type="arabicPeriod" startAt="3"/><a:defRPr b="1" i="1"/></a:lvl1pPr></p:notesStyle></p:notesMaster>"#
        let rels = B.relationshipsXML([("master", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesMaster", "../notesMasters/m.xml"), ("slide", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide", "../slides/s.xml")])
        let entries = [(name: "ppt/notesSlides/n.xml", data: Array(notes.utf8)), (name: "ppt/notesSlides/_rels/n.xml.rels", data: Array(rels.utf8)), (name: "ppt/notesMasters/m.xml", data: Array(master.utf8))]
        let package = PowerPointPackage(archive: try #require(Archive(data: PagesConverterTests.makeZip(entries), accessMode: .read)))
        var cache = PowerPointConverter.PartCache(archive: package)
        let relations = ["notes": PowerPointConverter.Relationship(type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide", target: "../notesSlides/n.xml", external: false)]
        #expect(PowerPointConverter.notes(forSlide: "ppt/slides/s.xml", relationships: relations, archive: package, parts: &cache) == "3. ***Note***")
    }

    @Test func optionalListIndentDoesNotCreateChildren() throws {
        for source in ["- one\n - two", "10. one\n 11. two", "  - one\n- two"] {
            let result = ConverterResult(sections: [.init(markdown: source)])
            let html = try DocumentRenderer.render(result, to: .html)
            #expect(html.components(separatedBy: "<li").count - 1 == 2)
            #expect(html.components(separatedBy: source.hasPrefix("10.") ? "<ol" : "<ul").count - 1 == 1)
        }
        let nested = ConverterResult(sections: [.init(markdown: "10. Parent\n    - child\n 11. Sibling")])
        #expect(try DocumentRenderer.render(nested, to: .plaintext) == "10. Parent\n    - child\n11. Sibling")
    }

    @Test func referencedDocumentsMustHaveExpectedRootTypes() async throws {
        typealias B = PowerPointConverterTests
        for type in ["notesSlide", "slideLayout"] {
            for wrongXML in ["<root/>", "<root \(B.namespaces)><p:notes/></root>"] {
                let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Title"), relationships: [("part", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/" + type, "wrong.xml")])], extraParts: [("ppt/slides/wrong.xml", Array(wrongXML.utf8))])
                await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: data, filename: "wrong-root.pptx") }
            }
        }
    }

    @Test func iWorkAndWordTablesPreserveLiteralSourceSyntax() async throws {
        typealias B = PagesConverterTests
        func field(_ n: Int, _ value: UInt64) -> [UInt8] { B.tag(field: n, wire: 0) + B.varint(value) }
        func bytes(_ n: Int, _ value: [UInt8]) -> [UInt8] { B.tag(field: n, wire: 2) + B.varint(UInt64(value.count)) + value }
        let literal = #"<br> *stars* `code` [label](target) \path |"#
        let cell: [UInt8] = [5, 3] + Array(repeating: 0, count: 10) + [1,0,0,0]
        let tile = bytes(5, bytes(6, cell) + bytes(7, [0,0]))
        let strings = field(1, 1) + bytes(3, field(1, 1) + bytes(3, Array(literal.utf8)))
        let objects: [(UInt64, UInt64, [UInt8], [UInt64])] = [(20,6001,[],[21,22]), (21,6002,tile,[]), (22,6005,strings,[])]
        var stream: [UInt8] = []
        for (id,type,payload,references) in objects {
            var info = field(1,type) + field(3,UInt64(payload.count))
            for reference in references { info += field(5,reference) }
            let header = field(1,id) + bytes(2,info)
            stream += B.varint(UInt64(header.count)) + header + payload
        }
        let table = try #require(IWATable.markdownTables(from: [stream]).first)
        let iwork = ConverterResult(sections: [.init(kind: .table, markdown: table)])
        let document = #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:tbl><w:tr><w:tc><w:p><w:r><w:rPr><w:b/></w:rPr><w:t>&lt;br&gt; *stars* `code` [label](target) \path |</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>"#
        let word = try await PicoDocsEngine.convert(data: B.makeZip([(name: "word/document.xml", data: Array(document.utf8))]), filename: "literal.docx")
        for result in [iwork,word] {
            for format in [ExportFileType.plaintext,.csv] { #expect(try DocumentRenderer.render(result, to: format).contains(literal)) }
            let html = try DocumentRenderer.render(result, to: .html)
            #expect(html.contains("&lt;br&gt; *stars* `code` [label](target) \\path |"))
            #expect(!html.contains("<br>"))
        }
    }

    @Test func notesMasterUsesConversionWideDocumentCache() throws {
        typealias B = PowerPointConverterTests
        let notes = "<p:notes \(B.namespaces)><p:cSld><p:spTree>" + B.shape(placeholder: #"<p:ph type="body"/>"#, paragraphs: ["<a:p><a:r><a:t>Note</a:t></a:r></a:p>"]) + "</p:spTree></p:cSld></p:notes>"
        let master = "<p:notesMaster \(B.namespaces)><p:cSld><p:spTree/></p:cSld></p:notesMaster>"
        let rels = B.relationshipsXML([("master", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesMaster", "../notesMasters/m.xml"), ("slide", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide", "../slides/s.xml")])
        let entries = [(name: "ppt/notesSlides/n.xml", data: Array(notes.utf8)), (name: "ppt/notesSlides/_rels/n.xml.rels", data: Array(rels.utf8)), (name: "ppt/notesMasters/m.xml", data: Array(master.utf8))]
        let package = PowerPointPackage(archive: try #require(Archive(data: PagesConverterTests.makeZip(entries), accessMode: .read)), totalLimit: entries.reduce(0) { $0 + $1.data.count } + 4 * notes.utf8.count)
        var cache = PowerPointConverter.PartCache(archive: package)
        let relations = ["notes": PowerPointConverter.Relationship(type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide", target: "../notesSlides/n.xml", external: false)]
        for _ in 0..<5 { #expect(PowerPointConverter.notes(forSlide: "ppt/slides/s.xml", relationships: relations, archive: package, parts: &cache) == "Note") }
        try package.check()
    }

    @Test func malformedXMLNeverNormalizesIntoValidContent() async throws {
        for source in ["<p:sld><p:cSld/></p:sld>", "<root><child></root>", "<root xmlns:p=\"x\"><p:item></root>"] {
            #expect(PowerPointXML.normalize(Data(source.utf8)) == nil)
        }
        typealias B = PowerPointConverterTests
        let malformed = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Title") + "<unknown:shape/>")])
        await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: malformed, filename: "bad.pptx") }
    }

    @Test func pictureAltAndSpreadsheetCellsKeepLiteralInlineSyntax() async throws {
        typealias B = PowerPointConverterTests
        let picture = #"<p:pic><p:nvPicPr><p:cNvPr descr="*draft* `code` [copy]"/></p:nvPicPr><p:blipFill><a:blip r:embed="image"/></p:blipFill></p:pic>"#
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Title") + picture, relationships: [("image", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", "../media/p.png")])], extraParts: [("ppt/media/p.png", [1,2,3])])
        let result = try await PicoDocsEngine.convert(data: data, filename: "image.pptx")
        #expect(try DocumentRenderer.render(result, to: .html).contains(#"alt="*draft* `code` [copy]""#))
        for format in [ExportFileType.plaintext, .csv] { #expect(try DocumentRenderer.render(result, to: format).contains("*draft* `code` [copy]")) }
        let worksheet = #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>*stars* `code` [label](target) \path | &lt;br&gt;</t></is></c></row></sheetData></worksheet>"#
        let workbook = try await PicoDocsEngine.convert(data: ConverterTests.xlsx(sheetXML: worksheet), filename: "literal.xlsx")
        for format in [ExportFileType.plaintext, .csv] {
            #expect(try DocumentRenderer.render(workbook, to: format).contains(#"*stars* `code` [label](target) \path | <br>"#))
        }
        #expect(try DocumentRenderer.render(workbook, to: .html).contains(#"*stars* `code` [label](target) \path | &lt;br&gt;"#))
    }

    @Test func sharedRelationshipCacheUsesDistinctPartBudget() throws {
        typealias B = PowerPointConverterTests
        let xml = B.relationshipsXML([("master", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster", "../slideMasters/m.xml")])
        let data = PagesConverterTests.makeZip([(name: "ppt/slideLayouts/_rels/shared.xml.rels", data: Array(xml.utf8))])
        let package = PowerPointPackage(archive: try #require(Archive(data: data, accessMode: .read)), totalLimit: xml.utf8.count)
        for _ in 0..<5 { #expect(PowerPointConverter.relationships(package, forPart: "ppt/slideLayouts/shared.xml")["master"]?.target == "../slideMasters/m.xml") }
        try package.check()
    }

    @Test func missingPictureRelationshipsAndNotesShapeLinks() async throws {
        typealias B = PowerPointConverterTests
        let picture = #"<p:pic><p:nvPicPr><p:cNvPr descr="Missing"/></p:nvPicPr><p:blipFill><a:blip r:embed="missing"/></p:blipFill></p:pic>"#
        let missing = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Title") + picture)])
        await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: missing, filename: "missing.pptx") }
        let shape = B.shape(placeholder: #"<p:ph type="body"/>"#, paragraphs: [#"<a:p><a:r><a:t>Linked note</a:t></a:r></a:p>"#])
            .replacingOccurrences(of: #"<p:cNvPr id="2" name="Shape"/>"#, with: #"<p:cNvPr id="2" name="Shape"><a:hlinkClick r:id="link"/></p:cNvPr>"#)
        let notes = "<p:notes \(B.namespaces)><p:cSld><p:spTree>" + shape + "</p:spTree></p:cSld></p:notes>"
        let rels = B.relationshipsXML([("link", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", "https://example.com/notes\" TargetMode=\"External")])
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Title"), relationships: [("notes", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide", "../notesSlides/n.xml")])], extraParts: [("ppt/notesSlides/n.xml", Array(notes.utf8)), ("ppt/notesSlides/_rels/n.xml.rels", Array(rels.utf8))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "notes.pptx")
        #expect(result.markdown().contains("[Linked note](https://example.com/notes)"))
    }

    @Test func tableLiteralPunctuationUnicodeWhitespaceAndBackticks() async throws {
        typealias B = PowerPointConverterTests
        let table = #"<p:graphicFrame><a:graphic><a:graphicData uri='http://schemas.openxmlformats.org/drawingml/2006/table'><a:tbl><a:tr><a:tc><a:txBody><a:p><a:r><a:t>*stars* `code` \path | &lt;br&gt;</a:t></a:r></a:p></a:txBody></a:tc></a:tr></a:tbl></a:graphicData></a:graphic></p:graphicFrame>"#
        let shape = B.shape(placeholder: nil, paragraphs: ["<a:p><a:r><a:t>Hello</a:t></a:r><a:r><a:rPr b=\"1\"/><a:t>\u{00A0}world\u{2003}\u{00A0}</a:t></a:r><a:r><a:t>end</a:t></a:r></a:p>"])
        let result = try await PicoDocsEngine.convert(data: B.deck(slides: [.init(file: "s.xml", shapes: shape + table)]), filename: "literal.pptx")
        #expect(result.markdown().contains("Hello\u{00A0}**world**\u{2003}\u{00A0}end"))
        for format in [ExportFileType.html, .plaintext, .csv] {
            let rendered = try DocumentRenderer.render(result, to: format)
            #expect(rendered.contains("*stars* `code` \\path | " + (format == .html ? "&lt;br&gt;" : "<br>")))
            #expect(!rendered.contains("<em>stars</em>")); #expect(!rendered.contains("<code>code</code>"))
        }
        let mixed = ConverterResult(sections: [.init(markdown: #"\`literal\` and `\*code` and \`[^n]\`"# + "\n\n[^n]: Note")])
        let html = try DocumentRenderer.render(mixed, to: .html)
        #expect(html.contains("`literal`")); #expect(html.contains(#"<code>\*code</code>"#))
        #expect(html.contains("footnote-ref")); #expect(html.contains("Note"))
    }

    @Test func defaultParagraphStyleAndExplicitLinkOverride() async throws {
        typealias B = PowerPointConverterTests
        let shape = B.shape(placeholder: nil, paragraphs: [
            #"<a:p><a:r><a:rPr><a:hlinkClick r:id="jump"/></a:rPr><a:t>Internal override</a:t></a:r></a:p>"#])
            .replacingOccurrences(of: "<a:bodyPr/>", with: #"<a:bodyPr/><a:lstStyle><a:defPPr><a:buChar char="•"/><a:defRPr b="1" i="1"/></a:defPPr></a:lstStyle>"#)
            .replacingOccurrences(of: #"<p:cNvPr id="2" name="Shape"/>"#, with: #"<p:cNvPr id="2" name="Shape"><a:hlinkClick r:id="outer"/></p:cNvPr>"#)
        let title = B.shape(placeholder: #"<p:ph type="title"/>"#, paragraphs: [#"<a:p><a:r><a:t>Plan</a:t></a:r><a:br/><a:r><a:t>Draft</a:t></a:r></a:p>"#])
        let data = B.deck(slides: [.init(file: "s.xml", shapes: title + shape, relationships: [
            ("outer", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", "https://example.com\" TargetMode=\"External"),
            ("jump", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide", "s.xml")])])
        let result = try await PicoDocsEngine.convert(data: data, filename: "defaults.pptx")
        #expect(result.sections.first?.title == "Plan Draft")
        #expect(result.markdown().contains("- ***Internal override***"))
        #expect(!result.markdown().contains("https://example.com"))
    }

    @Test func invalidRelationshipsNotesMastersAndCRC() async throws {
        typealias B = PowerPointConverterTests
        let malformed = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Title"))], extraParts: [("ppt/slides/_rels/s.xml.rels", Array("<bad".utf8))])
        await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: malformed, filename: "bad.pptx") }
        let notes = "<p:notes \(B.namespaces)><p:cSld><p:spTree>" + B.shape(placeholder: #"<p:ph type="body"/>"#, paragraphs: ["<a:p><a:r><a:t>Note</a:t></a:r></a:p>"]) + "</p:spTree></p:cSld></p:notes>"
        let notesRels = B.relationshipsXML([("master", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesMaster", "../notesMasters/missing.xml")])
        let missing = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Title"), relationships: [("notes", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide", "../notesSlides/n.xml")])], extraParts: [("ppt/notesSlides/n.xml", Array(notes.utf8)), ("ppt/notesSlides/_rels/n.xml.rels", Array(notesRels.utf8))])
        await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: missing, filename: "missing.pptx") }
        var corrupt = PagesConverterTests.makeZip([(name: "part", data: Array("UNIQUEPAYLOAD".utf8))])
        let range = try #require(corrupt.range(of: Data("UNIQUEPAYLOAD".utf8)))
        corrupt[range.lowerBound] = 0
        let package = PowerPointPackage(archive: try #require(Archive(data: corrupt, accessMode: .read)))
        #expect(package.read("part") == nil)
        #expect(throws: PicoDocsError.fileCorrupted) { try package.check() }
    }

    @Test func literalEscapeTokensAndTableBreakText() async throws {
        let literal = "\u{E006}0\u{E007}"
        let result = ConverterResult(sections: [.init(markdown: literal + " \\* `" + literal + "`")])
        for format in [ExportFileType.html, .plaintext] {
            let text = try DocumentRenderer.render(result, to: format)
            #expect(text.components(separatedBy: literal).count == 3)
        }
        let xml = #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:tbl><w:tr><w:tc><w:p><w:r><w:t>\&lt;br&gt;</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>"#
        let word = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(xml.utf8))]), filename: "literal.docx")
        #expect(try DocumentRenderer.render(word, to: .plaintext).contains(#"\<br>"#))
        #expect(try DocumentRenderer.render(word, to: .html).contains(#"\&lt;br&gt;"#))
        #expect(try DocumentRenderer.render(word, to: .csv).contains(#"\<br>"#))
    }

    @Test func declaredLayoutsAndInheritedRunDefaults() async throws {
        typealias B = PowerPointConverterTests
        let relation = ("layout", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout", "../slideLayouts/layout.xml")
        let shape = B.shape(placeholder: #"<p:ph type="body" idx="1"/>"#, paragraphs: [
            #"<a:p><a:r><a:t>Inherited</a:t></a:r></a:p>"#,
            #"<a:p><a:r><a:rPr b="0"/><a:t>Italic only</a:t></a:r></a:p>"#])
        let missing = B.deck(slides: [.init(file: "s.xml", shapes: shape, relationships: [relation])])
        await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: missing, filename: "bad.pptx") }
        let layoutShape = B.shape(placeholder: #"<p:ph type="body" idx="1"/>"#, paragraphs: [])
            .replacingOccurrences(of: "<a:bodyPr/>", with: #"<a:bodyPr/><a:lstStyle><a:lvl1pPr><a:buNone/><a:defRPr b="1"/></a:lvl1pPr></a:lstStyle>"#)
        let layout = "<p:sldLayout \(B.namespaces)><p:cSld><p:spTree>\(layoutShape)</p:spTree></p:cSld></p:sldLayout>"
        let master = "<p:sldMaster \(B.namespaces)><p:cSld><p:spTree/></p:cSld><p:txStyles><p:bodyStyle><a:lvl1pPr><a:defRPr i=\"1\"/></a:lvl1pPr></p:bodyStyle></p:txStyles></p:sldMaster>"
        let rels = B.relationshipsXML([("master", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster", "../slideMasters/master.xml")])
        let data = B.deck(slides: [.init(file: "s.xml", shapes: shape, relationships: [relation])], extraParts: [
            ("ppt/slideLayouts/layout.xml", Array(layout.utf8)), ("ppt/slideLayouts/_rels/layout.xml.rels", Array(rels.utf8)), ("ppt/slideMasters/master.xml", Array(master.utf8))])
        let markdown = try await PicoDocsEngine.convert(data: data, filename: "styled.pptx").markdown()
        #expect(markdown.contains("***Inherited***"))
        #expect(markdown.contains("*Italic only*"))
        #expect(!markdown.contains("**Italic only**"))
    }

    @Test func localizedNumbersHardBreaksAndPlainTitles() async throws {
        typealias B = PowerPointConverterTests
        let title = B.shape(placeholder: #"<p:ph type="title"/>"#, paragraphs: [#"<a:p><a:r><a:rPr b="1"/><a:t>Plan [Draft]</a:t></a:r></a:p>"#])
        let paragraphs = [#"<a:p><a:pPr><a:buChar char="•"/></a:pPr><a:r><a:t>First</a:t></a:r><a:br/><a:r><a:t>Second</a:t></a:r></a:p>"#]
            + ["circleNumWdBlackPlain", "thaiNumPeriod", "hindiAlphaPeriod", "ea1ChsPeriod"].map {
                "<a:p><a:pPr><a:buAutoNum type=\"\($0)\"/></a:pPr><a:r><a:t>Item</a:t></a:r></a:p>"
            }
        let result = try await PicoDocsEngine.convert(data: B.deck(slides: [.init(file: "s.xml", shapes: title + B.shape(placeholder: nil, paragraphs: paragraphs))]), filename: "local.pptx")
        #expect(result.sections.first?.title == "Plan [Draft]")
        #expect(result.markdown().contains("First  \n  Second"))
        #expect(try DocumentRenderer.render(result, to: .html).contains("First<br>Second"))
        #expect(try DocumentRenderer.render(result, to: .plaintext).contains("First\n  Second"))
        #expect(result.markdown().contains("❶ Item"))
        #expect(result.markdown().contains("๑. Item"))
        #expect(result.markdown().contains("अ. Item"))
        #expect(result.markdown().contains("ea1ChsPeriod"))
    }

    @Test func manifestIsCachedAndEscapedImageReferencesEmbed() throws {
        let manifest = #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="png" ContentType="image/png"/></Types>"#
        let data = PagesConverterTests.makeZip([(name: "[Content_Types].xml", data: Array(manifest.utf8))])
        let package = PowerPointPackage(archive: try #require(Archive(data: data, accessMode: .read)), totalLimit: manifest.utf8.count)
        for name in ["a.png", "b.png", "c.png"] { #expect(PowerPointConverter.contentType(name, archive: package) == "image/png") }
        try package.check()
        let result = ConverterResult(sections: [.init(markdown: "![Image](chart&notes.png)"), .init(kind: .image, markdown: "", sourcePath: "chart&notes.png", metadata: ["base64": "AQID", "mimeType": "image/png"])])
        #expect(try DocumentRenderer.render(result, to: .html).contains("data:image/png;base64,AQID"))
    }

    @Test func manifestMIMEAndAssembledMarkers() async throws {
        typealias B = PowerPointConverterTests
        let paragraphs = [["-", " item"], ["1", ". item"], ["  ", "# heading"], ["-", "--"]].map { runs in
            "<a:p>" + runs.map { "<a:r><a:t>\($0)</a:t></a:r>" }.joined() + "</a:p>"
        }
        let picture = #"<p:pic><p:nvPicPr><p:cNvPr descr="Image"/></p:nvPicPr><p:blipFill><a:blip r:embed="image"/></p:blipFill></p:pic>"#
        let manifest = #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="png" ContentType="image/png"/></Types>"#
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.shape(placeholder: nil, paragraphs: paragraphs) + picture,
            relationships: [("image", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", "../media/p.png")])],
            extraParts: [("ppt/media/p.png", [1,2,3]), ("[Content_Types].xml", Array(manifest.utf8))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "deck.pptx")
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("data:image/png;base64,"))
        #expect(!html.contains("onerror="))
        for tag in ["<ul>", "<ol>", "<h1>", "<hr>"] { #expect(!html.contains(tag)) }
        #expect(html.contains("1. item"))
    }

    @Test func missingNotesAndAutomaticSchemes() async throws {
        typealias B = PowerPointConverterTests
        let broken = B.deck(slides: [.init(file: "s.xml", shapes: "", relationships: [
            ("notes", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide", "../notesSlides/missing.xml")])])
        await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: broken, filename: "broken.pptx") }
        let paragraphs = [("alphaLcParenR", 1), ("alphaUcPeriod", 2), ("romanUcPeriod", 4)].map { scheme, start in
            "<a:p><a:pPr><a:buAutoNum type=\"\(scheme)\" startAt=\"\(start)\"/></a:pPr><a:r><a:t>Item</a:t></a:r></a:p>"
        }
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.shape(placeholder: nil, paragraphs: paragraphs))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "schemes.pptx")
        for format in [ExportFileType.markdown, .plaintext, .html] {
            let text = try DocumentRenderer.render(result, to: format)
            for label in ["a) Item", "B. Item", "IV. Item"] { #expect(text.contains(label)) }
        }
        #expect(PowerPointConverter.automaticNumber(27, scheme: "alphaLcParenBoth") == "(aa)")
    }

    @Test func literalWordTableBreakMarker() async throws {
        let xml = #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:tbl><w:tr><w:tc><w:p><w:r><w:t>&lt;br&gt;</w:t><w:br/><w:t>Next</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>"#
        let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(xml.utf8))]), filename: "table.docx")
        for format in [ExportFileType.html, .plaintext, .csv] {
            let text = try DocumentRenderer.render(result, to: format)
            #expect(text.contains(format == .html ? "&lt;br&gt;" : "<br>"))
            #expect(text.contains("Next"))
        }
    }

    @Test func literalEscapesCodeFootnotesAndScaling() throws {
        for format in [ExportFileType.html, .plaintext] {
            let code = try DocumentRenderer.render(ConverterResult(sections: [DocumentSection(markdown: #"`\*`"#)]), to: format)
            #expect(code.contains(#"\*"#))
            let note = try DocumentRenderer.render(ConverterResult(sections: [DocumentSection(markdown: "\\[^n]\n\n[^n]: Hidden definition")]), to: format)
            #expect(note.contains("[^n]"))
            #expect(!note.contains("Hidden definition"))
            let escaped = String(repeating: #"\*"#, count: 10_000)
            let rendered = try DocumentRenderer.render(ConverterResult(sections: [DocumentSection(markdown: escaped)]), to: format)
            #expect(rendered.contains(String(repeating: "*", count: 10_000)))
            let table = try DocumentRenderer.render(ConverterResult(sections: [DocumentSection(markdown: #"| \<br> | first<br>second |"# + "\n| --- | --- |")]), to: format)
            #expect(table.contains(format == .html ? "&lt;br&gt;" : "<br>"))
            #expect(table.contains(format == .html ? "first<br>second" : "first\nsecond"))
        }
    }

    @Test func strictAndUnknownNamespaceNormalization() throws {
        let strict = #"<s:sld xmlns:s="http://purl.oclc.org/ooxml/presentationml/main" xmlns:t="http://purl.oclc.org/ooxml/drawingml/main" xmlns:x="urn:one" xmlns:y="urn:two" x:attr="one" y:attr="two"><t:p/></s:sld>"#
        let normalized = try #require(PowerPointXML.normalize(Data(strict.utf8)))
        #expect(normalized.contains("<p:sld"))
        #expect(normalized.contains("<a:p>"))
        #expect(normalized.contains("extension0:attr="))
        #expect(normalized.contains("extension1:attr="))
    }

    @Test func literalRulesShapeLinksAndPictures() async throws {
        typealias B = PowerPointConverterTests
        let rule = B.shape(placeholder: nil, paragraphs: ["<a:p><a:r><a:t>---</a:t></a:r></a:p>"])
        let linked = B.shape(placeholder: nil, paragraphs: ["<a:p><a:r><a:t>Shape link</a:t></a:r></a:p>"])
            .replacingOccurrences(of: #"<p:cNvPr id="2" name="Shape"/>"#, with: #"<p:cNvPr id="2" name="Shape"><a:hlinkClick r:id="link"/></p:cNvPr>"#)
        let picture = #"<p:pic><p:nvPicPr><p:cNvPr descr="Trailing\"/></p:nvPicPr><p:blipFill><a:blip r:embed="image"/></p:blipFill></p:pic>"#
        let relationships = [("link", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", "https://example.com\" TargetMode=\"External"), ("image", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", "../media/p.png")]
        let data = B.deck(slides: [.init(file: "s.xml", shapes: rule + linked + picture, relationships: relationships)], extraParts: [("ppt/media/p.png", [1, 2, 3])])
        let result = try await PicoDocsEngine.convert(data: data, filename: "deck.pptx")
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(!html.contains("<hr>"))
        #expect(html.contains("---"))
        #expect(html.contains(#"href="https://example.com""#))
        #expect(html.contains("<img"))
        let missing = B.deck(slides: [.init(file: "s.xml", shapes: picture, relationships: relationships)])
        await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: missing, filename: "bad.pptx") }
    }

    @Test func nestedStartsSurviveRenderedExports() throws {
        let result = ConverterResult(sections: [DocumentSection(markdown: "5. Parent\n   - Child\n6. Next")])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains(#"<ol start="5">"#))
        #expect(html.contains("Parent\n<ul>"))
        #expect(try DocumentRenderer.render(result, to: .plaintext) == "5. Parent\n   - Child\n6. Next")
    }
}
