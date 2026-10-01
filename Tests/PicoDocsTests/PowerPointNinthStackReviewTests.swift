import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

struct PowerPointNinthStackReviewTests {
    typealias B = PowerPointConverterTests
    typealias R = PowerPointThirdStackReviewTests
    typealias N = PowerPointFifthStackReviewTests

    @Test func literalPrivateUseSequencesAreNotGeneratedLinksOrCode() throws {
        let literal = "\u{E002}0\u{E003} \u{E000}0\u{E001}"
        let result = ConverterResult(sections: [.init(markdown: literal + " [real](https://example.com) `code`")])
        #expect(try DocumentRenderer.render(result, to: .plaintext) == literal + " real code")
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains(literal))
        #expect(html.components(separatedBy: "href=\"https://example.com\"").count - 1 == 1)
    }

    @Test func literalSpreadsheetWhitespaceEntitiesAreNotPowerPointMetadata() async throws {
        for value in ["&#32;", "&#9;", "&#160;", "\u{E008}32\u{E009}"] {
            let result = try await CSVConverter().convert(Data(("Value\n" + value).utf8), info: StreamInfo(detectedFormat: .csv))
            #expect(try DocumentRenderer.render(result, to: .plaintext).contains(value))
            #expect(try DocumentRenderer.render(result, to: .html).contains(value.replacingOccurrences(of: "&", with: "&amp;")))
        }
    }

    @Test func numericWhitespaceAndEmptyPlainParagraphsRespectListGrammar() async throws {
        let first = "<a:p><a:pPr lvl=' 1 '><a:buAutoNum type='arabicPeriod' startAt=' 3 '/></a:pPr><a:r><a:t>First</a:t></a:r></a:p>"
        let reset = "<a:p><a:pPr><a:buNone/></a:pPr></a:p>"
        let last = "<a:p><a:pPr><a:buAutoNum type='arabicPeriod'/></a:pPr><a:r><a:t>Last</a:t></a:r></a:p>"
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.shape(placeholder: nil, paragraphs: [first, reset, last]))])
        let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
        #expect(result.markdown() == "3. First\n\n1. Last")
    }

    @Test func themeAndNotesBackgroundsUseTheirOwnRelationships() async throws {
        let layout = "<p:sldLayout " + B.namespaces + "><p:cSld><p:spTree/></p:cSld></p:sldLayout>"
        let master = "<p:sldMaster " + B.namespaces + "><p:cSld><p:spTree/></p:cSld></p:sldMaster>"
        let theme = "<a:theme " + B.namespaces + "><a:themeElements><a:fmtScheme name='Theme'><a:bgFillStyleLst><a:blipFill><a:blip r:embed='bg'/></a:blipFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>"
        let notes = "<p:notes " + B.namespaces + "><p:cSld><p:bg><p:bgPr><a:blipFill><a:blip r:embed='noteBg'/></a:blipFill></p:bgPr></p:bg><p:spTree/></p:cSld></p:notes>"
        let extra: [(name: String, data: [UInt8])] = [
            ("ppt/slideLayouts/l.xml", Array(layout.utf8)),
            ("ppt/slideLayouts/_rels/l.xml.rels", Array(B.relationshipsXML([("master", N.rel + "slideMaster", "../slideMasters/m.xml")]).utf8)),
            ("ppt/slideMasters/m.xml", Array(master.utf8)),
            ("ppt/slideMasters/_rels/m.xml.rels", Array(B.relationshipsXML([("theme", N.rel + "theme", "../theme/t.xml")]).utf8)),
            ("ppt/theme/t.xml", Array(theme.utf8)),
            ("ppt/theme/_rels/t.xml.rels", Array(B.relationshipsXML([("bg", N.rel + "image", "../media/theme.png")]).utf8)),
            ("ppt/notesSlides/n.xml", Array(notes.utf8)),
            ("ppt/notesSlides/_rels/n.xml.rels", Array(B.relationshipsXML([("noteBg", N.rel + "image", "../media/notes.png")]).utf8)),
            ("ppt/media/theme.png", [1, 2]), ("ppt/media/notes.png", [3, 4])
        ]
        let seed = B.deck(slides: [.init(file: "s.xml", shapes: "", relationships: [("layout", N.rel + "slideLayout", "../slideLayouts/l.xml"), ("notes", N.rel + "notesSlide", "../notesSlides/n.xml")])], extraParts: extra)
        let data = try R.replacing(seed, part: "ppt/slides/s.xml") { $0.replacingOccurrences(of: "<p:spTree>", with: "<p:bg><p:bgRef idx='1001'><a:srgbClr val='FFFFFF'/></p:bgRef></p:bg><p:spTree>") }
        let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
        #expect(result.sections.first?.metadata["notes"] == "![image](notes.png)")
        #expect(result.sections.first?.markdown.contains("![image](theme.png)") == true)
        #expect(result.sections.filter { $0.kind == .image }.count == 2)
    }
    @Test func lineStorageIsBoundedBeforeSplitting() throws {
        let exact = ConverterResult(sections: [.init(markdown: "a\nb")])
        try DocumentRenderer.preflightRenderInput(exact, maximumBytes: 515, maximumLines: 2)
        #expect(throws: PicoDocsError.fileCorrupted) { try DocumentRenderer.preflightRenderInput(exact, maximumBytes: 514, maximumLines: 2) }
        #expect(throws: PicoDocsError.fileCorrupted) { try DocumentRenderer.preflightRenderInput(exact, maximumBytes: 515, maximumLines: 1) }
        let excessive = ConverterResult(sections: [.init(markdown: String(repeating: "\n", count: 100_000))])
        #expect(throws: PicoDocsError.fileCorrupted) { _ = try DocumentRenderer.render(excessive, to: .html) }
    }

    @Test func manyImageReferencesShareOneCumulativeRewrite() throws {
        var html = "", replacements: [String: (mime: String, base64: String)] = [:]
        for index in 0..<2000 {
            let reference = "image\(index).png"
            html += "<img src=\"" + reference + "\">"
            replacements[reference] = ("image/png", "AQI=")
        }
        let rendered = try DocumentRenderer.boundedImageReplacements(html, replacements: replacements)
        #expect(rendered.components(separatedBy: "data:image/png;base64,AQI=").count - 1 == 2000)
        #expect(try DocumentRenderer.boundedImageReplacements(html, replacements: replacements, maximumBytes: rendered.utf8.count) == rendered)
        #expect(throws: PicoDocsError.fileCorrupted) { _ = try DocumentRenderer.boundedImageReplacements(html, replacements: replacements, maximumBytes: rendered.utf8.count - 1) }
    }

}
