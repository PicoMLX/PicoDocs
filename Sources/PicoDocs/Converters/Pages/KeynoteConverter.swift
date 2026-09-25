//
//  KeynoteConverter.swift
//  PicoDocs
//
//  Converts modern Apple Keynote (`.key`, iWork '13+) presentations to Markdown,
//  reusing the in-module iWork Archive (IWA) decoder built for Pages — Snappy +
//  protobuf-wire + `IWAArchive` (no Keynote.app, no Apple frameworks, no
//  protobuf/snappy dependency). A `.key` is the same ZIP/IWA container; slides
//  live in `Index/Slide*.iwa` (loose, or inside a nested `Index.zip`), with
//  `MasterSlide-*.iwa` / `TemplateSlide-*.iwa` masters and `Document.iwa`
//  presentation metadata (incl. the slide tree).
//
//  Scope: each slide's body text (the `kind == 0` TSWP storages, same extraction
//  as Pages) becomes one section, in deck order resolved from `Document.iwa`'s
//  slide tree. Master/template slides are excluded, and presenter notes (`kind`
//  4) are excluded by the `kind == 0` filter — both confirmed against a real
//  `.key` (kinds: 0=body, 1=header/footer, 4=note, 5=cell). Tables are
//  reconstructed (see IWATable) and placed with the slide that owns them (by
//  reachability from the slide object); per-slide title-vs-body structure and
//  inline images remain follow-ups.
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

        // Decompress every component once and reuse the streams throughout. A
        // slide's stream is primary content, so its failure is corruption;
        // auxiliary streams are skipped leniently.
        var streams: [(name: String, stream: [UInt8])] = []
        for component in components {
            try Task.checkCancellation()
            do {
                streams.append((component.name, try Snappy.decompressIWA(component.bytes)))
            } catch {
                if Self.isSlide(component.name) { throw PicoDocsError.fileCorrupted }
            }
        }

        // Per-slide KN.SlideArchive id (to resolve deck order from the document's
        // slide tree) and body text (kind == 0; presenter notes are kind 4 and so
        // already excluded).
        var slides: [(name: String, id: UInt64, text: String)] = []
        for entry in streams where Self.isSlide(entry.name) {
            try Task.checkCancellation()
            let objects = IWAArchive.objects(in: entry.stream)
            let slideID = objects.first { $0.type == Self.slideArchiveType }?.identifier ?? 0
            slides.append((entry.name, slideID, Self.normalize(IWAArchive.text(from: objects))))
        }

        // Order by the document's slide tree (authoritative); fall back to
        // slide-archive id, then filename, when it can't be resolved.
        let documentStream = streams.first { $0.name.hasSuffix("Document.iwa") }?.stream
        let deck = Self.deckOrder(documentStream: documentStream, slideIDs: Set(slides.map(\.id)))
        let rank = Dictionary(deck.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = slides.sorted { lhs, rhs in
            let lr = rank[lhs.id] ?? Int.max
            let rr = rank[rhs.id] ?? Int.max
            if lr != rr { return lr < rr }
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            // Final fallback (no slide tree, ids unresolved): numeric filename
            // order, so Slide2 precedes Slide10 (lexicographic would not).
            let lo = Self.slideOrder(lhs.name)
            let ro = Self.slideOrder(rhs.name)
            if lo != ro { return lo < ro }
            return lhs.name < rhs.name
        }

        // Master/template object ids, so the table reachability walk can avoid
        // descending into theme subgraphs.
        var masterObjectIDs: Set<UInt64> = []
        for entry in streams where Self.isMaster(entry.name) {
            for object in IWAArchive.objects(in: entry.stream) { masterObjectIDs.insert(object.identifier) }
        }
        // Tables grouped by the slide that owns them (reachable from the slide
        // object, not from master/template subgraphs), so each renders right after
        // its slide rather than appended at the end of the deck.
        let tablesForSlide = IWATable.tablesBySlide(
            slideIDs: ordered.map(\.id), in: streams.map(\.stream), excludingSubgraphs: masterObjectIDs
        )

        var sections: [DocumentSection] = []
        var emittedSlideText = false
        for (index, slide) in ordered.enumerated() {
            // slideNumber is the deck position, so skipping an empty slide leaves a
            // gap rather than renumbering the slides after it. A slide's tables are
            // emitted right after its text, sharing the slide number.
            let slideTables = tablesForSlide[slide.id] ?? []
            guard !slide.text.isEmpty || !slideTables.isEmpty else { continue }
            if !slide.text.isEmpty {
                sections.append(DocumentSection(
                    kind: .slide,
                    markdown: slide.text,
                    sourcePath: slide.name,
                    slideNumber: index + 1
                ))
                emittedSlideText = true
            }
            for markdown in slideTables {
                sections.append(DocumentSection(
                    kind: .table,
                    markdown: markdown,
                    sourcePath: slide.name,
                    slideNumber: index + 1
                ))
            }
        }

        // Fallback: no per-slide *text* found (unexpected layout) — recover body
        // text from the non-master components. Gated on whether slide text was
        // emitted, not on `sections`, so a deck that yielded only tables still
        // recovers its text; the recovered body leads, ahead of any table sections.
        if !emittedSlideText {
            var pieces: [String] = []
            for entry in streams.filter({ !Self.isMaster($0.name) }).sorted(by: { $0.name < $1.name }) {
                let text = IWAArchive.text(in: entry.stream)
                if !text.isEmpty { pieces.append(text) }
            }
            let cleaned = Self.normalize(pieces.joined(separator: "\n\n"))
            if !cleaned.isEmpty { sections.insert(DocumentSection(kind: .body, markdown: cleaned), at: 0) }
        }

        guard !sections.isEmpty else { throw PicoDocsError.emptyDocument }
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
        return base.hasPrefix("MasterSlide") || base.hasPrefix("TemplateSlide")
    }

    /// The trailing number in a `Slide<N>.iwa` filename (`Slide12.iwa` → 12), used
    /// only as the final ordering fallback when the slide tree and slide ids can't
    /// be resolved. Numeric so `Slide2` precedes `Slide10`; unnumbered names
    /// (e.g. `Slide.iwa`) sort last.
    static func slideOrder(_ path: String) -> Int {
        let base = path.split(separator: "/").last.map(String.init) ?? path
        let digits = base.drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits) ?? Int.max
    }

    /// KN.SlideArchive message type — the slide object inside each `Slide*.iwa`,
    /// whose identifier the document's slide tree references (confirmed against a
    /// real `.key`).
    static let slideArchiveType: UInt64 = 5

    /// Resolves deck order from `Document.iwa`'s slide tree: each tree node
    /// references one slide, and the tree references its nodes in order. Returns
    /// slide ids in deck order, or empty if it can't be resolved (caller then
    /// falls back to slide-id / filename order). Structural — it identifies the
    /// tree and nodes via the reference graph rather than hard-coding their
    /// message types; only the slide-archive type above is fixed.
    private static func deckOrder(documentStream: [UInt8]?, slideIDs: Set<UInt64>) -> [UInt64] {
        guard !slideIDs.isEmpty, let documentStream else { return [] }
        let objects = IWAArchive.objects(in: documentStream)
        // A slide-tree node references exactly one slide; map node id -> slide id.
        var nodeToSlide: [UInt64: UInt64] = [:]
        for object in objects {
            if let slideID = object.references.first(where: { slideIDs.contains($0) }) {
                nodeToSlide[object.identifier] = slideID
            }
        }
        guard !nodeToSlide.isEmpty else { return [] }
        // The slide tree is the object referencing the most of those nodes; its
        // node references, in order, give the deck order.
        var orderedNodes: [UInt64] = []
        for object in objects {
            let nodes = object.references.filter { nodeToSlide[$0] != nil }
            if nodes.count > orderedNodes.count { orderedNodes = nodes }
        }
        return orderedNodes.compactMap { nodeToSlide[$0] }
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
