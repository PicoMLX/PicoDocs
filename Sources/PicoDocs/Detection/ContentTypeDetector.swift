//
//  ContentTypeDetector.swift
//  PicoDocs
//
//  Content-based type detection. Runs once per input and stamps the result into
//  `StreamInfo` so converters can trust it. The resolution pipeline is ordered
//  by decreasing trust:
//
//    1. Magic bytes (definitive): %PDF, PK ZIP, {\rtf
//    2. Binary formats identified by hint (image / audio)
//    3. Document formats identified by hint but missing magic (corrupt /
//       mislabeled) — honored so they reach the right converter, not text
//    4. Binary guard: a NUL byte means "not text" — unless a wide text encoding
//       (UTF-16/UTF-32) is declared or detected via BOM, whose NULs are expected
//    5. Specific text-format hints (extension / UTType) — win over the loose
//       HTML content sniff
//    6. HTML content sniff
//    7. Plain-text default
//
//  ZIP subtyping reads the archive's central directory (authoritative, scanned
//  in full) rather than pulling in an unzip dependency at the detection stage.
//

import Foundation
import UniformTypeIdentifiers

public enum ContentTypeDetector {

    /// Returns a copy of `info` with `detectedFormat`/`confidence` populated, and
    /// `charset` filled in from a byte-order mark when the caller didn't supply one.
    public static func classify(_ data: Data, info: StreamInfo) -> StreamInfo {
        var result = info
        if result.charset == nil, let bom = encodingFromBOM(data) {
            result.charset = bom
        }
        let (format, confidence) = detect(data, info: result)
        result.detectedFormat = format
        result.confidence = confidence
        return result
    }

    static func detect(_ data: Data, info: StreamInfo) -> (DetectedFormat, Double) {
        // 1. Magic bytes (definitive).
        if data.starts(with: Magic.pdf) {
            return (.pdf, 1.0)
        }
        if data.starts(with: Magic.zipLocal)
            || data.starts(with: Magic.zipEmpty)
            || data.starts(with: Magic.zipSpanned) {
            let zipFormat = classifyZip(data)
            if zipFormat == .zip {
                // iWork '13+ packages are ZIPs without OOXML/EPUB markers. Route to
                // the Pages converter when the filename/UTType says Pages, raising
                // confidence when the archive's IWA layout confirms it.
                if let iwork = iworkFormatFromHints(info) {
                    return (iwork, isIWorkArchive(data) ? 0.95 : 0.5)
                }
                // If the archive couldn't be subtyped (generic .zip) but the
                // caller's filename/MIME claims a specific OOXML/EPUB document —
                // e.g. a truncated `report.docx` that still begins with PK — honor
                // that hint so it routes to the right converter.
                if let docHint = documentFormatFromHints(info) {
                    return (docHint, 0.5)
                }
            }
            return (zipFormat, 0.9)
        }
        if data.starts(with: Magic.rtf) {
            // RTF is text-based; catch it before the text logic so it isn't
            // emitted as a raw `{\rtf ...}` control stream. No RTF converter is
            // registered yet, so this resolves to "unsupported".
            return (.rtf, 0.95)
        }

        // 2. Binary formats identified by hint (legitimately binary).
        if let ut = info.utType {
            if ut.conforms(to: .image) { return (.image, 0.6) }
            if ut.conforms(to: .audio) { return (.audio, 0.6) }
        }

        // 3. Document formats identified by hint but lacking magic bytes (corrupt
        //    or mislabeled). Honor the hint so they reach the right converter (or
        //    report unsupported) instead of being mis-read as text.
        // iWork hints without ZIP magic (corrupt/mislabeled). Pages routes by any
        // hint (its extension is unambiguous).
        if let iwork = iworkFormatFromHints(info), iwork != .keynote {
            return (iwork, 0.4)
        }
        // Keynote needs care: the `.key` extension is ambiguous (PEM/SSH/license
        // keys), and a local `.key`'s MIME can be *synthesized* from its
        // extension-derived UTType (PicoDocument+Fetch uses `preferredMIMEType`),
        // so neither the extension nor a `.key`-derived MIME is trustworthy. But an
        // explicit Keynote MIME with NO `.key` extension can't have been synthesized
        // that way — it's a real server `Content-Type` (e.g. a truncated,
        // extensionless download) — so honor it. Real `.key` ZIPs still match above.
        if info.fileExtension?.lowercased() != "key", isKeynoteMIME(info.mimeType) {
            return (.keynote, 0.4)
        }
        if let docHint = documentFormatFromHints(info) {
            return (docHint, 0.4)
        }

        // 4. Binary guard. A NUL byte normally signals binary — but wide text
        //    encodings (UTF-16/UTF-32) legitimately contain NULs, so skip the
        //    guard when such an encoding is declared or detected via BOM.
        if !isWideEncoding(info.charset), looksBinary(data) {
            return (.unknown, 0.0)
        }

        // --- Treat as text from here. ---

        // 5. Specific text-format hints (extension / UTType) win over the loose
        //    HTML sniff, so a real ".txt" containing "<html" in prose stays text,
        //    and a ".csv" served as text/plain still resolves to .csv.
        if let hint = textFormatFromHints(info) {
            return (hint, 0.5)
        }

        // 6. HTML content sniff (only when no specific text hint applied).
        if looksLikeHTMLContent(data, charset: info.charset) {
            return (.html, 0.7)
        }

        // 7. Plain-text default.
        return (.plainText, 0.4)
    }

