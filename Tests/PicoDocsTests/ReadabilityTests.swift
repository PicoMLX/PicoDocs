import Foundation
import Testing
import WebKit
@testable import PicoDocs

@Suite(.serialized)
struct ReadabilityTests {
    @MainActor
    @Test("loadFile throws for a missing Readability.js resource")
    func loadFileThrowsForMissingScript() {
        do {
            _ = try ReadabilityUserScript.loadFile(
                name: "MissingReadability",
                type: "js",
                subdirectory: "Parsers/ParserTools/Readability"
            )
            Issue.record("Expected a missing script resource to throw.")
        } catch let error as ReadabilityError {
            switch error {
            case .scriptNotFound:
                break
            default:
                Issue.record("Unexpected ReadabilityError: \(String(describing: error))")
            }
        } catch {
            Issue.record("Unexpected error type: \(String(describing: error))")
        }
    }

    @MainActor
    @Test("ReadabilityUserScript loads the bundled Readability.js contents")
    func userScriptLoadsBundledReadabilityScript() throws {
        let bundledScript = try ReadabilityUserScript.loadFile(
            name: "Readability",
            type: "js",
            subdirectory: "Parsers/ParserTools/Readability"
        )

        let userScript = ReadabilityUserScript()

        #expect(bundledScript.isEmpty == false)
        #expect(bundledScript.contains("function Readability(doc, options)"))
        #expect(userScript.source.contains("function Readability(doc, options)"))
        #expect(userScript.source.count == bundledScript.count)
        #expect(userScript.injectionTime == .atDocumentEnd)
        #expect(userScript.isForMainFrameOnly)
    }

    @MainActor
    @Test("Readability.js is injected into a WKWebView page")
    func readabilityScriptIsInjectedIntoWebView() async throws {
        let webView = makeWebView()
        let navigator = NavigationDelegate()
        webView.navigationDelegate = navigator

        try await navigator.load(htmlString: Self.sampleHTML, in: webView)

        let readabilityType = try #require(
            try await webView.evaluateJavaScript("typeof Readability") as? String
        )
        #expect(readabilityType == "function")

