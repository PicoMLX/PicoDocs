//
//  KeynoteConverter.swift
//  PicoDocs
//
//  Converts modern Apple Keynote (`.key`, iWork '13+) presentations to Markdown,
//  reusing the in-module iWork Archive (IWA) decoder built for Pages — Snappy +
//  protobuf-wire + `IWAArchive` (no Keynote.app, no Apple frameworks, no
//  protobuf/snappy dependency). A `.key` is the same ZIP/IWA container; slides
//  live in `Index/Slide<N>.iwa` (loose, or inside a nested `Index.zip`), with
//  `MasterSlide-*.iwa` masters and `Document.iwa` presentation metadata.
//
//  Scope (v1): each slide's body text (the `kind == 0` TSWP storages, same
//  extraction as Pages) becomes one section, in slide-number order. Master/theme
//  template text and presenter notes are excluded; speaker notes, per-slide
//  titles vs body, ordering via the document object graph, tables, and inline
//  images are follow-ups — best validated against a real `.key` fixture (the
//  Pages real-file pass confirmed body = `kind 0`; slide-text kinds should be
//  re-confirmed the same way).
//
//  NOTE: `readEntry` / `normalize` mirror PagesConverter; a shared iWork helper
//  is a planned cleanup once both converters have settled.
//

import Foundation
import ZIPFoundation

public struct KeynoteConverter: DocumentConverter {

    public init() {}

    public func accepts(_ info: StreamInfo) -> Bool {
        info.detectedFormat == .keynote
    }

    public func convert(_ data: Data, info: StreamInfo) async throws -> ConverterResult {
        guard let archive = Archive(data: data, accessMode: .read) else {
            throw PicoDocsError.fileCorrupted
        }
        let components = try iwaComponents(in: archive)
        guard !components.isEmpty else {
            throw PicoDocsError.documentTypeNotSupported
        }

        // One section per slide (Index/Slide<N>.iwa), in slide-number order,
        // excluding MasterSlide* template text.
        let slides = components
            .filter { Self.isSlide($0.name) }
            .sorted { Self.slideOrder($0.name) < Self.slideOrder($1.name) }

        var sections: [DocumentSection] = []
        for (index, slide) in slides.enumerated() {
            try Task.checkCancellation()
            // A slide's stream is primary content: a decompression failure is
            // corruption, not an empty slide — fail rather than silently drop it.
            let stream: [UInt8]
            do {
                stream = try Snappy.decompressIWA(slide.bytes)
            } catch {
                throw PicoDocsError.fileCorrupted
            }
            let text = Self.normalize(IWAArchive.text(in: stream))
            guard !text.isEmpty else { continue }
            // slideNumber reflects the slide's position in deck order (by Slide<N>
            // filename), not the count of emitted sections, so skipping an empty
            // slide doesn't renumber the slides after it.
            sections.append(DocumentSection(
                kind: .slide,
                markdown: text,
                sourcePath: slide.name,
                slideNumber: index + 1
            ))
        }

        // Fallback: no per-slide text found (unexpected layout) — gather body text
        // from all non-master components as a single section rather than emit
        // nothing.
        if sections.isEmpty {
            var pieces: [String] = []
            for component in components.filter({ !Self.isMaster($0.name) }).sorted(by: { $0.name < $1.name }) {
                try Task.checkCancellation()
                guard let stream = try? Snappy.decompressIWA(component.bytes) else { continue }
                let text = IWAArchive.text(in: stream)
                if !text.isEmpty { pieces.append(text) }
            }
            let cleaned = Self.normalize(pieces.joined(separator: "\n\n"))
            guard !cleaned.isEmpty else { throw PicoDocsError.emptyDocument }
            sections = [DocumentSection(kind: .body, markdown: cleaned)]
        }

        let title = (info.filename?.isEmpty == false) ? info.filename : nil
        return ConverterResult(title: title, sections: sections)
    }

    // MARK: - Slide identification

    /// Slide components are `Slide<N>.iwa` (e.g. `Index/Slide1.iwa`). The
    /// `MasterSlide` prefix is deliberately excluded.
    static func isSlide(_ path: String) -> Bool {
        let base = path.split(separator: "/").last.map(String.init) ?? path
        return base.hasPrefix("Slide") && base.hasSuffix(".iwa")
    }

    static func isMaster(_ path: String) -> Bool {
        let base = path.split(separator: "/").last.map(String.init) ?? path
        return base.hasPrefix("MasterSlide")
    }

    /// The trailing slide number from the filename (`Slide12.iwa` → 12), for
    /// ordering. Falls back to `Int.max` so unnumbered names sort last/stably.
    static func slideOrder(_ path: String) -> Int {
        let base = path.split(separator: "/").last.map(String.init) ?? path
        let digits = base.drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits) ?? Int.max
    }

    // MARK: - IWA gathering

    private typealias Component = (name: String, bytes: [UInt8])

    /// Reads the `.iwa` component streams from loose `Index/*.iwa` entries, or —
    /// failing that — from a nested `Index.zip` (the common Keynote layout).
    private func iwaComponents(in archive: Archive) throws -> [Component] {
        var components: [Component] = []
        for entry in archive where entry.type == .file
            && entry.path.hasPrefix("Index/") && entry.path.hasSuffix(".iwa") {
            guard let data = Self.readEntry(archive, path: entry.path) else {
                // A present-but-unreadable slide is corruption (primary content);
                // auxiliary components are skipped leniently.
                if Self.isSlide(entry.path) { throw PicoDocsError.fileCorrupted }
                continue
            }
            components.append((entry.path, [UInt8](data)))
        }
        if !components.isEmpty { return components }

        // Nested layout: slides live inside Index.zip. If that container is present
        // but can't be read/opened, the file is corrupt — not an unsupported
        // layout — so surface that distinctly rather than failing silently.
        if archive["Index.zip"] != nil {
            guard let indexZip = Self.readEntry(archive, path: "Index.zip"),
                  let inner = Archive(data: indexZip, accessMode: .read) else {
                throw PicoDocsError.fileCorrupted
            }
            for entry in inner where entry.type == .file && entry.path.hasSuffix(".iwa") {
                guard let data = Self.readEntry(inner, path: entry.path) else {
                    if Self.isSlide(entry.path) { throw PicoDocsError.fileCorrupted }
                    continue
                }
                components.append((entry.path, [UInt8](data)))
            }
        }
        return components
    }

    // MARK: - Helpers (mirror PagesConverter; see file note)

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

    /// Folds iWork's line/paragraph separators to `\n`, drops C0/C1 control
    /// characters, trims each line, and collapses runs of blank lines.
    static func normalize(_ text: String) -> String {
        var unified = text
        for separator in ["\r\n", "\r", "\u{2028}", "\u{2029}", "\u{000B}", "\u{000C}"] {
            unified = unified.replacingOccurrences(of: separator, with: "\n")
        }
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
}
