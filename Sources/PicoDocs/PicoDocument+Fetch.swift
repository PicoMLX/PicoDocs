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
            // fatal to the parent.
            if let urls, recursive {
                for childURL in urls {
                    let child = await PicoDocument(url: childURL, utType: utType, parent: self)
                    do {
                        try await child.fetch(recursive: recursive, progressHandler: progressHandler)
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
    ///   - enhanceReadability: Reserved for the optional Readability cleanup pass.
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
                throw PicoDocsError.emptyDocument
            }
            let result = try await PicoDocsEngine.convert(
                data: originalContent,
                filename: self.filename,
                url: self.originURL
            )
            await updateParsedDocument(result)
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

    /// Maps a `ConverterResult` from the engine onto the document's published state.
    private func updateParsedDocument(_ result: ConverterResult) {
        self.exportedContent = result.sections.map(\.markdown)
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
