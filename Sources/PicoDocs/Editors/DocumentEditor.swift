//
//  DocumentEditor.swift
//  PicoDocs
//
//  The edit-side counterpart of `DocumentConverter`/`DocumentExporter`: a small,
//  Sendable in-place editor for one family of formats. Unlike the exporters
//  (which regenerate a document from Markdown and therefore lose the source's
//  formatting), an editor applies exact-match find/replace edits *to the original
//  file*, changing only the matched text and leaving everything else — styles,
//  images, structure — as close to untouched as the format allows.
//
//  Editors are `async throws` because they may touch the archive/XML layer; like
//  converters, detection has already run, so `accepts` only inspects the format.
//

import Foundation

public protocol DocumentEditor: Sendable {

    /// Cheap check against already-resolved `StreamInfo` (typically just
    /// `info.detectedFormat`). Must not perform heavy work or decode `data`.
    func accepts(_ info: StreamInfo) -> Bool

    /// The document's visible, editable text — the exact string a caller should
    /// present to an LLM and quote `TextEdit.find` from. It is *not* the rendered
    /// Markdown/plaintext (those add list markers, table pipes, etc.); it is the
    /// text the editor itself searches, so a verbatim quote always matches.
    func editableText(_ data: Data, info: StreamInfo) async throws -> String

    /// Apply `edits` in place, returning the edited document in the same format.
    ///
    /// All edits match against the same original snapshot; their targets must not
    /// overlap; application is all-or-nothing (any failing edit throws and no
    /// output is produced).
    func applyEdits(_ edits: [TextEdit], to data: Data, info: StreamInfo) async throws -> EditResult
}