        let articleTitle = try #require(
            try await webView.evaluateJavaScript(
                "new Readability(document).parse().title"
            ) as? String
        )
        #expect(articleTitle == Self.sampleTitle)
    }

    @MainActor
    @Test("Readability parses a local article with the bundled script")
    func parseLoadsAndExecutesBundledReadabilityScript() async throws {
        let htmlURL = try Self.makeSampleHTMLFile()
        defer { try? FileManager.default.removeItem(at: htmlURL) }

        let readability = Readability(url: htmlURL)
        let readable = try await readability.parse()

        #expect(readable.title == Self.sampleTitle)
        #expect(readable.content.contains("second paragraph exists to verify"))
        #expect(readable.textContent.contains("third paragraph makes the article long enough"))
        #expect(readable.length > 500)
        #expect(readable.excerpt?.isEmpty == false)
    }

    @Test("Readability preprocessing removes executable scripts but keeps JSON-LD")
    func preprocessingRemovesExecutableScripts() throws {
        let preprocessed = try ReadabilityHTMLPreprocessor.preprocess(
            Self.sampleHTMLWithAppState,
            baseURL: URL(string: "https://example.com/article")!
        )

        #expect(preprocessed.contains("window.__INITIAL_STATE__") == false)
        #expect(preprocessed.contains("\"headline\":\"\(Self.sampleTitle)\""))
        #expect(preprocessed.contains("articleBody") == false)
    }

    @Test("Readability preprocessing removes malformed inline state scripts")
    func preprocessingRemovesMalformedInlineStateScripts() throws {
        let preprocessed = try ReadabilityHTMLPreprocessor.preprocess(
            Self.sampleHTMLWithMalformedStateScript,
            baseURL: URL(string: "https://example.com/article")!
        )

        #expect(preprocessed.contains("window.__INITIAL_STATE__") == false)
        #expect(preprocessed.contains("components-AdLive-__AdLive__label"))
    }

    @MainActor
    @Test("Readability htmlString parsing excludes app state payloads")
    func parseHTMLStringExcludesAppStatePayloads() async throws {
        let readability = Readability(htmlString: Self.sampleHTMLWithAppState)
        let readable = try await readability.parse()

        #expect(readable.title == Self.sampleTitle)
        #expect(readable.textContent.contains("second paragraph exists to verify"))
        #expect(readable.textContent.contains("window.__INITIAL_STATE__") == false)
        #expect(readable.content.contains("window.__INITIAL_STATE__") == false)
    }

    @MainActor
    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(ReadabilityUserScript())
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private static let sampleTitle = "PicoDocs Readability Test Article"

    private static let sampleHTML = """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <title>\(sampleTitle)</title>
      </head>
      <body>
        <main>
          <article>
            <h1>\(sampleTitle)</h1>
            <p>The first paragraph gives Readability enough editorial structure to identify this page as an article instead of a generic collection of navigation elements. It contains deliberate, natural language sentences with enough substance to look like a real document and it mentions PicoDocs so the test can assert against unique content.</p>
            <p>The second paragraph exists to verify that the bundled Readability.js script is not only present, but also capable of extracting meaningful content from a loaded document. If this script is missing, malformed, or not injected into the web view at document end, the production parser will fail before it can produce a structured article.</p>
            <p>The third paragraph makes the article long enough to clear Readability's default character threshold while staying deterministic for a unit test. That lets this suite validate the exact integration path used by `Readability.parse()`, including the bundled resource lookup, user script injection, JavaScript execution, JSON serialization, and Swift decoding into the `Readable` model.</p>
          </article>
        </main>
      </body>
    </html>
    """

    private static let sampleHTMLWithAppState = """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <title>\(sampleTitle)</title>
        <script>
          window.__INITIAL_STATE__ = {
            "player": {
              "sponsorMessage": "Live Radio KQED News Player sponsored by"
            }
          };
        </script>
        <script type="application/ld+json">
          {"@context":"https://schema.org","@type":"NewsArticle","headline":"\(sampleTitle)"}
        </script>
      </head>
      <body>
        <article>
          <h1>\(sampleTitle)</h1>
          <p>The first paragraph gives Readability enough editorial structure to identify this page as an article instead of a generic collection of navigation elements. It contains deliberate, natural language sentences with enough substance to look like a real document and it mentions PicoDocs so the test can assert against unique content.</p>
          <p>The second paragraph exists to verify that the bundled Readability.js script is not only present, but also capable of extracting meaningful content from a loaded document. If this script is missing, malformed, or not injected into the web view at document end, the production parser will fail before it can produce a structured article.</p>
          <p>The third paragraph makes the article long enough to clear Readability's default character threshold while staying deterministic for a unit test. That lets this suite validate the exact integration path used by `Readability.parse()`, including the bundled resource lookup, user script injection, JavaScript execution, JSON serialization, and Swift decoding into the `Readable` model.</p>
        </article>
      </body>
    </html>
    """

    private static let sampleHTMLWithMalformedStateScript = """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <title>\(sampleTitle)</title>
      </head>
      <body>
        <article>
          <h1>\(sampleTitle)</h1>
          <p>The first paragraph gives Readability enough editorial structure to identify this page as an article instead of a generic collection of navigation elements. It contains deliberate, natural language sentences with enough substance to look like a real document and it mentions PicoDocs so the test can assert against unique content.</p>
          <p>The second paragraph exists to verify that the bundled Readability.js script is not only present, but also capable of extracting meaningful content from a loaded document. If this script is missing, malformed, or not injected into the web view at document end, the production parser will fail before it can produce a structured article.</p>
          <p>The third paragraph makes the article long enough to clear Readability's default character threshold while staying deterministic for a unit test. That lets this suite validate the exact integration path used by `Readability.parse()`, including the bundled resource lookup, user script injection, JavaScript execution, JSON serialization, and Swift decoding into the `Readable` model.</p>
        </article>
        <div class="components-AdLive-__AdLive__label">Player sponsored by</div>
        <script id="initial-state" charSet="UTF-8" />
          window.__IS_SSR__=true
          window.__INITIAL_STATE__={"attachmentsReducer":{"audio_0":{"type":"attachments"}}}
        </script>
      </body>
    </html>
    """

    private static func makeSampleHTMLFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("readability-\(UUID().uuidString)")
            .appendingPathExtension("html")
        try sampleHTML.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

@MainActor
private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(htmlString: String, in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(htmlString, baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resume(with: .success(()))
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        resume(with: .failure(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        resume(with: .failure(error))
    }

    private func resume(with result: Result<Void, Error>) {
        guard let continuation else {
            return
        }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
