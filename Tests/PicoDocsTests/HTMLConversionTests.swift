//
//  HTMLConversionTests.swift
//  PicoDocsTests
//
//  HTML → Markdown (issue #2: HTML used to come back as raw markup) plus the
//  pure-Swift Readability extraction pass. Readability is exercised through the
//  engine so the integrated path (detect → convert → render) is covered.
//

import Foundation
import Testing
@testable import PicoDocs

@Suite("HTML to Markdown")
struct HTMLConversionTests {

    /// Convert an HTML string with Readability off, so the full body is rendered
    /// deterministically (the structural assertions don't depend on scoring).
    private func fullBodyMarkdown(_ html: String) async throws -> String {
        try await PicoDocsEngine.convert(
            data: Data(html.utf8),
            filename: "page.html",
            mimeType: "text/html",
            enhanceReadability: false
        ).markdown()
    }

    @Test("Headings and emphasis become Markdown")
    func headingsAndEmphasis() async throws {
        let md = try await fullBodyMarkdown(
            "<html><body><h1>Title</h1><p>Hello <strong>world</strong> and <em>more</em>.</p></body></html>"
        )
        #expect(md.contains("# Title"))
        #expect(md.contains("**world**"))
        #expect(md.contains("*more*"))
    }

    @Test("HTML is not returned as raw markup")
    func noRawMarkup() async throws {
        let md = try await fullBodyMarkdown("<html><body><p>Just text</p></body></html>")
        #expect(md.contains("Just text"))
        #expect(!md.contains("<p>"))
        #expect(!md.contains("</p>"))
    }

    @Test("Relative links resolve against the document URL")
    func relativeLinks() async throws {
        let md = try await PicoDocsEngine.convert(
            data: Data("<html><body><p><a href=\"/about\">About</a></p></body></html>".utf8),
            url: try #require(URL(string: "https://example.com/index.html")),
            enhanceReadability: false
        ).markdown()
        #expect(md.contains("[About](https://example.com/about)"))
    }

    @Test("Tables render as Markdown pipe tables")
    func tables() async throws {
        let md = try await fullBodyMarkdown(
            "<html><body><table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table></body></html>"
        )
        #expect(md.contains("| A | B |"))
        #expect(md.contains("| 1 | 2 |"))
    }
}

@Suite("Readability extraction")
struct ReadabilityExtractionTests {

    private func readerMarkdown(_ html: String) async throws -> String {
        try await PicoDocsEngine.convert(
            data: Data(html.utf8),
            filename: "article.html",
            mimeType: "text/html",
            enhanceReadability: true
        ).markdown()
    }

    @Test("Keeps the article body, drops nav and footer boilerplate")
    func dropsBoilerplate() async throws {
        let html = """
        <html><head><title>Ignored</title></head><body>
        <nav class="navigation"><a href="/a">Home</a> <a href="/b">About</a> <a href="/c">Contact</a></nav>
        <div class="article-content">
        <h1>The Main Article</h1>
        <p>This is the first substantial paragraph of the article body. It has enough real,
        natural-language text to be recognized as the main content of the page rather than the
        navigation or boilerplate that surrounds it on a typical web page.</p>
        <p>This is the second substantial paragraph. It continues the article with several more
        sentences, so the scorer confidently selects this container as the article and emits it
        as the reader-mode Markdown output for downstream RAG use.</p>
        </div>
        <footer class="site-footer"><a href="/p">Privacy</a> <a href="/t">Terms</a></footer>
        </body></html>
        """
        let md = try await readerMarkdown(html)
        #expect(md.contains("The Main Article"))
        #expect(md.contains("first substantial paragraph"))
        #expect(!md.contains("Privacy"))
        #expect(!md.contains("Home"))
    }
}
