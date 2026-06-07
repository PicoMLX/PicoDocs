//
//  ReadabilityScorer.swift
//  PicoDocs
//
//  A pure-Swift, dependency-free port of the core of Mozilla's Readability
//  `grabArticle` scoring, run over a SwiftSoup DOM. This replaces the deleted
//  WKWebView + bundled Readability.js path: it needs no JavaScript engine and no
//  main-thread hop, so it runs off-actor like the rest of the engine.
//
//  It is intentionally a *subset* of Readability.js — strip unlikely nodes,
//  score paragraphs by text/comma/class signals, propagate to ancestors, pick a
//  top candidate, then pull in qualifying siblings. When it can't find a
//  confident article it returns `nil`, and `HTMLConverter` falls back to
//  converting the whole document body (i.e. no regression versus skipping it).
//

import Foundation
import SwiftSoup

enum ReadabilityScorer {

    /// The extracted article: the DOM subtree to render (kept attached to its
    /// owner document so relative links still resolve) plus a `Readable` value
    /// carrying the title/byline/excerpt/site metadata.
    struct Result {
        let article: Element
        let readable: Readable
    }

    /// Minimum extracted text length to trust the result. Below this we return
    /// `nil` so the caller converts the full body instead of a tiny fragment.
    private static let minArticleTextLength = 140

    /// Best-effort extraction. Never throws: any SwiftSoup error degrades to
    /// `nil` (caller falls back to full-body conversion).
    static func parse(_ document: Document) -> Result? {
        guard let body = document.body() else { return nil }

        let meta = metadata(document)
        stripUnlikelyNodes(in: body)

        // Score the candidate paragraphs and propagate to their ancestors.
        var scores: [ObjectIdentifier: Double] = [:]
        var candidates: [ObjectIdentifier: Element] = [:]

        for paragraph in scoreableNodes(in: body) {
            let innerText = text(paragraph)
            guard innerText.count >= 25 else { continue }

            let ancestors = ancestorChain(paragraph, max: 3)
            guard !ancestors.isEmpty else { continue }

            var contentScore = 1.0
            contentScore += Double(innerText.filter { $0 == "," }.count)
            contentScore += Double(min(innerText.count / 100, 3))

            for (level, ancestor) in ancestors.enumerated() {
                let key = ObjectIdentifier(ancestor)
                if scores[key] == nil {
                    scores[key] = baseScore(ancestor)
                    candidates[key] = ancestor
                }
                let divider: Double = level == 0 ? 1 : (level == 1 ? 2 : Double(level) * 3)
                scores[key, default: 0] += contentScore / divider
            }
        }

        // Scale each candidate by (1 - link density) and pick the best.
        var bestCandidate: Element?
        var topScore = -Double.greatestFiniteMagnitude
        for (key, element) in candidates {
            let scaled = (scores[key] ?? 0) * (1 - linkDensity(element))
            scores[key] = scaled
            if scaled > topScore {
                topScore = scaled
                bestCandidate = element
            }
        }
        guard let topCandidate = bestCandidate else { return nil }

        let article = assembleArticle(topCandidate, topScore: topScore, scores: scores)

        let articleText = text(article)
        guard articleText.count >= minArticleTextLength else { return nil }

        let html = (try? article.outerHtml()) ?? ""
        let readable = Readable(
            title: meta.title ?? "",
            content: html,
            textContent: articleText,
            length: articleText.count,
            excerpt: meta.excerpt,
            byline: meta.byline,
            dir: nil,
            siteName: meta.siteName,
            lang: meta.lang
        )
        return Result(article: article, readable: readable)
    }

    // MARK: - Stripping

    /// Tags that are never article content.
    private static let stripTags: Set<String> = [
        "script", "style", "noscript", "nav", "aside", "form",
        "button", "input", "select", "textarea", "iframe", "svg", "object", "embed",
    ]

    /// class/id/role substrings that mark a node as unlikely to be content.
    private static let unlikely: [String] = [
        "-ad-", "ai2html", "banner", "breadcrumb", "combx", "comment", "community",
        "cover-wrap", "disqus", "extra", "footer", "gdpr", "header", "legends", "menu",
        "menubar", "related", "remark", "replies", "rss", "shoutbox", "sidebar",
        "skyscraper", "social", "sponsor", "supplemental", "ad-break", "agegate",
        "pagination", "pager", "popup", "yom-remote", "nav", "masthead", "modal",
        "cookie", "complementary", "contentinfo", "dialog", "share",
        "newsletter", "promo", "subscribe", "signup", "sign-up", "paywall",
    ]

    /// Substrings that keep a node even if it also matched `unlikely`.
    private static let maybe: [String] = [
        "and", "article", "body", "column", "content", "main", "shadow",
    ]

