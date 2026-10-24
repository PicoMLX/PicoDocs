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
        }
    }
}
