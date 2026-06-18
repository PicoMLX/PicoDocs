//
//  MarkdownInline.swift
//  PicoDocs
//
//  A structured inline intermediate representation for the Markdown subset the
//  converters emit. The renderer's existing inline helpers (`extractCodeSpans`,
//  `extractLinks`, `applyEmphasisHTML`/`Strip`) are geared toward emitting HTML or
//  stripping to text; the office exporters instead need *run structure* — a DOCX
//  `w:r` with `w:b`/`w:i`, a `w:hyperlink`, an inline image — so they consume this
//  tree.
//
//  Scope (Phase 0B): this IR is introduced for the exporters. The HTML/plaintext
//  renderers keep their own battle-tested inline path for now; converging them onto
//  this model is a separate, test-guarded step.
//

import Foundation

/// One inline node of the canonical Markdown subset. Emphasis/strong/link labels
/// nest, so they carry child nodes.
indirect enum MarkdownInline: Equatable {
    case text(String)
    case strong([MarkdownInline])
    case emphasis([MarkdownInline])
    case code(String)
    case link(label: [MarkdownInline], destination: String)
    case image(alt: String, source: String)
    case footnoteReference(String)
}

enum MarkdownInlineParser {

    /// Parses an inline Markdown string into structured nodes. Code spans, links,
    /// images, and footnote references are pulled out by a single scan (so their
    /// contents aren't reinterpreted), and the remaining plain-text runs are parsed
    /// for `*`/`**`/`***` emphasis.
    static func parse(_ text: String) -> [MarkdownInline] {
        let chars = Array(text)
        var nodes: [MarkdownInline] = []
        var run = ""
        var i = 0

        func flush() {
            if !run.isEmpty {
                nodes.append(contentsOf: parseEmphasis(run))
                run = ""
            }
        }

        while i < chars.count {
            let c = chars[i]

            // Inline code span: `...` (literal, no nested formatting).
            if c == "`", let close = firstIndex(of: "`", in: chars, from: i + 1) {
                flush()
                nodes.append(.code(String(chars[(i + 1)..<close])))
                i = close + 1
                continue
            }

            // Image: ![alt](dest)
            if c == "!", i + 1 < chars.count, chars[i + 1] == "[",
               let parsed = parseLinkOrImage(chars, from: i, isImage: true) {
                flush()
                nodes.append(parsed.node)
                i = parsed.next
                continue
            }

            if c == "[" {
                // Footnote reference: [^id]
                if i + 1 < chars.count, chars[i + 1] == "^",
                   let close = firstIndex(of: "]", in: chars, from: i + 2) {
                    let id = String(chars[(i + 2)..<close])
                    if !id.isEmpty {
                        flush()
                        nodes.append(.footnoteReference(id))
                        i = close + 1
                        continue
                    }
                }
                // Link: [label](dest)
                if let parsed = parseLinkOrImage(chars, from: i, isImage: false) {
                    flush()
                    nodes.append(parsed.node)
                    i = parsed.next
                    continue
                }
            }

            run.append(c)
            i += 1
        }
        flush()
        return nodes
    }

    // MARK: - Link / image

    /// Parses `[label](dest)` or `![alt](dest)` starting at `from` (the `[` for a
    /// link, the `!` for an image). Supports CommonMark angle-bracket destinations
    /// `(<url with spaces>)` that `WordConverter` emits. Returns the node and the
    /// index just past the closing `)`, or nil if the syntax doesn't match.
    private static func parseLinkOrImage(_ chars: [Character], from: Int, isImage: Bool) -> (node: MarkdownInline, next: Int)? {
        let bracket = isImage ? from + 1 : from
        guard bracket < chars.count, chars[bracket] == "[" else { return nil }
        // Find the label's closing `]`, skipping backslash-escaped delimiters:
        // `WordConverter` escapes `[`/`]` inside labels and alt text, so a visible
        // `]` arrives as `\]` and must not terminate the label early.
        guard let labelEnd = indexOfUnescaped("]", in: chars, from: bracket + 1) else { return nil }
        let parenOpen = labelEnd + 1
        guard parenOpen < chars.count, chars[parenOpen] == "(" else { return nil }

        let destStart = parenOpen + 1
        var dest = ""
        var cursor = destStart
        if destStart < chars.count, chars[destStart] == "<" {
            guard let gt = firstIndex(of: ">", in: chars, from: destStart + 1) else { return nil }
            dest = String(chars[(destStart + 1)..<gt])
            cursor = gt + 1
            guard cursor < chars.count, chars[cursor] == ")" else { return nil }
        } else {
            // Bare destination: match balanced parentheses so a URL such as
            // `https://example.com/Foo_(bar)` (common in raw LLM Markdown) isn't
            // truncated at the first `)`.
            guard let parenClose = balancedParenClose(chars, from: destStart) else { return nil }
            dest = unescape(String(chars[destStart..<parenClose]))
            cursor = parenClose
        }
        let labelText = unescape(String(chars[(bracket + 1)..<labelEnd]))
        let node: MarkdownInline = isImage
            ? .image(alt: labelText, source: dest)
            : .link(label: parse(labelText), destination: dest)
        return (node, cursor + 1)   // past the ")"
    }

