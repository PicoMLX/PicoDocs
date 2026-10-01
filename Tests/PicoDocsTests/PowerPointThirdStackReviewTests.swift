import Foundation
import Testing
import ZIPFoundation
import SwiftSoup
@testable import PicoDocs

struct PowerPointThirdStackReviewTests {
    @Test func separatedWhitespaceExpansionIsPreflighted() throws {
        let input = String(repeating: "\u{E008}32\u{E009}a", count: 100)
        let html = try DocumentRenderer.boundedHTMLWhitespaceReferences(input)
        let bytes = html.utf8.count
        #expect(html.components(separatedBy: "white-space:pre-wrap").count - 1 == 100)
        #expect(try DocumentRenderer.boundedHTMLWhitespaceReferences(input, maximumBytes: bytes) == html)
        #expect(throws: PicoDocsError.fileCorrupted) { try DocumentRenderer.boundedHTMLWhitespaceReferences(input, maximumBytes: bytes - 1) }
        let result = ConverterResult(sections: [DocumentSection(kind: .body, markdown: String(repeating: "&#32;a", count: 1_700_000), metadata: ["powerPointWhitespace": "1"])])
        #expect(throws: PicoDocsError.fileCorrupted) { () throws -> Void in _ = try DocumentRenderer.render(result, to: .html) }
    }

    typealias B = PowerPointConverterTests
    static let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"

    static func replacing(_ data: Data, part: String, transform: (String) -> String) throws -> Data {
        let archive = try Archive(data: data, accessMode: .read)
        var parts: [(name: String, data: [UInt8])] = []
        for entry in archive where entry.type == .file {
            var bytes = Data()
            _ = try archive.extract(entry) { bytes.append($0) }
            parts.append((entry.path, entry.path == part ? Array(transform(String(decoding: bytes, as: UTF8.self)).utf8) : Array(bytes)))
        }
        return PagesConverterTests.makeZip(parts)
    }

    static func picture(_ id: String, external: Bool = false, hidden: Bool = false) -> String {
        "<p:pic><p:nvPicPr><p:cNvPr id='4' name='Notes'\(hidden ? " hidden='1'" : "")/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:\(external ? "link" : "embed")='\(id)'/></p:blipFill><p:spPr/></p:pic>"
    }

    @Test func repeatedEmbeddedPayloadCannotExceedHTMLAllowance() throws {
        let payload = String(repeating: "A", count: 1024 * 1024)
        let markdown = Array(repeating: "![Image](image.png)", count: 65).joined(separator: "\n\n")
        let result = ConverterResult(sections: [DocumentSection(markdown: markdown), DocumentSection(kind: .image, markdown: "![image.png](image.png)", sourcePath: "image.png", metadata: ["base64": payload, "mimeType": "image/png"])])
        #expect(throws: PicoDocsError.fileCorrupted) { _ = try DocumentRenderer.render(result, to: .html) }
    }

    @Test func adjacentPreservedWhitespaceUsesOneSpan() throws {
        let markers = String(repeating: "&#32;", count: 512)
        let html = try DocumentRenderer.render(ConverterResult(sections: [DocumentSection(markdown: markers + "End", metadata: ["powerPointWhitespace": "1"])]), to: .html)
        #expect(html.components(separatedBy: "white-space:pre-wrap").count - 1 == 1)
        #expect(html.utf8.count < markers.utf8.count + 512)
        #expect(html.contains("<span style=\"white-space:pre-wrap\">" + markers + "</span>End"))
    }

    @Test func strictCorePropertiesRetainMetadata() async throws {
        let core = "<cp:coreProperties xmlns:cp='http://purl.oclc.org/ooxml/package/metadata/core-properties' xmlns:dc='http://purl.org/dc/elements/1.1/'><dc:title>Strict</dc:title><dc:creator>Author</dc:creator></cp:coreProperties>"
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Slide"))], extraParts: [("docProps/core.xml", Array(core.utf8))])
        let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
        #expect(result.title == "Strict")
        #expect(result.author == "Author")
    }

