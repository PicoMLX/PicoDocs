//
//  PicoDocsTests.swift
//  PicoDocs
//
//  Minimal smoke tests for the converter engine. The full per-converter suite
//  (HTML/PDF/XLSX/DOCX/EPUB + the ContentTypeDetector issue-#2 regression guard)
//  lands with the dedicated test PR that also enables `swift test` in CI; these
//  keep the test target valid in the meantime.
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
