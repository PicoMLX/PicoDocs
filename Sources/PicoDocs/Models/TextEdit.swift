//
//  TextEdit.swift
//  PicoDocs
//
//  The edit-side value types. A `TextEdit` is an exact-match find/replace — the
//  same contract as a code editor's find/replace — chosen deliberately over
//  "regenerate the whole document" so an LLM can only change text it quotes
//  verbatim. The engine refuses any edit it can't match exactly and
//  unambiguously, which constrains *where and how much* of the document changes.
//  It does not (and cannot) verify that the replacement is factually correct —
//  that stays the caller's responsibility.
//

import Foundation

/// A single exact-match find/replace against a document's editable text (the
/// string returned by `PicoDocsEngine.editableText(for:)`).
public struct TextEdit: Sendable, Equatable, Codable {

    /// The exact text to find, quoted verbatim from the editable-text snapshot.
    /// Must be non-empty.
    public var find: String

    /// The text to substitute for `find`.
    public var replace: String

    /// When `false` (the default) `find` must occur exactly once, or the edit is
    /// rejected as ambiguous; when `true`, every non-overlapping occurrence is
    /// replaced.
    public var replaceAll: Bool

    public init(find: String, replace: String, replaceAll: Bool = false) {
        self.find = find
        self.replace = replace
        self.replaceAll = replaceAll
    }
}

/// What one `TextEdit` actually did, for callers that want to confirm/report.
public struct AppliedEdit: Sendable, Equatable, Codable {
    public var find: String
    public var replace: String
    /// Number of occurrences replaced (always 1 unless `replaceAll`).
    public var occurrences: Int

    public init(find: String, replace: String, occurrences: Int) {
        self.find = find
        self.replace = replace
        self.occurrences = occurrences
    }
}

/// The result of applying a batch of edits: the edited document in the **same
/// binary format as the input**, plus a per-edit summary.
public struct EditResult: Sendable, Equatable {

    /// The edited document's bytes, same format as the input.
    public var data: Data

    /// One entry per input `TextEdit`, in order.
    public var applied: [AppliedEdit]

    public init(data: Data, applied: [AppliedEdit]) {
        self.data = data
        self.applied = applied
    }
}
