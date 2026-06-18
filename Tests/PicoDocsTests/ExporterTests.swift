//
//  ExporterTests.swift
//  PicoDocsTests
//
//  The reverse flow: Markdown / ConverterResult -> office files. The primary signal
//  is round-trip — write a file, re-import it with the existing converter, and
//  compare the recovered text — using the readers as oracles. PPTX has no in-repo
//  reader, so it's checked structurally (unzip + required parts + title text).
//

import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

@Suite("Exporters (Markdown/ConverterResult -> office files)")
struct ExporterTests {

    // MARK: - Helpers

    /// Reads a single entry from an in-memory archive (test-side mirror of the
    /// converters' `readEntry`).
    private func entry(_ data: Data, _ path: String) -> Data? {
        guard let archive = Archive(data: data, accessMode: .read),
              let entry = archive[path] else { return nil }
        var out = Data()
        _ = try? archive.extract(entry) { out.append($0) }
        return out
    }

    private func text(_ data: Data, _ path: String) -> String? {
        entry(data, path).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: - DOCX round-trip (via WordConverter)

    @Test("DOCX round-trips heading, bold, list, and table through WordConverter")
    func docxRoundTrip() async throws {
        let markdown = """
        # Title

        Some **bold** and *italic* text.

        - First
        - Second

        | Name | Age |
        | --- | --- |
        | Alice | 30 |
        """
        let data = try PicoDocsEngine.write(markdown: markdown, to: .docx)

        // Detection should route ZIP -> docx via the well-known entry name.
        #expect(text(data, "word/document.xml") != nil)

        let result = try await PicoDocsEngine.convert(data: data, filename: "out.docx")
        let recovered = result.markdown()
        #expect(recovered.contains("# Title"))
        #expect(recovered.contains("**bold**"))
        #expect(recovered.contains("*italic*"))
        #expect(recovered.contains("- First"))
        #expect(recovered.contains("- Second"))
        #expect(recovered.contains("Alice"))
        #expect(recovered.contains("| Name | Age |"))
    }

    @Test("DOCX is a valid OOXML package with the required parts")
    func docxPackageParts() throws {
        let data = try PicoDocsEngine.write(markdown: "# Hi\n\nBody", to: .docx)
        #expect(text(data, "[Content_Types].xml") != nil)
        #expect(text(data, "_rels/.rels") != nil)
        #expect(text(data, "word/_rels/document.xml.rels") != nil)
        let document = try #require(text(data, "word/document.xml"))
        #expect(document.contains("<w:body>"))
        #expect(document.contains("Heading1"))
    }

    @Test("DOCX embeds image bytes from .image sections and round-trips the ref")
    func docxImageRoundTrip() async throws {
        // A 1x1 transparent PNG.
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        let body = DocumentSection(kind: .body, markdown: "![pic.png](pic.png)")
        let image = DocumentSection(
            title: "pic.png",
            kind: .image,
            markdown: "![pic.png](pic.png)",
            sourcePath: "word/media/pic.png",
            metadata: ["mimeType": "image/png", "base64": pngBase64]
        )
        let result = ConverterResult(sections: [body, image])
        let data = try PicoDocsEngine.write(result, to: .docx)

        #expect(entry(data, "word/media/pic.png") != nil)
        let recovered = try await PicoDocsEngine.convert(data: data, filename: "out.docx")
        #expect(recovered.sections.contains { $0.kind == .image })
    }

    @Test("Image-only result embeds its images instead of a blank file")
    func docxImageOnlyEmbeds() async throws {
        // A 1x1 transparent PNG, carried as the only section (no inline body ref).
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        let image = DocumentSection(
            title: "pic.png",
            kind: .image,
            markdown: "![pic.png](pic.png)",
            sourcePath: "word/media/pic.png",
            metadata: ["mimeType": "image/png", "base64": pngBase64]
        )
        let result = ConverterResult(sections: [image])
        let data = try PicoDocsEngine.write(result, to: .docx)

        #expect(entry(data, "word/media/pic.png") != nil)
        let recovered = try await PicoDocsEngine.convert(data: data, filename: "out.docx")
        #expect(recovered.sections.contains { $0.kind == .image })
    }

    // MARK: - XLSX round-trip (via SpreadsheetConverter / CoreXLSX)

    @Test("XLSX round-trips table cells through SpreadsheetConverter")
    func xlsxRoundTrip() async throws {
        let section = DocumentSection(
            title: "People",
            kind: .table,
            markdown: """
            | Name | Age |
            | --- | --- |
            | Alice | 30 |
            | Bob | 25 |
            """,
            sheetName: "People"
        )
        let result = ConverterResult(sections: [section])
        let data = try PicoDocsEngine.write(result, to: .xlsx)

        #expect(text(data, "xl/workbook.xml")?.contains("People") == true)

        let recovered = try await PicoDocsEngine.convert(data: data, filename: "out.xlsx")
        let md = recovered.markdown()
        #expect(md.contains("Alice"))
        #expect(md.contains("Bob"))
        #expect(md.contains("30"))
        #expect(md.contains("25"))
    }

    // MARK: - PPTX (structural — no in-repo reader)

    @Test("PPTX produces one slide per heading with title text")
    func pptxStructure() throws {
        let markdown = """
        # Slide One

        Point A

        # Slide Two

        Point B
        """
        let data = try PicoDocsEngine.write(markdown: markdown, to: .pptx)

        #expect(text(data, "ppt/presentation.xml") != nil)
        #expect(text(data, "ppt/slideMasters/slideMaster1.xml") != nil)
        #expect(text(data, "ppt/theme/theme1.xml") != nil)

        let slide1 = try #require(text(data, "ppt/slides/slide1.xml"))
        let slide2 = try #require(text(data, "ppt/slides/slide2.xml"))
        #expect(slide1.contains("Slide One"))
        #expect(slide1.contains("Point A"))
        #expect(slide2.contains("Slide Two"))
        // Exactly two slides.
        #expect(text(data, "ppt/slides/slide3.xml") == nil)
    }

    // MARK: - RTF (Apple-only, via RTFConverter)

    #if canImport(AppKit) || canImport(UIKit)
    @Test("RTF round-trips prose and bold through RTFConverter")
    func rtfRoundTrip() async throws {
        let markdown = "A paragraph with **bold** text."
        let data = try PicoDocsEngine.write(markdown: markdown, to: .rtf)
        let recovered = try await PicoDocsEngine.convert(data: data, filename: "out.rtf")
        let md = recovered.markdown()
        #expect(md.contains("paragraph"))
        #expect(md.contains("**bold**"))
    }
    #endif

    // MARK: - Contract

    @Test("Empty Markdown throws .emptyDocument")
    func emptyMarkdownThrows() {
        #expect(throws: PicoDocsError.self) {
            try PicoDocsEngine.write(markdown: "   \n  ", to: .docx)
        }
    }

