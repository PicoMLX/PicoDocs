//
//  DocumentRenderer.swift
//  PicoDocs
//
//  Renders a (canonical, structured) `ConverterResult` to a requested
//  `ExportFileType`. Keeping output formatting here — rather than branching on
//  format inside each converter — keeps the converter contract simple.
//
//  Markdown is the canonical form; other formats are derived. For now only
//  Markdown and plaintext are implemented; HTML/CSV/XML renderers land with the
//  converters that produce the structured tables/headings they need.
//

import Foundation

public enum DocumentRenderer {

    public static func render(_ result: ConverterResult, to format: ExportFileType) throws -> String {
        switch format {
        case .markdown, .plaintext:
            return result.sections.map(\.markdown).joined(separator: "\n\n")
        case .html, .xml, .csv:
            throw PicoDocsError.unableToExportToRequestedFormat
        }
    }
}
