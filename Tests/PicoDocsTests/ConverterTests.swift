//
//  ConverterTests.swift
//  PicoDocsTests
//
//  End-to-end conversion of the Tier A binary formats (the set that failed in
//  issue #2), the strict-failure rule (a corrupt document errors rather than
//  silently degrading to plain text), and the renderer's format handling.
//

import Foundation
import Testing
@testable import PicoDocs

@Suite("Tier A converters")
struct ConverterTests {

    @Test("DOCX converts to Markdown with heading and body text")
    func docx() async throws {
        let result = try await PicoDocsEngine.convert(data: Fixture.data("sample", "docx"), filename: "sample.docx")
        let md = result.markdown()
        #expect(md.contains("Sample Heading"))
        #expect(md.contains("Hello from a Word document."))
    }

    @Test("DOCX extracts embedded images: inline reference + an image section with bytes")
    func docxImages() async throws {
        let result = try await PicoDocsEngine.convert(data: Fixture.data("image", "docx"), filename: "image.docx")
        let md = result.markdown()
        #expect(md.contains("Before image."))
        #expect(md.contains("![A red dot](image1.png)"))   // alt text + filename, inline at position
        // Referenced once: the .image section's bytes don't render a duplicate.
        #expect(md.components(separatedBy: "image1.png").count == 2)
        let image = result.sections.first { $0.kind == .image }
        #expect(image?.sourcePath == "word/media/image1.png")
        #expect(image?.metadata["mimeType"] == "image/png")
        #expect(image?.metadata["base64"]?.isEmpty == false)
    }

    @Test("DOCX hyperlink wrapping an image keeps the image (renderer-safe)")
    func docxLinkedImage() async throws {
        let md = try await PicoDocsEngine.convert(
            data: Fixture.data("linked-image", "docx"), filename: "linked-image.docx"
        ).markdown()
        #expect(md.contains("![A red dot](image1.png)"))
        // We don't emit a nested linked image the renderers can't parse.
        #expect(!md.contains("https://example.com"))
    }

    @Test("HTML export embeds extracted DOCX images as data URLs")
    func docxImageHTML() async throws {
        let html = try await PicoDocsEngine.export(
            data: Fixture.data("image", "docx"), filename: "image.docx", to: .html
        )
        #expect(html.contains("<img src=\"data:image/png;base64,"))
        #expect(!html.contains("src=\"image1.png\""))
    }

    @Test("XLSX converts each sheet's cells to Markdown")
    func xlsx() async throws {
        let md = try await PicoDocsEngine.convert(data: Fixture.data("sample", "xlsx"), filename: "sample.xlsx").markdown()
        #expect(md.contains("Name"))
        #expect(md.contains("Score"))
        #expect(md.contains("Alice"))
    }

    @Test("CSV converts to a Markdown table and round-trips back to CSV")
    func csvInput() async throws {
        let csv = "Name,Score\nAlice,42\n\"Bob, Jr\",7"
        let result = try await PicoDocsEngine.convert(data: Data(csv.utf8), filename: "data.csv")
        let md = result.markdown()
        #expect(md.contains("| Name | Score |"))
        #expect(md.contains("| Alice | 42 |"))
        #expect(md.contains("| Bob, Jr | 7 |"))   // comma inside a quoted field stays one cell
        let roundTrip = try DocumentRenderer.render(result, to: .csv)
        #expect(roundTrip.contains("Name,Score"))
        #expect(roundTrip.contains("\"Bob, Jr\",7"))
    }

    @Test("CSV round-trip preserves quoted whitespace and embedded newlines")
    func csvRoundTripFidelity() async throws {
        let csv = "Name,Note\nAlice,\"hello\nworld\"\nBob,\" 007 \""
        let result = try await PicoDocsEngine.convert(data: Data(csv.utf8), filename: "d.csv")
        let out = try DocumentRenderer.render(result, to: .csv)
        #expect(out.contains("\"hello\nworld\""))   // embedded newline preserved
        #expect(out.contains("\" 007 \""))           // quoted leading/trailing spaces preserved
    }