    /// First index of `character` at or after `start` that isn't backslash-escaped.
    private static func indexOfUnescaped(_ character: Character, in chars: [Character], from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }   // skip the escape and its target
            if chars[i] == character { return i }
            i += 1
        }
        return nil
    }

    /// Index of the `)` that closes a bare destination opened just past `(`,
    /// honoring nested balanced parens and backslash escapes; nil if unbalanced.
    private static func balancedParenClose(_ chars: [Character], from start: Int) -> Int? {
        var depth = 0
        var i = start
        while i < chars.count {
            let c = chars[i]
            if c == "\\" { i += 2; continue }
            if c == "(" { depth += 1 }
            else if c == ")" {
                if depth == 0 { return i }
                depth -= 1
            }
            i += 1
        }
        return nil
    }

    /// Removes backslash escapes (`\x` -> `x`), recovering the literal label/destination
    /// text that `WordConverter` (and CommonMark authors) escape.
    private static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var out = ""
        var escaped = false
        for ch in text {
            if escaped { out.append(ch); escaped = false }
            else if ch == "\\" { escaped = true }
            else { out.append(ch) }
        }
        if escaped { out.append("\\") }
        return out
    }

    // MARK: - Emphasis

    /// `***`/`**`/`*` matchers, compiled once. `parseEmphasis` recurses over every
    /// inline run, so rebuilding these per call was needless CPU; the patterns are
    /// constant and known-valid, hence `try!`.
    private static let emphasisPatterns: [(regex: NSRegularExpression, wrap: ([MarkdownInline]) -> MarkdownInline)] = [
        (try! NSRegularExpression(pattern: "\\*\\*\\*(.+?)\\*\\*\\*"), { .strong([.emphasis($0)]) }),
        (try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*"), { .strong($0) }),
        (try! NSRegularExpression(pattern: "\\*(.+?)\\*"), { .emphasis($0) }),
    ]

    /// Parses `***`/`**`/`*` emphasis into nested nodes, preferring (at the same
    /// position) the longest delimiter — mirroring the renderer's pass order so
    /// `***x***` becomes strong(emphasis(x)).
    static func parseEmphasis(_ text: String) -> [MarkdownInline] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        var best: (full: Range<String.Index>, inner: String, wrap: ([MarkdownInline]) -> MarkdownInline)?
        for (regex, wrap) in emphasisPatterns {
            guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
                  let full = Range(match.range, in: text),
                  let inner = Range(match.range(at: 1), in: text) else { continue }
            // Strictly-less keeps the first (longest) pattern at a tie position.
            if best == nil || full.lowerBound < best!.full.lowerBound {
                best = (full, String(text[inner]), wrap)
            }
        }
        guard let match = best else { return [.text(text)] }
        var nodes: [MarkdownInline] = []
        let prefix = String(text[text.startIndex..<match.full.lowerBound])
        if !prefix.isEmpty { nodes.append(.text(prefix)) }
        nodes.append(match.wrap(parseEmphasis(match.inner)))
        nodes.append(contentsOf: parseEmphasis(String(text[match.full.upperBound...])))
        return nodes
    }

    private static func firstIndex(of character: Character, in chars: [Character], from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == character { return i }
            i += 1
        }
        return nil
    }
}

// MARK: - Plain text projection

extension MarkdownInline {
    /// The node's visible text with all inline formatting removed (links/images
    /// collapse to their label/alt; footnote references contribute nothing). Useful
    /// for exporters that need a bare string, e.g. spreadsheet cells.
    var plainText: String {
        switch self {
        case .text(let s): return s
        case .code(let s): return s
        case .strong(let children), .emphasis(let children): return children.plainText
        case .link(let label, _): return label.plainText
        case .image(let alt, _): return alt
        case .footnoteReference: return ""
        }
    }
}

extension Array where Element == MarkdownInline {
    var plainText: String { map(\.plainText).joined() }
}
