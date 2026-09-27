import Foundation
import Testing
import SwiftSoup
@testable import PicoDocs

struct LiteralBoundaryReviewTests {
    @Test func nativePagesListFenceTextUsesGeneratedStructure() async throws {
        for style in [PagesConverterTests.ListKind.bullet, .ordered] {
            for separator in ["\n", "\r", "\u{2029}", "\u{2028}"] {
                let source = "```" + separator + #"\* regex"#
                let data = PagesConverterTests.makeListPagesFile(text: source, style: style, restarts: [])
                let result = try await PicoDocsEngine.convert(data: data, filename: "fence-list.pages")
                for format in [ExportFileType.html, .plaintext, .csv] {
                    let rendered = try DocumentRenderer.render(result, to: format)
                    #expect(rendered.contains(#"\* regex"#))
                    #expect(!rendered.contains("<pre>"))
                }
            }
        }
        let source = "```\n\\* regex"
        let data = PagesConverterTests.makeListPagesFile(text: source, style: .ordered, restarts: [(4, 12)])
        let result = try await PicoDocsEngine.convert(data: data, filename: "restart.pages")
        #expect(try DocumentRenderer.render(result, to: .plaintext).contains(#"\* regex"#))
    }

    @Test func HTMLTablePipesEscapeBeforeCombiningScalars() throws {
        for mark in ["\u{0301}", "\u{FE0F}"] {
            for code in [false, true] {
                let source = "a|" + mark + "b"
                let inner = code ? "<code>\(source)</code>" : source
                let converted = try HTMLToMarkdown.convert(html: "<table><tr><td>\(inner)</td></tr></table>")
                #expect(converted.markdown.contains("a\\|" + mark + "b"))
                let result = ConverterResult(sections: [.init(markdown: converted.markdown)])
                let html = try SwiftSoup.parse(DocumentRenderer.render(result, to: .html))
                let cells = try html.select("th,td")
                #expect(cells.size() == 1)
                #expect(try cells.first()?.text() == source)
                #expect(try DocumentRenderer.render(result, to: .csv).contains(source))
            }
        }
    }


    @Test func PagesTrimmingUsesTheEmittedFenceContext() async throws {
        for separator in ["\n", "\r", "\u{2029}"] {
            let source = ["- item", "  ```", #"outside \*"#].joined(separator: separator)
            let data = PagesConverterTests.makeListPagesFile(text: source, style: .bullet, restarts: [], heading: false)
            // The unstyled storage path uses the same UTF-16 escape projection.
            typealias B = PagesConverterTests
            let storage = B.varintField(1, 0) + B.lengthField(3, Array(source.utf8))
            let stream = B.makeIWAStream(objects: [(1, 2001, storage, [])])
            let plainData = B.makeZip([("Index/Document.iwa", B.snappyFrame(stream))])
            let result = try await PicoDocsEngine.convert(data: plainData, filename: "trim.pages")
            let html = try SwiftSoup.parse(DocumentRenderer.render(result, to: .html))
            #expect(try html.getElementsByTag("code").first()?.text() == #"outside \*"#)
            #expect(try DocumentRenderer.render(result, to: .plaintext).contains(#"outside \*"#))
            // Native list rendering remains accepted with the same literal source.
            _ = try await PicoDocsEngine.convert(data: data, filename: "list.pages")
        }
    }

    @Test func spreadsheetEscapesPunctuationScalarsWithCombiningMarks() async throws {
        for mark in ["\u{0301}", "\u{FE0F}"] {
            let source = "*" + mark + "x*" + mark
            let sheet = "<worksheet xmlns='http://schemas.openxmlformats.org/spreadsheetml/2006/main'><sheetData><row r='1'><c r='A1' t='inlineStr'><is><t>\(source)</t></is></c></row></sheetData></worksheet>"
            let result = try await PicoDocsEngine.convert(data: ConverterTests.xlsx(sheetXML: sheet), filename: "unicode.xlsx")
            for format in [ExportFileType.html, .plaintext, .csv] {
                let rendered = try DocumentRenderer.render(result, to: format)
                #expect(rendered.contains(source)); #expect(!rendered.contains("<em>"))
            }
        }
    }


    @Test func rootFootnoteExtractionPreservesTheListExit() async throws {
        let source = "- x\n[^n]: note\n  ```\n\\*Z"
        let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "literal.txt")
        let html = try SwiftSoup.parse(DocumentRenderer.render(result, to: .html))
        let code = try #require(html.getElementsByTag("code").first())
        #expect(try code.text() == #"\*Z"#)
        #expect(try html.getElementsByTag("li").first()?.getElementsByTag("code").isEmpty() == true)
        #expect(try DocumentRenderer.render(result, to: .plaintext).contains(#"\*Z"#))
    }

