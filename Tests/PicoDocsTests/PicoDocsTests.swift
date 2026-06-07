//
//  PicoDocsTests.swift
//  PicoDocs
//
//  Smoke tests for the engine's public surface. The per-converter and detection
//  suites live in the sibling test files (ContentTypeDetectorTests,
//  HTMLConversionTests, ConverterTests, DocumentRendererTests).
//

import Testing
@testable import PicoDocs

@Suite("PicoDocs engine smoke")
struct PicoDocsSmokeTests {

    @Test("ExportFileType exposes the canonical Markdown case")
    func exportFileTypeHasMarkdown() {
        #expect(ExportFileType.allCases.contains(.markdown))
    }

    @Test("Default converter registry is constructible")
    func defaultRegistryBuilds() {
        // Exercises makeDefault() wiring (HTML/Spreadsheet/EPUB/Word/PDF/PlainText).
        _ = DocumentConverterRegistry.default
    }
}