    /// Recursively removes never-content tags and unlikely-candidate nodes,
    /// pruning whole subtrees in place. We never recurse into a node we remove,
    /// so discarded subtrees aren't processed (cheaper than flattening the whole
    /// tree first, then revisiting children of already-removed ancestors).
    private static func stripUnlikelyNodes(in element: Element) {
        for child in element.children().array() {
            let tag = child.tagName().lowercased()
            // Never strip anchors themselves, but still descend into kept nodes.
            if tag != "a" {
                if stripTags.contains(tag) {
                    try? child.remove()
                    continue
                }
                let signature = (attr(child, "class") + " " + attr(child, "id") + " " + attr(child, "role"))
                    .lowercased()
                if !signature.isEmpty,
                   unlikely.contains(where: { signature.contains($0) }),
                   !maybe.contains(where: { signature.contains($0) }) {
                    try? child.remove()
                    continue
                }
            }
            stripUnlikelyNodes(in: child)
        }
    }

    // MARK: - Candidate collection & scoring

    /// Block-level tags whose presence means a `<div>` is a wrapper, not a leaf
    /// paragraph.
    private static let blockTags: Set<String> = [
        "div", "p", "section", "article", "ul", "ol", "dl", "table", "pre",
        "blockquote", "figure", "header", "footer", "aside", "nav",
        "h1", "h2", "h3", "h4", "h5", "h6",
    ]

    /// Nodes whose text contributes to scoring: paragraphs, table cells, preformatted
    /// blocks, and "leaf" divs (divs with no block-level children, i.e. text wrappers).
    private static func scoreableNodes(in body: Element) -> [Element] {
        descendants(of: body).filter { element in
            switch element.tagName().lowercased() {
            case "p", "td", "pre":
                return true
            case "div":
                return !element.children().array().contains { blockTags.contains($0.tagName().lowercased()) }
            default:
                return false
            }
        }
    }

    /// Per-tag starting score (mirrors Readability's `initializeNode`).
    private static func baseScore(_ element: Element) -> Double {
        var score: Double
        switch element.tagName().lowercased() {
        case "div":
            score = 5
        case "pre", "td", "blockquote":
            score = 3
        case "address", "ol", "ul", "dl", "dd", "dt", "li", "form":
            score = -3
        case "h1", "h2", "h3", "h4", "h5", "h6", "th":
            score = -5
        default:
            score = 0
        }
        return score + classWeight(element)
    }

    /// +/- weight from positive/negative class & id signals.
    private static func classWeight(_ element: Element) -> Double {
        let signature = (attr(element, "class") + " " + attr(element, "id")).lowercased()
        var weight = 0.0
        if negative.contains(where: { signature.contains($0) }) { weight -= 25 }
        if positive.contains(where: { signature.contains($0) }) { weight += 25 }
        return weight
    }

    private static let positive: [String] = [
        "article", "body", "content", "entry", "hentry", "h-entry", "main", "page",
        "pagination", "post", "text", "blog", "story", "column",
    ]

    private static let negative: [String] = [
        "hidden", "banner", "combx", "comment", "com-", "contact", "foot", "footer",
        "footnote", "gdpr", "masthead", "media", "meta", "outbrain", "promo", "related",
        "scroll", "share", "shoutbox", "sidebar", "skyscraper", "sponsor", "shopping",
        "tags", "widget", "social", "modal", "popup",
    ]

    /// Ratio of link text to total text — high means navigation/boilerplate.
    private static func linkDensity(_ element: Element) -> Double {
        let total = Double(text(element).count)
        guard total > 0 else { return 0 }
        var linkLength = 0
        for anchor in (try? element.getElementsByTag("a").array()) ?? [] {
            linkLength += text(anchor).count
        }
        return Double(linkLength) / total
    }

    // MARK: - Sibling aggregation

    /// Table-structure tags whose Markdown only renders correctly from the
    /// enclosing `<table>` (HTMLToMarkdown only has a `table` handler).
    private static let tableSectionTags: Set<String> = [
        "td", "th", "tr", "tbody", "thead", "tfoot", "caption", "col", "colgroup",
    ]

