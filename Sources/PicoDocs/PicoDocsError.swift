//
//  PicoDocsError.swift
//  PicoDocs
//
//  Created by Ronald Mannak on 1/11/25.
//

import Foundation

public enum PicoDocsError: Error {
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

    /// A `TextEdit.find` was empty. An empty needle would match everywhere /
    /// nowhere, so it's rejected up front.
    case editEmptyFind
    /// `find` does not occur in the document's editable text — typically the
    /// model quoted text that isn't there (or quoted the rendered Markdown/
    /// plaintext rather than `editableText(for:)`).
    case editTextNotFound(find: String)
    /// `find` occurs more than once and `replaceAll` was not set. The caller must
    /// add surrounding context to make it unique, or opt into `replaceAll`.
    case editTextAmbiguous(find: String, occurrences: Int)
    /// Two edits in the same batch target overlapping text; the result would
    /// depend on order, so the whole batch is rejected.
    case editsOverlap
    /// The matched text crosses a boundary this version can't safely edit in
    /// place (a paragraph break, or a hyperlink/field/content-control/tracked-
    /// change/inline-object boundary). `kind` names the boundary.
    case editCrossesBoundary(kind: String)
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
            return String(localized: "The text to find is empty.", bundle: .module)
        case .editTextNotFound:
            return String(localized: "Couldn’t find the text to edit in the document.", bundle: .module)
        case .editTextAmbiguous(_, let occurrences):
            return String(localized: "The text to edit appears \(occurrences) times. Add surrounding context to make it unique, or allow replacing all occurrences.", bundle: .module)
        case .editsOverlap:
            return String(localized: "Two edits overlap the same text.", bundle: .module)
        case .editCrossesBoundary(let kind):
            return String(localized: "The edit crosses a \(kind) boundary, which can’t be changed in place.", bundle: .module)
        }
    }
}