    @Test func PagesLinkLabelsEscapeBracketScalarsWithCombiningMarks() async throws {
        typealias B = PagesConverterTests
        for mark in ["\u{0301}", "\u{FE0F}"] {
            for label in ["a]" + mark + "b", "a[" + mark + "b", #"\]"# + mark, #"\\["# + mark] {
                let run = B.lengthField(1, B.varintField(1, 0) + B.lengthField(2, B.varintField(1, 2)))
                let storage = B.varintField(1, 0) + B.lengthField(3, Array(label.utf8)) + B.lengthField(11, run)
                let stream = B.makeIWAStream(objects: [(1, 2001, storage, [2]), (2, 2032, B.lengthField(2, Array("https://example.com".utf8)), [])])
                let result = try await PicoDocsEngine.convert(data: B.makeZip([("Index/Document.iwa", B.snappyFrame(stream))]), filename: "label.pages")
                #expect(try DocumentRenderer.render(result, to: .plaintext) == label)
                let html = try SwiftSoup.parse(DocumentRenderer.render(result, to: .html))
                let link = try #require(html.getElementsByTag("a").first())
                #expect(try link.attr("href") == "https://example.com"); #expect(try link.text() == label)
            }
        }
    }

    @Test func oversizedNativeMarkersDoNotOwnInlineTables() async throws {
        for start in [UInt64(1_000_000_000), UInt64.max] {
            let data = PagesConverterTests.makeListPagesFile(text: "a \u{FFFC} b\nc", style: .ordered, restarts: [(0, start)], tableCell: "Cell")
            let result = try await PicoDocsEngine.convert(data: data, filename: "large-number.pages")
            let lines = result.markdown().components(separatedBy: "\n")
            #expect(lines.contains("b")); #expect(lines.contains("| Cell |"))
            #expect(lines.contains { $0.hasPrefix(String(start) + #"\. a"#) })
            let plain = try DocumentRenderer.render(result, to: .plaintext)
            #expect(!plain.contains(String(repeating: " ", count: 12) + "b"))
        }
    }

    @Test func RTFTrimmingAndEscapeProjectionShareFenceContext() async throws {
        let rtf = #"{\rtf1\ansi - item\par   ```\par outside \\*}"#
        let result = try await PicoDocsEngine.convert(data: Data(rtf.utf8), filename: "fence.rtf")
        let html = try SwiftSoup.parse(DocumentRenderer.render(result, to: .html))
        #expect(try html.getElementsByTag("code").first()?.text() == #"outside \*"#)
        #expect(try DocumentRenderer.render(result, to: .plaintext).contains(#"outside \*"#))
    }

