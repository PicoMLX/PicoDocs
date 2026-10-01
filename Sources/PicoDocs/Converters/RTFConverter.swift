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

    private struct Run { var text: String; var bold: Bool; var italic: Bool; var link: String?; var code: Bool; var field: Field? }
    private final class Field {
        static let maximumInstructionBytes = 65_536
        private(set) var instruction = ""
        private var instructionBytes = 0
        private var oversized = false
        var target: String?
        func appendInstruction(_ text: String) {
            guard !oversized else { return }
            let bytes = text.utf8.count
            guard bytes <= Self.maximumInstructionBytes - instructionBytes else {
                oversized = true; instruction = ""; return
            }
            instructionBytes += bytes
            instruction += text
        }
    }
    private struct GroupState { var bold: Bool; var italic: Bool; var ignore: Bool; var ucSkip: Int; var field: Field?; var instruction: Bool; var font: Int; var fontTable: Bool; var fontNameIgnored: Bool }

    /// Destination control words whose group contents are not body text.
    private static let ignoredDestinations: Set<String> = [
        "fonttbl", "colortbl", "stylesheet", "info", "pict", "header", "footer",
        "headerl", "headerr", "headerf", "footerl", "footerr", "footerf",
        "footnote", "object", "themedata", "colorschememapping", "latentstyles",
        "datastore", "generator", "xmlnstbl", "listtable", "listoverridetable",
        "revtbl", "rsidtbl",
    ]

    static func markdown(fromRTF rtf: String) -> String {
        // convert() decodes bytes as Latin-1: each scalar is exactly one source
        // byte. Keep CR and LF separate so \binN skips N bytes, not graphemes.
        let chars = rtf.unicodeScalars.map { Character(String($0)) }
        let n = chars.count
        var i = 0

        var bold = false
        var italic = false
        var ignore = false
        var ucSkip = 1
        var field: Field?
        var instruction = false
        var font = 0, defaultFont = 0
        var fontTable = false
        var fontNameIgnored = false
        var fontNames: [Int: String] = [:]
        var monospacedFonts: Set<Int> = []
        var ansiEncoding: String.Encoding = .windowsCP1252
        var isDBCS = false
        var stack: [GroupState] = []
        var pendingHighSurrogate: Int?
        // Bytes from consecutive `\'hh` escapes, buffered so a multibyte (DBCS)
        // character split across escapes is decoded as one unit (see flushBytes).
        var pendingBytes: [UInt8] = []

        var runs: [Run] = []
        var canonical = false
        var encounteredBody = false
        let canonicalMarker = Array("{\\*\\picodocsmarkdown1}")
        var nativeParagraphs: [[Run]] = []
        var paragraphs: [String] = []
        var markdownFence: (character: Character, length: Int)?
        var previousBlankParagraph = true

        func finishFont() {
            guard fontTable, !fontNameIgnored else { return }
            let name = fontNames[font, default: ""].lowercased()
            if ["menlo", "monaco", "courier", "consolas", "sfmono", "sfnsmono", "monospaced"].contains(where: name.contains) { monospacedFonts.insert(font) }
        }

        func appendText(_ s: String) {
            if fontTable {
                if !fontNameIgnored { fontNames[font, default: ""] += s }
                return
            }
            if instruction, let field { field.appendInstruction(s); return }
            let code = field?.target != nil && monospacedFonts.contains(font)
            guard !ignore, !s.isEmpty else { return }
            encounteredBody = true
            if var last = runs.last, last.bold == bold, last.italic == italic, last.link == field?.target, last.code == code, last.field === field {
                last.text += s
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(text: s, bold: bold, italic: italic, link: field?.target, code: code, field: field))
            }
        }

        // Decode any buffered `\'hh` bytes as a group (so a multibyte DBCS
        // character spanning consecutive escapes survives) and append the result.
        func flushBytes() {
            guard !pendingBytes.isEmpty else { return }
            let decoded = Self.decodeBytes(pendingBytes, encoding: ansiEncoding)
            pendingBytes.removeAll(keepingCapacity: true)
            appendText(decoded)
        }

        func flushParagraph() {
            if !canonical {
                if runs.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { nativeParagraphs.append(runs) }
                runs.removeAll(keepingCapacity: true)
                return
            }
            let raw = runs.map(\.text).joined()
            if let opening = markdownFence, !paragraphs.isEmpty {
                paragraphs[paragraphs.count - 1] += "\n" + raw
                if MarkdownBlockParser.closesFence(raw, opening: opening) { markdownFence = nil }
                runs.removeAll(keepingCapacity: true)
                previousBlankParagraph = false
                return
            }
            var rendered = "", index = 0
            while index < runs.count {
                let start = index, link = runs[index].link, origin = runs[index].field
                while index < runs.count, runs[index].link == link, runs[index].field === origin { index += 1 }
                let text = runs[start..<index].map { renderRun($0) }.joined()
                if let link {
                    let target = link.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E")
                    let destination = target.contains(where: { $0.isWhitespace || $0 == "(" || $0 == ")" }) ? "<" + target + ">" : target
                    rendered += "[" + text + "](" + destination + ")"
                } else { rendered += text }
            }
            runs.removeAll(keepingCapacity: true)
            // Apple's writer serializes attributed hard breaks as U+2028.
            // Keep table breaks canonical and prose/list breaks as Markdown.
            rendered = rendered.replacingOccurrences(of: "\u{2028}", with: rendered.hasPrefix("|") ? "<br>" : "  \n")
            let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                // Leading indentation carries nested list content columns.
                let trailing = rendered.reversed().prefix { $0.isWhitespace }.count
                let paragraph = String(rendered.dropLast(trailing))
                if let opening = MarkdownBlockParser.fence(raw.trimmingCharacters(in: .whitespaces)) {
                    markdownFence = opening
                    paragraphs.append(raw)
                } else if !previousBlankParagraph,
                          (paragraph.hasPrefix(">") && paragraphs.last?.hasPrefix(">") == true)
                            || (paragraph.hasPrefix("|") && paragraphs.last?.hasPrefix("|") == true) {
                    paragraphs[paragraphs.count - 1] += "\n" + paragraph
                } else { paragraphs.append(paragraph) }
                previousBlankParagraph = false
            } else { previousBlankParagraph = true }
        }

        while i < n {
            let c = chars[i]
            // Consecutive `\'hh` escapes form one (possibly multibyte) character;
            // flush the buffer before any other token so byte order is preserved.
            // Raw newlines are non-content (RTF line-wrapping) and can fall *inside*
            // a DBCS character (\'82\r\n\'a0), so they must not flush the buffer.
            if !pendingBytes.isEmpty,
               !(c == "\\" && i + 1 < n && chars[i + 1] == "'"),
               c != "\r", c != "\n", c != "\r\n" {
                flushBytes()
            }
            switch c {
            case "{":
                // Only the parsed top-level ignorable destination emitted by our
                // writer signals canonical Markdown. Binary/ignored payloads do not.
                if stack.count == 1, !ignore, !encounteredBody, chars[i...].starts(with: canonicalMarker) { canonical = true }
                stack.append(GroupState(bold: bold, italic: italic, ignore: ignore, ucSkip: ucSkip, field: field, instruction: instruction, font: font, fontTable: fontTable, fontNameIgnored: fontNameIgnored))
                i += 1

            case "}":
                if let saved = stack.popLast() {
                    finishFont()
                    if instruction, !saved.instruction, let field { field.target = hyperlinkTarget(field.instruction) }
                    bold = saved.bold; italic = saved.italic; ignore = saved.ignore; ucSkip = saved.ucSkip
                    field = saved.field; instruction = saved.instruction
                    font = saved.font; fontTable = saved.fontTable; fontNameIgnored = saved.fontNameIgnored
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
                    case "fonttbl": fontTable = true; ignore = true
                    case "deff": if let param { defaultFont = param; font = param }
                    case "f": if let param { finishFont(); font = param }
                    case "fmodern": if fontTable, !fontNameIgnored { monospacedFonts.insert(font) }
                    case "falt": if fontTable { fontNameIgnored = true }
                    case "field": field = Field()
                    case "fldinst": instruction = field != nil; ignore = true
                    case "fldrslt": instruction = false
                    case "par", "row", "sect", "page":
                        if !ignore { encounteredBody = true; flushParagraph() }   // a \par inside a skipped destination isn't a body break
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
                        if let param, let encoding = Self.encoding(forCodepage: param) {
                            ansiEncoding = encoding
                            isDBCS = Self.dbcsCodepages.contains(param)
                        }
                    case "bin":
                        // \binN: the next N bytes are raw binary (often inside an
                        // ignored \pict/\object) and may contain { } or \ — skip
                        // them so they can't corrupt group/brace parsing.
                        if let param, param > 0 { i += min(param, n - i) }
                    case "plain":
                        bold = false; italic = false; font = defaultFont
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
                            if fallback == "\r" || fallback == "\n" {
                                i += 1
                                continue // Source wrapping is not an ANSI fallback unit.
                            } else if fallback == "{" || fallback == "}" {
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
                    case "*":
                        ignore = true
                        // fonttbl is ignored as body text, but its primary names
                        // are collected separately from ignorable subgroups.
                        if fontTable { fontNameIgnored = true }
                    case "'":
                        if i + 1 < n, let byte = UInt8(String([chars[i], chars[i + 1]]), radix: 16) {
                            // DBCS code pages: buffer the byte (a lead byte alone is
                            // undecodable) and let flushBytes decode whole characters.
                            // Single-byte code pages decode each byte on its own.
                            if isDBCS {
                                if !ignore { pendingBytes.append(byte) }
                            } else {
                                appendText(Self.decodeByte(byte, encoding: ansiEncoding))
                            }
                            i += 2
                        }
                    case "\n", "\r", "\r\n":
                        if !ignore { flushParagraph() }        // escaped newline = \par
                    default: break
                    }
                }

            case "\r", "\n", "\r\n":
                i += 1                                          // raw line-wrapping bytes are not content

            default:
                appendText(String(c))
                i += 1
            }
        }
        flushBytes()
        flushParagraph()
        if canonical { return paragraphs.joined(separator: "\n\n") }
        // Trim the source runs before classifying block/code boundaries, so the
        // projection sees the same indentation as the emitted paragraph.
        nativeParagraphs = nativeParagraphs.map { paragraph in
            var trimmed = paragraph
            for index in trimmed.indices {
                trimmed[index].text = String(trimmed[index].text.drop { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" })
                if !trimmed[index].text.isEmpty { break }
            }
            for index in trimmed.indices.reversed() {
                trimmed[index].text = String(trimmed[index].text.reversed().drop { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" }.reversed())
                if !trimmed[index].text.isEmpty { break }
            }
            return trimmed.filter { !$0.text.isEmpty }
        }
        // Source offsets retain escape provenance. Classify block boundaries
        // from composed style runs, whose prefixes can change Markdown syntax.
        let source = nativeParagraphs.map { $0.map(\.text).joined() }.joined(separator: "\n\n")
        var boundaries: Set<Int> = [], position = 0
        for paragraph in nativeParagraphs {
            for run in paragraph { boundaries.insert(position); position += run.text.utf16.count }
            position += 2
        }
        let structure = nativeParagraphs.map { renderRuns($0) }.joined(separator: "\n\n")
        let escapes = MarkdownLiteral.escapeProjection(source, boundaries: boundaries, structuralText: structure)
        var offset = 0
        return nativeParagraphs.map { paragraph in
            let escapedRuns = paragraph.map { run in
                var escapedRun = run
                var units: [UInt16] = []
                for unit in run.text.utf16 {
                    if escapes.before.contains(offset) { units.append(0x5C) }
                    units.append(unit)
                    for _ in 0..<escapes.after[offset] { units.append(unit) }
                    offset += 1
                }
                escapedRun.text = String(decoding: units, as: UTF16.self)
                return escapedRun
            }
            offset += 2
            return renderRuns(escapedRuns)
        }.joined(separator: "\n\n")
    }

    private static func renderRuns(_ runs: [Run]) -> String {
        var rendered = "", index = 0
        while index < runs.count {
            let start = index, link = runs[index].link, origin = runs[index].field
            while index < runs.count, runs[index].link == link, runs[index].field === origin { index += 1 }
            let text = runs[start..<index].map { renderRun($0) }.joined()
            if let link {
                let target = link.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E")
                let destination = target.contains(where: { $0.isWhitespace || $0 == "(" || $0 == ")" }) ? "<" + target + ">" : target
                rendered += "[" + text + "](" + destination + ")"
            } else { rendered += text }
        }
        return rendered
    }

    private static let fieldTokenPattern = try! NSRegularExpression(pattern: #""([^"]*)"|(\S+)"#)
    private static func hyperlinkTarget(_ instruction: String) -> String? {
        guard instruction.utf8.count <= Field.maximumInstructionBytes else { return nil }
        let ns = instruction as NSString
        let tokens = fieldTokenPattern.matches(in: instruction, range: NSRange(location: 0, length: ns.length)).map { match in
            let quoted = match.range(at: 1).location != NSNotFound
            return (text: ns.substring(with: match.range(at: quoted ? 1 : 2)), quoted: quoted)
        }
        guard tokens.first?.text.uppercased() == "HYPERLINK" else { return nil }
        var target: String?, bookmark: String?, index = 1
        while index < tokens.count {
            let entry = tokens[index], token = entry.text
            let switchName = token.lowercased()
            index += 1
            if !entry.quoted, switchName == "\\l" || switchName == "\\o" || switchName == "\\t" {
                guard index < tokens.count else { return nil }
                if switchName == "\\l" { bookmark = tokens[index].text }
                index += 1
            } else if !entry.quoted, token.hasPrefix("\\") { continue }
            else if target == nil { target = token }
        }
        if let bookmark, !bookmark.isEmpty {
            return (target?.components(separatedBy: "#").first ?? "") + "#" + bookmark
        }
        return target.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Windows code pages that are double-byte (DBCS): one character may span two
    /// consecutive `\'hh` escapes, so their bytes are buffered and group-decoded
    /// (`decodeBytes`) rather than decoded one byte at a time. 932 Shift-JIS, 936
    /// GBK, 949 UHC, 950 Big5, 1361 Johab.
    private static let dbcsCodepages: Set<Int> = [932, 936, 949, 950, 1361]

    /// Decodes a run of buffered `\'hh` bytes using the declared code page —
    /// required for DBCS code pages, where a lead byte is undecodable on its own.
    ///
    /// If the whole run decodes, return it. Otherwise walk it greedily, taking the
    /// longest valid unit at each step (a two-byte lead+trail pair, else a single
    /// byte), so a malformed or partial byte only affects itself and not the valid
    /// characters around it — one bad byte can't corrupt a whole run of CJK. The
    /// offending byte still falls back to Windows-1252/Latin-1 so nothing is lost.
    private static func decodeBytes(_ bytes: [UInt8], encoding: String.Encoding) -> String {
        if let decoded = String(bytes: bytes, encoding: encoding), !decoded.isEmpty {
            return decoded
        }
        var result = ""
        var idx = 0
        let count = bytes.count
        while idx < count {
            if idx + 1 < count,
               let pair = String(bytes: bytes[idx...(idx + 1)], encoding: encoding), !pair.isEmpty {
                result += pair
                idx += 2
            } else if let single = String(bytes: bytes[idx...idx], encoding: encoding), !single.isEmpty {
                result += single
                idx += 1
            } else {
                result += decodeByte(bytes[idx], encoding: encoding)
                idx += 1
            }
        }
        return result
    }

    /// Decodes a single `\'hh` byte using the document's declared code page
    /// (`\ansicpgN`, defaulting to Windows-1252 for `\ansi`) — so bytes 0x80–0x9F
    /// become the right punctuation/letters rather than C1 control characters.
    /// Falls back to Windows-1252, then Latin-1, for undecodable bytes.
    ///
    /// Used for single-byte code pages; DBCS code pages declared via `\ansicpg`
    /// (Shift-JIS, GBK, Big5, …) are reassembled across escapes by `decodeBytes`.
    /// A document that switches code page per font via `\fcharsN` alone (without
    /// `\ansicpg`) is still a deferred niche — the font table isn't tracked.
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
        if run.code {
            let text = run.text
            let delimiter = String(repeating: "`", count: max(1, (text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0) + 1))
            let padding = text.hasPrefix("`") || text.hasSuffix("`") || (text.hasPrefix(" ") && text.hasSuffix(" ") && text.contains(where: { $0 != " " })) ? " " : ""
            var fragment = delimiter + padding + text + padding + delimiter
            if run.italic { fragment = "*" + fragment + "*" }
            if run.bold { fragment = "**" + fragment + "**" }
            return fragment
        }
        if run.text.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\n" }) { return run.text }
        let isSpace: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        let afterLeading = run.text.drop(while: isSpace)
        let leading = String(run.text.prefix(run.text.count - afterLeading.count))
        let trailingCount = afterLeading.reversed().prefix(while: isSpace).count
        let trailing = String(afterLeading.suffix(trailingCount))
        var core = String(afterLeading.dropLast(trailingCount))
        if run.link != nil { core = core.map { #"\`*_[]<>"#.contains($0) ? "\\" + String($0) : String($0) }.joined() }
        if run.italic { core = "*\(core)*" }
        if run.bold { core = "**\(core)**" }
        return leading + core + trailing
    }
}
