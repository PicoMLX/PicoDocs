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
//    3. Binary guard: a NUL byte means "not text" — don't let a text hint
//       (e.g. a ".txt" name on a binary blob) force text decoding
//    4. Specific text-format hints (extension / UTType) — these win over the
//       loose HTML content sniff
//    5. HTML content sniff
//    6. Plain-text default
//
//  ZIP subtyping reads the archive's central directory (authoritative + bounded)
//  rather than pulling in an unzip dependency at the detection stage.
//

import Foundation
import UniformTypeIdentifiers

public enum ContentTypeDetector {

    /// Returns a copy of `info` with `detectedFormat` and `confidence` populated.
    public static func classify(_ data: Data, info: StreamInfo) -> StreamInfo {
        var result = info
        let (format, confidence) = detect(data, info: info)
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
            return (classifyZip(data), 0.9)
        }
        if data.starts(with: Magic.rtf) {
            // RTF is text-based; catch it before the text logic so it isn't
            // emitted as a raw `{\rtf ...}` control stream. No RTF converter is
            // registered yet, so this resolves to "unsupported".
            return (.rtf, 0.95)
        }

        // 2. Binary formats identified by hint (legitimately binary, so checked
        //    before the NUL/text logic).
        if let ut = info.utType {
            if ut.conforms(to: .image) { return (.image, 0.6) }
            if ut.conforms(to: .audio) { return (.audio, 0.6) }
        }

        // 3. Binary guard. A NUL byte in the leading sample is a strong binary
        //    signal; since no magic/binary hint matched we can't identify it, and
        //    must not let a text hint force decoding of binary bytes.
        if looksBinary(data) {
            return (.unknown, 0.0)
        }

        // --- Content is text from here (no NUL in the leading sample). ---

        // 4. Specific text-format hints (extension / UTType) win over the loose
        //    HTML sniff, so a real ".txt" containing "<html" in prose stays text,
        //    and a ".csv" served as text/plain still resolves to .csv.
        if let hint = textFormatFromHints(info) {
            return (hint, 0.5)
        }

        // 5. HTML content sniff (only when no specific text hint applied).
        if looksLikeHTMLContent(data) {
            return (.html, 0.7)
        }

        // 6. Plain-text default.
        return (.plainText, 0.4)
    }

    // MARK: - ZIP subtyping

    /// Distinguish OOXML / EPUB / generic ZIP by scanning for well-known entry
    /// names. Prefers the archive's central directory (authoritative + bounded,
    /// since it contains only headers, not file data); falls back to a windowed
    /// byte scan if the directory can't be located.
    static func classifyZip(_ data: Data) -> DetectedFormat {
        let haystack = zipCentralDirectory(data) ?? data
        if contains(haystack, "application/epub+zip") || contains(haystack, "META-INF/container.xml") {
            return .epub
        }
        if contains(haystack, "word/document.xml") {
            return .docx
        }
        if contains(haystack, "xl/workbook.xml") {
            return .xlsx
        }
        if contains(haystack, "ppt/presentation.xml") {
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

    /// True if the leading sample looks like HTML by content (no hints).
    static func looksLikeHTMLContent(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(1024), as: UTF8.self).lowercased()
        return head.contains("<!doctype html")
            || head.contains("<html")
            || head.contains("<head")
            || head.contains("<body")
    }

    /// A NUL byte in the leading sample is a strong signal that the data is
    /// binary rather than text.
    static func looksBinary(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        return data.prefix(8192).contains(0x00)
    }

    /// Searches for an ASCII needle, bounding the scan to the first and last
    /// 128 KB when handed a large blob. (When handed the central directory this
    /// limit rarely matters, since the directory holds only entry headers.)
    static func contains(_ data: Data, _ ascii: String) -> Bool {
        let needle = Data(ascii.utf8)
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
