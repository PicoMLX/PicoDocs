import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

struct PowerPointFollowupTests {
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
        let master = "<p:sldMaster \(B.namespaces)><p:txStyles><p:bodyStyle><a:lvl1pPr><a:defRPr i=\"1\"/></a:lvl1pPr></p:bodyStyle></p:txStyles></p:sldMaster>"
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
        let manifest = #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="png" ContentType="image/png&quot; onerror=&quot;alert(1)"/></Types>"#
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