    @Test("Unimplemented iWork formats throw unableToExportToRequestedFormat")
    func iworkUnsupported() {
        #expect(!ExportableFileType.pages.isImplemented)
        #expect(!ExportableFileType.keynote.isImplemented)
        #expect(throws: PicoDocsError.self) {
            try PicoDocsEngine.write(markdown: "# Hi", to: .pages)
        }
    }
}

@Suite("Markdown inline IR")
struct MarkdownInlineParserTests {

    @Test("Parses nested strong/emphasis, code, and links")
    func parsesInline() {
        let nodes = MarkdownInlineParser.parse("a **b _c_** `d` [e](http://x)")
        // Plain-text projection collapses formatting.
        #expect(nodes.plainText == "a b _c_ d e")

        let strong = MarkdownInlineParser.parse("***x***")
        #expect(strong == [.strong([.emphasis([.text("x")])])])
    }

    @Test("Parses image and footnote reference")
    func parsesImageAndFootnote() {
        #expect(MarkdownInlineParser.parse("![alt](pic.png)") == [.image(alt: "alt", source: "pic.png")])
        #expect(MarkdownInlineParser.parse("[^1]") == [.footnoteReference("1")])
    }

    @Test("Handles balanced parens and escaped delimiters in links")
    func parsesTrickyLinks() {
        // Balanced parens in a bare destination aren't truncated at the first `)`.
        #expect(
            MarkdownInlineParser.parse("[spec](https://e.com/Foo_(bar))")
                == [.link(label: [.text("spec")], destination: "https://e.com/Foo_(bar)")]
        )
        // An escaped `]` in a label doesn't end it early and is unescaped.
        #expect(
            MarkdownInlineParser.parse("![a\\]b](pic.png)")
                == [.image(alt: "a]b", source: "pic.png")]
        )
    }
}
