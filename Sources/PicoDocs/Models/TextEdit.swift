//
//  TextEdit.swift
//  PicoDocs
//
//  The edit-side value types. A `TextEdit` is an exact-match find/replace, the
//  same contract as a code editor's find/replace, chosen over "regenerate the
//  whole document" so an LLM can only change text it quotes verbatim. Editing
//  refuses any edit it can't match exactly and unambiguously, which limits
//  *where and how much* of a document changes. It does not (and cannot) verify
//  that the replacement is correct — that stays the caller's responsibility.
//

import Foundation

/// One exact-match find/replace against a document's editable text.
public struct TextEdit: Sendable, Equatable {

    /// The text to find, quoted verbatim from the editable text. Must be non-empty.
    public var find: String

    /// The text to put in place of `find`.
    public var replace: String

    /// When `false` (the default), `find` must occur exactly once or the edit is
    /// rejected as ambiguous. When `true`, every occurrence is replaced.
    public var replaceAll: Bool

    public init(find: String, replace: String, replaceAll: Bool = false) {
        self.find = find
        self.replace = replace
        self.replaceAll = replaceAll
    }
}

/// The outcome of applying a batch of `TextEdit`s.
public struct EditResult: Sendable, Equatable {

    /// The edited document, in the same format as the input.
    public var data: Data

    /// How many occurrences each edit replaced, in the order the edits were
    /// given (always 1 for an edit without `replaceAll`).
    public var applied: [Int]

    public init(data: Data, applied: [Int]) {
        self.data = data
        self.applied = applied
    }
}
