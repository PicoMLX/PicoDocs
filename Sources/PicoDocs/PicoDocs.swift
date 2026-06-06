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

public enum PicoDocs {

    /// Convert raw `data` into the canonical, structured `ConverterResult`.
    ///
    /// Detection runs once up front and is stamped into the `StreamInfo` handed
    /// to converters. Throws `PicoDocsError.documentTypeNotSupported` if no
    /// registered converter accepts the input.
    public static func convert(
        data: Data,
        filename: String? = nil,
        mimeType: String? = nil,
        url: URL? = nil,
        registry: DocumentConverterRegistry = .default
    ) async throws -> ConverterResult {
        let info = makeStreamInfo(filename: filename, mimeType: mimeType, url: url)
        let resolved = ContentTypeDetector.classify(data, info: info)
        return try await registry.convert(data, info: resolved)
    }

    /// Convert and render to a specific `ExportFileType` (defaults to Markdown).
    public static func export(
        data: Data,
        filename: String? = nil,
        mimeType: String? = nil,
        url: URL? = nil,
        to format: ExportFileType = .markdown,
        registry: DocumentConverterRegistry = .default
    ) async throws -> String {
        let result = try await convert(
            data: data,
            filename: filename,
            mimeType: mimeType,
            url: url,
            registry: registry
        )
        return try DocumentRenderer.render(result, to: format)
    }

    // MARK: - StreamInfo construction

    static func makeStreamInfo(filename: String?, mimeType: String?, url: URL?) -> StreamInfo {
        let ext = fileExtension(filename: filename, url: url)
        let utType: UTType? = {
            if let mimeType, let ut = UTType(mimeType: mimeType) { return ut }
            if let ext, let ut = UTType(filenameExtension: ext) { return ut }
            return nil
        }()
        return StreamInfo(
            filename: filename ?? url?.lastPathComponent,
            fileExtension: ext,
            mimeType: mimeType,
            utType: utType,
            url: url
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
}
