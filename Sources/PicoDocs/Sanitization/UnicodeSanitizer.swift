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
//  dashes, ellipses, accents, ZWJ/ZWNJ joiners (which shape scripts and compose
//  emoji), or other legitimate typography. It only:
//    - removes invisible / control characters (zero-width space, word joiner,
//      soft hyphen, BOM, bidi controls, other C0/C1 controls, the U+FFFD
//      replacement char),
//    - normalizes line endings (CR / CRLF / LF) to a single newline, and folds
//      the other vertical separators (NEL, form feed, line/paragraph separators)
//      and Unicode space variants to a plain space — never injecting a newline
//      into already-built Markdown,
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

        // Single O(N) pass with inline carriage-return tracking, so CR, CRLF and
        // NEL all collapse to one newline without any intermediate string copies.
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(string.unicodeScalars.count)
        var lastWasCarriageReturn = false

        for scalar in string.unicodeScalars {
            // An LF immediately after a CR completes a CRLF; the CR already
            // emitted the newline, so swallow this LF.
            if lastWasCarriageReturn {
                lastWasCarriageReturn = false
                if scalar.value == 0x0A { continue }
            }

            switch scalar.value {
            // CR → newline (a following LF is swallowed above).
            case 0x0D:
                scalars.append("\n")
                lastWasCarriageReturn = true
            // Keep tab and (standalone) newline.
            case 0x09, 0x0A:
                scalars.append(scalar)
            // Vertical separators converters DON'T already flatten — NEL, form
            // feed (page break), and line/paragraph separators — fold to a space.
            // Not a newline: this pass runs after Markdown is built, so a stray
            // newline would split table rows etc.; a space keeps the word boundary.
            case 0x0C, 0x85, 0x2028, 0x2029:
                scalars.append(" ")
            // Other C0 controls, DEL, and C1 controls → drop.
            case 0x00...0x1F, 0x7F...0x9F:
                break
            // Zero-width space, word joiner, soft hyphen, BOM → drop. ZWNJ (U+200C)
            // and ZWJ (U+200D) are intentionally kept: they shape Persian/Indic
            // text and compose emoji (e.g. 👨‍👩‍👧‍👦), i.e. they're visible content.
            case 0x00AD, 0x200B, 0x2060, 0xFEFF:
                break
            // Bidirectional formatting controls (incl. U+061C Arabic Letter Mark).
            case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
                break
            // Unicode space variants → ASCII space.
            case 0x00A0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000:
                scalars.append(" ")
            // Replacement character (a failed decode) → drop.
            case 0xFFFD:
                break
            default:
                scalars.append(scalar)
            }
        }

        // Canonical composition (NFC): combine base + combining marks, etc.
        return String(String.UnicodeScalarView(scalars)).precomposedStringWithCanonicalMapping
    }

    /// Cleans the text-bearing fields of a `ConverterResult` — section `markdown`,
    /// titles, and (for non-image sections) `metadata` values — plus the document
    /// title/author. Image byte-carrier sections' `metadata` is left untouched (it
    /// holds base64 image data); `sourcePath`, `sheetName`, and `cover` are too.
    static func sanitize(_ result: ConverterResult) -> ConverterResult {
        var sanitized = result
        sanitized.title = result.title.map { sanitize($0) }
        sanitized.author = result.author.map { sanitize($0) }
        sanitized.sections = result.sections.map { section in
            var copy = section
            copy.markdown = sanitize(section.markdown)
            copy.title = section.title.map { sanitize($0) }
            // Sanitize text-bearing metadata too — e.g. CSVConverter keeps the
            // lossless body in metadata["csv"], which the CSV renderer prefers over
            // the Markdown table. Skip image byte-carrier sections, whose metadata
            // holds base64 image data that must not be altered.
            if section.kind != .image {
                copy.metadata = section.metadata.mapValues { sanitize($0) }
            }
            return copy
        }
        return sanitized
    }
}
