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
        var topCandidate: Element?
        var topScore = -Double.greatestFiniteMagnitude
        for (key, element) in candidates {
            let scaled = (scores[key] ?? 0) * (1 - linkDensity(element))
            scores[key] = scaled
            if scaled > topScore {
                topScore = scaled
                topCandidate = element
            }
        }
        guard let article = topCandidate else { return nil }

        appendQualifyingSiblings(to: article, topScore: topScore, scores: scores)

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
    ]

    /// Substrings that keep a node even if it also matched `unlikely`.
    private static let maybe: [String] = [
        "and", "article", "body", "column", "content", "main", "shadow",
    ]

    private static func stripUnlikelyNodes(in body: Element) {
        for element in descendants(of: body) {
            let tag = element.tagName().lowercased()
            if tag == "body" || tag == "a" { continue }
            if stripTags.contains(tag) {
                try? element.remove()
                continue
            }
            let signature = (attr(element, "class") + " " + attr(element, "id") + " " + attr(element, "role"))
                .lowercased()
            guard !signature.isEmpty else { continue }
            if unlikely.contains(where: { signature.contains($0) }),
               !maybe.contains(where: { signature.contains($0) }) {
                try? element.remove()
            }
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

    /// Pull in sibling nodes that also look like content (Readability merges the
    /// top candidate's qualifying siblings into the article).
    private static func appendQualifyingSiblings(to article: Element, topScore: Double, scores: [ObjectIdentifier: Double]) {
        guard let parent = article.parent() else { return }
        let threshold = max(10.0, topScore * 0.2)

        for sibling in parent.children().array() {
            if sibling === article { continue }

            var qualifies = false
            if let siblingScore = scores[ObjectIdentifier(sibling)], siblingScore >= threshold {
                qualifies = true
            } else if sibling.tagName().lowercased() == "p" {
                let siblingText = text(sibling)
                let density = linkDensity(sibling)
                if siblingText.count > 80, density < 0.25 {
                    qualifies = true
                } else if siblingText.count > 0, density == 0,
                          siblingText.range(of: #"\.( |$)"#, options: .regularExpression) != nil {
                    qualifies = true
                }
            }

            if qualifies {
                // Moves `sibling` under `article`; safe because we iterate a
                // snapshot array, and the owner document (base URI) is unchanged.
                _ = try? article.appendChild(sibling)
            }
        }
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
