import Foundation
import Testing
import SwiftSoup
import ZIPFoundation
@testable import PicoDocs

struct PowerPointStackReviewTests {
    @Test func combiningPunctuationStaysLiteral() async throws {
        typealias B = PowerPointConverterTests
        let literal = "*\u{0301}text*\u{0301} [\u{0301}label]\u{0301}"
        let paragraph = "<a:p><a:r><a:t>" + literal + "</a:t></a:r></a:p>"
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.shape(placeholder: nil, paragraphs: [paragraph]))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "literal.pptx")
        #expect(try DocumentRenderer.render(result, to: .plaintext) == literal)
        #expect(!(try DocumentRenderer.render(result, to: .html)).contains("<em>"))
    }

    @Test func significantASCIISpacesHaveHTMLPreservation() async throws {
        typealias B = PowerPointConverterTests
        let text = "  first\t  second  "
        let paragraph = "<a:p><a:r><a:t xml:space='preserve'>" + text + "</a:t></a:r></a:p>"
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.shape(placeholder: nil, paragraphs: [paragraph]))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "spaces.pptx")
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("white-space:pre-wrap"))
        #expect(try DocumentRenderer.render(result, to: .plaintext) == text)
        let literal = ConverterResult(sections: [.init(markdown: #"\&#32; `&#32;` [link](https://example.com/&#32;)"#)])
        let literalHTML = try DocumentRenderer.render(literal, to: .html)
        #expect(!literalHTML.contains("white-space:pre-wrap"))
        #expect(literalHTML.contains("<code>&amp;#32;</code>"))
        #expect(literalHTML.contains(#"href="https://example.com/&amp;#32;""#))
    }

    @Test func transientSlideDOMsConsumeTheSharedParseBudget() throws {
        typealias B = PowerPointConverterTests
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Title"))])
        let package = PowerPointPackage(archive: try #require(Archive(data: data, accessMode: .read)))
        let budget = PowerPointXML.Budget(nodes: 40)
        var parts = PowerPointConverter.PartCache(archive: package, budget: budget)
        let parsed = parts.document("ppt/slides/s.xml", root: "p:sld", cache: false)
        let first = try #require(parsed)
        let used = 40 - budget.nodes
        #expect(used > 0)
        // A fresh transient parse consumes the same number of nodes; it is not
        // excluded just because its DOM will be released after rendering.
        budget.nodes = used - 1
        #expect(parts.document("ppt/slides/s.xml", root: "p:sld", cache: false) == nil)
        #expect(throws: PicoDocsError.fileCorrupted) { try package.check() }
        #expect(first.children().first() != nil)
    }
}
