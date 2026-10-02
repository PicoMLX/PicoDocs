//
//  AttributedStringDocumentBuilder.swift
//  PicoDocs
//
//  Builds an `NSAttributedString` from a `ConverterResult` using the shared
//  Markdown block + inline IR, so Apple's document writers can serialize it to RTF
//  (`.rtf`) and DOCX (`.officeOpenXML`).
//
//  Why build the attributed string directly instead of via HTML import: the
//  `NSAttributedString(data:options:[.documentType:.html])` importer is WebKit-
//  backed and must run on the main thread, which would make the exporters unusable
//  from the engine's non-isolated, `Sendable` `write(...)`. Constructing runs from
//  the IR keeps serialization thread-agnostic and pure CPU.
//
//  Scope: prose fidelity (headings, bold/italic, links, lists, code, blockquotes,
//  tables as tab-separated rows). Images are rendered as their alt text here — the
//  hand-rolled OOXML exporters embed real image bytes; embedding via platform image
//  attachments (NSImage vs UIImage) is intentionally avoided to keep this portable
//  across AppKit/UIKit.
//

#if canImport(AppKit) || canImport(UIKit)

import Foundation

#if canImport(AppKit)
import AppKit
private typealias PlatformFont = NSFont
#elseif canImport(UIKit)
import UIKit
private typealias PlatformFont = UIFont
#endif

enum AttributedStringDocumentBuilder {

    private static let baseSize: CGFloat = 12

    /// Heading point sizes by level (1...6).
    private static func headingSize(_ level: Int) -> CGFloat {
        switch max(1, min(level, 6)) {
        case 1: return 24
        case 2: return 20
        case 3: return 17
        case 4: return 15
        case 5: return 13
        default: return 12
        }
    }

    static func attributedString(from result: ConverterResult, preserveBlockMarkers: Bool = false) throws -> NSAttributedString {
        try Task.checkCancellation()
        let result = PicoDocsEngine.withSynthesizedImageReferences(result)
        try Task.checkCancellation()
        let output = NSMutableAttributedString()
        let blocks = OfficeDocumentBlocks.parse(result)
        try Task.checkCancellation()
        for (index, block) in blocks.enumerated() {
            try Task.checkCancellation()
            try append(block, to: output, preserveBlockMarkers: preserveBlockMarkers)
            if index < blocks.count - 1 {
                output.append(NSAttributedString(string: "\n"))
            }
        }
        try Task.checkCancellation()
        return output
    }

    // MARK: - Blocks