    // MARK: - ZIP subtyping

    /// Distinguish OOXML / EPUB / generic ZIP by scanning for well-known entry
    /// names. When the central directory can be located it is scanned in full
    /// (it's authoritative and contains only headers); otherwise a windowed scan
    /// of the whole archive is used as a fallback.
    static func classifyZip(_ data: Data) -> DetectedFormat {
        if let centralDirectory = zipCentralDirectory(data) {
            return classifyZipEntries(in: centralDirectory, bounded: false)
        }
        return classifyZipEntries(in: data, bounded: true)
    }

    /// NOTE: a substring search over the central-directory bytes, not a strict
    /// per-entry-name match — a best-effort *hint*. A contrived archive with an
    /// entry like "backup/word/document.xml" could be mis-hinted as .docx. That's
    /// acceptable here: detection only routes to a converter, and the Phase 3
    /// OOXML/EPUB converters parse real entry names via ZIPFoundation and
    /// re-validate, so a mis-hint fails cleanly rather than producing wrong
    /// output. Strict entry-name parsing arrives with that work.
    private static func classifyZipEntries(in haystack: Data, bounded: Bool) -> DetectedFormat {
        func has(_ name: String) -> Bool {
            let needle = Data(name.utf8)
            return bounded ? boundedContains(haystack, needle) : (haystack.range(of: needle) != nil)
        }
        if has("application/epub+zip") || has("META-INF/container.xml") {
            return .epub
        }
        if has("word/document.xml") {
            return .docx
        }
        if has("xl/workbook.xml") {
            return .xlsx
        }
        if has("ppt/presentation.xml") {
            return .pptx
        }
        return .zip
    }

    /// Locates the ZIP central directory via the End Of Central Directory (EOCD)
    /// record. Returns the directory bytes (every entry name lives here), or nil
    /// if the structure can't be parsed (e.g. ZIP64), in which case the caller
    /// falls back to a windowed scan.
    static func zipCentralDirectory(_ data: Data) -> Data? {
        let eocdSignature = Data([0x50, 0x4B, 0x05, 0x06])
        // The EOCD lies within the last 22 bytes + up to 65535 bytes of comment.
        let maxBack = 22 + 0xFFFF
        let lower = data.count > maxBack
            ? data.index(data.endIndex, offsetBy: -maxBack)
            : data.startIndex
        let tail = data[lower..<data.endIndex]
        guard let sigRange = tail.range(of: eocdSignature, options: .backwards) else {
            return nil
        }
        let eocd = sigRange.lowerBound
        // Need bytes through offset 20 to read the size/offset fields.
        guard data.distance(from: eocd, to: data.endIndex) >= 20 else { return nil }
        let cdSize = Int(readUInt32LE(data, at: data.index(eocd, offsetBy: 12)))
        let cdOffset = Int(readUInt32LE(data, at: data.index(eocd, offsetBy: 16)))
        // ZIP64 stores 0xFFFFFFFF placeholders here; those fail these bounds and
        // fall back to the windowed scan.
        guard cdSize > 0, cdOffset >= 0, cdOffset + cdSize <= data.count else {
            return nil
        }
        let start = data.index(data.startIndex, offsetBy: cdOffset)
        let end = data.index(start, offsetBy: cdSize)
        return data[start..<end]
    }

