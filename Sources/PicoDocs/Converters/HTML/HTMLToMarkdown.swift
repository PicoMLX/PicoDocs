//
//  HTMLToMarkdown.swift
//  PicoDocs
//
//  Converts an HTML document to Markdown by walking the SwiftSoup DOM directly —
//  no NSAttributedString round-trip (which was lossy and main-thread-bound).
//  Synchronous and Sendable-friendly; reused by the EPUB converter later.
//

import Foundation
import SwiftSoup

enum HTMLToMarkdown {

    /// Parses `html` and renders its `<body>` to Markdown, returning the document
    /// title (from `<title>`) when present. `baseURI` resolves relative links.
    static func convert(html: String, baseURI: String? = nil) throws -> (title: String?, markdown: String) {
        let document = try SwiftSoup.parse(html, baseURI ?? "")
        let title = (try? document.title()).flatMap { $0.isEmpty ? nil : $0 }
        let root: Node = document.body() ?? document
        var out = ""
        renderChildren(of: root, into: &out)
        let markdown = normalizeBlankLines(out).trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, markdown)
    }

    /// Renders an already-parsed `Element` (e.g. the body, or the subtree the
    /// Readability scorer selected) to Markdown. Relative links resolve against
    /// the element's owner-document base URI. `Document` is an `Element`, so the
    /// whole document can be passed too.
    ///
    /// Renders the element *itself*, not just its children, so a semantic root
    /// (e.g. a `<table>` chosen as the Readability top candidate) goes through
    /// the matching block handler rather than having its cells concatenated.
    static func convert(element: Element) -> String {
        var out = ""
        render(element, into: &out)
        return normalizeBlankLines(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Walking

    private static func renderChildren(of node: Node, into out: inout String, preserveWhitespace: Bool = false, inList: Bool = false, depth: Int = 0) {
        for child in node.getChildNodes() {
            render(child, into: &out, preserveWhitespace: preserveWhitespace, inList: inList, depth: depth + 1)
        }
    }

    /// Renders an element's children to a trimmed inline string (whitespace
    /// collapsed — used for headings, links, emphasis, etc.).
    private static func inlineString(_ element: Element, inList: Bool, depth: Int) -> String {
        var s = ""
        renderChildren(of: element, into: &s, inList: inList, depth: depth)
        return collapseWhitespace(s).trimmingCharacters(in: .whitespaces)
    }

    private static func render(_ node: Node, into out: inout String, preserveWhitespace: Bool = false, inList: Bool = false, depth: Int = 0) {
        // Bound semantic recursion while retaining all visible text from an
        // unusually deep subtree. The fallback traversal itself is iterative.
        guard depth < 64 else {
            let text = flattenedText(node)
            out += preserveWhitespace ? text : escapeLiteral(collapseWhitespace(text), blockSyntax: inList)
            return
        }
        if let text = node as? TextNode {
            let whole = text.getWholeText()
            // Canonical Markdown must distinguish literal source characters
            // from markup emitted by semantic HTML tags.
            out += preserveWhitespace ? whole : escapeLiteral(collapseWhitespace(whole), blockSyntax: inList)
            return
        }
        guard let element = node as? Element else { return }

        switch element.tagName().lowercased() {
        case "script", "style", "noscript", "head", "title", "meta", "link", "svg":
            return // non-content

        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(element.tagName().dropFirst()) ?? 1
            let text = inlineString(element, inList: inList, depth: depth)
            if !text.isEmpty { out += "\n\n\(String(repeating: "#", count: level)) \(text)\n\n" }

        case "br":
            out += "  \n"

        case "hr":
            out += "\n\n---\n\n"

        case "strong", "b":
            let t = inlineString(element, inList: inList, depth: depth)
            if !t.isEmpty { out += "**\(t)**" }

        case "em", "i":
            let t = inlineString(element, inList: inList, depth: depth)
            if !t.isEmpty { out += "*\(t)*" }

        case "code":
            if element.parent()?.tagName().lowercased() == "pre" {
                renderChildren(of: element, into: &out, preserveWhitespace: true, inList: inList, depth: depth) // inside a fenced block
            } else {
                let t = (try? element.text()) ?? ""
                if !t.isEmpty { out += "`\(t)`" }
            }

        case "pre":
            out += "\n\n```\n"
            renderChildren(of: element, into: &out, preserveWhitespace: true, inList: inList, depth: depth)
            out += "\n```\n\n"

        case "a":
            let text = inlineString(element, inList: inList, depth: depth)
            let href = canonicalDestination(resolvedURL(element, attribute: "href"))
            out += (href.isEmpty || text.isEmpty) ? text : "[\(text)](\(href))"

        case "img":
            let alt = escapeLiteral((try? element.attr("alt")) ?? "", blockSyntax: false)
            let src = canonicalDestination(resolvedURL(element, attribute: "src"))
            if !src.isEmpty { out += "![\(alt)](\(src))" }

        case "ul":
            out += "\n\n" + renderList(element, ordered: false, depth: depth) + "\n\n"

        case "ol":
            out += "\n\n" + renderList(element, ordered: true, depth: depth) + "\n\n"

        case "blockquote":
            var inner = ""
            renderChildren(of: element, into: &inner, preserveWhitespace: preserveWhitespace, inList: inList, depth: depth)
            let quoted = normalizeBlankLines(inner)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
                .map { $0.isEmpty ? ">" : "> \($0)" }
                .joined(separator: "\n")
            if !quoted.isEmpty { out += "\n\n\(quoted)\n\n" }

        case "table":
            let table = renderTable(element, inList: inList, depth: depth)
            if !table.isEmpty { out += "\n\n\(table)\n\n" }

        case "p", "div", "section", "article", "main", "header", "footer", "figure", "figcaption":
            out += "\n\n"
            renderChildren(of: element, into: &out, preserveWhitespace: preserveWhitespace, inList: inList, depth: depth)
            out += "\n\n"

        default:
            renderChildren(of: element, into: &out, preserveWhitespace: preserveWhitespace, inList: inList, depth: depth)
        }
    }

    private static func flattenedText(_ root: Node) -> String {
        // Enter/exit events preserve separation on both sides of block elements
        // without recursively walking an adversarially deep tree.
        let boundaries: Set<String> = ["address", "article", "aside", "blockquote", "br", "caption", "dd", "details", "dialog", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr", "legend", "li", "main", "menu", "nav", "ol", "p", "pre", "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul"]
        var pending: [(Node, Bool)] = [(root, false)], output = ""
        while let (node, exiting) = pending.popLast() {
            if exiting { output += " "; continue }
            if let text = node as? TextNode { output += text.getWholeText(); continue }
            if let element = node as? Element {
                let tag = element.tagName().lowercased()
                if ["script", "style", "noscript", "head", "title", "meta", "link", "svg"].contains(tag) { continue }
                if boundaries.contains(tag) { output += " "; pending.append((node, true)) }
                if tag == "img" { output += (try? element.attr("alt")) ?? "" }
            }
            pending.append(contentsOf: node.getChildNodes().reversed().map { ($0, false) })
        }
        return output
    }

    private static func canonicalDestination(_ url: String) -> String {
        let escaped = url.replacingOccurrences(of: "\\", with: "\\\\")
        return escaped.contains(where: { $0.isWhitespace || $0 == "(" || $0 == ")" }) ? "<\(escaped)>" : escaped
    }

    private static func escapeLiteral(_ text: String, blockSyntax: Bool) -> String {
        let punctuation = blockSyntax ? #"\`*_{}[]<>()#+-.!|"# : #"\`*_{}[]<>"#
        return text.map { punctuation.contains($0) ? "\\" + String($0) : String($0) }.joined()
    }

    /// Cell content already carries canonical inline escapes. Add only missing
    /// pipe escapes; doubling existing backslashes would create visible slashes.
    private static func escapeTablePipes(_ text: String) -> String {
        var output = "", escaped = false
        for character in text {
            if character == "|", !escaped { output.append("\\") }
            output.append(character)
            escaped = character == "\\" && !escaped
        }
        return output
    }

    /// Resolves an element attribute to an absolute URL (against the parse base
    /// URI), falling back to the raw attribute value when there's no base.
    private static func resolvedURL(_ element: Element, attribute: String) -> String {
        if let absolute = try? element.absUrl(attribute), !absolute.isEmpty {
            return absolute
        }
        return (try? element.attr(attribute)) ?? ""
    }

    private static func renderList(_ element: Element, ordered: Bool, depth: Int) -> String {
        var lines: [String] = []
        var index = 1
        for child in element.children().array() where child.tagName().lowercased() == "li" {
            var itemBody = ""
            renderChildren(of: child, into: &itemBody, inList: true, depth: depth)
            let text = normalizeBlankLines(itemBody).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let marker = ordered ? "\(index). " : "- "
            let indent = String(repeating: " ", count: marker.count)
            let rendered = text.components(separatedBy: "\n").enumerated().map { offset, line in
                offset == 0 ? "\(marker)\(line)" : "\(indent)\(line)"
            }.joined(separator: "\n")
            lines.append(rendered)
            index += 1
        }
        return lines.joined(separator: "\n")
    }

    private static func renderTable(_ element: Element, inList: Bool, depth: Int) -> String {
        var rows: [[String]] = []
        let trs = (try? element.select("tr"))?.array() ?? []
        for tr in trs {
            let cells = tr.children().array().filter { ["td", "th"].contains($0.tagName().lowercased()) }
            guard !cells.isEmpty else { continue }
            rows.append(cells.map { cell in
                // Render the cell's children through the walker so inline links /
                // images / emphasis survive; collapse to a single line (table
                // cells can't contain newlines) and escape pipes.
                var rendered = ""
                renderChildren(of: cell, into: &rendered, inList: inList, depth: depth)
                return MarkdownTableCell.mapCodeSpans(
                    collapseWhitespace(rendered).trimmingCharacters(in: .whitespaces),
                    code: { MarkdownTableCell.codePipes($0, encoding: true) }, plain: escapeTablePipes
                )
            })
        }
        guard !rows.isEmpty else { return "" }
        let columns = rows.map(\.count).max() ?? 0
        func pad(_ row: [String]) -> [String] { row + Array(repeating: "", count: max(0, columns - row.count)) }
        var md = "| " + pad(rows[0]).joined(separator: " | ") + " |\n"
        md += "| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |"
        for row in rows.dropFirst() {
            md += "\n| " + pad(row).joined(separator: " | ") + " |"
        }
        return md
    }

    // MARK: - Whitespace

    /// Collapses runs of whitespace (including newlines) to a single space, for
    /// inline text where HTML treats all whitespace as equivalent.
    private static func collapseWhitespace(_ s: String) -> String {
        s.replacingOccurrences(of: "[ \\t\\r\\n\\f]+", with: " ", options: .regularExpression)
    }

    /// Collapses 3+ consecutive newlines down to a paragraph break.
    private static func normalizeBlankLines(_ s: String) -> String {
        s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    }
}
