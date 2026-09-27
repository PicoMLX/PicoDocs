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

    static func attributedString(from result: ConverterResult, preserveBlockMarkers: Bool = false) -> NSAttributedString {
        let result = PicoDocsEngine.withSynthesizedImageReferences(result)
        let output = NSMutableAttributedString()
        let blocks = OfficeDocumentBlocks.parse(result)
        for (index, block) in blocks.enumerated() {
            append(block, to: output, preserveBlockMarkers: preserveBlockMarkers)
            if index < blocks.count - 1 {
                output.append(NSAttributedString(string: "\n"))
            }
        }
        return output
    }

    // MARK: - Blocks

    private static func append(_ block: MarkdownBlock, to output: NSMutableAttributedString, preserveBlockMarkers: Bool) {
        switch block {
        case .heading(let level, let text):
            // A visible Markdown marker preserves heading semantics through RTF,
            // whose reader intentionally does not infer headings from font size.
            if preserveBlockMarkers {
                output.append(NSAttributedString(string: String(repeating: "#", count: max(1, min(level, 6))) + " ", attributes: [.font: bodyFont()]))
            }
            output.append(inline(text, size: headingSize(level), bold: true))
            output.append(NSAttributedString(string: "\n"))

        case .paragraph(let text):
            output.append(inline(text))
            output.append(NSAttributedString(string: "\n"))

        case .code(let code):
            let attrs: [NSAttributedString.Key: Any] = [.font: monospacedFont(size: baseSize)]
            if preserveBlockMarkers {
                var longest = 0, run = 0
                for character in code {
                    run = character == "`" ? run + 1 : 0
                    longest = max(longest, run)
                }
                let fence = String(repeating: "`", count: max(3, longest + 1))
                output.append(NSAttributedString(string: fence + "\n" + code + "\n" + fence + "\n", attributes: attrs))
            } else { output.append(NSAttributedString(string: code + "\n", attributes: attrs)) }

        case .blockquote(let lines):
            for line in lines {
                if preserveBlockMarkers { output.append(NSAttributedString(string: "> ", attributes: [.font: bodyFont()])) }
                output.append(inline(line, italic: true))
                output.append(NSAttributedString(string: "\n"))
            }

        case .list(let list):
            var widths: [Int: Int] = [:]
            for item in list.paragraphs() {
                let visible = item.ordered ? "\(item.number ?? 1). " : "- "
                let indent = (0..<item.level).reduce(0) { $0 + (widths[$1] ?? 2) }
                let marker = String(repeating: " ", count: indent + (item.continuation ? (widths[item.level] ?? visible.count) : 0)) + (item.continuation ? "" : visible)
                if !item.continuation { widths[item.level] = visible.count }
                output.append(NSAttributedString(string: marker, attributes: [.font: bodyFont()]))
                output.append(inline(item.text))
                output.append(NSAttributedString(string: "\n"))
            }

        case .table(let rows):
            for row in rows {
                for (index, cell) in row.enumerated() {
                    if index > 0 { output.append(NSAttributedString(string: "\t")) }
                    render(MarkdownInlineParser.parse(cell, tableCell: true), into: output, size: baseSize, bold: false, italic: false, link: nil)
                }
                output.append(NSAttributedString(string: "\n"))
            }

        case .rule:
            output.append(NSAttributedString(string: "————————\n", attributes: [.font: bodyFont()]))
        }
    }

    // MARK: - Inline

    private static func inline(_ markdown: String, size: CGFloat = baseSize, bold: Bool = false, italic: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString()
        render(MarkdownInlineParser.parse(markdown), into: result, size: size, bold: bold, italic: italic, link: nil)
        return result
    }

    private static func render(_ nodes: [MarkdownInline], into output: NSMutableAttributedString, size: CGFloat, bold: Bool, italic: Bool, link: String?) {
        for node in nodes {
            switch node {
            case .text(let s):
                output.append(NSAttributedString(string: s, attributes: attributes(size: size, bold: bold, italic: italic, monospace: false, link: link)))
            case .lineBreak(let hard):
                output.append(NSAttributedString(string: hard ? "\n" : " ", attributes: attributes(size: size, bold: bold, italic: italic, monospace: false, link: link)))
            case .code(let s):
                output.append(NSAttributedString(string: s, attributes: attributes(size: size, bold: bold, italic: italic, monospace: true, link: link)))
            case .strong(let children):
                render(children, into: output, size: size, bold: true, italic: italic, link: link)
            case .emphasis(let children):
                render(children, into: output, size: size, bold: bold, italic: true, link: link)
            case .link(let label, let destination):
                render(label, into: output, size: size, bold: bold, italic: italic, link: destination)
            case .image(let alt, _):
                output.append(NSAttributedString(string: alt, attributes: attributes(size: size, bold: bold, italic: italic, monospace: false, link: link)))
            case .footnoteReference(let id):
                // No footnote machinery in RTF output; keep the marker as literal text
                // (as the DOCX writer does) so references and `[^id]: note`
                // definitions stay paired.
                output.append(NSAttributedString(string: "[^\(id)]", attributes: attributes(size: size, bold: bold, italic: italic, monospace: false, link: link)))
            }
        }
    }

    private static func attributes(size: CGFloat, bold: Bool, italic: Bool, monospace: Bool, link: String?) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: monospace ? monospacedFont(size: size, bold: bold, italic: italic) : font(size: size, bold: bold, italic: italic)
        ]
        if let link, let url = URL(string: link) { attrs[.link] = url }
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
