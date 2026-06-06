//
//  EPUBConverter.swift
//  PicoDocs
//
//  Converts EPUB to Markdown: unzip with ZIPFoundation, read the OPF for spine
//  order + metadata, and render each chapter's XHTML through the shared
//  HTMLToMarkdown walker. Fully in-memory (Data in), cross-platform, and free of
//  the old EPUBKit + NSAttributedString path.
//

import Foundation
import ZIPFoundation
import SwiftSoup

public struct EPUBConverter: DocumentConverter {

    public init() {}

    public func accepts(_ info: StreamInfo) -> Bool {
        info.detectedFormat == .epub
    }

    public func convert(_ data: Data, info: StreamInfo) async throws -> ConverterResult {
        guard let archive = Archive(data: data, accessMode: .read) else {
            throw PicoDocsError.fileCorrupted
        }

        // 1. META-INF/container.xml -> path to the OPF package document.
        guard let containerData = Self.readEntry(archive, path: "META-INF/container.xml"),
              let containerXML = Self.decodeText(containerData),
              let opfPath = try Self.opfPath(fromContainer: containerXML) else {
            throw PicoDocsError.fileCorrupted
        }

        // 2. Parse the OPF: metadata, manifest (id -> href), spine (order).
        guard let opfData = Self.readEntry(archive, path: opfPath),
              let opfXML = Self.decodeText(opfData) else {
            throw PicoDocsError.fileCorrupted
        }
        let opf = try SwiftSoup.parse(opfXML, "", SwiftSoup.Parser.xmlParser())
        let opfDir = (opfPath as NSString).deletingLastPathComponent

        let title = (try? opf.getElementsByTag("dc:title").first()?.text())
            ?? (try? opf.getElementsByTag("title").first()?.text())
        let author = (try? opf.getElementsByTag("dc:creator").first()?.text())
            ?? (try? opf.getElementsByTag("creator").first()?.text())

        var manifest: [String: String] = [:]
        for item in (try? opf.getElementsByTag("item").array()) ?? [] {
            guard let id = try? item.attr("id"), let href = try? item.attr("href"),
                  !id.isEmpty, !href.isEmpty else { continue }
            manifest[id] = href
        }

        // 3. Walk the spine in order, rendering each chapter to Markdown.
        var sections: [DocumentSection] = []
        for itemref in (try? opf.getElementsByTag("itemref").array()) ?? [] {
            try Task.checkCancellation()
            // Skip non-linear spine items: auxiliary content (popups, end matter,
            // alternate views) that's outside the primary reading order.
            if (try? itemref.attr("linear"))?.lowercased() == "no" { continue }
            guard let idref = try? itemref.attr("idref"), let href = manifest[idref] else { continue }
            let entryPath = Self.resolve(path: href, relativeTo: opfDir)
            guard let chapterData = Self.readEntry(archive, path: entryPath),
                  let chapterHTML = Self.decodeText(chapterData) else { continue }
            guard let (chapterTitle, markdown) = try? HTMLToMarkdown.convert(html: chapterHTML) else { continue }
            let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            sections.append(DocumentSection(
                title: chapterTitle,
                kind: .chapter,
                markdown: trimmed,
                sourcePath: entryPath
            ))
        }

        guard !sections.isEmpty else { throw PicoDocsError.emptyDocument }

        let resolvedTitle = (title?.isEmpty == false) ? title : info.filename
        let cover = Self.coverData(archive: archive, opf: opf, manifest: manifest, opfDir: opfDir)
        return ConverterResult(
            title: resolvedTitle,
            author: (author?.isEmpty == false) ? author : nil,
            cover: cover,
            sections: sections
        )
    }

    // MARK: - Archive / OPF helpers

    static func readEntry(_ archive: Archive, path: String) -> Data? {
        // ZIP entries have no leading slash; strip one so resolved paths still match.
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

    /// Decodes text trying UTF-8, then UTF-16 (BOM-aware), then ISO Latin-1 as a
    /// never-fails fallback, so non-UTF-8 EPUB parts aren't silently dropped.
    static func decodeText(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let utf16 = String(data: data, encoding: .utf16) { return utf16 }
        return String(data: data, encoding: .isoLatin1)
    }

    static func opfPath(fromContainer xml: String) throws -> String? {
        let doc = try SwiftSoup.parse(xml, "", SwiftSoup.Parser.xmlParser())
        guard let rootfile = try doc.getElementsByTag("rootfile").first(),
              let path = try? rootfile.attr("full-path"), !path.isEmpty else {
            return nil
        }
        return path
    }

    /// Resolves a manifest href (which is relative to the OPF's directory) to a
    /// ZIP entry path, decoding percent-encoding and normalizing `..`/`.`.
    static func resolve(path href: String, relativeTo dir: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        // Normalize "."/".." against the OPF directory manually. These are logical
        // ZIP entry paths, not filesystem paths, so avoid NSString.standardizingPath
        // (filesystem-aware and platform-dependent for relative paths) and resolve
        // the components ourselves. A leading "/" is root-relative, so ignore dir.
        let startsWithSlash = decoded.hasPrefix("/")
        var components: [String] = (dir.isEmpty || startsWithSlash) ? [] : dir.split(separator: "/").map(String.init)
        for part in decoded.split(separator: "/") {
            switch part {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(String(part))
            }
        }
        return components.joined(separator: "/")
    }

    /// Best-effort cover image lookup (EPUB3 `properties="cover-image"`, then
    /// EPUB2 `<meta name="cover">`). Returns nil if not found.
    static func coverData(archive: Archive, opf: Document, manifest: [String: String], opfDir: String) -> Data? {
        let items = (try? opf.getElementsByTag("item").array()) ?? []
        if let item = items.first(where: { ((try? $0.attr("properties")) ?? "").contains("cover-image") }),
           let href = try? item.attr("href") {
            return readEntry(archive, path: resolve(path: href, relativeTo: opfDir))
        }
        let metas = (try? opf.getElementsByTag("meta").array()) ?? []
        if let meta = metas.first(where: { (try? $0.attr("name")) == "cover" }),
           let coverId = try? meta.attr("content"), let href = manifest[coverId] {
            return readEntry(archive, path: resolve(path: href, relativeTo: opfDir))
        }
        return nil
    }
}
