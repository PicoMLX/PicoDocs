//
//  Readability.swift
//  Pico
//
//  Created by Ronald Mannak on 4/19/24.
//
// See: https://www.artemnovichkov.com/blog/async-await-offline
// https://github.com/artemnovichkov/OfflineDataAsyncExample/blob/main/OfflineDataAsyncExample/WebDataManager.swift

import Foundation
import WebKit
import SwiftSoup

enum ReadabilityError: Error {
    case scriptNotFound
    case invalidResponse
    case jsonSerializationError
    case jsonDecodingError
}

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

enum ReadabilityHTMLPreprocessor {
    private static let removalSelectors = [
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

    private static let malformedInlineStateScriptPatterns = [
        #"(?is)<script\b[^>]*\/>\s*(?:(?!</script>).)*(?:window\.__INITIAL_STATE__|window\.__NEXT_DATA__|window\.__NUXT__|window\.__APOLLO_STATE__|window\.__PRELOADED_STATE__)(?:(?!</script>).)*</script>"#,
    ]

    static func preprocess(_ html: String, baseURL: URL?) throws -> String {
        let sanitizedHTML = stripMalformedInlineStateScripts(from: html)
        let document = try SwiftSoup.parse(sanitizedHTML, baseURL?.absoluteString ?? "")
        for selector in removalSelectors {
            try document.select(selector).remove()
        }
        return try document.outerHtml()
    }

    private static func stripMalformedInlineStateScripts(from html: String) -> String {
        malformedInlineStateScriptPatterns.reduce(html) { partialResult, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return partialResult
            }
            let range = NSRange(partialResult.startIndex..., in: partialResult)
            return regex.stringByReplacingMatches(
                in: partialResult,
                options: [],
                range: range,
                withTemplate: ""
            )
        }
    }
}

@MainActor
public class Readability: NSObject {
    
    enum Source {
        case url(URL)
        case htmlString(String)
    }
    
    private lazy var webView: WKWebView = {
        let webView = WKWebView(frame: .zero)
        webView.configuration.suppressesIncrementalRendering = true
        webView.configuration.userContentController.addUserScript(ReadabilityUserScript())
        webView.navigationDelegate = self
        return webView
    }()
    
    private let source: Source
    private var continuation: CheckedContinuation<Void, Error>?
    private let options: ReadabilityOptions
    
    public init(url: URL, options: ReadabilityOptions = .init()) {
        source = .url(url)
        self.options = options
        super.init()
    }
    
    public init(htmlString: String, options: ReadabilityOptions = .init()) {
        source = .htmlString(htmlString)
        self.options = options
        super.init()
    }
    
    public func parse() async throws -> Readable {
        
        // 1. Load page
        try await load(self.source)
        
        // 2. Inject and execute Readability script
        let optionsData = try JSONEncoder().encode(options)
        let optionsJSON = String(decoding: optionsData, as: UTF8.self)
        let readabilityScript = """
            (() => {
                const options = \(optionsJSON);
                const article = new Readability(document.cloneNode(true), options).parse();
                return article;
            })();
            """
        
        guard let result = try await self.webView.evaluateJavaScript(readabilityScript) as? [String: Any] else {
            throw ReadabilityError.invalidResponse
        }
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: result, options: []) else {
            throw ReadabilityError.jsonSerializationError
        }
        
        let decoder = JSONDecoder()
        guard let readable = try? decoder.decode(Readable.self, from: jsonData) else {
            throw ReadabilityError.jsonDecodingError
        }
        
        return readable
    }
    
    private func load(_ source: Source) async throws {
        switch source {
        case .url(let url):
            let htmlDocument = try await Self.staticHTMLDocument(for: url)
            try await loadHTML(htmlDocument.html, baseURL: htmlDocument.baseURL)
        case .htmlString(let htmlString):
            let preprocessedHTML = try ReadabilityHTMLPreprocessor.preprocess(htmlString, baseURL: nil)
            try await loadHTML(preprocessedHTML, baseURL: nil)
        }
    }

    private func loadHTML(_ htmlString: String, baseURL: URL?) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.webView.loadHTMLString(htmlString, baseURL: baseURL)
        }
    }

    private static func staticHTMLDocument(for url: URL) async throws -> (html: String, baseURL: URL?) {
        let htmlString: String

        if url.isFileURL {
            htmlString = try String(contentsOf: url, encoding: .utf8)
        } else {
            let (data, response) = try await URLSession.shared.data(from: url)
            htmlString = decodeHTML(data: data, response: response)
        }

        let preprocessedHTML = try ReadabilityHTMLPreprocessor.preprocess(htmlString, baseURL: url)
        return (preprocessedHTML, url)
    }

    private static func decodeHTML(data: Data, response: URLResponse) -> String {
        if let encodingName = response.textEncodingName {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
            guard cfEncoding != kCFStringEncodingInvalidId else {
                return decodeHTML(data: data)
            }
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            if let string = String(data: data, encoding: String.Encoding(rawValue: nsEncoding)) {
                return string
            }
        }

        return decodeHTML(data: data)
    }

    private static func decodeHTML(data: Data) -> String {
        if let string = String(data: data, encoding: .utf8) {
            return string
        }
        if let string = String(data: data, encoding: .isoLatin1) {
            return string
        }
        return String(decoding: data, as: UTF8.self)
    }
}

extension Readability: WKNavigationDelegate {
    
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume(returning: ())
        continuation = nil
    }
    
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

class ReadabilityUserScript: WKUserScript {
    convenience override init() {
        let js: String
        do {
            js = try Self.loadFile(
                name: "Readability",
                type: "js",
                subdirectory: "Parsers/ParserTools/Readability"
            )
        } catch {
            fatalError("Couldn't load Readability.js")
        }
        self.init(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }
    
//    static func loadFile(name: String, type: String, subdirectory: String) throws -> String {
//        guard let url = Bundle.module.url(
//            forResource: name,
//            withExtension: type,
//            subdirectory: subdirectory
//        ) else {
//            throw ReadabilityError.scriptNotFound
//        }
//        return try String(contentsOfFile: url.path(), encoding: .utf8)
//    }
     
    
    static func loadFile(name: String, type: String, subdirectory: String) throws -> String {
        let bundle = Bundle.module
        let fileName = "\(name).\(type)"
        let candidateSubdirectories = [
            subdirectory,
            URL(filePath: subdirectory).lastPathComponent,
        ]
        
        for candidate in candidateSubdirectories where candidate.isEmpty == false {
            if let url = bundle.url(
                forResource: name,
                withExtension: type,
                subdirectory: candidate
            ) {
                return try String(contentsOf: url, encoding: .utf8)
            }
        }
        
        if let url = bundle.url(forResource: name, withExtension: type) {
            return try String(contentsOf: url, encoding: .utf8)
        }
        
        // SwiftPM can flatten copied resources or keep a top-level directory
        // depending on how the bundle is assembled. Walk the bundle as a final
        // fallback so Readability.js still loads in both layouts.
        if let resourceURL = bundle.resourceURL,
           let enumerator = FileManager.default.enumerator(
            at: resourceURL,
            includingPropertiesForKeys: nil
           ) {
            for case let url as URL in enumerator where url.lastPathComponent == fileName {
                return try String(contentsOf: url, encoding: .utf8)
            }
        }
        throw ReadabilityError.scriptNotFound
    }
}
