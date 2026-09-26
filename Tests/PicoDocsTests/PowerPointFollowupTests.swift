import Foundation
import Testing
@testable import PicoDocs

struct PowerPointFollowupTests {
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
