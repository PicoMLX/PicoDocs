//
//  ContentTypeDetector.swift
//  PicoDocs
//
//  Content-based type detection. Resolves a `DetectedFormat` from magic bytes
//  first, then falls back to UTType / extension / MIME. Runs once per input and
//  stamps the result into `StreamInfo` so converters can trust it.
//
//  ZIP subtyping (docx/xlsx/pptx/epub) reads the archive's central directory
//  (which authoritatively lists every entry name) and scans it for well-known
//  parts — avoiding an unzip dependency at the detection stage. The converters
//  do real extraction later.
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
        // 1. Magic bytes (highest confidence).
        if data.starts(with: Magic.pdf) {
            return (.pdf, 1.0)
        }
        if data.starts(with: Magic.zipLocal)
            || data.starts(with: Magic.zipEmpty)
            || data.starts(with: Magic.zipSpanned) {
            return (classifyZip(data), 0.9)
        }
        if data.starts(with: Magic.rtf) {
            // RTF is text-based, so it must be caught before the text heuristic,
            // otherwise it falls through to `.plainText` and is exported as a raw
            // `{\rtf ...}` control stream. No RTF converter is registered in the
            // new engine yet, so this currently resolves to "unsupported".
            return (.rtf, 0.95)
        }

        // 2. HTML (textual sniff / hints).
        if looksLikeHTML(data, info: info) {
            return (.html, 0.7)
        }

        // 3. UTType / extension / MIME hints.
        if let hinted = formatFromHints(info) {
            return (hinted, 0.5)
        }

        // 4. Last resort: decodable text vs binary.
        if looksLikeText(data) {
            return (.plainText, 0.4)
        }

        return (.unknown, 0.0)
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

    // MARK: - Heuristics

    static func looksLikeHTML(_ data: Data, info: StreamInfo) -> Bool {
        if let mime = info.mimeType?.lowercased(), mime.contains("html") {
            return true
        }
        if let ext = info.fileExtension?.lowercased(), ["html", "htm", "xhtml"].contains(ext) {
            return true
        }
        let head = String(decoding: data.prefix(1024), as: UTF8.self).lowercased()
        return head.contains("<!doctype html")
            || head.contains("<html")
            || head.contains("<head")
            || head.contains("<body")
    }

    static func formatFromHints(_ info: StreamInfo) -> DetectedFormat? {
        // Specific UTType conformances first.
        if let ut = info.utType {
            if ut.conforms(to: .pdf) { return .pdf }
            if ut.conforms(to: .docx) { return .docx }
            if ut.conforms(to: .xlsx) { return .xlsx }
            if ut.conforms(to: .epub) { return .epub }
            // RTF conforms to public.text, so check it before the plain-text branch.
            if ut.conforms(to: .rtf) { return .rtf }
            if ut.conforms(to: .html) || ut.conforms(to: .xhtml) { return .html }
            if ut.conforms(to: .commaSeparatedText) { return .csv }
            if ut.conforms(to: .json) { return .json }
            if ut.conforms(to: .image) { return .image }
            if ut.conforms(to: .audio) { return .audio }
            // NOTE: generic .xml / .plainText / .text are intentionally checked
            // *after* the extension switch, so a specific extension (e.g.
            // "data.csv" served as text/plain) isn't masked by a generic text
            // UTType derived from the MIME type.
        }
        switch info.fileExtension?.lowercased() {
        case "pdf": return .pdf
        case "docx": return .docx
        case "xlsx": return .xlsx
        case "pptx": return .pptx
        case "epub": return .epub
        case "rtf": return .rtf
        case "html", "htm", "xhtml": return .html
        case "csv": return .csv
        case "json": return .json
        case "xml": return .xml
        case "md", "markdown", "txt", "text": return .plainText
        default: break
        }
        // Generic text fallbacks last.
        if let ut = info.utType {
            if ut.conforms(to: .xml) { return .xml }
            if ut.conforms(to: .plainText) || ut.conforms(to: .text) { return .plainText }
        }
        return nil
    }

    static func looksLikeText(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        // A NUL byte in the leading sample is a strong binary signal.
        return !data.prefix(8192).contains(0x00)
    }

    // MARK: - Helpers

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
