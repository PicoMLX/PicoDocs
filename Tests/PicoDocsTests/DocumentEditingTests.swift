//
//  DocumentEditingTests.swift
//  PicoDocsTests
//
//  The public editing surface: PicoDocsEngine.editableText(for:) and
//  applyEdits(...) dispatching through DocumentEditorRegistry, plus
//  snapshot/matcher parity on the bundled DOCX fixtures.
//

import Foundation
import Testing
@testable import PicoDocs

@Suite("Document editing (engine and registry)")
struct DocumentEditingTests {

    private static let docxFixtures = [
        "sample", "footnote", "image", "linked-image", "lists",
        "textbox", "textbox-fallback-only", "textbox-multi-choice", "textbox-table", "textbox-with-table",
    ]

    @Test("DOCX is detected and edited through the engine, with or without a filename")
    func engineRoundTrip() async throws {
        let docx = try PicoDocsEngine.write(markdown: "# Status\n\nThe project is on track.", to: .docx)
        #expect(try await PicoDocsEngine.editableText(for: docx) == "Status\nThe project is on track.")
        let result = try await PicoDocsEngine.applyEdits(
            [TextEdit(find: "on track", replace: "ahead of schedule")], to: docx, filename: "status.docx")
        #expect(result.applied == [1])
        #expect(try await PicoDocsEngine.editableText(for: result.data, filename: "status.docx")
            == "Status\nThe project is ahead of schedule.")
    }

    @Test("Formats without an editor are unsupported")
    func unsupportedFormats() async throws {
        await #expect(throws: PicoDocsError.documentTypeNotSupported) {
            try await PicoDocsEngine.editableText(for: Data("plain notes".utf8), filename: "notes.txt")
        }
        let xlsx = try Fixture.data("sample", "xlsx")
        await #expect(throws: PicoDocsError.documentTypeNotSupported) {
            try await PicoDocsEngine.applyEdits([TextEdit(find: "a", replace: "b")], to: xlsx, filename: "sample.xlsx")
        }
        let docx = try PicoDocsEngine.write(markdown: "Body", to: .docx)
        await #expect(throws: PicoDocsError.documentTypeNotSupported) {
            try await PicoDocsEngine.editableText(for: docx, filename: "body.docx", registry: DocumentEditorRegistry())
        }
    }

    @Test("A registered editor with override priority wins over the built-in one")
    func overrideEditor() async throws {
        struct Selected: DocumentEditor {
            func accepts(_ info: StreamInfo) -> Bool { info.detectedFormat == .docx }
            func editableText(_ data: Data) throws -> String { "selected" }
            func applyEdits(_ edits: [TextEdit], to data: Data) throws -> EditResult {
                EditResult(data: Data("selected".utf8), applied: edits.map { _ in 0 })
            }
        }
        let registry = DocumentEditorRegistry.default.registering(Selected(), priority: DocumentEditorRegistry.Priority.override)
        let docx = try PicoDocsEngine.write(markdown: "Body", to: .docx)
        #expect(try await PicoDocsEngine.editableText(for: docx, filename: "body.docx", registry: registry) == "selected")
        let result = try await PicoDocsEngine.applyEdits([TextEdit(find: "Body", replace: "x")], to: docx, filename: "body.docx", registry: registry)
        #expect(result == EditResult(data: Data("selected".utf8), applied: [0]))
    }

    @Test("Every line of a fixture's editable text, quoted verbatim, is found")
    func fixtureParity() async throws {
        var applied = 0
        for name in Self.docxFixtures {
            let data = try Fixture.data(name, "docx")
            let text = try await PicoDocsEngine.editableText(for: data, filename: "\(name).docx")
            for line in text.components(separatedBy: "\n") where !line.isEmpty {
                do {
                    let result = try await PicoDocsEngine.applyEdits([TextEdit(find: line, replace: line)], to: data, filename: "\(name).docx")
                    #expect(try await PicoDocsEngine.editableText(for: result.data, filename: "\(name).docx") == text)
                    applied += 1
                } catch PicoDocsError.editCrossesBoundary, PicoDocsError.editTextAmbiguous {
                    // Found, but fixed text or a repeated line: both mean the quote matched.
                }
            }
        }
        #expect(applied > 0)
    }
}
