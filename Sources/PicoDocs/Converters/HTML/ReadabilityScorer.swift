//
//  ReadabilityScorer.swift
//  PicoDocs
//
//  A pure-Swift port of Mozilla Readability's article extraction (`parse`,
//  `_grabArticle` and `_prepArticle` in Readability.js), run over a SwiftSoup
//  DOM. This replaces the deleted WKWebView + bundled Readability.js path: it
//  needs no JavaScript engine and no main-thread hop, so it runs off-actor like
//  the rest of the engine.
//
//  Ported: hidden/unlikely-node removal, div-to-paragraph conversion, paragraph
//  scoring propagated to five ancestor levels, top-candidate refinement,
//  sibling joining, `_prepArticle` cleanup (`_cleanConditionally`, `_clean`,
//  data tables, lazy images, single-cell tables), and the retry loop that
//  relaxes its flags when an attempt yields under 500 characters.
//
//  Deliberate differences, because PicoDocs renders the article to Markdown and
//  carries no separate title view: the title heading, the byline and `<h1>`
//  tags stay in the content; appended headings, `<pre>`, `<blockquote>` and data
//  tables keep their tags (Readability turns them into `<div>`s); and a result
//  under `minArticleTextLength` returns `nil`, so `HTMLConverter` converts the
//  whole body instead of a fragment.
//
//  Ported from Readability.js (https://github.com/mozilla/readability, commit
//  ab4027a8b37669745016869a37a504727992b2ba). Copyright (c) 2010 Arc90 Inc;
//  Copyright (c) 2010-2026 Mozilla and Contributors. Licensed under the Apache
//  License, Version 2.0: http://www.apache.org/licenses/LICENSE-2.0
//

import Foundation
import SwiftSoup

enum ReadabilityScorer {

    /// The extracted article: a detached `<div>` holding the selected nodes,
    /// which keep their own base URI so relative links still resolve, plus a
    /// `Readable` value carrying the title/byline/excerpt/site metadata.
    struct Result {
        let article: Element
        let readable: Readable
    }

    /// Minimum extracted text length to trust the result. Below this we return
    /// `nil` so the caller converts the full body instead of a tiny fragment.
    private static let minArticleTextLength = 140

