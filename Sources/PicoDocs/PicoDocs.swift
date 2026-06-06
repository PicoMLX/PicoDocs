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
        registry: DocumentConverterRegistry = .default
    ) async throws -> ConverterResult {
        let info = makeStreamInfo(filename: filename, mimeType: mimeType, url: url, charset: charset)
        let resolved = ContentTypeDetector.classify(data, info: info)
        return try await registry.convert(data, info: resolved)
    }

    /// Convert and render to a specific `ExportFileType` (defaults to Markdown).
    public static func export(
        data: Data,
        filename: String? = nil,
        mimeType: String? = nil,
        url: URL? = nil,
        charset: String.Encoding? = nil,
        to format: ExportFileType = .markdown,
        registry: DocumentConverterRegistry = .default
    ) async throws -> String {
        let result = try await convert(
            data: data,
            filename: filename,
            mimeType: mimeType,
            url: url,
            charset: charset,
            registry: registry
        )
        return try DocumentRenderer.render(result, to: format)
    }

    // MARK: - StreamInfo construction

    static func makeStreamInfo(filename: String?, mimeType: String?, url: URL?, charset: String.Encoding?) -> StreamInfo {
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
            charset: charset ?? encoding(fromMIME: mimeType)
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
