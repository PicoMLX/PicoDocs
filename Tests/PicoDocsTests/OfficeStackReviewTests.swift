import Foundation
import Testing
import ZIPFoundation
#if canImport(AppKit)
import AppKit
#endif
@testable import PicoDocs

struct OfficeStackReviewTests {
    static func xml(_ data: Data, _ path: String) throws -> String {
        let archive = try Archive(data: data, accessMode: .read)
        let entry = try #require(archive[path])
        var bytes = Data(); _ = try archive.extract(entry) { bytes.append($0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    @Test func unsafeOfficeLinksStayInert() throws {
        for url in ["file:///etc/passwd", "javascript:alert(1)", "ms-msdt:test", "custom:test"] {
            let result = ConverterResult(sections: [.init(markdown: "[Label](<" + url + ">)")])
            for (format, path) in [(ExportableFileType.docx, "word/_rels/document.xml.rels"), (.pptx, "ppt/slides/_rels/slide1.xml.rels")] {
                let relationships = try Self.xml(PicoDocsEngine.write(result, to: format), path)
                #expect(!relationships.contains("/hyperlink"))
            }
            #if canImport(AppKit)
            let attributed = AttributedStringDocumentBuilder.attributedString(from: result)
            #expect(attributed.attribute(.link, at: 0, effectiveRange: nil) == nil)
            #endif
        }
        #expect(try Self.xml(PicoDocsEngine.write(markdown: "[Allowed](https://example.com)", to: .docx), "word/_rels/document.xml.rels").contains("https://example.com"))
    }

    @Test func presenterNotesAreNeverVisibleSlideText() throws {
        let result = ConverterResult(sections: [.init(title: "Talk", kind: .slide, markdown: "## Talk\n\nPublic\n\n### Notes\n\nSecret", slideNumber: 1, metadata: ["notes": "Secret"])])
        let xml = try Self.xml(PicoDocsEngine.write(result, to: .pptx), "ppt/slides/slide1.xml")
        #expect(xml.contains("Public")); #expect(!xml.contains("Secret"))
        let authored = ConverterResult(sections: [.init(kind: .slide, markdown: "### Notes\n\nAuthored", slideNumber: 1)])
        #expect(try Self.xml(PicoDocsEngine.write(authored, to: .pptx), "ppt/slides/slide1.xml").contains("Authored"))
    }

    @Test func generatedImageAliasesRemainExactDOCXIdentities() throws {
        let result = ConverterResult(sections: [
            .init(markdown: "![One](a.png) ![Two](picodocs-embedded/2/a.png)"),
            .init(kind: .image, markdown: "", sourcePath: "ppt/media/a.png", metadata: ["base64": "AQID", "mimeType": "image/png", "markdownReference": "a.png"]),
            .init(kind: .image, markdown: "", sourcePath: "ppt/notes/media/a.png", metadata: ["base64": "BAUG", "mimeType": "image/png", "markdownReference": "picodocs-embedded/2/a.png"])
        ])
        let data = try PicoDocsEngine.write(result, to: .docx)
        let archive = try Archive(data: data, accessMode: .read)
        #expect(archive.filter { $0.path.hasPrefix("word/media/") }.count == 2)
        #expect(try Self.xml(data, "word/document.xml").components(separatedBy: "<w:drawing>").count - 1 == 2)
    }

    @Test func literalEscapingUsesMatchingFenceGrammar() {
        for source in ["~~~\na\\b\n~~~", "````\n```\na\\b\n````", "- ~~~\n  a\\b\n  ~~~"] {
            #expect(MarkdownLiteral.escapeBackslashes(source) == source)
        }
        #expect(MarkdownLiteral.escapeBackslashes("~~~\ncode\n~~~\na\\b").hasSuffix("a\\\\b"))
    }

    @Test func CSVParagraphStopsBeforeTildeCode() throws {
        let result = ConverterResult(sections: [.init(markdown: "before\n~~~\na|b\n~~~")])
        #expect(try DocumentRenderer.render(result, to: .csv) == "before\na|b")
    }

    @Test func binaryAndNestedRTFMarkersCannotEnableCanonicalMode() throws {
        let marker = #"{\*\picodocsmarkdown1}"#
        for payload in [#"{\pict\bin"# + String(marker.utf8.count) + " " + marker + "}", #"{\info "# + marker + "}"] {
            let source = #"{\rtf1"# + payload + #" a\\*b}"#
            let markdown = RTFConverter.markdown(fromRTF: source)
            #expect(try DocumentRenderer.render(ConverterResult(sections: [.init(markdown: markdown)]), to: .plaintext) == #"a\*b"#)
        }
    }

    @Test func bookmarkedHeadingsFollowWrappersAndTextBoxOrder() async throws {
        func heading(_ bookmark: String) -> String { "<w:p><w:pPr><w:pStyle w:val='Heading1'/></w:pPr><w:bookmarkStart w:id='1' w:name='" + bookmark + "'/><w:r><w:t>Same</w:t></w:r></w:p>" }
        let body = "<w:p><w:r><w:t>Anchor</w:t></w:r><w:txbxContent>" + heading("Early") + "</w:txbxContent></w:p><w:ins>" + heading("Wrapped") + "</w:ins>" + heading("Late") + "<w:p><w:hyperlink w:anchor='Early'><w:r><w:t>First</w:t></w:r></w:hyperlink><w:hyperlink w:anchor='Wrapped'><w:r><w:t>Second</w:t></w:r></w:hyperlink><w:hyperlink w:anchor='Late'><w:r><w:t>Third</w:t></w:r></w:hyperlink></w:p>"
        let document = "<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body>" + body + "</w:body></w:document>"
        let result = try await WordConverter().convert(PagesConverterTests.makeZip([("word/document.xml", Array(document.utf8))]), info: StreamInfo(detectedFormat: .docx))
        #expect(result.markdown().contains("[First](#same)"))
        #expect(result.markdown().contains("[Second](#same-1)"))
        #expect(result.markdown().contains("[Third](#same-2)"))
    }

    @Test func multiSheetCSVKeepsNamesAndRawFields() throws {
        let result = ConverterResult(sections: [.init(title: "First", kind: .sheet, markdown: "", sheetName: "First", metadata: ["csv": "\"a\""]), .init(title: "Second", kind: .sheet, markdown: "", sheetName: "Second", metadata: ["csv": "\"b\""])])
        #expect(try DocumentRenderer.render(result, to: .csv) == "First\n\"a\"\nSecond\n\"b\"")
    }

    @Test func emptyOfficeSectionsConsumeProjectionBudget() throws {
        let result = ConverterResult(sections: [.init(markdown: ""), .init(markdown: ""), .init(markdown: "x")])
        try OfficeDocumentBlocks.validateInput(result, maximumBytes: 903)
        #expect(throws: ExporterError.self) { try OfficeDocumentBlocks.validateInput(result, maximumBytes: 902) }
    }

    @Test func cancelledDenseWorksheetStopsMaterialization() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SpreadsheetConverter.materializeGrid([600_000: ["last"]], rows: 600_000, columns: 1, sheetName: "Sparse")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func loosePPTXListsKeepTheirContinuationLevels() async throws {
        for source in ["- Parent\n\n  Continuation\n- Next", "10. Parent\n\n    Continuation\n11. Next", "- Parent\n  - Child\n\n    Child continuation\n\n  Parent continuation\n- Next"] {
            let data = try PicoDocsEngine.write(markdown: source, to: .pptx)
            let restored = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
            #expect(restored.markdown() == source)
        }
    }
}
