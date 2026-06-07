//
//  RTFConverter.swift
//  PicoDocs
//
//  Converts RTF to Markdown with a small, dependency-free parser — no
//  NSAttributedString (the lossy, main-thread-biased path this rewrite removed).
//  It extracts text, paragraphs, and bold/italic emphasis, skips the control
//  tables (font/color/stylesheet/info) and ignorable destinations, and decodes
//  \uN / \'hh escapes. RTF carries no semantic headings, so none are inferred
//  (we deliberately don't guess headings from font sizes).
//

import Foundation

public struct RTFConverter: DocumentConverter {

    public init() {}

    public func accepts(_ info: StreamInfo) -> Bool {
        info.detectedFormat == .rtf
    }

    public func convert(_ data: Data, info: StreamInfo) async throws -> ConverterResult {
        // RTF is a byte-oriented ASCII container (non-ASCII arrives via \uN or
        // \'hh escapes), so decode it losslessly as Latin-1.
        guard let rtf = String(data: data, encoding: .isoLatin1), !rtf.isEmpty else {
            throw ConverterError.decodingFailed
        }
        // A valid RTF document begins with the {\rtf signature. When .rtf was
        // inferred from a filename/MIME hint rather than the magic bytes, reject
        // mislabeled or corrupt input here (strict failure) instead of emitting
        // its raw text as a "document".
        guard rtf.drop(while: { $0.isWhitespace }).hasPrefix("{\\rtf") else {
            throw PicoDocsError.fileCorrupted
        }
        let markdown = Self.markdown(fromRTF: rtf)
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PicoDocsError.emptyDocument
        }
        let section = DocumentSection(title: info.filename, kind: .body, markdown: markdown)
        return ConverterResult(title: info.filename, sections: [section])
    }

    // MARK: - Parser

    private struct Run { var text: String; var bold: Bool; var italic: Bool }
    private struct GroupState { var bold: Bool; var italic: Bool; var ignore: Bool; var ucSkip: Int }

    /// Destination control words whose group contents are not body text.
    private static let ignoredDestinations: Set<String> = [
        "fonttbl", "colortbl", "stylesheet", "info", "pict", "header", "footer",
        "headerl", "headerr", "headerf", "footerl", "footerr", "footerf",
        "footnote", "object", "themedata", "colorschememapping", "latentstyles",
        "datastore", "generator", "xmlnstbl", "listtable", "listoverridetable",
        "revtbl", "rsidtbl",
    ]

    static func markdown(fromRTF rtf: String) -> String {
        let chars = Array(rtf)
        let n = chars.count
        var i = 0

        var bold = false
        var italic = false
        var ignore = false
        var ucSkip = 1
        var ansiEncoding: String.Encoding = .windowsCP1252
        var stack: [GroupState] = []
        var pendingHighSurrogate: Int?

        var runs: [Run] = []
        var paragraphs: [String] = []

        func appendText(_ s: String) {
            guard !ignore, !s.isEmpty else { return }
            if var last = runs.last, last.bold == bold, last.italic == italic {
                last.text += s
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(text: s, bold: bold, italic: italic))
            }
        }

        func flushParagraph() {
            let rendered = runs.map { renderRun($0) }.joined()
            runs.removeAll(keepingCapacity: true)
            let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { paragraphs.append(trimmed) }
        }

        while i < n {
            let c = chars[i]
            switch c {
            case "{":
                stack.append(GroupState(bold: bold, italic: italic, ignore: ignore, ucSkip: ucSkip))
                i += 1

            case "}":
                if let saved = stack.popLast() {
                    bold = saved.bold; italic = saved.italic; ignore = saved.ignore; ucSkip = saved.ucSkip
                }
                i += 1

            case "\\":
                i += 1
                guard i < n else { break }
                let next = chars[i]
                if next.isLetter {
                    // Control word: letters, then an optional (signed) parameter,
                    // then an optional single delimiting space.
                    var word = ""
                    while i < n, chars[i].isLetter { word.append(chars[i]); i += 1 }
                    var paramText = ""
                    if i < n, chars[i] == "-" { paramText.append("-"); i += 1 }
                    while i < n, chars[i].isNumber { paramText.append(chars[i]); i += 1 }
                    let param = Int(paramText)
                    if i < n, chars[i] == " " { i += 1 }

                    switch word {
                    case "par", "row", "sect", "page":
                        if !ignore { flushParagraph() }   // a \par inside a skipped destination isn't a body break
                    case "line":
                        appendText("  \n")                // Markdown hard break (matches the DOCX w:br path)
                    case "tab", "cell":
                        appendText("\t")
                    case "emdash": appendText("\u{2014}")
                    case "endash": appendText("\u{2013}")
                    case "bullet": appendText("\u{2022}")
                    case "lquote": appendText("\u{2018}")
                    case "rquote": appendText("\u{2019}")
                    case "ldblquote": appendText("\u{201C}")
                    case "rdblquote": appendText("\u{201D}")
                    case "emspace", "enspace", "qmspace": appendText(" ")
                    case "ansicpg":
                        if let param, let encoding = Self.encoding(forCodepage: param) { ansiEncoding = encoding }
                    case "bin":
                        // \binN: the next N bytes are raw binary (often inside an
                        // ignored \pict/\object) and may contain { } or \ — skip
                        // them so they can't corrupt group/brace parsing.
                        if let param, param > 0 { i += min(param, n - i) }
                    case "plain":
                        bold = false; italic = false
                    case "b":
                        bold = (param ?? 1) != 0
                    case "i":
                        italic = (param ?? 1) != 0
                    case "uc":
                        if let param { ucSkip = max(0, param) }
                    case "u":
                        if let param {
                            // \uN values are UTF-16 code units; combine surrogate
                            // pairs so astral characters (e.g. emoji) survive.
                            let value = param < 0 ? param + 65_536 : param
                            if value >= 0xD800, value <= 0xDBFF {
                                pendingHighSurrogate = value
                            } else if value >= 0xDC00, value <= 0xDFFF {
                                if let high = pendingHighSurrogate {
                                    let combined = 0x10000 + (high - 0xD800) * 0x400 + (value - 0xDC00)
                                    if let scalar = Unicode.Scalar(UInt32(combined)) {
                                        appendText(String(Character(scalar)))
                                    }
                                    pendingHighSurrogate = nil
                                }
                                // a lone low surrogate is dropped
                            } else {
                                pendingHighSurrogate = nil
                                if value >= 0, let scalar = Unicode.Scalar(UInt32(value)) {
                                    appendText(String(Character(scalar)))
                                }
                            }
                        }
                        // Skip the \ucN fallback that follows a \uN. Each fallback
                        // is one "unit", which may be a literal char, a \'hh hex
                        // escape, a control word, or a control symbol — skip whole
                        // units so an escaped fallback (e.g. a \'92 hex escape)
                        // isn't re-parsed and duplicated into the output.
                        var skipped = 0
                        while i < n, skipped < ucSkip {
                            let fallback = chars[i]
                            if fallback == "{" || fallback == "}" {
                                break
                            } else if fallback == "\\" {
                                if i + 1 < n, chars[i + 1] == "'" {
                                    i += min(4, n - i)            // \ ' h h
                                } else if i + 1 < n, chars[i + 1].isLetter {
                                    i += 1
                                    while i < n, chars[i].isLetter { i += 1 }
                                    if i < n, chars[i] == "-" { i += 1 }
                                    while i < n, chars[i].isNumber { i += 1 }
                                    if i < n, chars[i] == " " { i += 1 }
                                } else {
                                    i += 2                         // control symbol
                                }
                            } else {
                                i += 1
                            }
                            skipped += 1
                        }
                    default:
                        if Self.ignoredDestinations.contains(word) { ignore = true }
                        // All other control words carry no body text.
                    }
                } else {
                    // Control symbol.
                    i += 1
                    switch next {
                    case "\\", "{", "}": appendText(String(next))
                    case "~": appendText("\u{00A0}")          // non-breaking space
                    case "_": appendText("-")                 // non-breaking hyphen
                    case "-": break                            // optional hyphen
                    case "*": ignore = true                    // ignorable destination
                    case "'":
                        if i + 1 < n, let byte = UInt8(String([chars[i], chars[i + 1]]), radix: 16) {
                            appendText(Self.decodeByte(byte, encoding: ansiEncoding))
                            i += 2
                        }
                    case "\n", "\r":
                        if !ignore { flushParagraph() }        // escaped newline = \par
                    default: break
                    }
                }

            case "\r", "\n":
                i += 1                                          // raw newlines aren't content

            default:
                appendText(String(c))
                i += 1
            }
        }
        flushParagraph()
        return paragraphs.joined(separator: "\n\n")
    }

    /// Decodes a single `\'hh` byte using the document's declared code page
    /// (`\ansicpgN`, defaulting to Windows-1252 for `\ansi`) — so bytes 0x80–0x9F
    /// become the right punctuation/letters rather than C1 control characters.
    /// Falls back to Windows-1252, then Latin-1, for undecodable bytes.
    ///
    /// Each `\'hh` is decoded on its own. Multibyte ANSI code pages (e.g. 932
    /// Shift-JIS) that split one character across consecutive `\'hh` escapes are
    /// not reassembled here — a deliberately deferred legacy niche, since modern
    /// RTF emits non-ASCII (including CJK) as `\uN`, which is handled in full.
    private static func decodeByte(_ byte: UInt8, encoding: String.Encoding) -> String {
        if let decoded = String(bytes: [byte], encoding: encoding), !decoded.isEmpty {
            return decoded
        }
        if encoding != .windowsCP1252,
           let decoded = String(bytes: [byte], encoding: .windowsCP1252), !decoded.isEmpty {
            return decoded
        }
        return Unicode.Scalar(UInt32(byte)).map { String(Character($0)) } ?? ""
    }

    /// Maps an RTF `\ansicpgN` Windows code page number to a `String.Encoding`.
    private static func encoding(forCodepage codepage: Int) -> String.Encoding? {
        guard codepage > 0 else { return nil }
        let cfEncoding = CFStringConvertWindowsCodepageToEncoding(UInt32(codepage))
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    /// Renders one formatting run, keeping emphasis markers hugging the text (so
    /// `**word** ` rather than `** word **`).
    private static func renderRun(_ run: Run) -> String {
        guard !run.text.isEmpty else { return "" }
        if run.text.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\n" }) { return run.text }
        let isSpace: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        let afterLeading = run.text.drop(while: isSpace)
        let leading = String(run.text.prefix(run.text.count - afterLeading.count))
        let trailingCount = afterLeading.reversed().prefix(while: isSpace).count
        let trailing = String(afterLeading.suffix(trailingCount))
        var core = String(afterLeading.dropLast(trailingCount))
        if run.italic { core = "*\(core)*" }
        if run.bold { core = "**\(core)**" }
        return leading + core + trailing
    }
}
