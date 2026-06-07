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
        let markdown = Self.markdown(fromRTF: rtf)
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PicoDocsError.emptyDocument
        }
        let section = DocumentSection(title: info.filename, kind: .body, markdown: markdown)
        return ConverterResult(title: info.filename, sections: [section])
    }

    // MARK: - Parser

    private struct Run { var text: String; var bold: Bool; var italic: Bool }
    private struct GroupState { var bold: Bool; var italic: Bool; var ignore: Bool }

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
        var stack: [GroupState] = []

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
                stack.append(GroupState(bold: bold, italic: italic, ignore: ignore))
                i += 1

            case "}":
                if let saved = stack.popLast() {
                    bold = saved.bold; italic = saved.italic; ignore = saved.ignore
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
                    case "par", "row", "sect":
                        flushParagraph()
                    case "line":
                        appendText("\n")
                    case "tab", "cell":
                        appendText("\t")
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
                            let value = param < 0 ? param + 65_536 : param
                            if value >= 0, let scalar = Unicode.Scalar(UInt32(value)) {
                                appendText(String(Character(scalar)))
                            }
                        }
                        // Skip the \ucN fallback characters that follow a \uN.
                        var skipped = 0
                        while i < n, skipped < ucSkip,
                              chars[i] != "\\", chars[i] != "{", chars[i] != "}" {
                            i += 1; skipped += 1
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
                        if i + 1 < n,
                           let byte = UInt32(String([chars[i], chars[i + 1]]), radix: 16),
                           let scalar = Unicode.Scalar(byte) {
                            appendText(String(Character(scalar)))
                            i += 2
                        }
                    case "\n", "\r": flushParagraph()          // escaped newline = \par
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