    @Test("CSV parser keeps a final quoted empty record")
    func csvFinalEmptyRecord() {
        let rows = CSVConverter.parseCSV("value\n\"\"")
        #expect(rows.count == 2)
        #expect(rows.last == [""])
    }

    @Test("EPUB converts spine chapters and reads metadata")
    func epub() async throws {
        let result = try await PicoDocsEngine.convert(data: Fixture.data("sample", "epub"), filename: "sample.epub")
        #expect(result.markdown().contains("Hello from an EPUB chapter."))
        #expect(result.title == "Sample EPUB")
    }

    @Test("RTF converts to Markdown with paragraphs and emphasis")
    func rtf() async throws {
        let rtf = "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Times New Roman;}}Hello \\b world\\b0 . This is \\i italic\\i0  text.\\par Second paragraph here.\\par}"
        let md = try await PicoDocsEngine.convert(data: Data(rtf.utf8), filename: "sample.rtf").markdown()
        #expect(md.contains("**world**"))
        #expect(md.contains("*italic*"))
        #expect(md.contains("Second paragraph here."))
        // Control tables are skipped, and no raw control words leak through.
        #expect(!md.contains("Times New Roman"))
        #expect(!md.contains("\\rtf"))
    }

    @Test("RTF keeps a \\uN char and skips its \\'hh fallback (no duplicate)")
    func rtfUnicodeFallback() async throws {
        // A U+2019 right single quote written as the control word u8217, with a
        // hex-escape CP1252 fallback, must yield one quote -- not the quote plus
        // the raw fallback byte.
        let rtf = "{\\rtf1\\ansi\\uc1 It\\u8217\\'92s fine.\\par}"
        let md = try await PicoDocsEngine.convert(data: Data(rtf.utf8), filename: "q.rtf").markdown()
        #expect(md.contains("It\u{2019}s fine."))
        #expect(!md.contains("\u{0092}"))
    }

    @Test("RTF hex escapes decode via Windows-1252, not raw Latin-1")
    func rtfWindows1252() async throws {
        // 0x93/0x94 are CP1252 curly double quotes; 0x97 is an em dash. As raw
        // Latin-1 these would be invisible C1 control characters.
        let rtf = "{\\rtf1\\ansi \\'93quoted\\'94 and a dash\\'97here.\\par}"
        let md = try await PicoDocsEngine.convert(data: Data(rtf.utf8), filename: "q.rtf").markdown()
        #expect(md.contains("\u{201C}quoted\u{201D}"))
        #expect(md.contains("\u{2014}"))
    }

    @Test("RTF combines \\uN surrogate pairs into astral characters")
    func rtfSurrogatePair() async throws {
        // U+1F600 as a UTF-16 surrogate pair (\uc0 means no fallback bytes).
        let rtf = "{\\rtf1\\ansi\\uc0\\u-10179\\u-8704 done.\\par}"
        let md = try await PicoDocsEngine.convert(data: Data(rtf.utf8), filename: "e.rtf").markdown()
        #expect(md.contains("\u{1F600}"))
        #expect(md.contains("done."))
    }

    @Test("RTF paragraph breaks inside skipped destinations don't split the body")
    func rtfIgnoredDestinationParagraphs() async throws {
        let rtf = "{\\rtf1\\ansi Hello{\\footnote\\par ignored}world.\\par}"
        let md = try await PicoDocsEngine.convert(data: Data(rtf.utf8), filename: "f.rtf").markdown()
        #expect(md.contains("Helloworld."))
    }

