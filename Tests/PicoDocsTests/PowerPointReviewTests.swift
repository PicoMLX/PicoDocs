import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

struct PowerPointReviewTests {
    typealias FixtureBuilder = PowerPointConverterTests
    private func paragraph(_ text: String, properties: String = "") -> String {
        "<a:p>\(properties)<a:r><a:t>\(text)</a:t></a:r></a:p>"
    }
    private func convert(_ shapes: String, extra: [(name: String, data: [UInt8])] = [], relationships: [(id: String, type: String, target: String)] = []) async throws -> ConverterResult {
        try await PicoDocsEngine.convert(data: FixtureBuilder.deck(slides: [.init(file: "s.xml", shapes: shapes, relationships: relationships)], extraParts: extra), filename: "review.pptx")
    }

    @Test func invalidSlidesCountersAndDepthAreRejected() async throws {
        let missing = FixtureBuilder.deck(slides: [.init(file: "s.xml", shapes: FixtureBuilder.titleShape("Valid"))], order: ["s.xml", "missing.xml"])
        await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: missing, filename: "bad.pptx") }
        for start in [String(Int.min), String(Int.max), "0", "32768", "bad"] {
            let shape = FixtureBuilder.shape(placeholder: nil, paragraphs: [paragraph("Item", properties: "<a:pPr><a:buAutoNum startAt=\"\(start)\"/></a:pPr>")])
            await #expect(throws: PicoDocsError.fileCorrupted) { try await convert(shape) }
        }
        let deeplyNested = String(repeating: "<p:grpSp>", count: 150) + FixtureBuilder.titleShape("Deep") + String(repeating: "</p:grpSp>", count: 150)
        await #expect(throws: PicoDocsError.fileCorrupted) { try await convert(deeplyNested) }
        await #expect(throws: PicoDocsError.fileCorrupted) { try await convert("<p:sp>") }
    }

    @Test func extractionBudgetsAndCancellation() async throws {
        let data = PagesConverterTests.makeZip([(name: "one", data: [1, 2, 3]), (name: "two", data: [4, 5, 6])])
        let archive = try #require(Archive(data: data, accessMode: .read))
        let entryBound = PowerPointPackage(archive: archive, entryLimit: 2)
        #expect(entryBound.read("one") == nil)
        #expect(throws: PicoDocsError.fileCorrupted) { try entryBound.check() }
        let totalBound = PowerPointPackage(archive: archive, totalLimit: 5)
        #expect(totalBound.read("one") == Data([1, 2, 3]))
        #expect(totalBound.read("two") == nil)
        #expect(throws: PicoDocsError.fileCorrupted) { try totalBound.check() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await convert(FixtureBuilder.titleShape("Canceled"))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func aliasesAndShapeStylesAndRunDefaults() async throws {
        let style = "<a:lstStyle><a:lvl1pPr><a:buAutoNum startAt=\"5\"/></a:lvl1pPr></a:lstStyle>"
        let shape = FixtureBuilder.shape(placeholder: "<p:ph type=\"body\"/>", paragraphs: [style, paragraph("Inherited", properties: "<a:pPr><a:defRPr b=\"true\" i=\"1\"/></a:pPr>")])
        let result = try await convert(shape)
        #expect(result.markdown() == "5. ***Inherited***")
        let namespace = FixtureBuilder.namespaces.replacingOccurrences(of: "xmlns:p=", with: "xmlns:deck=")
        let slide = "<deck:sld \(namespace)><deck:cSld><deck:spTree>\(FixtureBuilder.titleShape("Alias").replacingOccurrences(of: "p:", with: "deck:"))</deck:spTree></deck:cSld></deck:sld>"
        let presentation = "<deck:presentation \(namespace)><deck:sldIdLst><deck:sldId r:id=\"s\"/></deck:sldIdLst></deck:presentation>"
        let rels = FixtureBuilder.relationshipsXML([("s", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide", "slides/s.xml")])
        let file = PagesConverterTests.makeZip([(name: "ppt/presentation.xml", data: Array(presentation.utf8)), (name: "ppt/_rels/presentation.xml.rels", data: Array(rels.utf8)), (name: "ppt/slides/s.xml", data: Array(slide.utf8))])
        #expect(try await PicoDocsEngine.convert(data: file, filename: "alias.pptx").markdown() == "## Alias")
    }

    @Test func tablesLiteralTextAndLinks() async throws {
        let literal = FixtureBuilder.shape(placeholder: nil, paragraphs: [paragraph("1. literal *stars*"), paragraph("- literal"), paragraph("# literal")])
        let result = try await convert(literal)
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(!html.contains("<ol>"))
        #expect(!html.contains("<ul>"))
        #expect(!html.contains("<em>"))
        #expect(try DocumentRenderer.render(result, to: .plaintext) == "1. literal *stars*\n\n- literal\n\n# literal")
        let list = paragraph("first", properties: "<a:pPr><a:buAutoNum startAt=\"5\"/></a:pPr>") + paragraph("second", properties: "<a:pPr><a:buAutoNum startAt=\"5\"/></a:pPr>")
        let table = "<p:graphicFrame><a:tbl><a:tr><a:tc><a:txBody>\(list)</a:txBody></a:tc><a:tc hMerge=\"true\"><a:txBody>\(paragraph("hidden"))</a:txBody></a:tc></a:tr></a:tbl></p:graphicFrame>"
        let cells = try await convert(table)
        #expect(cells.markdown().contains("5. first<br>6. second"))
        #expect(!cells.markdown().contains("hidden"))
        #expect(try DocumentRenderer.render(cells, to: .html).contains("5. first<br>6. second"))
        #expect(try DocumentRenderer.render(cells, to: .csv).contains("5. first\n6. second"))
        for url in ["tel:123", "ftp://example.com/file"] {
            let link = FixtureBuilder.shape(placeholder: nil, paragraphs: ["<a:p><a:r><a:rPr><a:hlinkClick r:id=\"link\"/></a:rPr><a:t>Open</a:t></a:r></a:p>"])
            let linked = try await convert(link, relationships: [("link", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", url + "\" TargetMode=\"External")])
            #expect(linked.markdown() == "[Open](\(url))")
        }
    }

    @Test func notesMasterAndContentTypes() async throws {
        let notes = "<p:notes \(FixtureBuilder.namespaces)><p:cSld><p:spTree>\(FixtureBuilder.shape(placeholder: "<p:ph type=\"body\"/>", paragraphs: [paragraph("Note")]))</p:spTree></p:cSld></p:notes>"
        let masterShape = FixtureBuilder.shape(placeholder: "<p:ph type=\"body\"/>", paragraphs: ["<a:lstStyle><a:lvl1pPr><a:buAutoNum startAt=\"3\"/></a:lvl1pPr></a:lstStyle>"])
        let master = "<p:notesMaster \(FixtureBuilder.namespaces)><p:cSld><p:spTree>\(masterShape)</p:spTree></p:cSld></p:notesMaster>"
        let rels = FixtureBuilder.relationshipsXML([("m", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesMaster", "../notesMasters/m.xml")])
        let picture = "<p:pic><p:nvPicPr><p:cNvPr descr=\"Photo\"/></p:nvPicPr><p:blipFill><a:blip r:embed=\"image\"/></p:blipFill></p:pic>"
        let types = "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Override PartName=\"/ppt/media/photo\" ContentType=\"image/jpeg\"/></Types>"
        let result = try await convert(FixtureBuilder.titleShape("Title") + picture, extra: [
            ("ppt/notesSlides/n.xml", Array(notes.utf8)), ("ppt/notesSlides/_rels/n.xml.rels", Array(rels.utf8)),
            ("ppt/notesMasters/m.xml", Array(master.utf8)), ("ppt/media/photo", [1, 2, 3]), ("[Content_Types].xml", Array(types.utf8))
        ], relationships: [("n", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide", "../notesSlides/n.xml"), ("image", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", "../media/photo")])
        #expect(result.markdown().contains("3. Note"))
        #expect(result.sections.first { $0.kind == .image }?.metadata["mimeType"] == "image/jpeg")
    }
}
