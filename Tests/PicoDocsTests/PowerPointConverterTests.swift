//
//  PowerPointConverterTests.swift
//  PicoDocsTests
//
//  PPTX import. `sample.pptx` is a real deck (authored in LibreOffice Impress
//  and saved through its PowerPoint exporter); synthetic packages cover what
//  that fixture doesn't — reordered slides, links, numbering, groups, pictures,
//  merged cells.
//

import Foundation
import Testing
import UniformTypeIdentifiers
@testable import PicoDocs

@Suite("PowerPoint converter")
struct PowerPointConverterTests {

    // MARK: - Real fixture

    @Test("Converts a real deck: titles, emphasis, nested bullets, tables, notes")
    func realDeck() async throws {
        let result = try await PicoDocsEngine.convert(data: Fixture.data("sample", "pptx"), filename: "sample.pptx")
        let slides = result.sections.filter { $0.kind == .slide }
        #expect(slides.map(\.slideNumber) == [1, 2, 3, 4])
        #expect(slides.map(\.title) == ["Quarterly Review", "Highlights", "Numbers", "Wrap-up"])

        #expect(slides[0].markdown == "## Quarterly Review\n\nFY2026 Q3 results")
        #expect(slides[1].markdown == """
        ## Highlights

        Revenue up **12%** year over year

        - Driven by services

        Details at

        ### Notes

        Mention the two new hires.
        """)
        #expect(slides[1].metadata["notes"] == "Mention the two new hires.")
        #expect(slides[2].markdown == """
        ## Numbers

        | Region | Revenue |
        | --- | --- |
        | EMEA | 4.2 |
        | APAC | 3.1 |
        """)
        #expect(slides[3].markdown == "## Wrap-up\n\nQuestions?")
    }

    @Test("A .pptx is detected, supported, and routed to the PowerPoint converter")
    func routing() async throws {
        #expect(UTType.pptx.isSupported)
        let data = try Fixture.data("sample", "pptx")
        #expect(ContentTypeDetector.classify(data, info: StreamInfo()).detectedFormat == .pptx)
        #expect(PowerPointConverter().accepts(StreamInfo(detectedFormat: .pptx)))
    }

    // MARK: - Synthetic decks

    @Test("Slides follow the presentation's order, not their file names")
    func slideOrder() async throws {
        let deck = Self.deck(slides: [
            .init(file: "slide1.xml", shapes: Self.titleShape("Second")),
            .init(file: "slide2.xml", shapes: Self.titleShape("First")),
        ], order: ["slide2.xml", "slide1.xml"])
        let result = try await PicoDocsEngine.convert(data: deck, filename: "order.pptx")
        #expect(result.sections.map(\.title) == ["First", "Second"])
        #expect(result.sections.map(\.sourcePath) == ["ppt/slides/slide2.xml", "ppt/slides/slide1.xml"])
    }

    @Test("Body placeholders are bullets; numbering honors startAt and restarts per level")
    func lists() async throws {
        let body = Self.shape(placeholder: "<p:ph idx=\"1\"/>", paragraphs: [
            "<a:p><a:r><a:t>Implicit bullet</a:t></a:r></a:p>",
            "<a:p><a:pPr lvl=\"1\"><a:buAutoNum type=\"arabicPeriod\" startAt=\"3\"/></a:pPr><a:r><a:t>Third</a:t></a:r></a:p>",
            "<a:p><a:pPr lvl=\"1\"><a:buAutoNum type=\"arabicPeriod\" startAt=\"3\"/></a:pPr><a:r><a:t>Fourth</a:t></a:r></a:p>",
            "<a:p><a:pPr lvl=\"2\"><a:buChar char=\"•\"/></a:pPr><a:r><a:t>Deeper</a:t></a:r></a:p>",
            "<a:p><a:r><a:t>Back to top</a:t></a:r></a:p>",
            "<a:p><a:pPr lvl=\"1\"><a:buAutoNum type=\"arabicPeriod\"/></a:pPr><a:r><a:t>Restarted</a:t></a:r></a:p>",
            "<a:p><a:pPr><a:buNone/></a:pPr><a:r><a:t>Plain line</a:t></a:r></a:p>",
        ])
        let textBox = Self.shape(placeholder: nil, paragraphs: ["<a:p><a:r><a:t>Text box line</a:t></a:r></a:p>"])
        let deck = Self.deck(slides: [.init(file: "slide1.xml", shapes: Self.titleShape("Lists") + body + textBox)])
        let markdown = try await PicoDocsEngine.convert(data: deck, filename: "lists.pptx").markdown()
        #expect(markdown == """
        ## Lists

        - Implicit bullet
          3. Third
          4. Fourth
             - Deeper
        - Back to top
          1. Restarted

        Plain line

        Text box line
        """)
    }

    @Test("Runs keep emphasis, external links, fields, and line breaks")
    func runs() async throws {
        let paragraph = """
        <a:p><a:r><a:rPr b="1"/><a:t>Bold </a:t></a:r><a:r><a:rPr i="1"/><a:t>italic</a:t></a:r>\
        <a:r><a:t> see </a:t></a:r><a:r><a:rPr><a:hlinkClick r:id="rIdLink"/></a:rPr><a:t>the report</a:t></a:r>\
        <a:r><a:t> or </a:t></a:r><a:r><a:rPr><a:hlinkClick r:id="rIdJump" action="ppaction://hlinksldjump"/></a:rPr><a:t>slide 2</a:t></a:r>\
        <a:br/><a:fld id="{1}" type="datetime1"><a:t>9/25/2026</a:t></a:fld></a:p>
        """
        let shapes = Self.titleShape("Runs") + Self.shape(placeholder: nil, paragraphs: [paragraph])
        let deck = Self.deck(slides: [.init(file: "slide1.xml", shapes: shapes, relationships: [
            ("rIdLink", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", "https://example.com/q3\" TargetMode=\"External"),
            ("rIdJump", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide", "slide2.xml"),
        ])])
        let markdown = try await PicoDocsEngine.convert(data: deck, filename: "runs.pptx").markdown()
        #expect(markdown == "## Runs\n\n**Bold** *italic* see [the report](https://example.com/q3) or slide 2  \n9/25/2026")
    }

    @Test("Tables keep merged cells aligned; groups, alternate content and pictures render")
    func tablesGroupsPictures() async throws {
        let table = """
        <p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="4" name="Table"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>\
        <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table"><a:tbl>\
        <a:tr><a:tc gridSpan="2"><a:txBody><a:p><a:r><a:t>Merged | header</a:t></a:r></a:p></a:txBody></a:tc><a:tc hMerge="1"><a:txBody><a:p/></a:txBody></a:tc></a:tr>\
        <a:tr><a:tc><a:txBody><a:p><a:r><a:t>a</a:t></a:r></a:p><a:p><a:r><a:t>b</a:t></a:r></a:p></a:txBody></a:tc><a:tc><a:txBody><a:p><a:r><a:t>c</a:t></a:r></a:p></a:txBody></a:tc></a:tr>\
        </a:tbl></a:graphicData></a:graphic></p:graphicFrame>
        """
        let group = "<p:grpSp><p:nvGrpSpPr><p:cNvPr id=\"5\" name=\"Group\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"
            + Self.shape(placeholder: nil, paragraphs: ["<a:p><a:r><a:t>Grouped text</a:t></a:r></a:p>"]) + "</p:grpSp>"
        let alternate = "<mc:AlternateContent><mc:Choice Requires=\"p14\">"
            + Self.shape(placeholder: nil, paragraphs: ["<a:p><a:r><a:t>Choice text</a:t></a:r></a:p>"])
            + "</mc:Choice><mc:Fallback>"
            + Self.shape(placeholder: nil, paragraphs: ["<a:p><a:r><a:t>Fallback text</a:t></a:r></a:p>"])
            + "</mc:Fallback></mc:AlternateContent>"
        let picture = """
        <p:pic><p:nvPicPr><p:cNvPr id="6" name="Picture 1" descr="Revenue chart"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr>\
        <p:blipFill><a:blip r:embed="rIdImage"/></p:blipFill><p:spPr/></p:pic>
        """
        let footer = Self.shape(placeholder: "<p:ph type=\"sldNum\" idx=\"12\"/>", paragraphs: ["<a:p><a:fld id=\"{2}\" type=\"slidenum\"><a:t>1</a:t></a:fld></a:p>"])
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let deck = Self.deck(
            slides: [.init(file: "slide1.xml", shapes: Self.titleShape("Mixed") + table + group + alternate + picture + footer, relationships: [
                ("rIdImage", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", "../media/image1.png"),
            ])],
            extraParts: [(name: "ppt/media/image1.png", data: png)]
        )
        let result = try await PicoDocsEngine.convert(data: deck, filename: "mixed.pptx")
        #expect(result.markdown() == """
        ## Mixed

        | Merged \\| header |  |
        | --- | --- |
        | a<br>b | c |

        Grouped text

        Choice text

        ![Revenue chart](image1.png)
        """)
        let image = try #require(result.sections.first { $0.kind == .image })
        #expect(image.sourcePath == "ppt/media/image1.png")
        #expect(image.metadata["mimeType"] == "image/png")
        #expect(image.metadata["base64"] == Data(png).base64EncodedString())
    }

    @Test("Document properties give the title and author; empty slides keep numbering")
    func propertiesAndEmptySlides() async throws {
        let core = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Board Deck</dc:title><dc:creator>Ada</dc:creator></cp:coreProperties>
        """
        let deck = Self.deck(slides: [
            .init(file: "slide1.xml", shapes: ""),
            .init(file: "slide2.xml", shapes: Self.titleShape("Only content")),
        ], extraParts: [(name: "docProps/core.xml", data: Array(core.utf8))])
        let result = try await PicoDocsEngine.convert(data: deck, filename: "deck.pptx")
        #expect(result.title == "Board Deck")
        #expect(result.author == "Ada")
        #expect(result.sections.map(\.slideNumber) == [2])
    }

