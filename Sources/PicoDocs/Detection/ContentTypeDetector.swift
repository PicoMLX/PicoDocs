//
//  ContentTypeDetector.swift
//  PicoDocs
//
//  Content-based type detection. Resolves a `DetectedFormat` from magic bytes
//  first, then falls back to UTType / extension / MIME. Runs once per input and
//  stamps the result into `StreamInfo` so converters can trust it.
//
//  ZIP subtyping (docx/xlsx/pptx/epub) is done with a raw byte scan for
//  well-known entry names, which avoids pulling in an unzip dependency just to
//  classify. The converters do real extraction later.
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

    // MARK: - ZIP subtyping (raw byte scan)

    /// Distinguish OOXML / EPUB / generic ZIP by scanning for well-known entry
    /// names present in the archive's headers / central directory.
    static func classifyZip(_ data: Data) -> DetectedFormat {
        if contains(data, "application/epub+zip") || contains(data, "META-INF/container.xml") {
            return .epub
        }
        if contains(data, "word/document.xml") {
            return .docx
        }
        if contains(data, "xl/workbook.xml") {
            return .xlsx
        }
        if contains(data, "ppt/presentation.xml") {
            return .pptx
        }
        return .zip
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
        if let ut = info.utType {
            if ut.conforms(to: .pdf) { return .pdf }
            if ut.conforms(to: .docx) { return .docx }
            if ut.conforms(to: .xlsx) { return .xlsx }
            if ut.conforms(to: .epub) { return .epub }
            if ut.conforms(to: .html) || ut.conforms(to: .xhtml) { return .html }
            if ut.conforms(to: .commaSeparatedText) { return .csv }
            if ut.conforms(to: .json) { return .json }
            if ut.conforms(to: .image) { return .image }
            if ut.conforms(to: .audio) { return .audio }
            if ut.conforms(to: .xml) { return .xml }
            if ut.conforms(to: .plainText) || ut.conforms(to: .text) { return .plainText }
        }
        switch info.fileExtension?.lowercased() {
        case "pdf": return .pdf
        case "docx": return .docx
        case "xlsx": return .xlsx
        case "pptx": return .pptx
        case "epub": return .epub
        case "html", "htm", "xhtml": return .html
        case "csv": return .csv
        case "json": return .json
        case "xml": return .xml
        case "md", "markdown", "txt", "text": return .plainText
        default: return nil
        }
    }

    static func looksLikeText(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        // A NUL byte in the leading sample is a strong binary signal.
        return !data.prefix(8192).contains(0x00)
    }

    // MARK: - Helpers

    /// Searches for an ASCII needle in the archive, bounding the scan to the
    /// first and last 128 KB. ZIP local file headers for the main parts sit near
    /// the start, and the central directory (which lists every entry name) sits
    /// at the end — so this stays correct on large archives without scanning the
    /// megabytes of compressed media in between.
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
    }
}
