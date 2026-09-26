//
//  ExportableFileType.swift
//  PicoDocs
//
//  The binary office formats PicoDocs can *write* (the reverse of the read-only
//  `DocumentConverter` flow). Kept separate from `ExportFileType` — which is the
//  LLM-friendly *text* output set (markdown/html/xml/csv/plaintext) returned as a
//  `String` — so "returns String" and "returns Data" never conflate at the API.
//
//  Use in `PicoDocsEngine.write(...)`.
//

import Foundation

public enum ExportableFileType: String, Equatable, Codable, CaseIterable, Identifiable, Sendable {
    case docx
    case rtf
    case xlsx
    case pptx
    case pages
    case keynote

    public var id: String { rawValue }

    /// The conventional file extension (matches the raw value).
    public var fileExtension: String { rawValue }

    /// The format's MIME type.
    public var mimeType: String {
        switch self {
        case .docx: return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case .xlsx: return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case .pptx: return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case .rtf:  return "application/rtf"
        case .pages: return "application/x-iwork-pages-sffpages"
        case .keynote: return "application/x-iwork-keynote-sffkey"
        }
    }

    /// Whether a built-in exporter exists for this format *on the current platform*.
    /// `.rtf` is written through `NSAttributedString`, so it's only available where
    /// AppKit/UIKit is — matching the registry, which registers the RTF exporter
    /// under the same condition (`DocumentExporterRegistry.makeDefault`). iWork
    /// (Pages/Keynote) is a research spike — writing valid third-party iWork is
    /// unsupported — so it always reports `false` and `write(...)` throws
    /// `unableToExportToRequestedFormat`.
    public var isImplemented: Bool {
        switch self {
        case .docx, .xlsx, .pptx: return true
        case .rtf:
            #if canImport(AppKit) || canImport(UIKit)
            return true
            #else
            return false
            #endif
        case .pages, .keynote: return false
        }
    }
}