    static func readUInt32LE(_ data: Data, at index: Data.Index) -> UInt32 {
        let b0 = UInt32(data[index])
        let b1 = UInt32(data[data.index(index, offsetBy: 1)])
        let b2 = UInt32(data[data.index(index, offsetBy: 2)])
        let b3 = UInt32(data[data.index(index, offsetBy: 3)])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    // MARK: - Hints & heuristics

    /// Resolves binary document formats (pdf/docx/xlsx/pptx/epub) from hints.
    /// Used only for inputs that lack magic bytes (valid ones are caught earlier),
    /// i.e. corrupt or mislabeled documents — honored rather than read as text.
    static func documentFormatFromHints(_ info: StreamInfo) -> DetectedFormat? {
        if let ut = info.utType {
            if ut.conforms(to: .pdf) { return .pdf }
            if ut.conforms(to: .docx) { return .docx }
            if ut.conforms(to: .xlsx) { return .xlsx }
            if ut.conforms(to: .pptx) { return .pptx }
            if ut.conforms(to: .epub) { return .epub }
        }
        switch info.fileExtension?.lowercased() {
        case "pdf": return .pdf
        case "docx": return .docx
        case "xlsx": return .xlsx
        case "pptx": return .pptx
        case "epub": return .epub
        default: return nil
        }
    }

    /// Resolves iWork formats from hints (Pages, Keynote). Numbers will get its
    /// own `DetectedFormat` case when supported.
    static func iworkFormatFromHints(_ info: StreamInfo) -> DetectedFormat? {
        if let ut = info.utType {
            if ut.conforms(to: .pages) || ut.conforms(to: .pagesSingleFile) { return .pages }
            if ut.conforms(to: .keynote) || ut.conforms(to: .keynoteSingleFile) { return .keynote }
        }
        switch info.fileExtension?.lowercased() {
        case "pages": return .pages
        case "key": return .keynote
        default: break
        }
        // Extensionless web downloads: route by the iWork MIME type.
        if isPagesMIME(info.mimeType) { return .pages }
        if isKeynoteMIME(info.mimeType) { return .keynote }
        return nil
    }

    private static func baseMIME(_ mimeType: String?) -> String? {
        mimeType?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    /// True for the current/legacy Pages MIME types.
    static func isPagesMIME(_ mimeType: String?) -> Bool {
        let m = baseMIME(mimeType)
        return m == "application/vnd.apple.pages" || m == "application/x-iwork-pages-sffpages"
    }

    /// True for the current/legacy Keynote MIME types.
    static func isKeynoteMIME(_ mimeType: String?) -> Bool {
        let m = baseMIME(mimeType)
        return m == "application/vnd.apple.keynote" || m == "application/x-iwork-keynote-sffkey"
    }

    /// Best-effort check that a ZIP is an iWork '13+ package: it carries IWA
    /// component streams (`*.iwa`, possibly inside a nested `Index.zip`) or the
    /// iWork `Metadata/DocumentIdentifier`. Scans the central directory when
    /// locatable (authoritative), else a bounded whole-archive scan — mirroring
    /// `classifyZipEntries`.
    static func isIWorkArchive(_ data: Data) -> Bool {
        let markers = [".iwa", "Index.zip", "Metadata/DocumentIdentifier"]
        if let cd = zipCentralDirectory(data) {
            return markers.contains { cd.range(of: Data($0.utf8)) != nil }
        }
        return markers.contains { boundedContains(data, Data($0.utf8)) }
    }

    /// Resolves text-family formats from extension / UTType. The extension switch
    /// is consulted before the generic `.xml` / `.plainText` / `.text` UTType
    /// fallback so a specific extension (e.g. "data.csv" served as text/plain)
    /// isn't masked by a generic MIME-derived type.
    static func textFormatFromHints(_ info: StreamInfo) -> DetectedFormat? {
        if let ut = info.utType {
            if ut.conforms(to: .rtf) { return .rtf }
            if ut.conforms(to: .html) || ut.conforms(to: .xhtml) { return .html }
            if ut.conforms(to: .commaSeparatedText) { return .csv }
            if ut.conforms(to: .json) { return .json }
        }
        switch info.fileExtension?.lowercased() {
        case "rtf": return .rtf
        case "html", "htm", "xhtml": return .html
        case "csv": return .csv
        case "json": return .json
        case "xml": return .xml
        case "md", "markdown", "txt", "text": return .plainText
        default: break
        }
        if let ut = info.utType {
            if ut.conforms(to: .xml) { return .xml }
            if ut.conforms(to: .plainText) || ut.conforms(to: .text) { return .plainText }
        }
        return nil
    }

    /// True if the leading sample looks like HTML by content. Decodes with the
    /// resolved charset (e.g. a UTF-16 BOM) so wide-encoded markers are seen,
    /// falling back to a lossy UTF-8 read.
    static func looksLikeHTMLContent(_ data: Data, charset: String.Encoding?) -> Bool {
        let prefix = data.prefix(1024)
        let head: String
        if let charset, let decoded = String(data: prefix, encoding: charset) {
            head = decoded.lowercased()
        } else {
            head = String(decoding: prefix, as: UTF8.self).lowercased()
        }
        return head.contains("<!doctype html")
            || head.contains("<html")
            || head.contains("<head")
            || head.contains("<body")
    }

    /// A NUL byte in the leading sample is a strong signal that the data is
    /// binary rather than text (for UTF-8 / single-byte encodings).
    static func looksBinary(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        return data.prefix(8192).contains(0x00)
    }

    /// Maps a leading byte-order mark to its encoding, if present. UTF-32 BOMs
    /// are checked before UTF-16 because the UTF-32-LE BOM starts with the
    /// UTF-16-LE BOM bytes.
    static func encodingFromBOM(_ data: Data) -> String.Encoding? {
        let b = [UInt8](data.prefix(4))
        // Return the BOM-*consuming* .utf16/.utf32 (not endian-specific) variants:
        // they read the BOM to determine byte order and strip it, so decoded text
        // doesn't retain a stray leading U+FEFF.
        if b.count >= 4, b[0] == 0xFF, b[1] == 0xFE, b[2] == 0x00, b[3] == 0x00 { return .utf32 }
        if b.count >= 4, b[0] == 0x00, b[1] == 0x00, b[2] == 0xFE, b[3] == 0xFF { return .utf32 }
        if b.count >= 2, b[0] == 0xFF, b[1] == 0xFE { return .utf16 }
        if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF { return .utf16 }
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { return .utf8 }
        return nil
    }

    /// True for UTF-16/UTF-32 encodings, whose text legitimately contains NUL
    /// bytes and so must bypass the binary guard.
    static func isWideEncoding(_ encoding: String.Encoding?) -> Bool {
        guard let encoding else { return false }
        let wide: Set<String.Encoding> = [
            .utf16, .utf16BigEndian, .utf16LittleEndian,
            .utf32, .utf32BigEndian, .utf32LittleEndian,
        ]
        return wide.contains(encoding)
    }

    /// Searches for a needle, bounding the scan to the first and last 128 KB.
    /// Used for the whole-archive fallback when the central directory can't be
    /// located; the directory itself is scanned in full (see `classifyZip`).
    static func boundedContains(_ data: Data, _ needle: Data) -> Bool {
        let limit = 128 * 1024
        if data.count <= 2 * limit {
            return data.range(of: needle) != nil
        }
        return data.prefix(limit).range(of: needle) != nil
            || data.suffix(limit).range(of: needle) != nil
    }

    enum Magic {
        static let pdf: [UInt8] = [0x25, 0x50, 0x44, 0x46]          // "%PDF"
        static let zipLocal: [UInt8] = [0x50, 0x4B, 0x03, 0x04]     // "PK\x03\x04"
        static let zipEmpty: [UInt8] = [0x50, 0x4B, 0x05, 0x06]     // empty archive
        static let zipSpanned: [UInt8] = [0x50, 0x4B, 0x07, 0x08]   // spanned archive
        static let rtf: [UInt8] = [0x7B, 0x5C, 0x72, 0x74, 0x66]    // "{\rtf"
    }
}