    /// Best-effort extraction. Never throws: any SwiftSoup error degrades to
    /// `nil` (caller falls back to full-body conversion). Mutates `document`.
    static func parse(_ document: Document) -> Result? {
        guard let body = document.body() else { return nil }

        let meta = metadata(document)
        guard let (article, textLength) = try? ArticleGrabber(document: document, body: body).grab(),
              textLength >= minArticleTextLength else {
            return nil
        }

        let articleText = DOM.textContent(article)
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

    // MARK: - Metadata

    private static func metadata(_ document: Document) -> (title: String?, byline: String?, excerpt: String?, siteName: String?, lang: String?) {
        var properties: [String: String] = [:]   // <meta property=...>
        var names: [String: String] = [:]         // <meta name=...> / itemprop

        for meta in (try? document.getElementsByTag("meta").array()) ?? [] {
            let content = DOM.attr(meta, "content")
            guard !content.isEmpty else { continue }
            let property = DOM.attr(meta, "property").lowercased()
            if !property.isEmpty { properties[property] = content }
            let name = DOM.attr(meta, "name").lowercased()
            if !name.isEmpty { names[name] = content }
            let itemprop = DOM.attr(meta, "itemprop").lowercased()
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
}

// MARK: - Article grabbing

/// One extraction over one document: Readability.js's `parse` minus metadata.
/// Per-attempt state (scores, data-table marks) is keyed by element identity;
/// the keyed elements are retained so an identifier is never reused.
private final class ArticleGrabber {

    private struct Flags: OptionSet {
        let rawValue: Int
        static let stripUnlikelys = Flags(rawValue: 1)
        static let weightClasses = Flags(rawValue: 2)
        static let cleanConditionally = Flags(rawValue: 4)
    }

    /// An attempt shorter than this is retried with fewer flags.
    private static let charThreshold = 500
    private static let topCandidateCount = 5

    private let document: Document
    private let body: Element
    private var flags: Flags = [.stripUnlikelys, .weightClasses, .cleanConditionally]
    private var scores: [ObjectIdentifier: Double] = [:]
    private var dataTables: Set<ObjectIdentifier> = []
    private var retained: [Element] = []

    init(document: Document, body: Element) {
        self.document = document
        self.body = body
    }

    /// The article and its text length, or `nil` when no attempt found text.
    func grab() throws -> (Element, Int)? {
        unwrapNoscriptImages()
        for element in DOM.descendants(of: document, tags: ["script", "noscript", "style"]) {
            try? element.remove()
        }
        replaceBrs(in: body)
        for font in DOM.descendants(of: body, tags: ["font"]) {
            try font.tagName("span")
        }

        // Each failed attempt restores the body from this snapshot.
        let output = document.outputSettings()
        let prettyPrint = output.prettyPrint()
        output.prettyPrint(pretty: false)
        let pageCache = try body.html()
        output.prettyPrint(pretty: prettyPrint)

        var attempts: [(article: Element, textLength: Int)] = []
        while true {
            let article = try grabAttempt()
            let textLength = DOM.innerTextLength(article)
            if textLength >= Self.charThreshold {
                try postProcess(article)
                return (article, textLength)
            }
            attempts.append((article, textLength))
            try body.html(pageCache)

            if flags.contains(.stripUnlikelys) {
                flags.remove(.stripUnlikelys)
            } else if flags.contains(.weightClasses) {
                flags.remove(.weightClasses)
            } else if flags.contains(.cleanConditionally) {
                flags.remove(.cleanConditionally)
            } else {
                // No luck after removing flags: keep the longest attempt.
                var best = attempts[0]
                for attempt in attempts.dropFirst() where attempt.textLength > best.textLength {
                    best = attempt
                }
                guard best.textLength > 0 else { return nil }
                try postProcess(best.article)
                return best
            }
        }
    }

    // MARK: Document prep

    /// Readability's `_unwrapNoscriptImages`: drops placeholder `<img>`s with
    /// nothing that could load, then swaps a lone image preceding a
    /// `<noscript>` for the noscript's (real) image, keeping the old URLs.
    private func unwrapNoscriptImages() {
        for img in DOM.descendants(of: document, tags: ["img"]) {
            let attributes = img.getAttributes()?.asList() ?? []
            let mightLoad = attributes.contains { attribute in
                ["src", "srcset", "data-src", "data-srcset"].contains(attribute.getKey())
                    || DOM.matches(Self.imageExtension, attribute.getValue())
            }
            if !mightLoad { try? img.remove() }
        }

        for noscript in DOM.descendants(of: document, tags: ["noscript"]) {
            guard isSingleImage(noscript),
                  let replacement = DOM.firstElementChild(noscript),
                  let previous = DOM.previousElementSibling(noscript), isSingleImage(previous),
                  let previousImage = DOM.tag(previous) == "img" ? previous : DOM.descendants(of: previous, tags: ["img"]).first,
                  let newImage = DOM.tag(replacement) == "img" ? replacement : DOM.descendants(of: replacement, tags: ["img"]).first else {
                continue
            }
            for attribute in previousImage.getAttributes()?.asList() ?? [] {
                let name = attribute.getKey(), value = attribute.getValue()
                guard !value.isEmpty,
                      name == "src" || name == "srcset" || DOM.matches(Self.imageExtension, value),
                      DOM.attr(newImage, name) != value else { continue }
                _ = try? newImage.attr(newImage.hasAttr(name) ? "data-old-" + name : name, value)
            }
            try? previous.replaceWith(replacement)
        }
    }

    private func isSingleImage(_ element: Element) -> Bool {
        var current = element
        while true {
            if DOM.tag(current) == "img" { return true }
            let children = DOM.elementChildren(current)
            guard children.count == 1, !DOM.hasNonSpaceText(current) else { return false }
            current = children[0]
        }
    }

    /// Readability's `_replaceBrs`: a chain of two or more `<br>`s becomes a
    /// `<p>` holding the phrasing content that follows it. Chains only rearrange
    /// their own parent's children, so each parent is rebuilt once.
    private func replaceBrs(in root: Element) {
        var parents: [Element] = []
        var seen: Set<ObjectIdentifier> = []
        for br in DOM.descendants(of: root, tags: ["br"]) {
            if let parent = br.parent(), seen.insert(ObjectIdentifier(parent)).inserted {
                parents.append(parent)
            }
        }
        for parent in parents { replaceBrChains(in: parent) }
    }

    private func replaceBrChains(in parent: Element) {
        let nodes = parent.getChildNodes()
        var removed = [Bool](repeating: false, count: nodes.count)
        /// The next sibling at or after `index` that isn't removed or blank text.
        func nextContent(from index: Int) -> Int {
            var index = index
            while index < nodes.count, removed[index] || (!(nodes[index] is Element) && DOM.isBlankNonElement(nodes[index])) {
                index += 1
            }
            return index
        }
        func isBr(_ index: Int) -> Bool { index < nodes.count && DOM.isTag(nodes[index], "br") }

        var children: [Node] = []
        var paragraphs: [(Element, [Node])] = []
        var index = 0
        while index < nodes.count {
            let node = nodes[index]
            guard !removed[index] else {
                index += 1
                continue
            }
            var chainEnd = isBr(index) ? nextContent(from: index + 1) : nodes.count
            guard isBr(chainEnd), let paragraph = try? document.createElement("p") else {
                children.append(node)
                index += 1
                continue
            }
            while isBr(chainEnd) {
                removed[chainEnd] = true
                chainEnd = nextContent(from: chainEnd + 1)
            }
            // The <p> takes the following phrasing content, up to the next chain.
            var content: [Node] = []
            index += 1
            while index < nodes.count {
                if removed[index] { index += 1; continue }
                if isBr(index) && isBr(nextContent(from: index + 1)) { break }
                guard DOM.isPhrasingContent(nodes[index]) else { break }
                content.append(nodes[index])
                index += 1
            }
            while let last = content.last, DOM.isWhitespace(last) { content.removeLast() }
            children.append(paragraph)
            paragraphs.append((paragraph, content))
        }
        guard !paragraphs.isEmpty else { return }

        // Detach from the end (SwiftSoup then never shifts its child array).
        for node in nodes.reversed() { try? node.remove() }
        for (paragraph, content) in paragraphs { try? paragraph.addChildren(content) }
        try? parent.addChildren(children)
        if DOM.tag(parent) == "p" { _ = try? parent.tagName("div") }
    }

    // MARK: Grab

    private static let tagsToScore: Set<String> = ["section", "h2", "h3", "h4", "h5", "h6", "p", "td", "pre"]
    private static let removableWhenEmpty: Set<String> = ["div", "section", "header", "h1", "h2", "h3", "h4", "h5", "h6"]
    private static let unlikelyRoles: Set<String> = ["menu", "menubar", "complementary", "navigation", "alert", "alertdialog", "dialog"]
    private static let alterToDivExceptions: Set<String> = ["div", "article", "section", "p", "ol", "ul"]
    /// Appended nodes whose Markdown depends on their tag (PicoDocs keeps them).
    private static let semanticSiblingTags: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6", "pre", "blockquote"]

    /// One pass of `_grabArticle` with the current flags. Returns the detached
    /// article container (possibly with little or no text).
    private func grabAttempt() throws -> Element {
        scores = [:]
        retained = []
        var elementsToScore: [Element] = []

        // Node prepping: trash nodes that look cruddy, and turn divs used as
        // paragraphs into <p>s.
        var node = DOM.firstElementChild(document)
        while let current = node {
            let tag = DOM.tag(current)
            let matchString = (DOM.attr(current, "class") + " " + DOM.attr(current, "id")).lowercased()

            if !DOM.isProbablyVisible(current)
                || (DOM.attr(current, "aria-modal") == "true" && DOM.attr(current, "role") == "dialog") {
                node = removeAndGetNext(current)
                continue
            }

            if flags.contains(.stripUnlikelys) {
                if Self.isUnlikelyCandidate(matchString),
                   !DOM.hasAncestorTag(current, "table"), !DOM.hasAncestorTag(current, "code"),
                   tag != "body", tag != "a" {
                    node = removeAndGetNext(current)
                    continue
                }
                if Self.unlikelyRoles.contains(DOM.attr(current, "role")) {
                    node = removeAndGetNext(current)
                    continue
                }
            }

            if Self.removableWhenEmpty.contains(tag), DOM.isElementWithoutContent(current) {
                node = removeAndGetNext(current)
                continue
            }

            if Self.tagsToScore.contains(tag) {
                elementsToScore.append(current)
            }

            var next = current
            if tag == "div" {
                try wrapPhrasingContent(in: current)
                // A div holding just one paragraph is that paragraph.
                if let paragraph = DOM.singleChild(of: current, tag: "p"), linkDensity(current) < 0.25 {
                    try current.replaceWith(paragraph)
                    next = paragraph
                    elementsToScore.append(paragraph)
                } else if !DOM.hasChildBlockElement(current) {
                    try current.tagName("p")
                    elementsToScore.append(current)
                }
            }
            node = DOM.nextNode(next)
        }

        // Score paragraphs and add their score to their ancestors.
        var candidates: [Element] = []
        for element in elementsToScore {
            guard let parent = element.parent(), !(parent is Document) else { continue }
            let text = DOM.textStats(element)
            guard text.length >= 25 else { continue }
            let ancestors = DOM.ancestors(of: element, maxDepth: 5)
            guard !ancestors.isEmpty else { continue }

            // A point for the paragraph, one per comma-separated part, and one
            // per 100 characters (up to 3).
            let contentScore = 1 + Double(text.commas + 1) + Double(min(text.length / 100, 3))
            for (level, ancestor) in ancestors.enumerated() {
                guard !(ancestor is Document), let grandparent = ancestor.parent(), !(grandparent is Document) else { continue }
                let key = ObjectIdentifier(ancestor)
                if scores[key] == nil {
                    initializeNode(ancestor)
                    candidates.append(ancestor)
                }
                let divider = level == 0 ? 1 : (level == 1 ? 2 : Double(level) * 3)
                scores[key, default: 0] += contentScore / divider
            }
        }

        // Scale by link density and keep the best few.
        var topCandidates: [Element] = []
        for candidate in candidates {
            let score = self.score(candidate) * (1 - linkDensity(candidate))
            scores[ObjectIdentifier(candidate)] = score
            if let index = topCandidates.firstIndex(where: { score > self.score($0) }) {
                topCandidates.insert(candidate, at: index)
                if topCandidates.count > Self.topCandidateCount { topCandidates.removeLast() }
            } else if topCandidates.count < Self.topCandidateCount {
                topCandidates.append(candidate)
            }
        }

        let topCandidate: Element
        if let best = topCandidates.first, DOM.tag(best) != "body" {
            topCandidate = refine(best, among: topCandidates)
        } else {
            // No candidate (or the body itself): wrap everything in a div.
            let container = try document.createElement("div")
            let children = body.getChildNodes()
            for child in children.reversed() { try child.remove() }
            try container.addChildren(children)
            try body.appendChild(container)
            initializeNode(container)
            topCandidate = container
        }

        // Join siblings that look related: preambles, content split by ads.
        let article = try document.createElement("div")
        let siblingThreshold = max(10, score(topCandidate) * 0.2)
        let topClass = DOM.attr(topCandidate, "class")
        for sibling in topCandidate.parent().map(DOM.elementChildren) ?? [topCandidate] {
            var append = sibling === topCandidate
            if !append {
                let bonus = !topClass.isEmpty && DOM.attr(sibling, "class") == topClass ? score(topCandidate) * 0.2 : 0
                if let siblingScore = scores[ObjectIdentifier(sibling)], siblingScore + bonus >= siblingThreshold {
                    append = true
                } else if DOM.tag(sibling) == "p" {
                    let density = linkDensity(sibling)
                    let length = DOM.innerTextLength(sibling)
                    if length > 80 && density < 0.25 {
                        append = true
                    } else if length < 80 && length > 0 && density == 0 {
                        append = DOM.matches(Self.sentenceEnd, DOM.innerText(sibling))
                    }
                }
            }
            guard append else { continue }
            let tag = DOM.tag(sibling)
            // Readability turns other tags into divs so later cleaning treats
            // them as content; Markdown needs headings, code and tables intact.
            if !Self.alterToDivExceptions.contains(tag), !Self.semanticSiblingTags.contains(tag),
               !(tag == "table" && Self.isDataTable(sibling)) {
                try sibling.tagName("div")
            }
            try article.appendChild(sibling)
        }

        try prepArticle(article)
        return article
    }

    /// The candidate-refinement steps of `_grabArticle`: prefer a common
    /// ancestor of several near-top candidates, climb while the parent scores
    /// higher, and step over single-child wrappers.
    private func refine(_ best: Element, among topCandidates: [Element]) -> Element {
        var topCandidate = best
        let minimumTopCandidates = 3
        let alternativeAncestors = topCandidates.dropFirst()
            .filter { score($0) / score(best) >= 0.75 }
            .map { Set(DOM.ancestors(of: $0, maxDepth: 0).map(ObjectIdentifier.init)) }
        if alternativeAncestors.count >= minimumTopCandidates {
            var parent = topCandidate.parent()
            while let current = parent, DOM.tag(current) != "body" {
                if alternativeAncestors.filter({ $0.contains(ObjectIdentifier(current)) }).count >= minimumTopCandidates {
                    topCandidate = current
                    break
                }
                parent = current.parent()
            }
        }
        if scores[ObjectIdentifier(topCandidate)] == nil { initializeNode(topCandidate) }

        // A parent scoring higher than the candidate hints at more content to
        // unify; stop once scores drop below a third of the candidate's.
        var parent = topCandidate.parent()
        var lastScore = score(topCandidate)
        let scoreThreshold = lastScore / 3
        while let current = parent, DOM.tag(current) != "body" {
            guard let parentScore = scores[ObjectIdentifier(current)] else {
                parent = current.parent()
                continue
            }
            if parentScore < scoreThreshold { break }
            if parentScore > lastScore {
                topCandidate = current
                break
            }
            lastScore = parentScore
            parent = current.parent()
        }

        // An only child: use the parent, so sibling joining sees its siblings.
        parent = topCandidate.parent()
        while let current = parent, DOM.tag(current) != "body", DOM.elementChildren(current).count == 1 {
            topCandidate = current
            parent = current.parent()
        }
        if scores[ObjectIdentifier(topCandidate)] == nil { initializeNode(topCandidate) }
        return topCandidate
    }

    /// Wraps each run of phrasing content directly inside `div` in a `<p>`,
    /// dropping the run's leading and trailing whitespace.
    private func wrapPhrasingContent(in div: Element) throws {
        let nodes = div.getChildNodes()
        let phrasing = nodes.map(DOM.isPhrasingContent)
        guard phrasing.contains(true) else { return }

        // Detach from the end (SwiftSoup then never shifts its child array),
        // then re-append in order.
        for node in nodes.reversed() { try node.remove() }
        var index = 0
        while index < nodes.count {
            guard phrasing[index] else {
                try div.appendChild(nodes[index])
                index += 1
                continue
            }
            var end = index
            while end < nodes.count && phrasing[end] { end += 1 }
            var run = nodes[index..<end]
            index = end
            while let first = run.first, DOM.isWhitespace(first) { run.removeFirst() }
            while let last = run.last, DOM.isWhitespace(last) { run.removeLast() }
            guard !run.isEmpty else { continue }
            let paragraph = try document.createElement("p")
            try paragraph.addChildren(Array(run))
            try div.appendChild(paragraph)
        }
    }

    private func removeAndGetNext(_ element: Element) -> Element? {
        let next = DOM.nextNode(element, skippingChildren: true)
        try? element.remove()
        return next
    }

    // MARK: Scoring

    private func score(_ element: Element) -> Double {
        scores[ObjectIdentifier(element)] ?? 0
    }

    /// Readability's `_initializeNode`: a starting score by tag, plus the
    /// class/id weight.
    private func initializeNode(_ element: Element) {
        var score: Double
        switch DOM.tag(element) {
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
        scores[ObjectIdentifier(element)] = score + classWeight(element)
        retained.append(element)
    }

    /// +/-25 each for positive/negative signals in the class and the id.
    private func classWeight(_ element: Element) -> Double {
        guard flags.contains(.weightClasses) else { return 0 }
        var weight = 0.0
        for value in [DOM.attr(element, "class"), DOM.attr(element, "id")] where !value.isEmpty {
            let lowered = value.lowercased()
            if Self.isNegative(lowered) { weight -= 25 }
            if Self.positive.contains(where: lowered.contains) { weight += 25 }
        }
        return weight
    }

    /// Share of the text inside links; in-page (`#...`) links count 30%.
    private func linkDensity(_ element: Element) -> Double {
        let textLength = DOM.innerTextLength(element)
        guard textLength > 0 else { return 0 }
        return Self.linkDensity(textLength: textLength, links: DOM.descendants(of: element, tags: ["a"]))
    }

    private static func linkDensity(textLength: Int, links: [Element]) -> Double {
        guard textLength > 0 else { return 0 }
        var linkLength = 0.0
        for link in links {
            let href = DOM.attr(link, "href")
            let coefficient = href.count > 1 && href.hasPrefix("#") ? 0.3 : 1
            linkLength += Double(DOM.innerTextLength(link)) * coefficient
        }
        return linkLength / Double(textLength)
    }

    private static let unlikelyCandidates = [
        "-ad-", "ai2html", "banner", "breadcrumbs", "combx", "comment", "community", "cover-wrap", "disqus",
        "extra", "footer", "gdpr", "header", "legends", "menu", "related", "remark", "replies", "rss",
        "shoutbox", "sidebar", "skyscraper", "social", "sponsor", "supplemental", "ad-break", "agegate",
        "pagination", "pager", "popup", "yom-remote",
    ]
    private static let maybeCandidates = ["and", "article", "body", "column", "content", "main", "mathjax", "shadow"]
    private static let positive = [
        "article", "body", "content", "entry", "hentry", "h-entry", "main", "page", "pagination", "post",
        "text", "blog", "story",
    ]
    private static let negative = [
        "-ad-", "hidden", "banner", "combx", "comment", "com-", "contact", "footer", "gdpr", "masthead",
        "media", "meta", "outbrain", "promo", "related", "scroll", "share", "shoutbox", "sidebar",
        "skyscraper", "sponsor", "shopping", "tags", "widget",
    ]

    /// `matchString` is the lowercased "class id".
    private static func isUnlikelyCandidate(_ matchString: String) -> Bool {
        unlikelyCandidates.contains(where: matchString.contains) && !maybeCandidates.contains(where: matchString.contains)
    }

    /// The negative pattern, including its `hid` as a whole word.
    private static func isNegative(_ value: String) -> Bool {
        negative.contains(where: value.contains)
            || value == "hid" || value.hasPrefix("hid ") || value.hasSuffix(" hid") || value.contains(" hid ")
    }

    // MARK: Article prep

    /// Readability's `_prepArticle`, minus its `<h1>`-to-`<h2>` rename and
    /// presentational-attribute stripping (Markdown carries neither).
    private func prepArticle(_ article: Element) throws {
        dataTables = []
        for table in DOM.descendants(of: article, tags: ["table"]) where Self.isDataTable(table) {
            dataTables.insert(ObjectIdentifier(table))
            retained.append(table)
        }
        try fixLazyImages(article)

        cleanConditionally(article, tag: "form")
        cleanConditionally(article, tag: "fieldset")
        for tag in ["object", "embed", "footer", "link", "aside"] { clean(article, tag: tag) }

        // Little share widgets, except in the top-level nodes themselves.
        for child in DOM.elementChildren(article) {
            let end = DOM.nextNode(child, skippingChildren: true)
            var node = DOM.nextNode(child)
            while let current = node, current !== end {
                let matchString = DOM.attr(current, "class") + " " + DOM.attr(current, "id")
                if DOM.matches(Self.shareElements, matchString), DOM.rawTextLength(current, below: Self.charThreshold) < Self.charThreshold {
                    node = removeAndGetNext(current)
                } else {
                    node = DOM.nextNode(current)
                }
            }
        }

        for tag in ["iframe", "input", "textarea", "select", "button"] { clean(article, tag: tag) }
        for heading in DOM.descendants(of: article, tags: ["h1", "h2"]).reversed() where classWeight(heading) < 0 {
            try? heading.remove()
        }

        cleanConditionally(article, tag: "table")
        cleanConditionally(article, tag: "ul")
        cleanConditionally(article, tag: "div")

        // Remove empty paragraphs (media-only ones stay).
        for paragraph in DOM.descendants(of: article, tags: ["p"]).reversed()
        where DOM.descendants(of: paragraph, tags: ["img", "embed", "object", "iframe"]).isEmpty && !DOM.hasNonSpaceText(paragraph) {
            try? paragraph.remove()
        }

        for br in DOM.descendants(of: article, tags: ["br"]) {
            if let next = DOM.skipWhitespace(br.nextSibling()), DOM.isTag(next, "p") {
                try? br.remove()
            }
        }

        // Single-cell (layout) tables become their cell.
        for table in DOM.descendants(of: article, tags: ["table"]) {
            let tbody = DOM.singleChild(of: table, tag: "tbody") ?? table
            guard let row = DOM.singleChild(of: tbody, tag: "tr"),
                  let cell = DOM.singleChild(of: row, tag: "td") else { continue }
            _ = try? cell.tagName(cell.getChildNodes().allSatisfy(DOM.isPhrasingContent) ? "p" : "div")
            try? table.replaceWith(cell)
        }
    }

    /// Readability's `_postProcessContent`, as far as Markdown sees it: links
    /// to `javascript:` URLs keep only their content.
    private func postProcess(_ article: Element) throws {
        for link in DOM.descendants(of: article, tags: ["a"]) where DOM.attr(link, "href").hasPrefix("javascript:") {
            _ = try link.unwrap()
        }
    }

    /// Readability's `_clean`: removes every `tag`, except embedded videos.
    private func clean(_ root: Element, tag: String) {
        let isEmbed = ["object", "embed", "iframe"].contains(tag)
        for element in DOM.descendants(of: root, tags: [tag]).reversed() {
            if isEmbed, Self.isAllowedVideo(element) { continue }
            try? element.remove()
        }
    }

    private static func isAllowedVideo(_ element: Element) -> Bool {
        let attributes = element.getAttributes()?.asList() ?? []
        if attributes.contains(where: { DOM.matches(videos, $0.getValue()) }) { return true }
        return DOM.tag(element) == "object" && DOM.matches(videos, (try? element.html()) ?? "")
    }

    /// Readability's `_cleanConditionally`: removes `tag` elements that look
    /// like boilerplate by their commas, images, lists, inputs, embeds, link
    /// density and class weight. Deepest/last first, as Readability does.
    private func cleanConditionally(_ root: Element, tag: String) {
        guard flags.contains(.cleanConditionally) else { return }
        for node in DOM.descendants(of: root, tags: [tag]).reversed() where node.parent() != nil {
            if shouldRemoveConditionally(node, tag: tag) {
                try? node.remove()
            }
        }
    }

    private func isMarkedDataTable(_ element: Element) -> Bool {
        dataTables.contains(ObjectIdentifier(element))
    }

    /// What `_cleanConditionally` counts under a node, gathered in one walk.
    private struct Census {
        var paragraphs = 0, images = 0, listItems = 0, inputs = 0
        var lists: [Element] = [], tables: [Element] = [], embeds: [Element] = [], links: [Element] = []

        init(_ node: Element) {
            DOM.forEachDescendant(of: node) { element in
                switch DOM.tag(element) {
                case "p": paragraphs += 1
                case "img": images += 1
                case "li": listItems += 1
                case "input": inputs += 1
                case "ul", "ol": lists.append(element)
                case "table": tables.append(element)
                case "object", "embed", "iframe": embeds.append(element)
                case "a": links.append(element)
                default: break
                }
            }
        }
    }

    private func shouldRemoveConditionally(_ node: Element, tag: String) -> Bool {
        let text = DOM.textStats(node)
        let census = Census(node)
        var isList = tag == "ul" || tag == "ol"
        if !isList {
            let listLength = census.lists.reduce(0) { $0 + DOM.innerTextLength($1) }
            isList = text.length > 0 && Double(listLength) / Double(text.length) > 0.9
        }

        if !dataTables.isEmpty {
            if tag == "table" && isMarkedDataTable(node) { return false }
            if DOM.hasAncestorTag(node, "table", maxDepth: -1, where: isMarkedDataTable) { return false }
            if census.tables.contains(where: isMarkedDataTable) { return false }
        }
        if DOM.hasAncestorTag(node, "code") { return false }

        let weight = classWeight(node)
        if weight < 0 { return true }
        guard text.asciiCommas < 10 else { return false }

        let p = census.paragraphs, img = census.images, li = census.listItems - 100, input = census.inputs
        if census.embeds.contains(where: Self.isAllowedVideo) { return false }
        let embedCount = census.embeds.count

        let contentLength = text.length
        // Nothing but an ad or loading label.
        if contentLength <= 16, Self.isAdOrLoadingLabel(DOM.innerText(node)) { return true }

        let linkDensity = Self.linkDensity(textLength: contentLength, links: census.links)
        let isFigureChild = DOM.hasAncestorTag(node, "figure")

        let haveToRemove: Bool = {
            if !isFigureChild && img > 1 && Double(p) / Double(img) < 0.5 { return true }
            if !isList && li > p { return true }
            if input > p / 3 { return true }
            if !isList && !isFigureChild && contentLength < 25 && (img == 0 || img > 2) && linkDensity > 0
                && textDensity(node, tags: ["h1", "h2", "h3", "h4", "h5", "h6"], textLength: contentLength) < 0.9 {
                return true
            }
            if !isList && weight < 25 && linkDensity > 0.2 { return true }
            if weight >= 25 && linkDensity > 0.5 { return true }
            if (embedCount == 1 && contentLength < 75) || embedCount > 1 { return true }
            if img == 0 && !hasTextishText(node) { return true }
            return false
        }()

        // Allow simple lists of images to remain.
        if isList && haveToRemove {
            if DOM.elementChildren(node).contains(where: { DOM.elementChildren($0).count > 1 }) {
                return true
            }
            if img == census.listItems { return false }
        }
        return haveToRemove
    }

    private static let textishTags: Set<String> = ["span", "li", "td", "blockquote", "dl", "div", "img", "ol", "p", "pre", "table", "ul"]

    /// Readability's `_getTextDensity(node, textishTags) === 0`.
    private func hasTextishText(_ node: Element) -> Bool {
        DOM.descendants(of: node, tags: Self.textishTags).contains(where: DOM.hasNonSpaceText)
    }

    private func textDensity(_ node: Element, tags: Set<String>, textLength: Int) -> Double {
        guard textLength > 0 else { return 0 }
        let childrenLength = DOM.descendants(of: node, tags: tags).reduce(0) { $0 + DOM.innerTextLength($1) }
        return Double(childrenLength) / Double(textLength)
    }

    private static let adWords: Set<String> = ["ad", "advertising", "advertisement", "pub", "publicité", "werb", "werbung", "广告", "реклама", "anuncio"]
    private static let loadingWords: Set<String> = ["loading", "正在加载", "загрузка", "chargement", "cargando"]

    private static func isAdOrLoadingLabel(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if adWords.contains(lowered) { return true }
        for suffix in ["…", "..."] where lowered.hasSuffix(suffix) {
            if loadingWords.contains(String(lowered.dropLast(suffix.count))) { return true }
        }
        return loadingWords.contains(lowered)
    }

    /// Readability's `_markDataTables` test for one table.
    static func isDataTable(_ table: Element) -> Bool {
        if DOM.attr(table, "role") == "presentation" || DOM.attr(table, "datatable") == "0" { return false }
        if !DOM.attr(table, "summary").isEmpty { return true }
        if let caption = DOM.descendants(of: table, tags: ["caption"]).first, caption.childNodeSize() > 0 { return true }
        if !DOM.descendants(of: table, tags: ["col", "colgroup", "tfoot", "thead", "th"]).isEmpty { return true }
        if !DOM.descendants(of: table, tags: ["table"]).isEmpty { return false }

        var rows = 0, columns = 0
        for row in DOM.descendants(of: table, tags: ["tr"]) {
            rows += DOM.span(row, "rowspan")
            columns = max(columns, DOM.descendants(of: row, tags: ["td"]).reduce(0) { $0 + DOM.span($1, "colspan") })
        }
        if columns == 1 || rows == 1 { return false }
        if rows >= 10 || columns > 4 { return true }
        return rows * columns > 10
    }

    /// Readability's `_fixLazyImages`: copies image URLs from `data-*` style
    /// attributes into `src`/`srcset`, dropping tiny base64 placeholders.
    private func fixLazyImages(_ root: Element) throws {
        for element in DOM.descendants(of: root, tags: ["img", "picture", "figure"]) {
            let tag = DOM.tag(element)
            let attributes = element.getAttributes()?.asList() ?? []
            if tag == "img" {
                let src = DOM.attr(element, "src")
                if let match = Self.base64DataURL.firstMatch(in: src, range: NSRange(src.startIndex..., in: src)),
                   let mime = Range(match.range(at: 1), in: src) {
                    // An SVG can be meaningful in under 133 bytes.
                    if src[mime] == "image/svg+xml" { continue }
                    let srcCouldBeRemoved = attributes.contains { $0.getKey() != "src" && DOM.matches(Self.imageExtension, $0.getValue()) }
                    if srcCouldBeRemoved, (src as NSString).length - match.range.length < 133 {
                        try element.removeAttr("src")
                    }
                }
                let srcset = DOM.attr(element, "srcset")
                if (element.hasAttr("src") || (!srcset.isEmpty && srcset != "null"))
                    && !DOM.attr(element, "class").lowercased().contains("lazy") {
                    continue
                }
            }

            for attribute in attributes where !["src", "srcset", "alt"].contains(attribute.getKey()) {
                let value = attribute.getValue()
                let copyTo: String
                if DOM.matches(Self.srcsetValue, value) {
                    copyTo = "srcset"
                } else if DOM.matches(Self.srcValue, value) {
                    copyTo = "src"
                } else {
                    continue
                }
                if tag == "img" || tag == "picture" {
                    try element.attr(copyTo, value)
                } else if DOM.descendants(of: element, tags: ["img", "picture"]).isEmpty {
                    let image = try document.createElement("img")
                    try image.attr(copyTo, value)
                    try element.appendChild(image)
                }
            }
        }
    }

    private static let imageExtension = try! NSRegularExpression(pattern: #"\.(jpg|jpeg|png|webp)"#, options: .caseInsensitive)
    private static let srcsetValue = try! NSRegularExpression(pattern: #"\.(jpg|jpeg|png|webp)\s+\d"#)
    private static let srcValue = try! NSRegularExpression(pattern: #"^\s*\S+\.(jpg|jpeg|png|webp)\S*\s*$"#)
    private static let base64DataURL = try! NSRegularExpression(pattern: #"^data:\s*([^\s;,]+)\s*;\s*base64\s*,"#, options: .caseInsensitive)
    private static let shareElements = try! NSRegularExpression(pattern: #"(\b|_)(share|sharedaddy)(\b|_)"#, options: .caseInsensitive)
    private static let sentenceEnd = try! NSRegularExpression(pattern: #"\.( |$)"#)
    private static let videos = try! NSRegularExpression(
        pattern: #"\/\/(www\.)?((dailymotion|youtube|youtube-nocookie|player\.vimeo|v\.qq|bilibili|live.bilibili)\.com|(archive|upload\.wikimedia)\.org|player\.twitch\.tv)"#,
        options: .caseInsensitive
    )
}

// MARK: - DOM helpers

/// SwiftSoup counterparts of the DOM operations Readability.js relies on. All
/// walks are iterative, so a deeply nested document can't exhaust the stack,
/// and sibling steps use the O(1) `nextSibling()` rather than rebuilding the
/// parent's child list.
private enum DOM {

    static func tag(_ element: Element) -> String {
        element.tagNameNormal()
    }

    static func isTag(_ node: Node, _ name: String) -> Bool {
        (node as? Element).map { tag($0) == name } ?? false
    }

    static func attr(_ element: Element, _ key: String) -> String {
        (try? element.attr(key)) ?? ""
    }

    static func matches(_ regex: NSRegularExpression, _ string: String) -> Bool {
        regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }

    /// `rowspan`/`colspan` as Readability reads it: `parseInt`, with 0 or
    /// garbage counting as 1.
    static func span(_ element: Element, _ key: String) -> Int {
        let digits = attr(element, key).drop { $0.isWhitespace }.prefix { $0.isASCII && $0.isNumber }
        let value = Int(digits) ?? 0
        return value == 0 ? 1 : value
    }

    // MARK: Traversal

    static func elementChildren(_ element: Element) -> [Element] {
        element.getChildNodes().compactMap { $0 as? Element }
    }

    static func firstElementChild(_ element: Element) -> Element? {
        for child in element.getChildNodes() {
            if let element = child as? Element { return element }
        }
        return nil
    }

    static func nextElementSibling(_ node: Node) -> Element? {
        var sibling = node.nextSibling()
        while let current = sibling {
            if let element = current as? Element { return element }
            sibling = current.nextSibling()
        }
        return nil
    }

    static func previousElementSibling(_ node: Node) -> Element? {
        var sibling = node.previousSibling()
        while let current = sibling {
            if let element = current as? Element { return element }
            sibling = current.previousSibling()
        }
        return nil
    }

    /// Readability's `_getNextNode`: depth-first element order.
    static func nextNode(_ element: Element, skippingChildren: Bool = false) -> Element? {
        if !skippingChildren, let child = firstElementChild(element) { return child }
        var current: Element? = element
        while let node = current {
            if let sibling = nextElementSibling(node) { return sibling }
            current = node.parent()
        }
        return nil
    }

    /// Up to `maxDepth` ancestors, nearest first (0 = all). Includes the
    /// `Document` node, as the DOM's `parentNode` chain does.
    static func ancestors(of element: Element, maxDepth: Int) -> [Element] {
        var chain: [Element] = []
        var current = element.parent()
        while let node = current {
            chain.append(node)
            if maxDepth > 0 && chain.count == maxDepth { break }
            current = node.parent()
        }
        return chain
    }

    static func hasAncestorTag(_ element: Element, _ name: String, maxDepth: Int = 3, where filter: ((Element) -> Bool)? = nil) -> Bool {
        var depth = 0
        var current = element
        while let parent = current.parent() {
            if maxDepth > 0 && depth > maxDepth { return false }
            if tag(parent) == name && (filter?(parent) ?? true) { return true }
            current = parent
            depth += 1
        }
        return false
    }

    /// Calls `body` with each descendant element of `root` (not `root`
    /// itself), in document order.
    static func forEachDescendant(of root: Element, _ body: (Element) -> Void) {
        var stack: [Element] = []
        func pushChildren(of element: Element) {
            for child in element.getChildNodes().reversed() {
                if let child = child as? Element { stack.append(child) }
            }
        }
        pushChildren(of: root)
        while let element = stack.popLast() {
            body(element)
            pushChildren(of: element)
        }
    }

    /// Descendant elements of `root` (not `root` itself) in document order,
    /// like `getElementsByTagName`.
    static func descendants(of root: Element, tags: Set<String>) -> [Element] {
        var result: [Element] = []
        forEachDescendant(of: root) { element in
            if tags.contains(tag(element)) { result.append(element) }
        }
        return result
    }

    /// Readability's `_nextNode`: skips non-element nodes with blank text.
    static func skipWhitespace(_ node: Node?) -> Node? {
        var current = node
        while let node = current, isBlankNonElement(node) {
            current = node.nextSibling()
        }
        return current
    }

    /// A text or comment node whose `textContent` is blank.
    static func isBlankNonElement(_ node: Node) -> Bool {
        let content: String
        if let text = node as? TextNode {
            content = text.getWholeText()
        } else if let comment = node as? Comment {
            content = comment.getData()
        } else {
            return false
        }
        return content.unicodeScalars.allSatisfy(isSpace)
    }

    // MARK: Content tests

    private static let phrasingTags: Set<String> = [
        "abbr", "audio", "b", "bdo", "br", "button", "cite", "code", "data", "datalist", "dfn", "em", "embed",
        "i", "img", "input", "kbd", "label", "mark", "math", "meter", "noscript", "object", "output", "progress",
        "q", "ruby", "samp", "script", "select", "small", "span", "strong", "sub", "sup", "textarea", "time",
        "var", "wbr",
    ]

    /// Text, a phrasing element, or a link/`del`/`ins` holding only phrasing content.
    static func isPhrasingContent(_ node: Node) -> Bool {
        var stack = [node]
        while let current = stack.popLast() {
            if current is TextNode { continue }
            guard let element = current as? Element else { return false }
            let name = tag(element)
            if phrasingTags.contains(name) { continue }
            guard name == "a" || name == "del" || name == "ins" else { return false }
            stack.append(contentsOf: element.getChildNodes())
        }
        return true
    }

    /// Whitespace-only text, or a `<br>`.
    static func isWhitespace(_ node: Node) -> Bool {
        if let text = node as? TextNode { return !hasNonSpaceText(text) }
        return isTag(node, "br")
    }

    private static let divToParagraphTags: Set<String> = ["blockquote", "dl", "div", "img", "ol", "p", "pre", "table", "ul"]

    /// Whether any descendant is a block that keeps a div from being a paragraph.
    static func hasChildBlockElement(_ element: Element) -> Bool {
        var stack = elementChildren(element)
        while let current = stack.popLast() {
            if divToParagraphTags.contains(tag(current)) { return true }
            stack.append(contentsOf: elementChildren(current))
        }
        return false
    }

    /// The only element child, when it has tag `name` and no text node beside
    /// it ends in non-whitespace (Readability's `_hasSingleTagInsideElement`).
    static func singleChild(of element: Element, tag name: String) -> Element? {
        var only: Element?
        for child in element.getChildNodes() {
            if let childElement = child as? Element {
                guard only == nil else { return nil }
                only = childElement
            } else if let text = child as? TextNode, let last = text.getWholeText().unicodeScalars.last, !isSpace(last) {
                return nil
            }
        }
        guard let only, tag(only) == name else { return nil }
        return only
    }

    /// No text, and no children beyond `<br>`/`<hr>`.
    static func isElementWithoutContent(_ element: Element) -> Bool {
        guard !hasNonSpaceText(element) else { return false }
        let childCount = elementChildren(element).count
        return childCount == 0 || childCount == descendants(of: element, tags: ["br", "hr"]).count
    }

    /// Readability's `_isProbablyVisible`: not `display: none`, not
    /// `visibility: hidden`, not `hidden`, and not `aria-hidden` (except
    /// Wikipedia's math fallback images).
    static func isProbablyVisible(_ element: Element) -> Bool {
        if element.hasAttr("hidden") { return false }
        if attr(element, "aria-hidden") == "true" && !attr(element, "class").contains("fallback-image") { return false }
        let style = attr(element, "style")
        guard !style.isEmpty else { return true }
        var display = "", visibility = ""
        for declaration in style.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            var value = parts[1].lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasSuffix("!important") {
                value = String(value.dropLast("!important".count)).trimmingCharacters(in: .whitespaces)
            }
            switch parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "display": display = value
            case "visibility": visibility = value
            default: break
            }
        }
        return display != "none" && visibility != "hidden"
    }

    // MARK: Text

    /// JavaScript's `\s`, which `trim()` and Readability's patterns use.
    static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    private static let commas: Set<UInt32> = [0x002C, 0x060C, 0xFE50, 0xFE10, 0xFE11, 0x2E41, 0x2E34, 0x2E32, 0xFF0C]

    /// Calls `body` with each text node's text under `node`, in order.
    private static func forEachText(in node: Node, _ body: (String) -> Bool) {
        var stack = [node]
        while let current = stack.popLast() {
            if let text = current as? TextNode {
                guard body(text.getWholeText()) else { return }
                continue
            }
            stack.append(contentsOf: current.getChildNodes().reversed())
        }
    }

    /// Readability's `_getInnerText` (textContent, trimmed, runs of 2+
    /// whitespace collapsed to one space) measured in UTF-16 units like
    /// JavaScript's `length`, with its comma counts, without building it.
    static func textStats(_ node: Node) -> (length: Int, commas: Int, asciiCommas: Int) {
        var length = 0, commaCount = 0, asciiCommas = 0
        var started = false, pendingSpace = false
        forEachText(in: node) { text in
            for scalar in text.unicodeScalars {
                if isSpace(scalar) {
                    pendingSpace = started
                    continue
                }
                if pendingSpace { length += 1 }
                pendingSpace = false
                started = true
                length += scalar.utf16.count
                if commas.contains(scalar.value) {
                    commaCount += 1
                    if scalar == "," { asciiCommas += 1 }
                }
            }
            return true
        }
        return (length, commaCount, asciiCommas)
    }

    static func innerTextLength(_ node: Node) -> Int {
        textStats(node).length
    }

    /// Readability's `_getInnerText` itself (for the few short texts it tests).
    static func innerText(_ node: Node) -> String {
        var raw = ""
        forEachText(in: node) { raw += $0; return true }
        var result = "", pending = ""
        for scalar in raw.unicodeScalars {
            if isSpace(scalar) {
                pending.unicodeScalars.append(scalar)
                continue
            }
            if !result.isEmpty { result += pending.unicodeScalars.count > 1 ? " " : pending }
            pending = ""
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    /// The text as `Element.text()` presents it (whitespace collapsed, blocks
    /// and `<br>`s separated by a space) in one linear pass; SwiftSoup's own
    /// `text()` rescans its buffer per text node, quadratic on long articles.
    static func textContent(_ root: Element) -> String {
        var output = ""
        var pendingSpace = false
        var stack: [(node: Node, exiting: Bool)] = [(root, false)]
        while let (node, exiting) = stack.popLast() {
            if let text = node as? TextNode {
                for scalar in text.getWholeText().unicodeScalars {
                    if isSpace(scalar) {
                        pendingSpace = true
                    } else {
                        if pendingSpace && !output.isEmpty { output += " " }
                        pendingSpace = false
                        output.unicodeScalars.append(scalar)
                    }
                }
                continue
            }
            guard let element = node as? Element else { continue }
            if element.isBlock() || tag(element) == "br" { pendingSpace = true }
            guard !exiting else { continue }
            stack.append((element, true))
            stack.append(contentsOf: element.getChildNodes().reversed().map { ($0, false) })
        }
        return output
    }

    static func hasNonSpaceText(_ node: Node) -> Bool {
        var found = false
        forEachText(in: node) { text in
            found = text.unicodeScalars.contains { !isSpace($0) }
            return !found
        }
        return found
    }

    /// `textContent.length`, counted only up to `limit`.
    static func rawTextLength(_ node: Node, below limit: Int) -> Int {
        var length = 0
        forEachText(in: node) { text in
            length += text.utf16.count
            return length < limit
        }
        return length
    }
}
