//
//  DocumentEditorRegistry.swift
//  PicoDocs
//
//  An immutable, Sendable registry of in-place editors — the edit-side mirror of
//  `DocumentConverterRegistry` / `DocumentExporterRegistry`. Editing is pure
//  (data in, data out) with no shared mutable state, so this is a value type.
//
//  Only `WordEditor` is registered today (DOCX). Other formats fall through to
//  `documentTypeNotSupported`; the lossy Markdown round-trip fallback (convert →
//  edit Markdown → `PicoDocsEngine.write`) is a host-side recipe, not an editor.
//

import Foundation

public struct DocumentEditorRegistry: Sendable {

    private struct Entry: Sendable {
        let priority: Double
        let editor: any DocumentEditor
    }

    /// Kept sorted by ascending priority (see `registering`).
    private let entries: [Entry]

    /// Standard priorities. Lower is tried first (more specific wins).
    public enum Priority {
        public static let specific: Double = 0
        public static let generic: Double = 10
    }

    public init() {
        self.entries = []
    }

    private init(entries: [Entry]) {
        self.entries = entries
    }

    /// Returns a new registry with `editor` added. Value-returning so it can be
    /// chained on a `let` (third parties extend the engine this way).
    public func registering(_ editor: any DocumentEditor, priority: Double = Priority.specific) -> DocumentEditorRegistry {
        var updated = entries
        let index = updated.firstIndex { $0.priority > priority } ?? updated.endIndex
        updated.insert(Entry(priority: priority, editor: editor), at: index)
        return DocumentEditorRegistry(entries: updated)
    }

    /// The default registry with all built-in editors registered.
    public static let `default`: DocumentEditorRegistry = makeDefault()

    static func makeDefault() -> DocumentEditorRegistry {
        DocumentEditorRegistry()
            .registering(WordEditor(), priority: Priority.specific)
    }

    /// The first accepting editor for `info`, or nil if none accepts.
    func editor(for info: StreamInfo) -> (any DocumentEditor)? {
        entries.first { $0.editor.accepts(info) }?.editor
    }

    /// Apply `edits` using the first accepting editor (ascending priority).
    public func applyEdits(_ edits: [TextEdit], to data: Data, info: StreamInfo) async throws -> EditResult {
        guard let editor = editor(for: info) else { throw PicoDocsError.documentTypeNotSupported }
        return try await editor.applyEdits(edits, to: data, info: info)
    }

    /// The editable-text snapshot from the first accepting editor.
    public func editableText(_ data: Data, info: StreamInfo) async throws -> String {
        guard let editor = editor(for: info) else { throw PicoDocsError.documentTypeNotSupported }
        return try await editor.editableText(data, info: info)
    }
}