    private static func append(_ block: MarkdownBlock, to output: NSMutableAttributedString, preserveBlockMarkers: Bool) throws {
        switch block {
        case .heading(let level, let text):
            // A visible Markdown marker preserves heading semantics through RTF,
            // whose reader intentionally does not infer headings from font size.
            if preserveBlockMarkers {
                output.append(NSAttributedString(string: String(repeating: "#", count: max(1, min(level, 6))) + " ", attributes: [.font: bodyFont()]))
            }
            output.append(try inline(text, size: headingSize(level), bold: !preserveBlockMarkers, escapeLiterals: preserveBlockMarkers))
            output.append(NSAttributedString(string: "\n"))

        case .paragraph(let text):
            output.append(try inline(text, escapeLiterals: preserveBlockMarkers))
            output.append(NSAttributedString(string: "\n"))

        case .code(let code):
            let attrs: [NSAttributedString.Key: Any] = [.font: monospacedFont(size: baseSize)]
            if preserveBlockMarkers {
                let fence = try codeFence(code, minimum: 3)
                output.append(NSAttributedString(string: fence + "\n" + code + "\n" + fence + "\n", attributes: attrs))
            } else { output.append(NSAttributedString(string: code + "\n", attributes: attrs)) }

        case .blockquote(let lines):
            for line in lines {
                try Task.checkCancellation()
                if preserveBlockMarkers { output.append(NSAttributedString(string: "> ", attributes: [.font: bodyFont()])) }
                output.append(try inline(line, italic: !preserveBlockMarkers, escapeLiterals: preserveBlockMarkers))
                output.append(NSAttributedString(string: "\n"))
            }

        case .list(let list):
            var widths: [Int: Int] = [:]
            for item in list.paragraphs() {
                try Task.checkCancellation()
                let visible = item.ordered ? "\(item.number ?? 1). " : "- "
                let indent = (0..<item.level).reduce(0) { $0 + (widths[$1] ?? 2) }
                let marker = String(repeating: " ", count: indent + (item.continuation ? (widths[item.level] ?? visible.count) : 0)) + (item.continuation ? "" : visible)
                if !item.continuation { widths[item.level] = visible.count }
                output.append(NSAttributedString(string: marker, attributes: [.font: bodyFont()]))
                output.append(try inline(item.text, escapeLiterals: preserveBlockMarkers, hardBreakIndent: preserveBlockMarkers ? String(repeating: " ", count: marker.count) : ""))
                output.append(NSAttributedString(string: "\n"))
            }

        case .table(let rows):
            if preserveBlockMarkers {
                for (index, row) in rows.enumerated() {
                    try Task.checkCancellation()
                    let cells = try row.map { cell in
                        try Task.checkCancellation()
                        return MarkdownTableCell.escapeCanonicalPipes(try tableMarkup(MarkdownInlineParser.parse(cell, tableCell: true)))
                    }
                    output.append(NSAttributedString(string: "| " + cells.joined(separator: " | ") + " |\n", attributes: [.font: bodyFont()]))
                    if index == 0 {
                        output.append(NSAttributedString(string: "| " + Array(repeating: "---", count: row.count).joined(separator: " | ") + " |\n", attributes: [.font: bodyFont()]))
                    }
                }
                break
            }
            for row in rows {
                try Task.checkCancellation()
                for (index, cell) in row.enumerated() {
                    try Task.checkCancellation()
                    if index > 0 { output.append(NSAttributedString(string: "\t")) }
                    try render(MarkdownInlineParser.parse(cell, tableCell: true), into: output, size: baseSize, bold: false, italic: false, link: nil)
                }
                output.append(NSAttributedString(string: "\n"))
            }

        case .rule:
            output.append(NSAttributedString(string: preserveBlockMarkers ? "---\n" : "————————\n", attributes: [.font: bodyFont()]))
        }
    }

    // MARK: - Inline

