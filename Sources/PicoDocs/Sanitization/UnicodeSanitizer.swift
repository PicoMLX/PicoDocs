//
//  UnicodeSanitizer.swift
//  PicoDocs
//
//  Conservative Unicode clean-up for extracted text, so downstream LLM / RAG
//  consumers get well-formed text without invisible, control, or layout-only
//  characters that hurt tokenization and matching. Applied centrally by
//  `PicoDocsEngine.convert` to every text section, guarded by
//  `StreamInfo.sanitizeUnicode`.
//
//  Deliberately non-lossy for *visible* content: it does NOT touch smart quotes,
//  dashes, ellipses, accents, or other legitimate typography. It only:
//    - removes invisible / control characters (zero-width, bidi, soft hyphen,
//      BOM, C0/C1 controls, the U+FFFD replacement char),
//    - folds Unicode space variants to a plain space and line/paragraph
//      separators (and CR/CRLF/NEL) to a newline,
//    - applies canonical composition (NFC, *not* the lossy NFKC, so ligatures
//      and full-width forms are preserved).
//
//  `sanitize(_:)` is idempotent.
//

import Foundation

public enum UnicodeSanitizer {

    /// Cleans a single string. See the type documentation for the exact set of
    /// transforms. Tab and newline are preserved; CR / CRLF / NEL collapse to a
    /// single newline.
    public static func sanitize(_ string: String) -> String {
        guard !string.isEmpty else { return string }

        // Normalize line endings up front so CR / CRLF fold to LF without
        // producing extra blank lines in the scalar pass below.
        var source = string
        if source.contains("\r") {
            source = source
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
        }

        var output = ""
        output.unicodeScalars.reserveCapacity(source.unicodeScalars.count)
        for scalar in source.unicodeScalars {
            switch scalar.value {
            // Keep tab and newline.
            case 0x09, 0x0A:
                output.unicodeScalars.append(scalar)
            // NEL (next line) → newline.
            case 0x85:
                output.unicodeScalars.append("\n")
            // Other C0 controls, DEL, and C1 controls → drop.
            case 0x00...0x1F, 0x7F...0x9F:
                break
            // Zero-width / invisible formatting, soft hyphen, word joiner, BOM.
            case 0x00AD, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF:
                break
            // Bidirectional formatting controls.
            case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
                break
            // Unicode space variants → ASCII space.
            case 0x00A0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000:
                output.unicodeScalars.append(" ")
            // Line / paragraph separators → newline.
            case 0x2028, 0x2029:
                output.unicodeScalars.append("\n")
            // Replacement character (a failed decode) → drop.
            case 0xFFFD:
                break
            default:
                output.unicodeScalars.append(scalar)
            }
        }

        // Canonical composition (NFC): combine base + combining marks, etc.
        return output.precomposedStringWithCanonicalMapping
    }

    /// Cleans the text-bearing fields of a `ConverterResult` — section `markdown`
    /// and titles, plus the document title/author. Binary / provenance fields are
    /// left untouched: section `metadata` (may carry base64 image bytes),
    /// `sourcePath`, `sheetName`, and `cover`.
    static func sanitize(_ result: ConverterResult) -> ConverterResult {
        var sanitized = result
        sanitized.title = result.title.map { sanitize($0) }
        sanitized.author = result.author.map { sanitize($0) }
        sanitized.sections = result.sections.map { section in
            var copy = section
            copy.markdown = sanitize(section.markdown)
            copy.title = section.title.map { sanitize($0) }
            return copy
        }
        return sanitized
    }
}
