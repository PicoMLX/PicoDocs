import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

struct PowerPointSeventhStackReviewTests {
    typealias B = PowerPointConverterTests
    typealias N = PowerPointFifthStackReviewTests

    @Test func relocatedPresentationRoutesWithoutHints() async throws {
        let archive = try Archive(data: B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Moved"))]), accessMode: .read)
        var parts: [(name: String, data: [UInt8])] = []
        for entry in archive {
            var bytes = Data(); _ = try archive.extract(entry) { bytes.append($0) }
            var name = entry.path
            if name == "ppt/presentation.xml" { name = "custom/deck.xml" }
            if name == "ppt/_rels/presentation.xml.rels" {
                name = "custom/_rels/deck.xml.rels"
                bytes = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "slides/s.xml", with: "../ppt/slides/s.xml").utf8)
            }
            if name == "_rels/.rels" || name == "[Content_Types].xml" {
                bytes = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "ppt/presentation.xml", with: "custom/deck.xml").utf8)
            }
            parts.append((name, Array(bytes)))
        }
        let data = PagesConverterTests.makeZip(parts)
        #expect(ContentTypeDetector.classify(data, info: StreamInfo()).detectedFormat == .pptx)
        #expect(try await PicoDocsEngine.convert(data: data).markdown() == "## Moved")
    }

    static func filledShape(text: String = "") -> String {
        let body = text.isEmpty ? "" : "<p:txBody><a:bodyPr/><a:p><a:r><a:t>" + text + "</a:t></a:r></a:p></p:txBody>"
        return "<p:sp><p:nvSpPr><p:cNvPr id='2' name='Fill image'/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:blipFill><a:blip r:embed='fill'/><a:stretch><a:fillRect/></a:stretch></a:blipFill></p:spPr>" + body + "</p:sp>"
    }

    @Test func shapeFillImagesSurviveWithAndWithoutText() async throws {
        for text in ["", "Caption"] {
            let data = B.deck(slides: [.init(file: "s.xml", shapes: Self.filledShape(text: text), relationships: [("fill", N.rel + "image", "../media/photo.png")])], extraParts: [("ppt/media/photo.png", [1, 2, 3])])
            let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
            #expect(result.sections.filter { $0.kind == .image }.count == 1)
            #expect(result.markdown().contains("![Fill image]"))
            if !text.isEmpty { #expect(result.markdown().contains(text)) }
        }
        let notes = N.deck(masterShapes: Self.filledShape(), localShapes: N.text("Local"), masterRels: [("fill", N.rel + "image", "../media/photo.png")], extra: [("ppt/media/photo.png", [1, 2, 3])])
        let result = try await PowerPointConverter().convert(notes, info: StreamInfo(detectedFormat: .pptx))
        #expect(result.sections.filter { $0.kind == .image }.count == 1)
        #expect(result.sections.first?.metadata["notes"]?.contains("![Fill image]") == true)
    }

    @Test func booleanWhitespaceRetainsSchemaSemantics() async throws {
        let formatted = B.shape(placeholder: nil, paragraphs: ["<a:p><a:r><a:rPr b=' true ' i=' 1 '/><a:t>Styled</a:t></a:r></a:p>"])
        let hidden = N.text("Hidden").replacingOccurrences(of: "name=\"Shape\"", with: "name=\"Shape\" hidden=' 1 '")
        let table = "<p:graphicFrame><a:tbl><a:tr><a:tc><a:txBody><a:p><a:r><a:t>Visible</a:t></a:r></a:p></a:txBody></a:tc><a:tc hMerge=' true '><a:txBody><a:p><a:r><a:t>Duplicate</a:t></a:r></a:p></a:txBody></a:tc></a:tr></a:tbl></p:graphicFrame>"
        let result = try await PowerPointConverter().convert(B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Slide") + formatted + hidden + table)]), info: StreamInfo(detectedFormat: .pptx))
        #expect(result.markdown().contains("***Styled***"))
        #expect(!result.markdown().contains("Hidden"))
        #expect(!result.markdown().contains("Duplicate"))
        let notes = try await PowerPointConverter().convert(N.deck(masterShapes: N.text("Master"), localShapes: N.text("Local"), visibility: " false "), info: StreamInfo(detectedFormat: .pptx))
        #expect(notes.sections.first?.metadata["notes"] == "Local")
    }

    @Test func tildeFenceOpenersRemainLiteralSlideText() async throws {
        for text in ["~~~", "~~~~swift"] {
            let result = try await PowerPointConverter().convert(B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Slide") + N.text(text) + N.text("Following"))]), info: StreamInfo(detectedFormat: .pptx))
            let parsed = try AttributedString(markdown: result.markdown())
            #expect(String(parsed.characters).contains(text))
            #expect(result.markdown().contains("\\" + text))
        }
    }

    @Test func adjacentEquivalentRunStylesHaveOneDelimiterPair() async throws {
        for (attributes, marker) in [("i='1'", "*"), ("b='1'", "**"), ("b='1' i='1'", "***")] {
            let runs = ["A", "B"].map { "<a:r><a:rPr " + attributes + "/><a:t>" + $0 + "</a:t></a:r>" }.joined()
            let result = try await PowerPointConverter().convert(B.deck(slides: [.init(file: "s.xml", shapes: B.shape(placeholder: nil, paragraphs: ["<a:p>" + runs + "</a:p>"]))]), info: StreamInfo(detectedFormat: .pptx))
            #expect(result.markdown() == marker + "AB" + marker)
            #expect(String(try AttributedString(markdown: result.markdown()).characters) == "AB")
        }
    }
}