    /// Canonical table markup keeps cell structure while using native RTF line
    /// separators for hard breaks. Literal code and escaped punctuation stay literal.
    private static func tableMarkup(_ nodes: [MarkdownInline]) throws -> String {
        func escaped(_ text: String) throws -> String {
            try escapedText(text, punctuation: #"\`*_[]<>"#)
        }
        func destination(_ text: String) -> String {
            "<" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E") + ">"
        }
        return try nodes.map { node in
            try Task.checkCancellation()
            switch node {
            case .text(let text): return try escaped(text)
            case .lineBreak(let hard): return hard ? "\u{2028}" : " "
            case .code(let text):
                let fence = try codeFence(text, minimum: 1)
                let padding = text.contains(where: { $0 != " " }) ? " " : ""
                return fence + padding + text + padding + fence
            case .strong(let children): return try "**" + tableMarkup(children) + "**"
            case .emphasis(let children): return try "*" + tableMarkup(children) + "*"
            case .link(let label, let target): return try "[" + tableMarkup(label) + "](" + destination(target) + ")"
            case .image(let alt, let target): return try "![" + escaped(alt) + "](" + destination(target) + ")"
            case .footnoteReference(let id): return try "[^" + escaped(id) + "]"
            }
        }.joined()
    }


    private static func inline(_ markdown: String, size: CGFloat = baseSize, bold: Bool = false, italic: Bool = false, escapeLiterals: Bool = false, hardBreakIndent: String = "") throws -> NSAttributedString {
        try Task.checkCancellation()
        let result = NSMutableAttributedString()
        try render(MarkdownInlineParser.parse(markdown), into: result, size: size, bold: bold, italic: italic, link: nil, escapeLiterals: escapeLiterals, hardBreakIndent: hardBreakIndent)
        try Task.checkCancellation()
        return result
    }

    private static func render(_ nodes: [MarkdownInline], into output: NSMutableAttributedString, size: CGFloat, bold: Bool, italic: Bool, link: String?, escapeLiterals: Bool = false, hardBreakIndent: String = "") throws {
        func escaped(_ text: String) throws -> String {
            // The reader already escapes hyperlink labels before adding Markdown.
            guard escapeLiterals, link == nil else { return text }
            return try escapedText(text, punctuation: #"\`*_{}[]<>()#+-.!|~"#)
        }
        for node in nodes {
            try Task.checkCancellation()
            switch node {
            case .text(let s):
                output.append(NSAttributedString(string: try escaped(s), attributes: attributes(size: size, bold: bold, italic: italic, monospace: false, link: link)))
            case .lineBreak(let hard):
                output.append(NSAttributedString(string: hard ? (escapeLiterals ? "\u{2028}" : "\n") + hardBreakIndent : " ", attributes: attributes(size: size, bold: bold, italic: italic, monospace: false, link: link)))
            case .code(let s):
                let text = escapeLiterals && link == nil ? try tableMarkup([.code(s)]) : s
                output.append(NSAttributedString(string: text, attributes: attributes(size: size, bold: bold, italic: italic, monospace: true, link: link)))
            case .strong(let children):
                try render(children, into: output, size: size, bold: true, italic: italic, link: link, escapeLiterals: escapeLiterals, hardBreakIndent: hardBreakIndent)
            case .emphasis(let children):
                try render(children, into: output, size: size, bold: bold, italic: true, link: link, escapeLiterals: escapeLiterals, hardBreakIndent: hardBreakIndent)
            case .link(let label, let destination):
                let accepted = DocumentRenderer.isSafeURL(destination, isImage: false) && URL(string: destination) != nil
                try render(label, into: output, size: size, bold: bold, italic: italic, link: accepted ? destination : nil, escapeLiterals: escapeLiterals, hardBreakIndent: hardBreakIndent)
            case .image:
                output.append(NSAttributedString(string: try escaped(node.plainText), attributes: attributes(size: size, bold: bold, italic: italic, monospace: false, link: link)))
            case .footnoteReference(let id):
                // No footnote machinery in RTF output; keep the marker as literal text
                // (as the DOCX writer does) so references and `[^id]: note`
                // definitions stay paired.
                output.append(NSAttributedString(string: "[^\(id)]", attributes: attributes(size: size, bold: bold, italic: italic, monospace: false, link: link)))
            }
        }
    }

    private static func escapedText(_ text: String, punctuation: String) throws -> String {
        try text.enumerated().map { index, character in
            if index.isMultiple(of: 4096) { try Task.checkCancellation() }
            return punctuation.contains(character) ? "\\" + String(character) : String(character)
        }.joined()
    }

    private static func codeFence(_ text: String, minimum: Int) throws -> String {
        var longest = 0, run = 0
        for (index, character) in text.enumerated() {
            if index.isMultiple(of: 4096) { try Task.checkCancellation() }
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        return String(repeating: "`", count: max(minimum, longest + 1))
    }

    private static func attributes(size: CGFloat, bold: Bool, italic: Bool, monospace: Bool, link: String?) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: monospace ? monospacedFont(size: size, bold: bold, italic: italic) : font(size: size, bold: bold, italic: italic)
        ]
        if let link, DocumentRenderer.isSafeURL(link, isImage: false), let url = URL(string: link) { attrs[.link] = url }
        return attrs
    }

    // MARK: - Fonts

    private static func bodyFont() -> PlatformFont { font(size: baseSize, bold: false, italic: false) }

    private static func font(size: CGFloat, bold: Bool, italic: Bool) -> PlatformFont {
        let base = PlatformFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        return italic ? applyItalic(base, size: size) : base
    }

    private static func monospacedFont(size: CGFloat, bold: Bool = false, italic: Bool = false) -> PlatformFont {
        let base = PlatformFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
        return italic ? applyItalic(base, size: size) : base
    }

    private static func applyItalic(_ base: PlatformFont, size: CGFloat) -> PlatformFont {
        #if canImport(AppKit)
        let descriptor = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.italic))
        return NSFont(descriptor: descriptor, size: size) ?? base
        #else
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(
            base.fontDescriptor.symbolicTraits.union(.traitItalic)
        ) else { return base }
        return UIFont(descriptor: descriptor, size: size)
        #endif
    }
}

#endif