    @Test func literalListContentFencesKeepBackslashesAndDefinitions() async throws {
        for marker in ["-", "1.", "12."] {
            let indent = String(repeating: " ", count: marker.count + 1)
            let source = marker + " ```\n" + indent + #"\*Z"# + "\n" + indent + "[^n]: literal\n" + indent + "```"
            let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "list-code.txt")
            let html = try SwiftSoup.parse(DocumentRenderer.render(result, to: .html))
            let code = try #require(html.getElementsByTag("code").first())
            #expect(try code.text().contains(#"\*Z"#)); #expect(try code.text().contains("[^n]: literal"))
            for format in [ExportFileType.plaintext, .csv] {
                let rendered = try DocumentRenderer.render(result, to: format)
                #expect(rendered.contains(#"\*Z"#)); #expect(!rendered.contains(#"\\\*Z"#))
                #expect(rendered.contains("[^n]: literal"))
            }
        }
    }

    @Test func inlineCodeDelimitersRecognizeTheirUnicodeScalars() async throws {
        for mark in ["\u{0301}", "\u{FE0F}"] {
            let content = mark + "x"
            let inputs = [("code.md", "`" + content + "`"), ("code.html", "<code>" + content + "</code>")]
            for (filename, source) in inputs {
                let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: filename)
                #expect(try DocumentRenderer.render(result, to: .plaintext) == content)
                #expect(try DocumentRenderer.render(result, to: .csv).contains(content))
                let html = try SwiftSoup.parse(DocumentRenderer.render(result, to: .html))
                #expect(try html.getElementsByTag("code").first()?.text() == content)
            }
        }
    }


    @Test func extractedListFootnotesKeepInlineBoundaries() async throws {
        for marker in ["-", "1."] {
            let indent = marker == "-" ? "  " : "   "
            let source = marker + " `open\n" + indent + "[^x]: note\n  close \\* `end\n" + (marker == "-" ? "- next" : "2. next")
            let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "literal.txt")
            let plain = try DocumentRenderer.render(result, to: .plaintext)
            #expect(plain.contains(#"close \* `end"#))
            #expect(!plain.contains(#"\\\*"#))
            let html = try SwiftSoup.parse(DocumentRenderer.render(result, to: .html))
            #expect(try html.getElementsByTag("code").isEmpty())
            #expect(try html.getElementsByTag(marker == "-" ? "ul" : "ol").count == 1)
            #expect(try html.getElementsByTag("li").count == 2)
        }
    }

    @Test func literalRestartMarkerSurvivesSourceConverters() async throws {
        let marker = MarkdownLiteral.listRestartBoundary
        for source in [marker, "before\n" + marker + "\nafter", "  " + marker + "  "] {
            let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "literal.txt")
            #expect(try DocumentRenderer.render(result, to: .plaintext).contains(marker))
            #expect(try DocumentRenderer.render(result, to: .csv).contains(marker))
            let html = try SwiftSoup.parse(DocumentRenderer.render(result, to: .html))
            #expect(try html.text().contains(marker))
        }
        let rtf = "{\\rtf1\\ansi \\b <\\b0 !-- PicoDocs:list-restart -->}"
        let inputs = [("literal.rtf", Data(rtf.utf8)), ("literal.pages", PagesConverterTests.makePagesFile(paragraphs: [marker]))]
        for (filename, data) in inputs {
            let result = try await PicoDocsEngine.convert(data: data, filename: filename)
            #expect(try DocumentRenderer.render(result, to: .plaintext).contains(marker))
        }
        let fenced = "```\n" + marker + "\n```"
        #expect(MarkdownLiteral.escapeBackslashes(fenced) == fenced)
    }

    @Test func restartMarkerEscapesRetainSectionAndRunOffsets() throws {
        let marker = MarkdownLiteral.listRestartBoundary
        let source = "😀\n  " + marker + "\n\\*"
        let projection = MarkdownLiteral.escapeProjection(source, boundaries: [5, 6])
        #expect(projection.before == [5])
        let sections: [DocumentSection] = [.init(markdown: "intro"), .init(markdown: source)]
        let escaped = MarkdownLiteral.escapeSectionBackslashes(sections)
        #expect(escaped[0].markdown == "intro")
        #expect(escaped[1].markdown == MarkdownLiteral.escapeBackslashes(source))
        let plain = try DocumentRenderer.render(ConverterResult(sections: escaped), to: .plaintext)
        #expect(plain.contains(marker)); #expect(plain.contains(#"\*"#))
    }


    @Test func nativePunctuationEscapesOperateOnUnicodeScalars() async throws {
        for mark in ["\u{0301}", "\u{FE0F}"] {
            let source = "*" + mark + "x*" + mark
            let html = try await PicoDocsEngine.convert(data: Data("<p>\(source)</p>".utf8), filename: "literal.html")
            let document = "<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body><w:p><w:r><w:t>\(source)</w:t></w:r></w:p></w:body></w:document>"
            let word = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([("word/document.xml", Array(document.utf8))]), filename: "literal.docx")
            let pages = try await PicoDocsEngine.convert(data: PagesConverterTests.makeListPagesFile(text: "\u{FFFC}", style: .bullet, restarts: [], tableCell: source), filename: "literal.pages")
            for result in [html, word, pages] {
                #expect(try DocumentRenderer.render(result, to: .plaintext).contains(source))
                let rendered = try DocumentRenderer.render(result, to: .html)
                #expect(rendered.contains(source)); #expect(!rendered.contains("<em>"))
            }
        }
    }

    @Test func nativeRestartsAfterTablesRemainDistinctEvenWithSequentialNumbers() async throws {
        for ordered in [true, false] {
            for restart in [true, false] {
                let data = PagesConverterTests.makeListPagesFile(text: "a\nb \u{FFFC}\nc", style: ordered ? .ordered : .bullet,
                    restarts: [(0, 1), (2, 0), (6, restart ? (ordered ? 3 : 1) : 0)], tableCell: "X")
                let result = try await PicoDocsEngine.convert(data: data, filename: "restart.pages")
                #expect(result.markdown().contains(MarkdownLiteral.listRestartBoundary) == restart)
                let html = try SwiftSoup.parse(DocumentRenderer.render(result, to: .html))
                let lists = try html.getElementsByTag(ordered ? "ol" : "ul")
                #expect(lists.count == (restart ? 2 : 1))
                if restart { #expect(lists.last()?.children().count == 1) }
                else { #expect(lists.first()?.children().count == 3) }
                for format in [ExportFileType.html, .plaintext, .csv] {
                    #expect(!(try DocumentRenderer.render(result, to: format)).contains("PicoDocs:list-restart"))
                }
            }
        }
    }

    @Test func PagesListLiteralFootnotesFindTheirUnescapedCloser() async throws {
        for source in [#"[^a\]b]: note"#, #"[^a\\\]b]: note"#] {
            let data = PagesConverterTests.makeListPagesFile(text: "item\u{2028}" + source, style: .bullet, restarts: [])
            let result = try await PicoDocsEngine.convert(data: data, filename: "literal.pages")
            #expect(try DocumentRenderer.render(result, to: .plaintext).contains(source))
            let html = try DocumentRenderer.render(result, to: .html)
            #expect(html.contains(source)); #expect(!html.contains("class=\"footnotes\""))
        }
    }


    @Test func blankLinesEndListScopedFencesAtTheContentColumn() async throws {
        let source = "1. x\n   ```\n\n  a\\*b"
        let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "fence.txt")
        for format in [ExportFileType.html, .plaintext, .csv] {
            let rendered = try DocumentRenderer.render(result, to: format)
            #expect(rendered.contains(#"a\*b"#))
            #expect(!rendered.contains(#"a\\\*b"#))
        }
    }

    @Test func leadingListIndentationIsPreservedBeforeBlockParsing() async throws {
        let source = "  - item\n  ```\noutside \\*"
        let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "indented.txt")
        for format in [ExportFileType.html, .plaintext, .csv] {
            let rendered = try DocumentRenderer.render(result, to: format)
            #expect(rendered.contains(#"outside \*"#))
            #expect(!rendered.contains(#"outside \\\*"#))
        }
        let html = try SwiftSoup.parse(DocumentRenderer.render(result, to: .html))
        let code = try #require(html.getElementsByTag("pre").first())
        #expect(code.parent()?.tagName() != "li")
    }

    @Test func blankSeparatedNestedTablesResumeTheSameList() throws {
        for source in ["1. a\n2. b\n\n   | X |\n   | --- |\n\n3. c", "- a\n- b\n\n  | X |\n  | --- |\n\n- c"] {
            let result = ConverterResult(sections: [.init(markdown: source)])
            let html = try SwiftSoup.parse(DocumentRenderer.render(result, to: .html))
            let lists = try html.getElementsByTag(source.hasPrefix("1") ? "ol" : "ul")
            #expect(lists.count == 1)
            let list = try #require(lists.first())
            #expect(list.children().count == 3)
            #expect(try list.children().get(1).getElementsByTag("table").count == 1)
            #expect(try list.children().get(2).text() == "c")
        }
    }

    @Test func outerFootnotesSurviveUnclosedListFences() throws {
        for source in ["- x\n  ```\noutside[^n]\n[^n]: note", "1. x\n   ```\n\n  outside[^n]\n[^n]: note"] {
            let result = ConverterResult(sections: [.init(markdown: source)])
            let plain = try DocumentRenderer.render(result, to: .plaintext)
            #expect(plain.contains("outside[1]")); #expect(plain.contains("[1] note"))
            #expect(!plain.contains("[^n]"))
            let html = try SwiftSoup.parse(DocumentRenderer.render(result, to: .html))
            #expect(try html.getElementsByClass("footnote-ref").count == 1)
        }
        let inside = ConverterResult(sections: [.init(markdown: "- x\n  ```\n  [^n]: literal")])
        #expect(try DocumentRenderer.render(inside, to: .plaintext).contains("[^n]: literal"))
    }


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
