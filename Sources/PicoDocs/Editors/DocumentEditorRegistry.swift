//
//  DocumentEditorRegistry.swift
//  PicoDocs
//
//  An immutable, Sendable registry of in-place editors — the edit-side mirror of
//  `DocumentConverterRegistry` and `DocumentExporterRegistry`. Editing is pure
//  (bytes in, bytes out) with no shared mutable state, so this is a value type.
//
//  Only `WordEditor` (DOCX) is built in. Other formats throw
//  `documentTypeNotSupported`; the lossy fallback (convert → edit the Markdown
//  → `PicoDocsEngine.write`) is a host-side recipe, not an editor.
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
        /// An explicitly selected editor takes precedence over built-ins.
        public static let override: Double = -10
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
    /// chained on a `let`. Equal priorities keep registration order.
    public func registering(_ editor: any DocumentEditor, priority: Double = Priority.specific) -> DocumentEditorRegistry {
        var updated = entries
        let index = updated.firstIndex { $0.priority > priority } ?? updated.endIndex
        updated.insert(Entry(priority: priority, editor: editor), at: index)
        return DocumentEditorRegistry(entries: updated)
    }

    /// The default registry with all built-in editors registered.
    public static let `default` = DocumentEditorRegistry().registering(WordEditor(), priority: Priority.specific)

    /// The editable text from the first editor that accepts `info`.
    public func editableText(_ data: Data, info: StreamInfo) throws -> String {
        try editor(for: info).editableText(data)
    }

    /// Applies `edits` with the first editor that accepts `info`.
    public func applyEdits(_ edits: [TextEdit], to data: Data, info: StreamInfo) throws -> EditResult {
        try editor(for: info).applyEdits(edits, to: data)
    }

    private func editor(for info: StreamInfo) throws -> any DocumentEditor {
        guard let entry = entries.first(where: { $0.editor.accepts(info) }) else {
            throw PicoDocsError.documentTypeNotSupported
        }
        return entry.editor
    }
}
