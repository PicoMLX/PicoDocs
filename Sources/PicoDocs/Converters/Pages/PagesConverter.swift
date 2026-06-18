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
//  exports) — plus table content, reconstructed as Markdown grids and placed
//  inline at their attachment points in reading order (falling back to appending
//  them after the body when attachments can't be mapped 1:1; see IWATable).
//  Remaining rich structure (headings, styling, footnotes, inline images),
//  non-text table cells (numbers/dates), the legacy iWork '09 XML format, and
//  ingesting a `.pages` *package directory* (an on-disk bundle, which the
//  FileFetcher currently treats as a folder) are planned follow-ups; this
//  converter raises a clear, actionable error for inputs it can't yet read
//  rather than emitting nothing.
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

        // Decompress every component once. The main story (Document.iwa) is
        // authoritative: if present it must decompress cleanly (corruption →
        // fail) and its text — even if empty — is the body, so we never scavenge
        // stylesheet/header text and pass it off as the body. Auxiliary
        // components that fail to decompress are skipped leniently; they are
        // still gathered whole for table reconstruction (tiles, datalists, and
        // the table model live in separate Tables/*.iwa and CalculationEngine.iwa).
        var streams: [(name: String, stream: [UInt8])] = []
        var documentStream: [UInt8]?
        for component in components {
            try Task.checkCancellation()
            do {
                let stream = try Snappy.decompressIWA(component.bytes)
                if component.name.hasSuffix("Document.iwa") { documentStream = stream }
                streams.append((name: component.name, stream: stream))
            } catch {
                if component.name.hasSuffix("Document.iwa") { throw PicoDocsError.fileCorrupted }
            }
        }

        let allStreams = streams.map(\.stream)
        var sections: [DocumentSection] = []

        // Prefer inline layout: tables placed at their ￼ attachment points, in
        // reading order. Falls back to body text + tables appended after it when
        // the attachments can't be mapped 1:1 (so a table is never dropped).
        if let documentStream,
           let blocks = IWATable.inlineBlocks(documentStream: documentStream, in: allStreams) {
            for block in blocks {
                switch block {
                case .text(let raw):
                    let cleaned = Self.normalize(raw)
                    if !cleaned.isEmpty {
                        sections.append(DocumentSection(kind: .body, markdown: cleaned, sourcePath: "Index/Document.iwa"))
                    }
                case .table(let markdown):
                    sections.append(DocumentSection(kind: .table, markdown: markdown, sourcePath: "Index/Tables"))
                }
            }
        } else {
            // Body text: from Document.iwa if present, else the first component (by
            // name) that yields any text.
            let bodyText: String
            if let documentStream {
                bodyText = IWAArchive.text(in: documentStream)
            } else {
                var firstText = ""
                for entry in streams.sorted(by: { $0.name < $1.name }) {
                    let extracted = IWAArchive.text(in: entry.stream)
                    if !extracted.isEmpty { firstText = extracted; break }
                }
                bodyText = firstText
            }
            let cleaned = Self.normalize(bodyText)
            if !cleaned.isEmpty {
                sections.append(DocumentSection(kind: .body, markdown: cleaned, sourcePath: "Index/Document.iwa"))
            }
            for markdown in IWATable.markdownTables(from: allStreams) {
                sections.append(DocumentSection(kind: .table, markdown: markdown, sourcePath: "Index/Tables"))
            }
        }

        guard !sections.isEmpty else { throw PicoDocsError.emptyDocument }
        let title = (info.filename?.isEmpty == false) ? info.filename : nil
        return ConverterResult(title: title, sections: sections)
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
        // Loose layout is `Index/*.iwa`; scope the scan to that path so a stray
        // outer `.iwa` can't shadow the nested `Index.zip` body below.
        for entry in archive where entry.type == .file
            && entry.path.hasPrefix("Index/") && entry.path.hasSuffix(".iwa") {
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
        // Drop C0/C1 control characters (e.g. Pages' U+0004 section-break sentinel)
        // that aren't real text; tab/newline are kept and handled by the line loop.
        var scalars = unified.unicodeScalars
        scalars.removeAll { scalar in
            let value = scalar.value
            guard value != 0x0A, value != 0x09 else { return false }  // keep newline, tab
            return value <= 0x1F                  // C0 controls
                || (0x7F...0x9F).contains(value)  // C1 controls
                || value == 0xFFFC                // object-replacement placeholder (image/table/etc.)
        }
        unified = String(scalars)
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
        // Cap the reservation hint: `uncompressedSize` is untrusted central-
        // directory data, only validated during extract. Clamp in UInt64 before
        // the Int cast so a ZIP64 size > Int.max can't trap.
        let reserve = Int(min(UInt64(entry.uncompressedSize), 16 * 1024 * 1024))
        var data = Data(capacity: reserve)
        do {
            _ = try archive.extract(entry) { data.append($0) }
        } catch {
            return nil
        }
        return data
    }
}