    @Test func notesUsePresentationDefaultsForTextAndTables() async throws {
        let paragraph = "<a:p><a:r><a:t>Note</a:t></a:r></a:p>"
        let table = "<p:graphicFrame><a:graphic><a:graphicData uri='http://schemas.openxmlformats.org/drawingml/2006/table'><a:tbl><a:tr><a:tc><a:txBody>" + paragraph.replacingOccurrences(of: "Note", with: "Cell") + "</a:txBody></a:tc></a:tr></a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
        let note = "<p:notes \(B.namespaces)><p:cSld><p:spTree>" + B.shape(placeholder: "<p:ph type='body'/>", paragraphs: [paragraph]) + table + "</p:spTree></p:cSld></p:notes>"
        let master = "<p:notesMaster \(B.namespaces)><p:cSld><p:spTree/></p:cSld><p:notesStyle><a:lvl1pPr/></p:notesStyle></p:notesMaster>"
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Slide"), relationships: [("notes", Self.rel + "notesSlide", "../notesSlides/n.xml")])], extraParts: [("ppt/notesSlides/n.xml", Array(note.utf8)), ("ppt/notesSlides/_rels/n.xml.rels", Array(B.relationshipsXML([("master", Self.rel + "notesMaster", "../notesMasters/m.xml")]).utf8)), ("ppt/notesMasters/m.xml", Array(master.utf8))])
        let styled = try Self.replacing(data, part: "ppt/presentation.xml") { $0.replacingOccurrences(of: "</p:presentation>", with: "<p:defaultTextStyle><a:lvl1pPr><a:buAutoNum type='arabicPeriod' startAt='3'/><a:defRPr b='1' i='1'/></a:lvl1pPr></p:defaultTextStyle></p:presentation>") }
        let result = try await PowerPointConverter().convert(styled, info: StreamInfo(detectedFormat: .pptx))
        #expect(result.sections.first?.metadata["notes"]?.contains("3. ***Note***") == true)
        #expect(result.sections.first?.metadata["notes"]?.contains("3. ***Cell***") == true)
    }

