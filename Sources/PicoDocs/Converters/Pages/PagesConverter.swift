//
//  PagesConverter.swift
//  PicoDocs
//
//  Converts modern Apple Pages (`.pages`, iWork '13+) documents to Markdown by
//  decoding the iWork Archive (IWA) format in-module — no Pages.app, no Apple
//  frameworks, no protobuf/snappy dependency. The package is a ZIP holding
//  `Index/*.iwa` (or a nested `Index.zip`); each `.iwa` is a Snappy-framed
//  protobuf object stream whose TSWP text storages carry the body text.
//
//  Scope (v1): extracts the document's plain text (paragraphs) from the flat,
//  single-file `.pages` ZIP — the common transport form (downloads, mail, Files
//  exports). Rich structure (headings, styling, tables, footnotes, inline
//  images), the legacy iWork '09 XML format, and ingesting a `.pages` *package
//  directory* (an on-disk bundle, which the FileFetcher currently treats as a
//  folder) are planned follow-ups; this converter raises a clear, actionable
//  error for inputs it can't yet read rather than emitting nothing.
//
//  Format references: obriensp/iWorkFileFormat, the SheetJS IWA notes, and
//  Cocoanetics/SwiftText (MIT) — the in-module decode approach here is informed
//  by SwiftText's SwiftTextPages module.
//

import Foundation
import ZIPFoundation

public struct PagesConverter: DocumentConverter {

    public init() {}

    public func accepts(_ info: StreamInfo) -> Bool {
        info.detectedFormat == .pages
    }

    public func convert(_ data: Data, info: StreamInfo) async throws -> ConverterResult {
        guard let archive = Archive(data: data, accessMode: .read) else {
            throw PicoDocsError.fileCorrupted
        }

        // Gather the IWA component streams. Two common on-disk layouts: loose
        // `Index/*.iwa` entries, or a nested `Index.zip` containing them.
        let components = try iwaComponents(in: archive)
        guard !components.isEmpty else {
            // Likely a legacy iWork '09 package (index.xml[.gz]) or an unexpected
            // layout — not supported yet.
            throw PicoDocsError.documentTypeNotSupported
        }

        // The main story lives in Document.iwa and is authoritative: if present it
        // must decompress cleanly (corruption → fail), and its text — even if
        // empty — determines the result, so we never scavenge stylesheet/header
        // text from auxiliary components and pass it off as the body. Only when
        // Document.iwa is absent do we fall back to a best-effort scan.
        var bodyText = ""
        if let main = components.first(where: { $0.name.hasSuffix("Document.iwa") }) {
            try Task.checkCancellation()
            do {
                bodyText = IWAArchive.text(in: try Snappy.decompressIWA(main.bytes))
            } catch {
                throw PicoDocsError.fileCorrupted
            }
        } else {
            for component in components.sorted(by: { $0.name < $1.name }) {
                try Task.checkCancellation()
                guard let stream = try? Snappy.decompressIWA(component.bytes) else { continue }
                let extracted = IWAArchive.text(in: stream)
                if !extracted.isEmpty {
                    bodyText = extracted
                    break
                }
            }
        }

        let cleaned = Self.normalize(bodyText)
        guard !cleaned.isEmpty else { throw PicoDocsError.emptyDocument }

        let section = DocumentSection(
            kind: .body,
            markdown: cleaned,
            sourcePath: "Index/Document.iwa"
        )
        let title = (info.filename?.isEmpty == false) ? info.filename : nil
        return ConverterResult(title: title, sections: [section])
    }

    // MARK: - IWA gathering

    private struct Component {
        let name: String
        let bytes: [UInt8]
    }

    /// Reads the `.iwa` component streams from loose `Index/*.iwa` entries, or —
    /// failing that — from a nested `Index.zip`. A present-but-unreadable main
    /// story (`Document.iwa`) is treated as corruption; auxiliary entries that
    /// fail to extract are skipped leniently.
    private func iwaComponents(in archive: Archive) throws -> [Component] {
        var components: [Component] = []
        for entry in archive where entry.type == .file && entry.path.hasSuffix(".iwa") {
            guard let data = Self.readEntry(archive, path: entry.path) else {
                if entry.path.hasSuffix("Document.iwa") { throw PicoDocsError.fileCorrupted }
                continue
            }
            components.append(Component(name: entry.path, bytes: [UInt8](data)))
        }
        if !components.isEmpty { return components }

        // Nested layout: the IWA streams live inside Index.zip. If that container
        // is present but can't be read/opened, the file is corrupt — not an
        // unsupported layout — so surface that distinctly.
        if archive["Index.zip"] != nil {
            guard let indexZip = Self.readEntry(archive, path: "Index.zip"),
                  let inner = Archive(data: indexZip, accessMode: .read) else {
                throw PicoDocsError.fileCorrupted
            }
            for entry in inner where entry.type == .file && entry.path.hasSuffix(".iwa") {
                guard let data = Self.readEntry(inner, path: entry.path) else {
                    if entry.path.hasSuffix("Document.iwa") { throw PicoDocsError.fileCorrupted }
                    continue
                }
                components.append(Component(name: entry.path, bytes: [UInt8](data)))
            }
        }
        return components
    }

    // MARK: - Text normalization

    /// Folds iWork's line/paragraph separators to `\n`, trims each line, and
    /// collapses runs of blank lines so the body reads as clean paragraphs.
    static func normalize(_ text: String) -> String {
        var unified = text
        for separator in ["\r\n", "\r", "\u{2028}", "\u{2029}", "\u{000B}", "\u{000C}"] {
            unified = unified.replacingOccurrences(of: separator, with: "\n")
        }
        let inlineWhitespace = CharacterSet(charactersIn: " \t")
        var out: [String] = []
        var pendingBlank = false
        for rawLine in unified.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: inlineWhitespace)
            if line.isEmpty {
                pendingBlank = true
            } else {
                if pendingBlank && !out.isEmpty { out.append("") }
                pendingBlank = false
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - ZIP helper

    static func readEntry(_ archive: Archive, path: String) -> Data? {
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let entry = archive[cleanPath] else { return nil }
        var data = Data(capacity: Int(entry.uncompressedSize))
        do {
            _ = try archive.extract(entry) { data.append($0) }
        } catch {
            return nil
        }
        return data
    }
}
