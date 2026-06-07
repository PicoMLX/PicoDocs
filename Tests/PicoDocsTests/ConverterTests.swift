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

    @Test("XLSX converts each sheet's cells to Markdown")
    func xlsx() async throws {
        let md = try await PicoDocsEngine.convert(data: Fixture.data("sample", "xlsx"), filename: "sample.xlsx").markdown()
        #expect(md.contains("Name"))
        #expect(md.contains("Score"))
        #expect(md.contains("Alice"))
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

    @Test("Unimplemented formats throw rather than leak Markdown")
    func unsupportedFormatThrows() {
        let result = ConverterResult(sections: [DocumentSection(kind: .body, markdown: "x")])
        #expect(throws: PicoDocsError.self) {
            _ = try DocumentRenderer.render(result, to: .html)
        }
    }
}