    /// Assembles the final article subtree. Readability merges the top candidate
    /// with its qualifying siblings; to preserve reading order we keep them in
    /// place and prune the rest. Because nothing is moved, original DOM order and
    /// per-node base URIs (link resolution) are preserved — the same ordered set
    /// as Readability's "wrap siblings in a new container", without allocating a
    /// node or relying on element-construction APIs.
    private static func assembleArticle(_ topCandidate: Element, topScore: Double, scores: [ObjectIdentifier: Double]) -> Element {
        // A candidate inside a table renders correctly only from the <table>
        // (otherwise the cells are concatenated instead of forming a table).
        let candidate = enclosingTable(of: topCandidate) ?? topCandidate

        // Choose the root to filter and the child to always keep (the anchor):
        //  - a normal candidate: filter its parent's children, keep the candidate;
        //  - a body-level candidate (flat layout where <body> itself wins): filter
        //    <body>'s own children so promo/newsletter blocks don't leak.
        let root: Element
        let anchor: Element?
        if candidate.tagName().lowercased() == "body" || candidate.parent() == nil {
            root = candidate
            anchor = nil
        } else if let parent = candidate.parent() {
            root = parent
            anchor = candidate
        } else {
            return candidate
        }

        let threshold = max(10.0, topScore * 0.2)

        // Prune at the node level: drop non-qualifying element children and loose
        // non-blank text nodes (HTMLToMarkdown renders text nodes directly, so a
        // bare "Advertisement" string between blocks would otherwise leak). The
        // anchor and qualifying element siblings stay in their original order.
        for child in root.getChildNodes() {
            if let element = child as? Element {
                if element === anchor { continue }
                if !siblingQualifies(element, threshold: threshold, scores: scores) {
                    try? element.remove()
                }
            } else if let textNode = child as? TextNode {
                if !textNode.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try? textNode.remove()
                }
            }
        }
        return root
    }

    /// Returns the `<table>` enclosing a table-structure element (or the element
    /// itself if it is a `<table>`); `nil` for non-table elements.
    private static func enclosingTable(of element: Element) -> Element? {
        let tag = element.tagName().lowercased()
        if tag == "table" { return element }
        guard tableSectionTags.contains(tag) else { return nil }
        var current = element.parent()
        while let node = current {
            if node.tagName().lowercased() == "table" { return node }
            current = node.parent()
        }
        return nil
    }

    /// Whether a sibling of the top candidate looks like article content worth
    /// keeping (mirrors Readability's sibling-merge test).
    private static func siblingQualifies(_ sibling: Element, threshold: Double, scores: [ObjectIdentifier: Double]) -> Bool {
        if let siblingScore = scores[ObjectIdentifier(sibling)], siblingScore >= threshold {
            return true
        }
        guard sibling.tagName().lowercased() == "p" else { return false }
        let siblingText = text(sibling)
        let density = linkDensity(sibling)
        if siblingText.count > 80, density < 0.25 { return true }
        if siblingText.count > 0, density == 0,
           siblingText.range(of: #"\.( |$)"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    // MARK: - Metadata

    private static func metadata(_ document: Document) -> (title: String?, byline: String?, excerpt: String?, siteName: String?, lang: String?) {
        var properties: [String: String] = [:]   // <meta property=...>
        var names: [String: String] = [:]         // <meta name=...> / itemprop

        for meta in (try? document.getElementsByTag("meta").array()) ?? [] {
            let content = attr(meta, "content")
            guard !content.isEmpty else { continue }
            let property = attr(meta, "property").lowercased()
            if !property.isEmpty { properties[property] = content }
            let name = attr(meta, "name").lowercased()
            if !name.isEmpty { names[name] = content }
            let itemprop = attr(meta, "itemprop").lowercased()
            if !itemprop.isEmpty { names[itemprop] = content }
        }

        func clean(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }

        let title = clean(properties["og:title"]) ?? clean(names["twitter:title"]) ?? clean(try? document.title())
        let byline = clean(names["author"]) ?? clean(properties["article:author"]) ?? clean(names["dc.creator"])
        let excerpt = clean(names["description"]) ?? clean(properties["og:description"])
        let siteName = clean(properties["og:site_name"])

        var lang: String?
        if let htmlElement = try? document.getElementsByTag("html").first() {
            lang = clean(try? htmlElement.attr("lang"))
        }

        return (title, byline, excerpt, siteName, lang)
    }

    // MARK: - SwiftSoup helpers

    /// All descendant elements of `root`, depth-first (snapshot, so callers can
    /// mutate the tree while iterating).
    private static func descendants(of root: Element) -> [Element] {
        var result: [Element] = []
        func walk(_ element: Element) {
            for child in element.children().array() {
                result.append(child)
                walk(child)
            }
        }
        walk(root)
        return result
    }

    /// Up to `max` ancestors, nearest first.
    private static func ancestorChain(_ element: Element, max: Int) -> [Element] {
        var chain: [Element] = []
        var current = element.parent()
        while let node = current, chain.count < max {
            chain.append(node)
            current = node.parent()
        }
        return chain
    }

    private static func text(_ element: Element) -> String {
        (try? element.text()) ?? ""
    }

    private static func attr(_ element: Element, _ key: String) -> String {
        (try? element.attr(key)) ?? ""
    }
}
