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
        // considered empty: their byte carriers live in `.image` sections. Empty
        // worksheet sections also represent valid workbook structure.)
        if sanitized.markdown().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !sanitized.sections.contains(where: { $0.kind == .image || $0.kind == .sheet || $0.kind == .slide }) {
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
        guard !isEmptyForExport(result) else { throw PicoDocsError.emptyDocument }
        return try registry.write(result, format: format)
    }

    /// Custom writers may consume covers; built-ins validate their own support.
    static func isEmptyForExport(_ result: ConverterResult, includingCover: Bool = true) -> Bool {
        let isEmpty = !result.sections.lazy.filter { $0.kind != .image }.contains { section in
            section.markdown.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) }
        }
        let hasImages = result.sections.contains { $0.kind == .image }
        let hasCover = includingCover && !(result.cover?.isEmpty ?? true)
        let hasCSV = result.sections.contains { !($0.metadata["csv"] ?? "").isEmpty }
        let hasSheets = result.sections.contains { $0.kind == .sheet }
        let hasSlides = result.sections.contains { $0.kind == .slide || $0.slideNumber != nil }
        return isEmpty && !hasImages && !hasCover && !hasCSV && !hasSheets && !hasSlides
    }

    /// Inserts a `.body` section beside each image carrier with an inline `![alt](reference)` for each `.image`
    /// carrier, so an image-only result renders its images instead of a blank
    /// document. `reference` is the carrier's full source path — the exporters'
    /// primary image-index key — so two carriers that share a basename
    /// (`charts/logo.png` vs `headers/logo.png`) each resolve to their own bytes;
    /// it falls back to the title. A carrier with neither is given a generated
    /// `image-<n>.<ext>` name (extension from its MIME), assigned as its `sourcePath`
    /// so the exporter's index derives the identical lookup key — so even an
    /// unnamed, MIME-only carrier is embedded rather than silently dropped.
    static func withSynthesizedImageReferences(_ result: ConverterResult) -> ConverterResult {
        guard result.markdown().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return result }
        var sections = result.sections
        // Every Office writer projects image-only carriers through this path.
        // Clean identities before choosing visible labels or generated fallbacks.
        func visibleIdentity(_ source: String) -> String? {
            let clean = OOXMLPackageWriter.xmlSafeText(source)
            return clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : clean
        }
        for index in sections.indices where sections[index].kind == .image {
            sections[index].title = sections[index].title.flatMap(visibleIdentity)
            sections[index].sourcePath = sections[index].sourcePath.flatMap(visibleIdentity)
        }
        var refs: [Int: DocumentSection] = [:]
        var generatedCount = 0
        let identities = sections.filter { $0.kind == .image }.compactMap {
            [$0.sourcePath, $0.title].compactMap { $0 }.first { !$0.isEmpty }
        }
        let counts = Dictionary(identities.map { ($0, 1) }, uniquingKeysWith: +)
        var used = Set(identities)
        for index in sections.indices where sections[index].kind == .image {
            let section = sections[index]
            var reference = [section.sourcePath, section.title]
                .compactMap { $0 }
                .first { !$0.isEmpty }
            if reference == nil || counts[reference ?? "", default: 0] > 1 || reference?.contains(where: { $0.isNewline }) == true {
                let ext = OfficeMediaType.fileExtension(forMIME: section.metadata["mimeType"] ?? "")
                var generated: String
                repeat {
                    generatedCount += 1
                    generated = "image-\(generatedCount).\(ext)"
                } while used.contains(generated)
                used.insert(generated)
                sections[index].sourcePath = generated
                reference = generated
            }
            guard let reference else { continue }
            let alt = MarkdownBlockParser.normalizedLineEndings(section.title.flatMap { $0.isEmpty ? nil : $0 } ?? (reference as NSString).lastPathComponent).replacingOccurrences(of: "\n", with: " ")
            refs[index] = DocumentSection(
                kind: .body,
                markdown: "![\(Self.escapeMarkdown(alt, "\\`*_{}[]<>"))](<\(Self.escapeMarkdown(reference, "\\<>"))>)",
                slideNumber: section.slideNumber
            )
        }
        guard !refs.isEmpty else { return result }
        var ordered: [DocumentSection] = []
        ordered.reserveCapacity(sections.count + refs.count)
        for (index, section) in sections.enumerated() {
            ordered.append(section)
            if let reference = refs[index] { ordered.append(reference) }
        }
        return ConverterResult(title: result.title, author: result.author, cover: result.cover, sections: ordered)
    }

    /// Backslash-escapes each character of `special` in `text`, so a synthesized
    /// image label/destination containing `]` or `)` survives `MarkdownInlineParser`.
    private static func escapeMarkdown(_ text: String, _ special: String) -> String {
        var out = ""
        for ch in text {
            if special.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
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
