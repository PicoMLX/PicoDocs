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
    public nonisolated func parse(to type: ExportFileType? = nil, recursive: Bool = true, enhanceReadability: Bool = true) async throws {
        // Parse children first. A child failure is recorded on the child and is
        // not fatal to the parent.
        if let children = await self.children, recursive {
            for child in children {
                do {
                    try await child.parse(to: type, recursive: recursive, enhanceReadability: enhanceReadability)
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
            let result = try await PicoDocsEngine.convert(
                data: originalContent,
                filename: self.filename,
                url: self.originURL,
                enhanceReadability: enhanceReadability
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

    /// Renders the engine result to the requested export format. Markdown (the
    /// canonical form) is returned per-section; other formats go through
    /// `DocumentRenderer`, which throws `unableToExportToRequestedFormat` for the
    /// formats not yet implemented (html/xml/csv) rather than silently returning
    /// Markdown.
    private nonisolated static func exportedContent(from result: ConverterResult, format: ExportFileType?) throws -> [String] {
        switch format ?? .markdown {
        case .markdown:
            return result.sections.map(\.markdown)
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
