import Foundation
import Testing
import SwiftSoup
import ZIPFoundation
@testable import PicoDocs

struct PowerPointEleventhStackReviewTests {
    typealias B = PowerPointConverterTests
    typealias R = PowerPointThirdStackReviewTests
    typealias N = PowerPointFifthStackReviewTests

    @Test func CSVConsumesOnlyOwnedWhitespace() throws {
        let owned = ConverterResult(sections: [.init(markdown: "A&#32;B", metadata: ["preservedWhitespace": "1"])])
        #expect(try DocumentRenderer.render(owned, to: .csv) == "A B")
        let literal = ConverterResult(sections: [.init(markdown: "A&#32;B")])
        #expect(try DocumentRenderer.render(literal, to: .csv) == "A&#32;B")
        let escaped = ConverterResult(sections: [.init(markdown: #"A\&#32;B"#, metadata: ["preservedWhitespace": "1"])])
        #expect(try DocumentRenderer.render(escaped, to: .csv) == "A&#32;B")
    }
    @Test func fencedCodeRetainsLiteralWhitespaceSentinels() throws {
        let text = "\u{E008}32\u{E009} \u{E008}\u{E008} \u{E000}\u{E000}"
        let source = ConverterResult(sections: [.init(markdown: "```\n" + text + "\n```")])
        #expect(try DocumentRenderer.render(source, to: .plaintext) == text)
        let html = try DocumentRenderer.render(source, to: .html)
        #expect(html.contains("<pre><code>" + text + "</code></pre>"))
    }
    @Test func graphicPayloadURIsCollapseXMLWhitespace() async throws {
        let table = "<p:graphicFrame><a:graphic><a:graphicData uri=' &#9;http://schemas.openxmlformats.org/drawingml/2006/table &#13;'><a:tbl><a:tr><a:tc><a:txBody><a:p><a:r><a:t>Visible</a:t></a:r></a:p></a:txBody></a:tc></a:tr></a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
        let result = try await PowerPointConverter().convert(B.deck(slides: [.init(file: "s.xml", shapes: table)]), info: StreamInfo(detectedFormat: .pptx))
        #expect(result.markdown().contains("Visible"))
    }
    @Test func literalEqualsUnderlinesNeverBecomeHeadings() async throws {
        let shape = B.shape(placeholder: nil, paragraphs: ["<a:p><a:r><a:t>Heading</a:t></a:r><a:br/><a:r><a:t>===</a:t></a:r></a:p>"])
        let result = try await PowerPointConverter().convert(B.deck(slides: [.init(file: "s.xml", shapes: shape)]), info: StreamInfo(detectedFormat: .pptx))
        let attributed = try AttributedString(markdown: result.markdown())
        #expect(!attributed.runs.contains { $0.presentationIntent?.components.contains { if case .header = $0.kind { return true }; return false } == true })
        #expect(try DocumentRenderer.render(result, to: .plaintext).contains("==="))
    }
    @Test func themeShapeFillsUseThemeRelationships() async throws {
        let shape = "<p:sp><p:nvSpPr><p:cNvPr id='2' name='Shape'/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr/><p:style><a:fillRef idx='1'><a:srgbClr val='FFFFFF'/></a:fillRef></p:style></p:sp>"
        let layout = "<p:sldLayout " + B.namespaces + "><p:cSld><p:spTree/></p:cSld></p:sldLayout>"
        let master = "<p:sldMaster " + B.namespaces + "><p:cSld><p:spTree/></p:cSld></p:sldMaster>"
        let theme = "<a:theme " + B.namespaces + "><a:themeElements><a:fmtScheme name='Theme'><a:fillStyleLst><a:blipFill><a:blip r:embed='fill'/></a:blipFill></a:fillStyleLst></a:fmtScheme></a:themeElements></a:theme>"
        let extra: [(name: String, data: [UInt8])] = [
            ("ppt/slideLayouts/l.xml", Array(layout.utf8)),
            ("ppt/slideLayouts/_rels/l.xml.rels", Array(B.relationshipsXML([("master", N.rel + "slideMaster", "../slideMasters/m.xml")]).utf8)),
            ("ppt/slideMasters/m.xml", Array(master.utf8)),
            ("ppt/slideMasters/_rels/m.xml.rels", Array(B.relationshipsXML([("theme", N.rel + "theme", "../theme/t.xml")]).utf8)),
            ("ppt/theme/t.xml", Array(theme.utf8)),
            ("ppt/theme/_rels/t.xml.rels", Array(B.relationshipsXML([("fill", N.rel + "image", "../media/theme.png")]).utf8)),
            ("ppt/media/theme.png", [1, 2, 3])
        ]
        let result = try await PowerPointConverter().convert(B.deck(slides: [.init(file: "s.xml", shapes: shape, relationships: [("layout", N.rel + "slideLayout", "../slideLayouts/l.xml")])], extraParts: extra), info: StreamInfo(detectedFormat: .pptx))
        #expect(result.markdown().contains("![Shape](theme.png)"))
    }
    @Test func embeddedNamesDoNotAliasExternalRelativeURLs() async throws {
        let embedded = B.Slide(file: "e.xml", shapes: R.picture("image"), relationships: [("image", N.rel + "image", "../media/caf%C3%A9.png")])
        let outside = B.Slide(file: "x.xml", shapes: R.picture("outside", external: true), relationships: [("outside", N.rel + "image", "caf%C3%A9.png\" TargetMode=\"External")])
        let result = try await PowerPointConverter().convert(B.deck(slides: [embedded, outside], extraParts: [("ppt/media/caf%C3%A9.png", [1, 2, 3])]), info: StreamInfo(detectedFormat: .pptx))
        let reference = try #require(result.sections.first { $0.kind == .image }?.metadata["markdownReference"])
        #expect(reference.hasPrefix("picodocs-embedded/"))
        #expect(result.sections[1].markdown.contains("caf%C3%A9.png"))
    }
    @Test func placeholderIndexesDistinguishEquivalentTypeAndDefaultID() throws {
        let title = B.shape(placeholder: "<p:ph type='title'/>", paragraphs: [])
        let body = B.shape(placeholder: "<p:ph type='body'/>", paragraphs: [])
        let xml = "<p:sldLayout " + B.namespaces + "><p:cSld><p:spTree>" + title + body + "</p:spTree></p:cSld></p:sldLayout>"
        let document = try SwiftSoup.parse(xml, "", SwiftSoup.Parser.xmlParser())
        let cache = PowerPointConverter.PlaceholderCache()
        let foundTitle = try #require(cache.match(in: document, type: "ctrTitle", index: "0"))
        let foundBody = try #require(cache.match(in: document, type: "obj", index: "0"))
        #expect(PowerPointConverter.placeholderType(of: foundTitle) == "title")
        #expect(PowerPointConverter.placeholderType(of: foundBody) == "body")
        #expect(cache.match(in: document, type: "body", index: "9") == nil)
    }
    @Test func partQueueDeduplicatesBeforeRetentionAndBoundsMissingPaths() throws {
        var queue = PowerPointConverter.PartQueue(maximumBytes: 8, maximumParts: 2)
        for _ in 0..<65_536 { try queue.schedule("longpath") }
        #expect(queue.popLast() == "longpath")
        #expect(queue.popLast() == nil)
        try queue.schedule("longpath") // visited identity remains deduplicated
        #expect(throws: PicoDocsError.self) { try queue.schedule("x") }
        var count = PowerPointConverter.PartQueue(maximumBytes: 10, maximumParts: 1)
        try count.schedule("a")
        #expect(throws: PicoDocsError.self) { try count.schedule("b") }
    }
    @Test func presentationSniffStopsAtRootWithinBoundedPrefix() throws {
        let root = "<p:presentation xmlns:p='http://purl.oclc.org/ooxml/presentationml/main'>"
        let body = root + "<!--" + String(repeating: "x", count: 1024 * 1024 + 1) + "--></p:presentation>"
        let data = PagesConverterTests.makeZip([("moved.xml", Array(body.utf8))])
        let archive = try Archive(data: data, accessMode: .read)
        let package = PowerPointPackage(archive: archive)
        #expect(ContentTypeDetector.sniffPresentationRoot(package, path: "moved.xml", maximumBytes: root.utf8.count))
        #expect(!ContentTypeDetector.sniffPresentationRoot(package, path: "moved.xml", maximumBytes: root.utf8.count - 1))
        let entity = "<!DOCTYPE presentation [<!ENTITY text 'value'>]>" + root + "</p:presentation>"
        let unsafeArchive = try Archive(data: PagesConverterTests.makeZip([("moved.xml", Array(entity.utf8))]), accessMode: .read)
        #expect(!ContentTypeDetector.sniffPresentationRoot(PowerPointPackage(archive: unsafeArchive), path: "moved.xml"))
    }

}
