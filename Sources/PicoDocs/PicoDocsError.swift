//
//  PicoDocsError.swift
//  PicoDocs
//
//  Created by Ronald Mannak on 1/11/25.
//

import Foundation

// Hashable is declared because the edit cases carry associated values, which
// would otherwise drop the conformance the plain cases got automatically.
public enum PicoDocsError: Error, Hashable {
    case documentTypeNotSupported
    case parsingError
    case emptyDocument
    case noContent
    case noAccess
    case stale
    case invalidURL
    case unableToExportToRequestedFormat
    case fileCorrupted

    // MARK: - Editing

    /// A `TextEdit.find` was empty.
    case editEmptyFind
    /// `find` doesn't occur in the document's editable text: usually the quote
    /// isn't verbatim, or it came from another rendering of the document.
    case editTextNotFound(find: String)
    /// `find` occurs `occurrences` times and `replaceAll` wasn't set.
    case editTextAmbiguous(find: String, occurrences: Int)
    /// Two edits in one batch target overlapping text, so the result would
    /// depend on their order.
    case editsOverlap
    /// The edit touches document structure that can't be changed in place,
    /// either by matching across it or by adding it in the replacement.
    case editCrossesBoundary(kind: EditBoundary)

    /// The structure an edit ran into (see `editCrossesBoundary(kind:)`).
    public enum EditBoundary: String, Hashable, Sendable, CaseIterable {
        case paragraph
        case lineBreak
        case tab
        case hyperlink
        case field
        case contentControl
        case trackedChange
        case hiddenText
        case object
    }
}

extension PicoDocsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .documentTypeNotSupported:
            return String(localized: "This document type isn’t supported.", bundle: .module)
        case .parsingError:
            return String(localized: "The document couldn’t be read.", bundle: .module)
        case .emptyDocument:
            return String(localized: "The document is empty.", bundle: .module)
        case .noContent:
            return String(localized: "The document has no readable content.", bundle: .module)
        case .noAccess:
            return String(localized: "You don’t have permission to open this file.", bundle: .module)
        case .stale:
            return String(localized: "Select the file again to allow access.", bundle: .module)
        case .invalidURL:
            return String(localized: "The URL isn’t valid.", bundle: .module)
        case .unableToExportToRequestedFormat:
            return String(localized: "The file can’t be exported in this format.", bundle: .module)
        case .fileCorrupted:
            return String(localized: "The file is damaged and can’t be opened.", bundle: .module)
        case .editEmptyFind:
            return String(localized: "The text to find is empty. Quote the exact text to change.", bundle: .module)
        case .editTextNotFound:
            return String(localized: "The text to find isn’t in the document. Quote it exactly as it appears in the document’s editable text.", bundle: .module)
        case .editTextAmbiguous(_, let occurrences):
            return String(localized: "The text to find appears \(occurrences) times. Include more surrounding text to make it unique, or replace all occurrences.", bundle: .module)
        case .editsOverlap:
            return String(localized: "Two edits change overlapping text. Combine them into one edit.", bundle: .module)
        case .editCrossesBoundary(let kind):
            switch kind {
            case .paragraph:
                return String(localized: "The edit adds or removes a paragraph break, which can’t be changed in place. Edit one paragraph at a time.", bundle: .module)
            case .lineBreak:
                return String(localized: "The edit adds or removes a line break, which can’t be changed in place. Edit the text on one side of it.", bundle: .module)
            case .tab:
                return String(localized: "The edit adds or removes a tab, which can’t be changed in place. Edit the text on one side of it.", bundle: .module)
            case .hyperlink:
                return String(localized: "The edit touches a hyperlink, which can’t be changed in place.", bundle: .module)
            case .field:
                return String(localized: "The edit touches a field, which can’t be changed in place.", bundle: .module)
            case .contentControl:
                return String(localized: "The edit touches a content control, which can’t be changed in place.", bundle: .module)
            case .trackedChange:
                return String(localized: "The edit touches a tracked change, which can’t be changed in place.", bundle: .module)
            case .hiddenText:
                return String(localized: "The edit spans hidden text, which can’t be changed in place. Edit the text on one side of it.", bundle: .module)
            case .object:
                return String(localized: "The edit spans an embedded object, which can’t be changed in place. Edit the text on one side of it.", bundle: .module)
            }
        }
    }
}
