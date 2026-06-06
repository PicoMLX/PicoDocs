//
//  DocumentRenderer.swift
//  PicoDocs
//
//  Renders a (canonical, structured) `ConverterResult` to a requested
//  `ExportFileType`. Keeping output formatting here — rather than branching on
//  format inside each converter — keeps the converter contract simple.
//
//  Markdown is the canonical form; other formats are derived. Only Markdown is
//  implemented so far. Notably, plaintext is intentionally *unsupported* rather
//  than returning raw Markdown: once converters emit real Markdown syntax, a
//  plaintext export must strip it, so emitting markup would be incorrect.
//

import Foundation

public enum DocumentRenderer {

    public static func render(_ result: ConverterResult, to format: ExportFileType) throws -> String {
        switch format {
        case .markdown:
            return result.sections.map(\.markdown).joined(separator: "\n\n")
        case .plaintext, .html, .xml, .csv:
            // TODO: implement these renderers alongside the converters that emit
            // the structured Markdown/tables they need. Plaintext requires a
            // Markdown-stripping pass; returning raw Markdown here would leak
            // syntax (headings, links, emphasis) into a "plaintext" export.
            throw PicoDocsError.unableToExportToRequestedFormat
        }
    }
}
