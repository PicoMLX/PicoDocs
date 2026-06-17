//
//  PicoDocument+Fetch.swift
//  PicoDocs
//
//  Created by Ronald Mannak on 1/12/25.
//

import Foundation
import UniformTypeIdentifiers

extension PicoDocument {

    /// Fetches the content of a document (and its children, if `recursive`).
    /// On failure the document's `status` is set to `.failed` and the error is rethrown.
    nonisolated
    public func fetch(recursive: Bool = true, progressHandler: ((Progress) -> Void)? = nil) async throws {
        let url = self.originURL
        do {
            let fetcher = Fetcher.fetcher(url: url)
            let (data, utType, urls) = try await fetcher.fetch(progressHandler: progressHandler)

            // Fetch children. A child failure is recorded on the child and is not
            // fatal to the parent. Sequential by design: a child must infer its
            // OWN type (don't pass the parent's utType), and the parent's
            // progressHandler isn't forwarded (it would jump 0->100 per child).
            // TaskGroup parallelism is a possible later optimization (complicated
            // here by the non-Sendable progressHandler).
            if let urls, recursive {
                for childURL in urls {
                    let child = await PicoDocument(url: childURL, parent: self)
                    do {
                        try await child.fetch(recursive: recursive)
                    } catch {
                        await child.setError(error)
                    }
                }
            }
            await updateData(data, utType: utType)
        } catch {
            await setError(error)
            throw error
        }
    }

    /// Parses `originalContent` into an LLM-readable form via `PicoDocsEngine`.
    /// On failure the document's `status` is set to `.failed` and the error is rethrown.
    /// - Parameters:
    ///   - type: Desired export format. Reserved — the engine currently produces
    ///     Markdown sections (the canonical LLM form); multi-format rendering is a
    ///     follow-up.
    ///   - recursive: If true, parses child documents first.
    ///   - enhanceReadability: For HTML, run the Readability extraction pass
    ///     (reader-mode: keep the main article, drop nav/ads/boilerplate). Ignored
    ///     by non-HTML formats. Defaults to `true`.
    ///   - enableOCR: Allow on-device OCR (Apple Vision) for image-only / scanned
    ///     PDF pages and standalone images. Defaults to `true`.
    ///   - sanitizeUnicode: Run extracted text through `UnicodeSanitizer`
    ///     (NFC + invisible/control-character removal, whitespace folding).
    ///     Defaults to `false` (opt-in) — see `StreamInfo.sanitizeUnicode`.
    public nonisolated func parse(to type: ExportFileType? = nil, recursive: Bool = true, enhanceReadability: Bool = true, enableOCR: Bool = true, sanitizeUnicode: Bool = false) async throws {
        // Parse children first. A child failure is recorded on the child and is
        // not fatal to the parent.
        if let children = await self.children, recursive {
            for child in children {
                do {
                    try await child.parse(to: type, recursive: recursive, enhanceReadability: enhanceReadability, enableOCR: enableOCR, sanitizeUnicode: sanitizeUnicode)
                } catch {
                    await child.setError(error)
                }
            }
        }

        do {
            guard let originalContent = await self.originalContent else {
                // A container document (directory, archive) has children but no
                // content of its own; that's a success, not a failure.
                if let children = await self.children, !children.isEmpty {
                    await updateParsedDocument(ConverterResult(), content: [])
                    return
                }
                throw PicoDocsError.emptyDocument
            }
            // Forward the document's resolved type as a MIME hint so a type
            // learned only from a fetched `Content-Type` (e.g. an extension-less
            // image URL) still reaches the right converter. Skip generic
            // catch-alls, though: a `.data` (e.g. from an
            // `application/octet-stream` response) would, via makeStreamInfo's
            // MIME-over-extension precedence, mask an informative filename
            // extension like `photo.png` and suppress classification. Magic-byte
            // detection still wins for formats that have it.
            let utType = await self.utType
            let genericTypes: Set<UTType> = [.data, .content, .item, .folder, .directory]
            let mimeHint = genericTypes.contains(utType) ? nil : utType.preferredMIMEType
            let result = try await PicoDocsEngine.convert(
                data: originalContent,
                filename: self.filename,
                mimeType: mimeHint,
                url: self.originURL,
                enhanceReadability: enhanceReadability,
                enableOCR: enableOCR,
                sanitizeUnicode: sanitizeUnicode
            )
            let exported = try Self.exportedContent(from: result, format: type)
            await updateParsedDocument(result, content: exported)
        } catch {
            await self.setError(error)
            throw error
        }
    }

    // MARK: - Private methods on MainActor

    /// Updates the document's data and metadata.
    private func updateData(_ data: Data?, utType: UTType? = nil) {
        self.dateLastFetched = Date()
        self.originalContent = data
        self.status = .downloaded
        if let utType {
            // Some web URLs have no extension; the type is only known from the
            // MIME type during fetch.
            self.utType = utType
        }
    }

    /// Per-format export of the engine result. Markdown is returned per content
    /// section (so EPUB chapters / XLSX sheets stay individually addressable),
    /// excluding `.image` byte-carrier sections — they're already referenced
    /// inline by the body, so they'd otherwise show as a duplicate image-only
    /// chunk. Other formats are rendered to a single string by `DocumentRenderer`.
    private nonisolated static func exportedContent(from result: ConverterResult, format: ExportFileType?) throws -> [String] {
        switch format ?? .markdown {
        case .markdown:
            return result.sections.filter { $0.kind != .image }.map(\.markdown)
        default:
            return [try DocumentRenderer.render(result, to: format ?? .markdown)]
        }
    }

    /// Maps a `ConverterResult` (and its rendered content) onto the published state.
    private func updateParsedDocument(_ result: ConverterResult, content: [String]) {
        self.exportedContent = content
        self.title = result.title
        self.author = result.author
        self.cover = result.cover
        self.status = .parsed
    }

    /// Sets the document's status to failed with the given error.
    private func setError(_ error: Error) {
        self.status = .failed(error)
    }
}