    @Test("A mislabeled .rtf without the RTF header throws (strict failure)")
    func rtfMislabeledThrows() async throws {
        let notRTF = Data("this is not actually an RTF file".utf8)
        await #expect(throws: (any Error).self) {
            _ = try await PicoDocsEngine.convert(data: notRTF, filename: "notes.rtf")
        }
    }

    @Test("RTF special-character control words become punctuation")
    func rtfSpecialChars() async throws {
        let rtf = "{\\rtf1\\ansi A\\emdash B, \\bullet item, \\ldblquote q\\rdblquote .\\par}"
        let md = try await PicoDocsEngine.convert(data: Data(rtf.utf8), filename: "s.rtf").markdown()
        #expect(md.contains("A\u{2014}B"))            // em dash
        #expect(md.contains("\u{2022}"))              // bullet
        #expect(md.contains("\u{201C}q\u{201D}"))     // curly double quotes
    }

    @Test("RTF honors a declared non-1252 code page for hex escapes")
    func rtfCodePage1251() async throws {
        // CP1251: 0xE0 -> U+0430, 0xE1 -> U+0431 (Cyrillic a/b).
        let rtf = "{\\rtf1\\ansi\\ansicpg1251 \\'e0\\'e1 done.\\par}"
        let md = try await PicoDocsEngine.convert(data: Data(rtf.utf8), filename: "c.rtf").markdown()
        #expect(md.contains("\u{0430}\u{0431}"))
    }

    @Test("RTF \\line is a hard break and \\page separates content")
    func rtfLineAndPageBreaks() async throws {
        let rtf = "{\\rtf1\\ansi Line one\\line Line two.\\page Next page.\\par}"
        let md = try await PicoDocsEngine.convert(data: Data(rtf.utf8), filename: "l.rtf").markdown()
        #expect(md.contains("Line one  \nLine two."))   // hard break preserved
        #expect(md.contains("Next page."))
        #expect(!md.contains("Line two.Next page."))     // \page kept them separate
    }

    @Test("RTF \\binN binary payload doesn't corrupt brace parsing")
    func rtfBinaryPayload() async throws {
        // The byte after \bin1 is a '}' that must not close the \pict group.
        let rtf = "{\\rtf1\\ansi Before {\\pict\\bin1 }X} After.\\par}"
        let md = try await PicoDocsEngine.convert(data: Data(rtf.utf8), filename: "b.rtf").markdown()
        #expect(md.contains("Before"))
        #expect(md.contains("After."))
        #expect(!md.contains("X"))
    }

    @Test("A corrupt DOCX throws instead of degrading to plain text")
    func corruptDocxIsStrict() async throws {
        // Detected as .docx by the filename hint, but the bytes aren't a zip — the
        // registry must surface the failure, not fall through to PlainTextConverter.
        let bogus = Data("this is definitely not a zip archive".utf8)
        await #expect(throws: (any Error).self) {
            _ = try await PicoDocsEngine.convert(data: bogus, filename: "broken.docx")
        }
    }

    #if canImport(PDFKit)
    @Test("PDF extracts text via PDFKit")
    func pdf() async throws {
        let result = try await PicoDocsEngine.convert(
            data: Fixture.data("TSLA-Q3-2024-Update", "pdf"),
            filename: "TSLA-Q3-2024-Update.pdf"
        )
        #expect(!result.markdown().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    #endif
}

@Suite("Document renderer")
struct DocumentRendererTests {

    @Test("Markdown rendering joins sections")
    func markdown() throws {
        let result = ConverterResult(title: "T", sections: [
            DocumentSection(kind: .body, markdown: "# Hi"),
            DocumentSection(kind: .body, markdown: "second"),
        ])
        let rendered = try DocumentRenderer.render(result, to: .markdown)
        #expect(rendered.contains("# Hi"))
        #expect(rendered.contains("second"))
    }

