//
//  Readability.swift
//  PicoDocs
//
//  Source-compatible wrapper for the legacy WebKit + Readability.js API. The
//  implementation now delegates to the pure-Swift SwiftSoup scorer used by the
//  HTML converter, so callers no longer need a JavaScript engine or main-thread
//  parsing.
//

import Foundation
import SwiftSoup

public struct ReadabilityOptions: Codable, Sendable {
    public var debug = false
    public var maxElemsToParse = 0
    public var nbTopCandidates = 5
    public var charThreshold = 500
    public var classesToPreserve: [String] = []
    public var keepClasses = false
    public var disableJSONLD = false
    public var linkDensityModifier = 0.0

    public init(
        debug: Bool = false,
        maxElemsToParse: Int = 0,
        nbTopCandidates: Int = 5,
        charThreshold: Int = 500,
        classesToPreserve: [String] = [],
        keepClasses: Bool = false,
        disableJSONLD: Bool = false,
        linkDensityModifier: Double = 0.0
    ) {
        self.debug = debug
        self.maxElemsToParse = maxElemsToParse
        self.nbTopCandidates = nbTopCandidates
        self.charThreshold = charThreshold
        self.classesToPreserve = classesToPreserve
        self.keepClasses = keepClasses
        self.disableJSONLD = disableJSONLD
        self.linkDensityModifier = linkDensityModifier
    }
}

public struct Readability: Sendable {

    private enum Source: Sendable {
        case url(URL)
        case htmlString(String)
    }

    private let source: Source
    public let options: ReadabilityOptions

    @MainActor
    public init(url: URL, options: ReadabilityOptions = .init()) {
        self.source = .url(url)
        self.options = options
    }

    @MainActor
    public init(htmlString: String, options: ReadabilityOptions = .init()) {
        self.source = .htmlString(htmlString)
        self.options = options
    }

    public func parse() async throws -> Readable {
        let loaded = try await loadHTML()
        let scoredDocument = try SwiftSoup.parse(loaded.html, loaded.baseURI)

        if let result = ReadabilityScorer.parse(scoredDocument) {
            return result.readable
        }

        let fallbackDocument = try SwiftSoup.parse(loaded.html, loaded.baseURI)
        Self.removeNonContentArtifacts(from: fallbackDocument)
        return try Self.readable(from: fallbackDocument)
    }

    private func loadHTML() async throws -> (html: String, baseURI: String) {
        switch source {
        case .htmlString(let html):
            return (html, "")

        case .url(let url):
            let data: Data
            let response: URLResponse?

            if url.isFileURL {
                data = try Data(contentsOf: url)
                response = nil
            } else {
                let fetched = try await URLSession.shared.data(from: url)
                data = fetched.0
                response = fetched.1
            }

            return (Self.decodeHTML(data: data, response: response), url.absoluteString)
        }
    }

    private static func decodeHTML(data: Data, response: URLResponse?) -> String {
        if let encodingName = response?.textEncodingName {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
                if let decoded = String(data: data, encoding: String.Encoding(rawValue: nsEncoding)) {
                    return decoded
                }
            }
        }

        if let encoding = HTMLConverter.sniffHTMLCharset(data),
           let decoded = String(data: data, encoding: encoding) {
            return decoded
        }
        if let decoded = String(data: data, encoding: .utf8) {
            return decoded
        }
        if let decoded = String(data: data, encoding: .isoLatin1) {
            return decoded
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static let fallbackRemovalSelectors = [
        "script:not([type='application/ld+json'])",
        "noscript",
        "template",
        "iframe",
        "canvas",
        "style",
        "link[rel='stylesheet']",
        "link[rel='preload']",
        "link[rel='modulepreload']",
        "link[rel='prefetch']",
        "link[rel='preconnect']",
        "link[rel='dns-prefetch']",
    ]

    private static func removeNonContentArtifacts(from document: Document) {
        for selector in fallbackRemovalSelectors {
            _ = try? document.select(selector).remove()
        }
    }

    private static func readable(from document: Document) throws -> Readable {
        let body = document.body() ?? document
        let textContent = try body.text()

        return Readable(
            title: metadataTitle(in: document) ?? "",
            content: try body.outerHtml(),
            textContent: textContent,
            length: textContent.count,
            excerpt: metadataContent(in: document, keys: ["description", "og:description", "twitter:description"]),
            byline: metadataContent(in: document, keys: ["author", "article:author", "dc.creator"]),
            dir: nil,
            siteName: metadataContent(in: document, keys: ["og:site_name"]),
            lang: documentLanguage(in: document)
        )
    }

    private static func metadataTitle(in document: Document) -> String? {
        metadataContent(in: document, keys: ["og:title", "twitter:title"]) ?? clean(try? document.title())
    }

    private static func metadataContent(in document: Document, keys: [String]) -> String? {
        let wanted = Set(keys.map { $0.lowercased() })

        for meta in (try? document.getElementsByTag("meta").array()) ?? [] {
            let content = clean(try? meta.attr("content"))
            guard let content else { continue }

            let property = ((try? meta.attr("property")) ?? "").lowercased()
            let name = ((try? meta.attr("name")) ?? "").lowercased()
            let itemprop = ((try? meta.attr("itemprop")) ?? "").lowercased()

            if wanted.contains(property) || wanted.contains(name) || wanted.contains(itemprop) {
                return content
            }
        }

        return nil
    }

    private static func documentLanguage(in document: Document) -> String? {
        guard let html = try? document.getElementsByTag("html").first() else { return nil }
        return clean(try? html.attr("lang"))
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
