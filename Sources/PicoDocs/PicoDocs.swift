//
//  PicoDocs.swift
//  PicoDocs
//
//  Stateless, Sendable entry point to the conversion engine. Usable from any
//  actor or context (server, CLI, tests) with no `@MainActor` requirement. The
//  `@Observable PicoDocument` type is a thin SwiftUI convenience layered on top
//  of this in a later phase.
//

import Foundation
import UniformTypeIdentifiers

public enum PicoDocsEngine {

    /// Convert raw `data` into the canonical, structured `ConverterResult`.
    ///
    /// Detection runs once up front and is stamped into the `StreamInfo` handed
    /// to converters. Throws `PicoDocsError.documentTypeNotSupported` if no
    /// registered converter accepts the input.
    ///
    /// - Parameter charset: Explicit text encoding for the input. When nil, the
    ///   encoding is parsed from the MIME type's `charset=` parameter if present,
    ///   otherwise converters default to UTF-8.
    public static func convert(
        data: Data,
        filename: String? = nil,
        mimeType: String? = nil,
        url: URL? = nil,
        charset: String.Encoding? = nil,
        enhanceReadability: Bool = true,
        enableOCR: Bool = true,
        sanitizeUnicode: Bool = false,
        registry: DocumentConverterRegistry = .default
    ) async throws -> ConverterResult {
        let info = makeStreamInfo(
            filename: filename,
            mimeType: mimeType,
            url: url,
            charset: charset,
            enhanceReadability: enhanceReadability,
            enableOCR: enableOCR,
            sanitizeUnicode: sanitizeUnicode
        )
        let resolved = ContentTypeDetector.classify(data, info: info)
        let result = try await registry.convert(data, info: resolved)
        // Opt-in post-process (default off): clean the extracted text once so every
        // caller (convert / export / PicoDocument.parse) benefits. NOTE: this runs
        // on already-built Markdown, so it can alter Markdown structure for inputs
        // with special characters in structural spots (line-leading markers,
        // link/image destinations, CSV cell edges) — hence opt-in until a
        // per-converter (pre-Markdown) pass lands. See `UnicodeSanitizer`.
        guard resolved.sanitizeUnicode else { return result }
        let sanitized = UnicodeSanitizer.sanitize(result)
        // Converters reject empty input before this pass, but sanitizing can empty
        // a result that held only removable characters — re-check so we don't
        // surface a blank, "successful" document. (Image-bearing results are never
        // considered empty: their byte carriers live in `.image` sections.)
        if sanitized.markdown().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !sanitized.sections.contains(where: { $0.kind == .image }) {
            throw PicoDocsError.emptyDocument
        }
        return sanitized
    }

    /// Convert and render to a specific `ExportFileType` (defaults to Markdown).
    public static func export(
        data: Data,
        filename: String? = nil,
        mimeType: String? = nil,
        url: URL? = nil,
        charset: String.Encoding? = nil,
        to format: ExportFileType = .markdown,
        enhanceReadability: Bool = true,
        enableOCR: Bool = true,
        sanitizeUnicode: Bool = false,
        registry: DocumentConverterRegistry = .default
    ) async throws -> String {
        let result = try await convert(
            data: data,
            filename: filename,
            mimeType: mimeType,
            url: url,
            charset: charset,
            enhanceReadability: enhanceReadability,
            enableOCR: enableOCR,
            sanitizeUnicode: sanitizeUnicode,
            registry: registry
        )
        return try DocumentRenderer.render(result, to: format)
    }

    // MARK: - Writing (Markdown / ConverterResult -> office files)

    /// Serialize a structured `ConverterResult` into an office file's bytes.
    ///
    /// The inverse of `convert`: detection/conversion produced the canonical
    /// `ConverterResult`; this hands it to the first registered exporter that
    /// accepts `format`. Throws `PicoDocsError.unableToExportToRequestedFormat`
    /// when no exporter accepts (e.g. `.pages`/`.keynote`, which are unimplemented),
    /// and `PicoDocsError.emptyDocument` for empty input.
    public static func write(
        _ result: ConverterResult,
        to format: ExportableFileType,
        registry: DocumentExporterRegistry = .default
    ) throws -> Data {
        // Mirror `convert`'s post-sanitize check: an empty document is an error,
        // *unless* it carries image sections (an image-only doc is valid output).
        if result.markdown().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !result.sections.contains(where: { $0.kind == .image }) {
            throw PicoDocsError.emptyDocument
        }
        return try registry.write(result, format: format)
    }

