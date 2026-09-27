import Foundation
import Testing
@testable import PicoDocs

struct LiteralBoundaryReviewTests {
    @Test func sourceFootnoteInlineContextStopsAtItsUnindentedEnd() async throws {
        for indent in ["", "   "] {
            let source = "See[^x]\n" + indent + "[^x]: `open\noutside " + #"\* `close"#
            let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "end.txt")
            for format in [ExportFileType.html, .plaintext, .csv] {
                let rendered = try DocumentRenderer.render(result, to: format)
                #expect(rendered.contains(#"outside \* `close"#))
                #expect(!rendered.contains(#"outside \\\*"#))
            }
        }
        for indent in ["    ", "\t"] {
            let source = "See[^x]\n[^x]: `open\n" + indent + #"\* close`"#
            let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "continued.txt")
            for format in [ExportFileType.html, .plaintext, .csv] {
                let rendered = try DocumentRenderer.render(result, to: format)
                #expect(rendered.contains(#"\* close"#)); #expect(!rendered.contains(#"\\\* close"#))
            }
        }
    }

    @Test func CSVInlineContextStopsWhenAnOutdentLeavesAList() async throws {
        for marker in ["-", "1.", "123."] {
            for bare in [false, true] {
                let prefix = bare ? marker + "\n" + String(repeating: " ", count: marker.count + 1) : marker + " "
                let source = prefix + "`open\noutside " + #"\* `close"#
                let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "outdent.txt")
                let csv = try DocumentRenderer.render(result, to: .csv)
                #expect(csv.contains(#"outside \* `close"#)); #expect(!csv.contains(#"outside \\\*"#))
            }
            let source = marker + " `open\n" + String(repeating: " ", count: marker.count + 1) + #"\* close`"#
            let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "nested.txt")
            let csv = try DocumentRenderer.render(result, to: .csv)
            #expect(csv.contains(#"\* close"#)); #expect(!csv.contains(#"\\\* close"#))
        }
    }


    @Test func footnoteDefinitionsEndSourceInlineCode() async throws {
        let source = "See[^x]\n`open\n[^x]: " + #"\* `close"#
        let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "notes.txt")
        for format in [ExportFileType.html, .plaintext] {
            #expect(try DocumentRenderer.render(result, to: format).contains(#"\* `close"#))
        }
    }

    @Test func tableCodeRetainsSourceSlashesBeforePipes() async throws {
        for count in [1, 3] {
            let literal = "a" + String(repeating: "\\", count: count) + "|b"
            let source = "| `" + literal + "` |\n| --- |"
            for (name, data) in [("table.txt", Data(source.utf8)), ("table.pages", PagesConverterTests.makePagesFile(paragraphs: [source]))] {
                let result = try await PicoDocsEngine.convert(data: data, filename: name)
                for format in [ExportFileType.html, .plaintext, .csv] {
                    #expect(try DocumentRenderer.render(result, to: format).contains(literal))
                }
            }
        }
    }

    @Test func CSVRetainsFencesAcrossSourceSections() throws {
        let source = [DocumentSection(markdown: "```"), .init(markdown: #"a\*b"#), .init(markdown: "```")]
        let result = ConverterResult(sections: MarkdownLiteral.escapeSectionBackslashes(source))
        for format in [ExportFileType.html, .plaintext, .csv] {
            #expect(try DocumentRenderer.render(result, to: format).contains(#"a\*b"#))
        }
    }

    @Test func CSVProtectsMultilineInlineCodeBeforeRenderingRows() async throws {
        let source = "prefix `open\n" + #"a\*b `close suffix"#
        let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "inline.txt")
        for format in [ExportFileType.html, .plaintext, .csv] {
            #expect(try DocumentRenderer.render(result, to: format).contains(#"a\*b"#))
        }
    }

    @Test func PagesEscapesUseVisibleTextAfterControlRemoval() async throws {
        for control in ["\u{0004}", "\u{007F}", "\u{009F}"] {
            let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makePagesFile(paragraphs: ["\\" + control + "*x*"]), filename: "control.pages")
            #expect(try DocumentRenderer.render(result, to: .plaintext) == #"\*x*"#)
            #expect(!(try DocumentRenderer.render(result, to: .html)).contains("<em>"))
        }
    }

    @Test func PagesHyperlinkLabelsPreserveCanonicalBracketEscapes() async throws {
        typealias B = PagesConverterTests
        for label in [#"\]"#, #"\["#, #"\\]"#, #"text [label]"#] {
            let run = B.lengthField(1, B.varintField(1, 0) + B.lengthField(2, B.varintField(1, 2)))
            let storage = B.varintField(1, 0) + B.lengthField(3, Array(label.utf8)) + B.lengthField(11, run)
            let stream = B.makeIWAStream(objects: [(1, 2001, storage, [2]), (2, 2032, B.lengthField(2, Array("https://example.com".utf8)), [])])
            let data = B.makeZip([(name: "Index/Document.iwa", data: B.snappyFrame(stream))])
            let result = try await PicoDocsEngine.convert(data: data, filename: "link.pages")
            #expect(try DocumentRenderer.render(result, to: .plaintext) == label)
            #expect(try DocumentRenderer.render(result, to: .html).contains("<a href=\"https://example.com\">" + label + "</a>"))
        }
    }


    @Test func confirmedBareListsFlushAtTheirExit() async throws {
        for marker in ["-", "1."] {
            let source = marker + "\n" + String(repeating: " ", count: marker.count + 1) + "`open\noutside " + #"\* `close"#
            let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "bare.txt")
            for format in [ExportFileType.html, .plaintext] { #expect(try DocumentRenderer.render(result, to: format).contains(#"outside \* `close"#)) }
        }
    }

    @Test func RTFPunctuationEscapesStayInsideTheirStyleRun() async throws {
        let rtf = #"{\rtf1\ansi \\\b *\b0 }"#
        let result = try await PicoDocsEngine.convert(data: Data(rtf.utf8), filename: "styles.rtf")
        #expect(try DocumentRenderer.render(result, to: .plaintext) == #"\*"#)
        #expect(try DocumentRenderer.render(result, to: .html).contains(#"\<strong>*</strong>"#))
        let projection = MarkdownLiteral.escapeProjection(#"\*"#, boundaries: [1])
        #expect(projection.after == [1, 0]); #expect(projection.before == [1])
    }

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