    @Test func notesPicturesAndOLEPreviewsShareCarriersAndReserveExternalNames() async throws {
        let pic = Self.picture("image")
        let preview = "<p:graphicFrame><a:graphic><a:graphicData uri='http://schemas.openxmlformats.org/presentationml/2006/ole'><p:oleObj>" + pic + "</p:oleObj></a:graphicData></a:graphic></p:graphicFrame>"
        let note = "<p:notes \(B.namespaces)><p:cSld><p:spTree>" + pic + "<p:grpSp>" + preview + "</p:grpSp>" + Self.picture("external", external: true) + Self.picture("image", hidden: true) + "</p:spTree></p:cSld></p:notes>"
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Slide"), relationships: [("notes", Self.rel + "notesSlide", "../notesSlides/n.xml")])], extraParts: [("ppt/notesSlides/n.xml", Array(note.utf8)), ("ppt/notesSlides/_rels/n.xml.rels", Array(B.relationshipsXML([("image", Self.rel + "image", "../media/note.png"), ("external", Self.rel + "image", "note.png\" TargetMode=\"External")]).utf8)), ("ppt/media/note.png", [1,2,3])])
        let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
        let carrier = try #require(result.sections.first { $0.kind == .image })
        let reference = try #require(carrier.metadata["markdownReference"])
        #expect(reference != "note.png")
        let notes = try #require(result.sections.first?.metadata["notes"])
        #expect(notes.components(separatedBy: "![Notes](\(reference))").count - 1 == 2)
        #expect(notes.contains("![Notes](note.png)"))
        #expect(result.sections.filter { $0.kind == .image }.count == 1)
    }

    @Test func inheritedNonPlaceholderShapesRespectVisibility() async throws {
        let text = B.shape(placeholder: nil, paragraphs: ["<a:p><a:r><a:t>Layout watermark</a:t></a:r></a:p>"])
        let masterText = text.replacingOccurrences(of: "Layout watermark", with: "Master watermark")
        for show in [true, false] {
            let layout = "<p:sldLayout \(B.namespaces) showMasterSp='\(show ? "1" : "0")'><p:cSld><p:spTree>" + text + B.titleShape("Placeholder prompt") + "</p:spTree></p:cSld></p:sldLayout>"
            let master = "<p:sldMaster \(B.namespaces)><p:cSld><p:spTree>" + masterText + "</p:spTree></p:cSld></p:sldMaster>"
            let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Slide"), relationships: [("layout", Self.rel + "slideLayout", "../slideLayouts/l.xml")])], extraParts: [("ppt/slideLayouts/l.xml", Array(layout.utf8)), ("ppt/slideLayouts/_rels/l.xml.rels", Array(B.relationshipsXML([("master", Self.rel + "slideMaster", "../slideMasters/m.xml")]).utf8)), ("ppt/slideMasters/m.xml", Array(master.utf8))])
            let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
            #expect(result.markdown().contains("Layout watermark"))
            #expect(result.markdown().contains("Master watermark") == show)
            #expect(!result.markdown().contains("Placeholder prompt"))
            let hidden = try Self.replacing(data, part: "ppt/slides/s.xml") { $0.replacingOccurrences(of: "<p:sld ", with: "<p:sld showMasterSp='0' ") }
            #expect(try await PowerPointConverter().convert(hidden, info: StreamInfo(detectedFormat: .pptx)).markdown() == "## Slide")
        }
    }

    @Test func repeatedImageProjectionHasExactByteBoundary() throws {
        let html = "<img src=\"i.png\"><img src=\"i.png\">"
        let expected = "<img src=\"data:image/png;base64,AAAA\"><img src=\"data:image/png;base64,AAAA\">"
        #expect(try DocumentRenderer.boundedImageReplacement(html, reference: "i.png", mime: "image/png", base64: "AAAA", maximumBytes: expected.utf8.count) == expected)
        #expect(throws: PicoDocsError.fileCorrupted) { _ = try DocumentRenderer.boundedImageReplacement(html, reference: "i.png", mime: "image/png", base64: "AAAA", maximumBytes: expected.utf8.count - 1) }
    }

    @Test func runAndCellBudgetsIncludePreviouslyRetainedContent() throws {
        let zip = PagesConverterTests.makeZip([("unused", [1])])
        func context(_ limit: Int, retained: Int = 0) throws -> PowerPointConverter.SlideContext {
            let archive = PowerPointPackage(archive: try Archive(data: zip, accessMode: .read))
            var context = PowerPointConverter.SlideContext(archive: archive, partPath: "s.xml", relationships: [:], images: .init())
            context.renderBudget = .init(maximumBytes: limit, archive: archive)
            context.renderedBlockBytes = retained
            return context
        }
        let run = "<a:r><a:t>" + String(repeating: "*", count: 20) + "</a:t></a:r>"
        let paragraph = try #require(SwiftSoup.parse("<a:p>" + run + run + "</a:p>", "", SwiftSoup.Parser.xmlParser()).children().first())
        var exact = try context(80)
        #expect(PowerPointConverter.renderRuns(paragraph, context: &exact).utf8.count == 80)
        try exact.archive.check()
        var short = try context(79)
        #expect(PowerPointConverter.renderRuns(paragraph, context: &short).isEmpty)
        #expect(throws: PicoDocsError.fileCorrupted) { try short.archive.check() }
        let cell = "<a:tc><a:txBody><a:p>" + run + "</a:p></a:txBody></a:tc>"
        let table = try #require(SwiftSoup.parse("<a:tbl><a:tr>" + cell + cell + "</a:tr></a:tbl>", "", SwiftSoup.Parser.xmlParser()).children().first())
        var accepted = try context(128, retained: 16)
        #expect(!PowerPointConverter.renderTable(table, context: &accepted).isEmpty)
        try accepted.archive.check()
        var rejected = try context(96, retained: 16)
        #expect(PowerPointConverter.renderTable(table, context: &rejected).isEmpty)
        #expect(throws: PicoDocsError.fileCorrupted) { try rejected.archive.check() }
    }

    @Test func carrierDebitChangesActiveBudgetAndSharedLookupStaysCached() throws {
        let archive = PowerPointPackage(archive: try Archive(data: PagesConverterTests.makeZip([("unused", [1])]), accessMode: .read))
        var remaining = 100
        let budget = PowerPointConverter.RenderBudget(maximumBytes: remaining, archive: archive, liveMaximum: { remaining })
        remaining -= 40
        #expect(budget.fits(60))
        #expect(!budget.fits(61))
        let xml = try SwiftSoup.parse("<p:sldLayout><p:cSld><p:spTree>" + B.shape(placeholder: "<p:ph type='body'/>", paragraphs: [String(repeating: "<a:unused/>", count: 1000) + "<a:lstStyle><a:lvl1pPr><a:buChar char='•'/></a:lvl1pPr></a:lstStyle>"]) + "</p:spTree></p:cSld></p:sldLayout>", "", SwiftSoup.Parser.xmlParser())
        let local = try #require(SwiftSoup.parse(B.shape(placeholder: "<p:ph type='body'/>", paragraphs: []), "", SwiftSoup.Parser.xmlParser()).children().first())
        let shared = PowerPointConverter.StyleChildCache(); shared.register(xml)
        var context = PowerPointConverter.SlideContext(archive: archive, partPath: "s.xml", relationships: [:], images: .init())
        context.layout = xml; context.styles = .init(shared: shared)
        _ = PowerPointConverter.inheritedBullets(for: local, context: context)
        let count = shared.buildCount
        for _ in 0..<1000 { _ = PowerPointConverter.inheritedBullets(for: local, context: context) }
        #expect(shared.buildCount == count)
        #expect(count > 1)
    }
}