    @Test("A deck with no text is an empty document")
    func emptyDeck() async throws {
        let deck = Self.deck(slides: [.init(file: "slide1.xml", shapes: "")])
        await #expect(throws: PicoDocsError.self) {
            try await PicoDocsEngine.convert(data: deck, filename: "empty.pptx")
        }
    }

    // MARK: - Builders

    struct Slide {
        var file: String
        var shapes: String
        var relationships: [(id: String, type: String, target: String)] = []
    }

    static let namespaces = """
    xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
    xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" \
    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
    xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
    """

    static func titleShape(_ title: String) -> String {
        shape(placeholder: "<p:ph type=\"title\"/>", paragraphs: ["<a:p><a:r><a:t>\(title)</a:t></a:r></a:p>"])
    }

    static func shape(placeholder: String?, paragraphs: [String]) -> String {
        "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"Shape\"/><p:cNvSpPr/><p:nvPr>\(placeholder ?? "")</p:nvPr></p:nvSpPr>"
            + "<p:spPr/><p:txBody><a:bodyPr/>\(paragraphs.joined())</p:txBody></p:sp>"
    }

    /// A minimal PPTX package: `ppt/presentation.xml` listing `order` (default:
    /// the slides as given) through its relationships, plus each slide part.
    static func deck(slides: [Slide], order: [String]? = nil,
                     extraParts: [(name: String, data: [UInt8])] = []) -> Data {
        let order = order ?? slides.map(\.file)
        let ids = order.enumerated().map { "<p:sldId id=\"\(256 + $0.offset)\" r:id=\"rIdSlide\($0.offset)\"/>" }.joined()
        let presentation = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><p:presentation \(namespaces)><p:sldIdLst>\(ids)</p:sldIdLst></p:presentation>"
        let presentationRels = relationshipsXML(order.enumerated().map {
            ("rIdSlide\($0.offset)", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide", "slides/\($0.element)")
        })
        var parts: [(name: String, data: [UInt8])] = [
            ("ppt/presentation.xml", Array(presentation.utf8)),
            ("ppt/_rels/presentation.xml.rels", Array(presentationRels.utf8)),
        ]
        for slide in slides {
            let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><p:sld \(namespaces)><p:cSld><p:spTree>"
                + "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"
                + slide.shapes + "</p:spTree></p:cSld></p:sld>"
            parts.append(("ppt/slides/\(slide.file)", Array(xml.utf8)))
            if !slide.relationships.isEmpty {
                parts.append(("ppt/slides/_rels/\(slide.file).rels", Array(relationshipsXML(slide.relationships).utf8)))
            }
        }
        return PagesConverterTests.makeZip(parts + extraParts)
    }

    static func relationshipsXML(_ relationships: [(id: String, type: String, target: String)]) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + relationships.map { "<Relationship Id=\"\($0.id)\" Type=\"\($0.type)\" Target=\"\($0.target)\"/>" }.joined()
            + "</Relationships>"
    }
}
