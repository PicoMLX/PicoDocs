//
//  DocumentEditor.swift
//  PicoDocs
//
//  The edit-side counterpart of `DocumentConverter` and `DocumentExporter`: a
//  small, Sendable in-place editor for one family of formats. Exporters
//  regenerate a file from Markdown and lose the source's formatting; an editor
//  applies exact-match find/replace edits to the original file, changing only
//  the matched text.
//
//  Editors are synchronous (`throws`, not `async`), like exporters: editing is
//  pure CPU work on bytes already in memory. Detection has already run, so
//  `accepts` only inspects the resolved format.
//

import Foundation

public protocol DocumentEditor: Sendable {

    /// Cheap check against already-resolved `StreamInfo` (typically just
    /// `info.detectedFormat`). Must not decode `data` or do heavy work.
    func accepts(_ info: StreamInfo) -> Bool

    /// The document's editable text: the exact string to show a model and to
    /// quote `TextEdit.find` from. It's the text the editor itself searches,
    /// so a verbatim quote always matches.
    func editableText(_ data: Data) throws -> String

    /// Applies `edits` in place and returns the document in the same format.
    ///
    /// All edits match against the same original text, their targets may not
    /// overlap, and the batch is all-or-nothing: any failing edit throws and no
    /// output is produced.
    func applyEdits(_ edits: [TextEdit], to data: Data) throws -> EditResult
}
