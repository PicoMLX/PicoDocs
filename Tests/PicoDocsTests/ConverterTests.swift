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
