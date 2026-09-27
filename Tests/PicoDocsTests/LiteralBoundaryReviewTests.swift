import Foundation
import Testing
@testable import PicoDocs

struct LiteralBoundaryReviewTests {
    @Test func leavingListsEndsInlineCodeButIndentedContinuationKeepsIt() async throws {
        for marker in ["- ", "1. ", "123. "] {
            let source = marker + "`open\noutside " + #"\* `close"#
            let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "list.txt")
            for format in [ExportFileType.html, .plaintext] {
                #expect(try DocumentRenderer.render(result, to: format).contains(#"outside \* `close"#))
            }
            let indented = marker + "`open\n" + String(repeating: " ", count: marker.count) + #"\* close`"#
            let continued = try await PicoDocsEngine.convert(data: Data(indented.utf8), filename: "list.txt")
            let html = try DocumentRenderer.render(continued, to: .html)
            #expect(html.contains("<code>")); #expect(html.contains(#"\* close"#)); #expect(!html.contains(#"\\* close"#))
        }
    }

    @Test func verbatimTableCellsHaveIndependentInlineCode() async throws {
        for source in [#"| `open | \* `close |"#, #"| `open | x\|y \* `close |"#] {
            let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "table.txt")
            for format in [ExportFileType.html, .plaintext, .csv] {
                #expect(try DocumentRenderer.render(result, to: format).contains(#"\* `close"#))
            }
        }
    }

    @Test func PagesHardParagraphSeparatorsBreakInlineSpans() async throws {
        for separator in ["\n", "\r", "\u{2029}"] {
            let source = "`open" + separator + #"\* `close"#
            let data = PagesConverterTests.makePagesFile(paragraphs: [source])
            let result = try await PicoDocsEngine.convert(data: data, filename: "paragraphs.pages")
            for format in [ExportFileType.html, .plaintext] {
                #expect(try DocumentRenderer.render(result, to: format).contains(#"\* `close"#))
            }
        }
        let fenced = PagesConverterTests.makePagesFile(paragraphs: ["```", #"\*"#, "```"])
        let result = try await PicoDocsEngine.convert(data: fenced, filename: "fenced.pages")
        #expect(try DocumentRenderer.render(result, to: .html).contains(#"\*"#))
        #expect(try !DocumentRenderer.render(result, to: .html).contains(#"\\*"#))
    }

    @Test func unmatchedCodeDoesNotCrossStructuralBoundaries() async throws {
        for prefix in ["# heading ", "> quote ", "- item ", "1. item ", "| cell "] {
            let source = "`open\n" + prefix + #"\* `close"#
            let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "literal.txt")
            for format in [ExportFileType.html, .plaintext] {
                #expect(try DocumentRenderer.render(result, to: format).contains(#"\* `close"#))
            }
        }
        for boundary in ["# heading", "> quote", "---", "***", "___"] {
            let source = "`open\n" + boundary + "\n" + #"\* `close"#
            let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "literal.txt")
            for format in [ExportFileType.html, .plaintext] {
                #expect(try DocumentRenderer.render(result, to: format).contains(#"\* `close"#))
            }
        }
    }

    @Test func escapedMarkerPunctuationRemainsLiteral() throws {
        for source in [#"\*literal*"#, #"\* literal*"#, #"\-literal"#, #"1\.literal"#] {
            let result = ConverterResult(sections: [.init(markdown: source)])
            let expected = source.replacingOccurrences(of: "\\", with: "")
            #expect(try DocumentRenderer.render(result, to: .plaintext) == expected)
            let html = try DocumentRenderer.render(result, to: .html)
            #expect(html.contains(expected))
            #expect(!html.contains("<em>"))
        }
    }
}