    @Test("HTML rendering converts headings, emphasis, links, and tables")
    func html() throws {
        let result = ConverterResult(title: "Doc", sections: [
            DocumentSection(kind: .body, markdown: "# Title\n\nHello **world** and a [link](https://example.com).\n\n| A | B |\n| --- | --- |\n| 1 | 2 |"),
        ])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("<h1>Title</h1>"))
        #expect(html.contains("<strong>world</strong>"))
        #expect(html.contains("<a href=\"https://example.com\">link</a>"))
        #expect(html.contains("<th>A</th>"))
        #expect(html.contains("<td>1</td>"))
    }

    @Test("HTML rendering escapes special characters including quotes")
    func htmlEscaping() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "1 < 2 & 3 > 0 with \"quotes\" and 'single'"),
        ])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("1 &lt; 2 &amp; 3 &gt; 0 with &quot;quotes&quot; and &#39;single&#39;"))
    }

    @Test("HTML rendering escapes quotes in link URLs (no attribute breakout)")
    func htmlLinkURLEscaping() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "[x](https://e.com/a\" onmouseover=\"alert(1))"),
        ])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(!html.contains("a\" onmouseover=\"alert"))   // the raw quote cannot close href
        #expect(html.contains("&quot;"))
    }

    @Test("HTML rendering handles combined and nested emphasis")
    func htmlEmphasis() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "***both*** and **bold *inner* bold**"),
        ])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("<strong><em>both</em></strong>"))
        #expect(html.contains("<strong>bold <em>inner</em> bold</strong>"))
    }

    @Test("Code spans keep Markdown metacharacters literal")
    func htmlCodeSpan() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "Use `*value*` literally."),
        ])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("<code>*value*</code>"))
        #expect(!html.contains("<em>value</em>"))
    }

    @Test("CSV keeps all-dash data rows after the header separator")
    func csvAllDashDataRow() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .sheet, markdown: "| A | B |\n| --- | --- |\n| - | - |\n| 1 | 2 |"),
        ])
        let csv = try DocumentRenderer.render(result, to: .csv)
        #expect(csv.contains("A,B"))
        #expect(csv.contains("-,-"))      // the all-dash DATA row is preserved
        #expect(csv.contains("1,2"))
    }

    @Test("Plaintext rendering strips Markdown syntax")
    func plaintext() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "# Heading\n\nHello **world** with a [link](https://example.com)."),
        ])
        let text = try DocumentRenderer.render(result, to: .plaintext)
        #expect(text.contains("Heading"))
        #expect(text.contains("Hello world with a link."))
        #expect(!text.contains("**"))
        #expect(!text.contains("#"))
        #expect(!text.contains("]("))
    }

    @Test("CSV rendering turns Markdown tables into CSV rows")
    func csv() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .sheet, markdown: "| Name | Score |\n| --- | --- |\n| Alice | 42 |\n| Bob, Jr | 7 |"),
        ])
        let csv = try DocumentRenderer.render(result, to: .csv)
        #expect(csv.contains("Name,Score"))
        #expect(csv.contains("Alice,42"))
        #expect(csv.contains("\"Bob, Jr\",7"))   // a field with a comma is quoted
    }

    @Test("XML rendering wraps sections with escaped content")
    func xml() throws {
        let result = ConverterResult(title: "T & U", sections: [
            DocumentSection(title: "S", kind: .body, markdown: "a < b"),
        ])
        let xml = try DocumentRenderer.render(result, to: .xml)
        #expect(xml.contains("<?xml version=\"1.0\""))
        #expect(xml.contains("title=\"T &amp; U\""))
        #expect(xml.contains("<section kind=\"body\" title=\"S\">"))
        #expect(xml.contains("a &lt; b"))
    }

    @Test("Emphasis characters in a link URL aren't rewritten; label emphasis is kept")
    func htmlLinkURLEmphasis() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "[x](https://e.com/*id*) and [**bold**](https://e.com)"),
        ])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("href=\"https://e.com/*id*\""))   // URL kept literal
        #expect(!html.contains("<em>id</em>"))
        #expect(html.contains("<a href=\"https://e.com\"><strong>bold</strong></a>"))
    }

    @Test("HTML handles angle-bracket link destinations with spaces and parens")
    func htmlAngleBracketLink() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "[label](<https://e.com/a b(1)>)"),
        ])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("<a href=\"https://e.com/a b(1)\">label</a>"))
    }

    @Test("CSV preserves fenced code lines instead of splitting them")
    func csvCodeFence() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "Code:\n\n```\n| grep foo | wc -l |\n```"),
        ])
        let csv = try DocumentRenderer.render(result, to: .csv)
        #expect(csv.contains("| grep foo | wc -l |"))
        #expect(!csv.contains("grep foo,wc -l"))
    }
}
