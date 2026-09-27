import Foundation
import Testing
import SwiftSoup
@testable import PicoDocs

struct LiteralBoundaryReviewTests {
    @Test func unmatchedTickRunsStayWholeWithoutAnEscape() throws {
        for source in ["``x`", "```x``", "\\\\``x`"] {
            let result = ConverterResult(sections: [.init(markdown: "prefix " + source)])
            let expected = source.hasPrefix("\\\\") ? String(source.dropFirst()) : source
            #expect(try DocumentRenderer.render(result, to: .plaintext) == "prefix " + expected)
            #expect(!(try DocumentRenderer.render(result, to: .html)).contains("<code>"))
        }
    }

    @Test func generatedLinkDestinationEscapesAlreadyDecodeOnce() async throws {
        for value in [#"foo\bar"#, #"foo\\bar"#, #"foo\(bar)"#] {
            let result = try await PicoDocsEngine.convert(data: Data("<p><a href=\"\(value)\">Link</a></p>".utf8), filename: "slashes.html")
            let html = try SwiftSoup.parse(DocumentRenderer.render(result, to: .html))
            #expect(try html.getElementsByTag("a").first()?.attr("href") == value)
            #expect(try DocumentRenderer.render(result, to: .plaintext) == "Link")
        }
    }

    @Test func literalSourceBackslashesProtectScalarPunctuation() async throws {
        for mark in ["\u{0301}", "\u{FE0F}"] {
            let source = "\\*" + mark + "x*" + mark
            let text = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "combining.txt")
            let sections = ConverterResult(sections: MarkdownLiteral.escapeSectionBackslashes([.init(markdown: source)]))
            for result in [text, sections] {
                #expect(try DocumentRenderer.render(result, to: .plaintext) == source)
                #expect(try DocumentRenderer.render(result, to: .csv) == source)
                #expect(!(try DocumentRenderer.render(result, to: .html)).contains("<em>"))
            }
        }
    }

    @Test func removingIndentedFootnotesKeepsTheEnclosingList() throws {
        for marker in ["-", "1."] {
            let indent = String(repeating: " ", count: marker.count + 1)
            let result = ConverterResult(sections: [.init(markdown: marker + " a[^x]\n" + indent + "[^x]: note\n" + marker + " b")])
            let html = try SwiftSoup.parse(DocumentRenderer.render(result, to: .html))
            let lists = try html.getElementsByTag(marker == "-" ? "ul" : "ol")
            let bodyList = try #require(lists.first())
            #expect(bodyList.children().count == 2)
            #expect(try bodyList.text().contains("b"))
            #expect(try html.getElementsByClass("footnotes").first()?.text().contains("note") == true)
        }
    }

    @Test func escapedFootnoteClosersMatchReferencesAndDefinitions() throws {
        for label in [#"a\]b"#, #"a\\\]b"#, #"a\\"#] {
            let result = ConverterResult(sections: [.init(markdown: "Body[^" + label + "]\n\n[^" + label + "]: note")])
            let text = try DocumentRenderer.render(result, to: .plaintext)
            #expect(text.contains("Body[1]")); #expect(text.contains("[1] note"))
            #expect(!text.contains("[^"))
        }
    }

    @Test func textImportsKeepTheSharedMarkdownBlockGrammar() async throws {
        for (source, tag) in [("text\n___", "hr"), ("1.\n   literal", "ol")] {
            let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "blocks.txt")
            let html = try SwiftSoup.parse(DocumentRenderer.render(result, to: .html))
            #expect(try !html.getElementsByTag(tag).isEmpty())
        }
    }

    @Test func RTFStylePrefixesDetermineInlineContextBoundaries() async throws {
        let rtf = #"{\rtf1\ansi `open\line \b # \\* `close\b0 }"#
        let result = try await PicoDocsEngine.convert(data: Data(rtf.utf8), filename: "composed.rtf")
        for format in [ExportFileType.html, .plaintext, .csv] {
            let rendered = try DocumentRenderer.render(result, to: format)
            #expect(rendered.contains(#"\*"#)); #expect(!rendered.contains(#"\\\*"#))
        }
        #expect(try DocumentRenderer.render(result, to: .html).contains("<code>"))
    }


    @Test func escapedTicksCanPrecedeIndependentCodeDelimiters() async throws {
        let html = "<p>`<code>x</code></p>"
        let result = try await PicoDocsEngine.convert(data: Data(html.utf8), filename: "ticks.html")
        #expect(try DocumentRenderer.render(result, to: .plaintext) == "`x")
        #expect(try DocumentRenderer.render(result, to: .csv) == "`x")
        #expect(try DocumentRenderer.render(result, to: .html).contains("`<code>x</code>"))
        for length in [1, 2, 3] {
            let delimiter = String(repeating: "`", count: length)
            let markdown = "\\`" + delimiter + "x" + delimiter
            let value = ConverterResult(sections: [.init(markdown: markdown)])
            #expect(try DocumentRenderer.render(value, to: .plaintext) == "`x")
            #expect(try DocumentRenderer.render(value, to: .html).contains("`<code>x</code>"))
        }
        let trailingSlash = ConverterResult(sections: [.init(markdown: "`a\\`")])
        #expect(try DocumentRenderer.render(trailingSlash, to: .plaintext) == "a\\")
    }

    @Test func CSVMarkdownEscapesPreserveCombiningMarksAndVariationSelectors() async throws {
        for mark in ["\u{0301}", "\u{FE0F}"] {
            for punctuation in ["*", "_", "`", "[", "]", "<", ">", "|", "\\"] {
                let value = punctuation + mark + "x" + punctuation + mark
                let result = try await PicoDocsEngine.convert(data: Data(("Header\n" + value).utf8), filename: "unicode.csv")
                let html = try SwiftSoup.parse(DocumentRenderer.render(result, to: .html))
                #expect(try html.getElementsByTag("td").first()?.text() == value)
                #expect(try DocumentRenderer.render(result, to: .plaintext).contains(value))
                #expect(try DocumentRenderer.render(result, to: .csv).contains(value))
            }
        }
    }

    @Test func bareTablePipesRemainCellBoundariesWithoutShiftingEscapes() async throws {
        let source = #"| `a|b` | later \* |"# + "\n| --- | --- |"
        let rtf = "{\\rtf1\\ansi " + source.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\line ") + "}"
        for (name, data) in [("pipes.txt", Data(source.utf8)), ("pipes.pages", PagesConverterTests.makePagesFile(paragraphs: [source])), ("pipes.rtf", Data(rtf.utf8))] {
            let result = try await PicoDocsEngine.convert(data: data, filename: name)
            let html = try DocumentRenderer.render(result, to: .html)
            let table = try #require(try SwiftSoup.parse(html).getElementsByTag("table").first())
            #expect(try table.getElementsByTag("th").count == 3)
            #expect(try table.getElementsByTag("code").isEmpty())
            for format in [ExportFileType.html, .plaintext, .csv] {
                let rendered = try DocumentRenderer.render(result, to: format)
                #expect(rendered.contains(#"later \*"#)); #expect(!rendered.contains(#"later \\\*"#))
            }
        }
        let projection = MarkdownLiteral.escapeProjection(source, boundaries: [4])
        #expect(!projection.before.contains(4))
    }

    @Test func indentedFootnoteLikeTextRetainsItsParagraphCodeContext() async throws {
        for indent in ["    ", "\t"] {
            let source = "`open\n" + indent + "[^x]: middle\noutside " + #"\* `close"#
            let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "indented-note.txt")
            for format in [ExportFileType.html, .plaintext, .csv] {
                let rendered = try DocumentRenderer.render(result, to: format)
                #expect(rendered.contains(#"outside \*"#)); #expect(!rendered.contains(#"outside \\\*"#))
            }
        }
    }


    @Test func nestedFencesUseTheSameStructuralOutdentRuleAsLists() async throws {
        for marker in ["1.", "123."] {
            for structural in ["# heading ", "> quote ", "- item ", "| cell "] {
                let source = marker + " item\n" + String(repeating: " ", count: marker.count + 1) + "```\n  " + structural + #"\*"#
                let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "structural-outdent.txt")
                for format in [ExportFileType.html, .plaintext, .csv] {
                    let rendered = try DocumentRenderer.render(result, to: format)
                    #expect(rendered.contains(#"\*"#)); #expect(!rendered.contains(#"\\\*"#))
                }
            }
        }
    }

    @Test func PagesFallbackRetainsValidLooseListParagraphs() async throws {
        typealias B = PagesConverterTests
        let source = "- item\n\n  continuation\n\noutside"
        #expect(PagesConverter.normalize(source) == source)
        let data = B.makeZip([(name: "Index/Other.iwa", data: B.snappyFrame(B.makeIWAStream(runs: [source])))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "loose-fallback.pages")
        let html = try DocumentRenderer.render(result, to: .html)
        let document = try SwiftSoup.parse(html)
        let item = try #require(document.getElementsByTag("li").first())
        #expect(try item.text().contains("continuation"))
        #expect(try !item.text().contains("outside"))
    }

    @Test func PagesTableAttachmentsSplitCodeContextButImagePlaceholdersDoNot() async throws {
        typealias B = PagesConverterTests
        let source = "`open\u{FFFC}after " + #"\* `close"#
        let data = B.makeListPagesFile(text: source, style: .bullet, restarts: [], tableCell: "Cell")
        let result = try await PicoDocsEngine.convert(data: data, filename: "code-table.pages")
        for format in [ExportFileType.html, .plaintext, .csv] {
            let rendered = try DocumentRenderer.render(result, to: format)
            #expect(rendered.contains(#"after \* `close"#)); #expect(!rendered.contains(#"after \\\*"#))
        }
        let image = try await PicoDocsEngine.convert(data: B.makePagesFile(paragraphs: [source]), filename: "code-image.pages")
        let text = try DocumentRenderer.render(image, to: .plaintext)
        #expect(text.contains(#"after \*"#)); #expect(!text.contains(#"after \\\*"#))
    }

    @Test func removedFootnotesRetainBodyParagraphBoundaries() async throws {
        let source = "`open\n[^x]: note\nclose " + #"\* `end"#
        let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "body-around-note.txt")
        for format in [ExportFileType.html, .plaintext, .csv] {
            let rendered = try DocumentRenderer.render(result, to: format)
            #expect(rendered.contains(#"close \* `end"#))
            #expect(!rendered.contains(#"close \\\*"#))
        }
    }

    @Test func confirmedBareMarkersInterruptParagraphContext() async throws {
        for marker in ["-", "1."] {
            let source = "`open\n" + marker + "\n" + marker + "\noutside " + #"\* `close"#
            let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "bare-boundary.txt")
            for format in [ExportFileType.html, .plaintext, .csv] {
                let rendered = try DocumentRenderer.render(result, to: format)
                #expect(rendered.contains(#"outside \* `close"#))
                #expect(!rendered.contains(#"outside \\\*"#))
            }
        }
    }

    @Test func listScopedFencesStopAtTheirContainerExit() async throws {
        for marker in ["-", "123."] {
            let indent = String(repeating: " ", count: marker.count + 1)
            let source = marker + " item\n" + indent + "```\n" + indent + #"inside \*"# + "\noutside " + #"\*"#
            let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "nested-fence.txt")
            for format in [ExportFileType.html, .plaintext, .csv] {
                let rendered = try DocumentRenderer.render(result, to: format)
                #expect(rendered.contains(#"inside \*"#)); #expect(rendered.contains(#"outside \*"#))
                #expect(!rendered.contains(#"outside \\\*"#))
            }
        }
    }

    @Test func PagesLargeListNumbersDegradeWithoutLosingTheDocument() async throws {
        for (start, next): (UInt64, String) in [(999_999_999, "1000000000"), (1_000_000_000, "1000000001"), (UInt64.max, "18446744073709551616")] {
            let data = PagesConverterTests.makeListPagesFile(text: "First\nNext", style: .ordered, restarts: [(0, start), (6, 0)])
            let result = try await PicoDocsEngine.convert(data: data, filename: "large-list.pages")
            let text = try DocumentRenderer.render(result, to: .plaintext)
            #expect(text.contains(String(start) + ". First"))
            #expect(text.contains(next + ". Next"))
        }
    }

    @Test func PagesRawFallbackEscapesTheNormalizedIndentation() async throws {
        typealias B = PagesConverterTests
        for marker in ["-", "+", "*"] {
            let source = marker + " `open\n  outside " + #"\* `close"#
            let stream = B.makeIWAStream(runs: [source])
            let data = B.makeZip([(name: "Index/Other.iwa", data: B.snappyFrame(stream))])
            let result = try await PicoDocsEngine.convert(data: data, filename: "fallback.pages")
            for format in [ExportFileType.html, .plaintext, .csv] {
                let rendered = try DocumentRenderer.render(result, to: format)
                #expect(rendered.contains(#"outside \*"#))
                #expect(!rendered.contains(#"outside \\\*"#))
            }
        }
    }

    @Test func footnoteCodeSpansContinueAcrossIndentedBlankParagraphs() async throws {
        for indent in ["    ", "\t"] {
            for blank in ["\n", "\n\n", "    \n"] {
                let source = "See[^x]\n[^x]: `open\n" + blank + indent + #"a\*b `close"#
                let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "continued-note.txt")
                for format in [ExportFileType.html, .plaintext, .csv] {
                    let rendered = try DocumentRenderer.render(result, to: format)
                    #expect(rendered.contains(#"a\*b"#))
                    #expect(!rendered.contains(#"a\\\*b"#))
                }
            }
            let source = "See[^x]\n[^x]: `open\n\n" + indent + "# " + #"a\*b `close"#
            let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "continued-heading-note.txt")
            #expect(try DocumentRenderer.render(result, to: .plaintext).contains(#"a\*b"#))
        }
        let source = "See[^x]\n[^x]: `open\n\noutside " + #"a\*b `close"#
        let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "ended-note.txt")
        #expect(try DocumentRenderer.render(result, to: .plaintext).contains(#"outside a\*b `close"#))
    }

    @Test func PagesSoftBreaksClassifyStructuralBoundariesWithoutSplittingPlainCode() async throws {
        for separator in ["\u{2028}", "\u{000B}", "\u{000C}"] {
            for marker in ["# heading ", "> quote ", "- item ", "1. item ", "| cell "] {
                let text = "`open" + separator + marker + #"a\*b `close"#
                let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makePagesFile(paragraphs: [text]), filename: "soft-structure.pages")
                for format in [ExportFileType.html, .plaintext] {
                    #expect(try DocumentRenderer.render(result, to: format).contains(#"a\*b `close"#))
                }
            }
            let text = "`open" + separator + #"a\*b `close"#
            let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makePagesFile(paragraphs: [text]), filename: "soft-code.pages")
            for format in [ExportFileType.html, .plaintext] {
                let rendered = try DocumentRenderer.render(result, to: format)
                #expect(rendered.contains(#"a\*b"#))
                #expect(!rendered.contains(#"a\\\*b"#))
            }
        }
    }

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
