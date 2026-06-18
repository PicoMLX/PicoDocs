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
        guard let labelEnd = firstIndex(of: "]", in: chars, from: bracket + 1) else { return nil }
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
            guard let parenClose = firstIndex(of: ")", in: chars, from: destStart) else { return nil }
            dest = String(chars[destStart..<parenClose])
            cursor = parenClose
        }
        let labelText = String(chars[(bracket + 1)..<labelEnd])
        let node: MarkdownInline = isImage
            ? .image(alt: labelText, source: dest)
            : .link(label: parse(labelText), destination: dest)
        return (node, cursor + 1)   // past the ")"
    }

    // MARK: - Emphasis

    /// Parses `***`/`**`/`*` emphasis into nested nodes, preferring (at the same
    /// position) the longest delimiter — mirroring the renderer's pass order so
    /// `***x***` becomes strong(emphasis(x)).
    static func parseEmphasis(_ text: String) -> [MarkdownInline] {
        guard !text.isEmpty else { return [] }
        let patterns: [(pattern: String, wrap: ([MarkdownInline]) -> MarkdownInline)] = [
            ("\\*\\*\\*(.+?)\\*\\*\\*", { .strong([.emphasis($0)]) }),
            ("\\*\\*(.+?)\\*\\*", { .strong($0) }),
            ("\\*(.+?)\\*", { .emphasis($0) }),
        ]
        let ns = text as NSString
        var best: (full: Range<String.Index>, inner: String, wrap: ([MarkdownInline]) -> MarkdownInline)?
        for (pattern, wrap) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
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