    /// Convenience: serialize a raw Markdown string into an office file's bytes.
    ///
    /// The string is wrapped into a single-body `ConverterResult` (exactly as the
    /// plain-text/RTF converters model raw input), so LLM Markdown output and a
    /// structured result share one write path. Empty input throws
    /// `PicoDocsError.emptyDocument`.
    public static func write(
        markdown: String,
        title: String? = nil,
        author: String? = nil,
        to format: ExportableFileType,
        registry: DocumentExporterRegistry = .default
    ) throws -> Data {
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PicoDocsError.emptyDocument
        }
        let result = ConverterResult(
            title: title,
            author: author,
            sections: [DocumentSection(kind: .body, markdown: markdown)]
        )
        return try write(result, to: format, registry: registry)
    }

    /// Read bytes in one format and write bytes in another (office -> office),
    /// bridging `convert` and `write`.
    public static func transcode(
        data: Data,
        filename: String? = nil,
        mimeType: String? = nil,
        url: URL? = nil,
        charset: String.Encoding? = nil,
        to format: ExportableFileType,
        enhanceReadability: Bool = true,
        enableOCR: Bool = true,
        sanitizeUnicode: Bool = false,
        convertRegistry: DocumentConverterRegistry = .default,
        exportRegistry: DocumentExporterRegistry = .default
    ) async throws -> Data {
        let result = try await convert(
            data: data,
            filename: filename,
            mimeType: mimeType,
            url: url,
            charset: charset,
            enhanceReadability: enhanceReadability,
            enableOCR: enableOCR,
            sanitizeUnicode: sanitizeUnicode,
            registry: convertRegistry
        )
        return try write(result, to: format, registry: exportRegistry)
    }

    // MARK: - StreamInfo construction

    static func makeStreamInfo(filename: String?, mimeType: String?, url: URL?, charset: String.Encoding?, enhanceReadability: Bool = true, enableOCR: Bool = true, sanitizeUnicode: Bool = false) -> StreamInfo {
        let ext = fileExtension(filename: filename, url: url)
        // Use only the base type (before any ";" parameters) for UTType lookup.
        let baseMIME = mimeType?.split(separator: ";").first.map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        let utType: UTType? = {
            if let baseMIME, let ut = UTType(mimeType: baseMIME) { return ut }
            if let ext, let ut = UTType(filenameExtension: ext) { return ut }
            return nil
        }()
        return StreamInfo(
            filename: filename ?? url?.lastPathComponent,
            fileExtension: ext,
            mimeType: mimeType,
            utType: utType,
            url: url,
            charset: charset ?? encoding(fromMIME: mimeType),
            enhanceReadability: enhanceReadability,
            enableOCR: enableOCR,
            sanitizeUnicode: sanitizeUnicode
        )
    }

    static func fileExtension(filename: String?, url: URL?) -> String? {
        if let filename {
            let ext = (filename as NSString).pathExtension
            if !ext.isEmpty { return ext.lowercased() }
        }
        if let url {
            let ext = url.pathExtension
            if !ext.isEmpty { return ext.lowercased() }
        }
        return nil
    }

    /// Parses a `charset=` parameter from a MIME type (e.g.
    /// "text/html; charset=iso-8859-1") into a `String.Encoding`, so non-UTF-8
    /// text (typically from HTTP responses) decodes correctly instead of failing.
    static func encoding(fromMIME mimeType: String?) -> String.Encoding? {
        guard let mimeType else { return nil }
        for part in mimeType.lowercased().split(separator: ";") {
            let trimmed = String(part).trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("charset=") else { continue }
            let name = String(trimmed.dropFirst("charset=".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            guard !name.isEmpty else { return nil }
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        }
        return nil
    }
}
