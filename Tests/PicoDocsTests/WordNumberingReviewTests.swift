import Foundation
import Testing
import ZIPFoundation
import SwiftSoup
@testable import PicoDocs

struct WordNumberingReviewTests {
    @Test func quotedHTMLListsDoNotExposeGeneratedBoundaries() throws {
        let list = "<ul><li>a</li></ul>"
        for source in ["<blockquote><p>lead</p>" + list + "</blockquote>",
                       "<blockquote><blockquote><p>lead</p>" + list + list + "</blockquote></blockquote>",
                       "<ul><li>parent<blockquote><p>lead</p>" + list + "</blockquote></li></ul>"] {
            let converted = try HTMLToMarkdown.convert(html: source)
            let result = ConverterResult(sections: [.init(markdown: converted.markdown)])
            for format in [ExportFileType.html, .plaintext, .csv] {
                let output = try DocumentRenderer.render(result, to: format)
                #expect(!output.contains("PicoDocs:list-restart"))
                #expect(output.contains("lead")); #expect(output.contains("a"))
            }
        }
    }

    @Test func flattenedHTMLKeepsLiteralBoundaryTextInCode() throws {
        let literal = "&lt;!-- PicoDocs:list-restart --&gt;"
        for source in ["<blockquote><p>" + literal + "</p></blockquote>",
                       "<blockquote><pre>" + literal + "</pre></blockquote>",
                       "<blockquote><blockquote><pre>" + literal + "</pre></blockquote></blockquote>",
                       "<table><tr><td><code>" + literal + "</code></td></tr></table>"] {
            let converted = try HTMLToMarkdown.convert(html: source)
            let result = ConverterResult(sections: [.init(markdown: converted.markdown)])
            for format in [ExportFileType.html, .plaintext, .csv] {
                #expect(try DocumentRenderer.render(result, to: format).contains("PicoDocs:list-restart"))
            }
        }
    }

    @Test func adjacentHTMLListInstancesStaySeparate() throws {
        let list = "<ul><li>a</li></ul>"
        for source in [list + list, "<div>" + list + "</div><div>" + list + "</div>",
                       "<ul><li>parent" + list + list + "</li></ul>"] {
            let converted = try HTMLToMarkdown.convert(html: source)
            let result = ConverterResult(sections: [.init(markdown: converted.markdown)])
            let expected = source.contains("parent") ? 3 : 2
            #expect(try DocumentRenderer.render(result, to: .html).components(separatedBy: "<ul>").count - 1 == expected)
            #expect(!(try DocumentRenderer.render(result, to: .plaintext)).contains(MarkdownLiteral.listRestartBoundary))
        }
        let continued = try HTMLToMarkdown.convert(html: "<ul><li>a</li><li>b</li></ul>")
        #expect(try DocumentRenderer.render(ConverterResult(sections: [.init(markdown: continued.markdown)]), to: .html)
            .components(separatedBy: "<ul>").count - 1 == 1)
    }

    @Test func adjacentDOCXListInstancesStaySeparate() async throws {
        for format in ["bullet", "decimal"] {
            let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(format)\"/><w:suff w:val=\"space\"/></w:lvl></w:abstractNum>" +
                [1, 2].map { "<w:num w:numId=\"\($0)\"><w:abstractNumId w:val=\"1\"/></w:num>" }.joined() + "</w:numbering>"
            func paragraph(_ id: Int) -> String {
                "<w:p><w:pPr><w:numPr><w:numId w:val=\"\(id)\"/></w:numPr></w:pPr><w:r><w:t>Item</w:t></w:r></w:p>"
            }
            let equivalentID = paragraph(1).replacingOccurrences(of: "w:numId w:val=\"1\"", with: "w:numId w:val=\"+0001\"")
            let body = paragraph(1) + equivalentID + "<w:sdt><w:sdtContent>" + paragraph(2) + paragraph(2) + "</w:sdtContent></w:sdt>" + paragraph(1)
            let document = "<w:document \(ns)><w:body>\(body)</w:body></w:document>"
            for includeDefinitions in [true, false] {
                var entries = [(name: "word/document.xml", data: Array(document.utf8))]
                if includeDefinitions { entries.append(("word/numbering.xml", Array(numbering.utf8))) }
                let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip(entries), filename: "instances.docx")
                let tag = includeDefinitions && format == "decimal" ? "<ol" : "<ul"
                #expect(try DocumentRenderer.render(result, to: .html).components(separatedBy: tag).count - 1 == 3)
                for output in [ExportFileType.html, .plaintext, .csv] {
                    #expect(!(try DocumentRenderer.render(result, to: output)).contains(MarkdownLiteral.listRestartBoundary))
                }
            }
        }
    }

    @Test func LibreOfficeListAliasResumptionKeepsItsNativeBoundary() async throws {
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:suff w:val=\"space\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num><w:num w:numId=\"2\"><w:abstractNumId w:val=\"1\"/><w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"5\"/></w:lvlOverride></w:num></w:numbering>"
        let body = [1, 2, 2, 1, 1].map {
            "<w:p><w:pPr><w:numPr><w:numId w:val=\"\($0)\"/></w:numPr></w:pPr><w:r><w:t>Item</w:t></w:r></w:p>"
        }.joined()
        for libreOffice in [true, false] {
            var entries = [(name: "word/document.xml", data: Array("<w:document \(ns)><w:body>\(body)</w:body></w:document>".utf8)),
                           (name: "word/numbering.xml", data: Array(numbering.utf8))]
            if libreOffice { entries.append(("docProps/app.xml", Array("<Properties><Application>LibreOffice</Application></Properties>".utf8))) }
            let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip(entries), filename: "alias.docx")
            let expectedCount = libreOffice ? 2 : 3
            #expect(try DocumentRenderer.render(result, to: .html).components(separatedBy: "<ol").count - 1 == expectedCount)
            #expect(result.markdown().contains(libreOffice ? "7. Item" : "2. Item"))
        }
    }

    @Test func flattenedHTMLTableListsDoNotExposeBoundaryMetadata() throws {
        let source = "<table><tr><th>Values</th></tr><tr><td>lead<ul><li>a</li></ul><ul><li>b</li></ul></td></tr></table>"
        let converted = try HTMLToMarkdown.convert(html: source)
        let result = ConverterResult(sections: [.init(markdown: converted.markdown)])
        for format in [ExportFileType.html, .plaintext, .csv] {
            #expect(!(try DocumentRenderer.render(result, to: format)).contains(MarkdownLiteral.listRestartBoundary))
        }
        let literal = try HTMLToMarkdown.convert(html: "<table><tr><td>&lt;!-- PicoDocs:list-restart --&gt;</td></tr></table>")
        #expect(try DocumentRenderer.render(ConverterResult(sections: [.init(markdown: literal.markdown)]), to: .plaintext)
            .contains(MarkdownLiteral.listRestartBoundary))
    }


    @Test func orderedDelimiterChangesStartSeparateLists() throws {
        for separator in ["\n", "\n\n"] {
            let source = ConverterResult(sections: [.init(markdown: "1. A" + separator + "2) B")])
            let html = try DocumentRenderer.render(source, to: .html)
            #expect(html.components(separatedBy: "<ol").count - 1 == 2)
            #expect(html.contains("<ol start=\"2\">"))
            let nested = ConverterResult(sections: [.init(markdown: "1. A\n   2) Nested\n2. B")])
            #expect(try DocumentRenderer.render(nested, to: .html).components(separatedBy: "<ol").count - 1 == 2)
        }
    }

    @Test func missingNumberDefinitionsKeepStyleListMembership() async throws {
        let styles = "<w:styles \(ns)><w:style w:styleId=\"List\"><w:pPr><w:numPr><w:numId w:val=\"8\"/></w:numPr></w:pPr></w:style></w:styles>"
        let document = "<w:document \(ns)><w:body><w:p><w:pPr><w:pStyle w:val=\"List\"/></w:pPr><w:r><w:t>Styled</w:t></w:r></w:p></w:body></w:document>"
        for definitions in [false, true] {
            var parts = [(name: "word/document.xml", data: Array(document.utf8)), (name: "word/styles.xml", data: Array(styles.utf8))]
            if definitions { parts.append(("word/numbering.xml", Array("<w:numbering \(ns)/>".utf8))) }
            let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip(parts), filename: "fallback.docx")
            #expect(result.markdown() == "- Styled")
        }
    }

    @Test func noteListsUseIndependentStoryCounters() async throws {
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:suff w:val=\"space\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        func paragraph(_ text: String) -> String { "<w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>" + text + "</w:t></w:r></w:p>" }
        let document = "<w:document \(ns)><w:body>" + paragraph("Body") + "<w:p><w:r><w:footnoteReference w:id=\"1\"/><w:endnoteReference w:id=\"1\"/></w:r></w:p></w:body></w:document>"
        let notes = "<w:footnotes \(ns)><w:footnote w:id=\"1\">" + paragraph("First") + paragraph("Second") + "</w:footnote></w:footnotes>"
        let endnotes = notes.replacingOccurrences(of: "footnote", with: "endnote")
        let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8)), (name: "word/footnotes.xml", data: Array(notes.utf8)), (name: "word/endnotes.xml", data: Array(endnotes.utf8))]), filename: "notes.docx")
        #expect(result.markdown().contains("1. Body"))
        for kind in ["fn", "en"] { #expect(result.markdown().contains("[^" + kind + "1]: 1. First\n    \n    2. Second")) }
        let plain = try DocumentRenderer.render(result, to: .plaintext)
        #expect(plain.components(separatedBy: "1. First").count - 1 == 2)
        #expect(plain.components(separatedBy: "2. Second").count - 1 == 2)
    }

    @Test func spreadsheetLiteralMarkupSurvivesCSVRendering() async throws {
        for value in ["*value*", "[label](https://example.com)", "`code`", #"\*literal*"#] {
            let sheet = "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>" + value + "</t></is></c></row></sheetData></worksheet>"
            let result = try await PicoDocsEngine.convert(data: ConverterTests.xlsx(sheetXML: sheet), filename: "literal.xlsx")
            #expect(try DocumentRenderer.render(result, to: .csv).contains(value))
            #expect(try DocumentRenderer.render(result, to: .plaintext).contains(value))
        }
    }


    @Test func parenthesizedDecimalLabelsRemainOrdered() async throws {
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:lvlText w:val=\"%1)\"/><w:suff w:val=\"space\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        let doc = "<w:document \(ns)><w:body><w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>Item</w:t></w:r></w:p></w:body></w:document>"
        let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(doc.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8))]), filename: "ordered.docx")
        #expect(result.markdown() == "1) Item")
        #expect(try DocumentRenderer.render(result, to: .plaintext) == "1) Item")
        #expect(try DocumentRenderer.render(result, to: .html).contains("<ol>"))
        #expect(try !DocumentRenderer.render(result, to: .html).contains("<ul>"))
    }

    @Test func wordLiteralTicksAndMarkdownCodeKeepDistinctSemantics() throws {
        for marker in ["- second", "2. second", "2) second"] {
            let xml = "<w:p \(ns)><w:pPr><w:numPr><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>`first</w:t><w:br/><w:t>" + marker + "`</w:t></w:r></w:p>"
            let document = try SwiftSoup.parse(xml, "", SwiftSoup.Parser.xmlParser())
            let paragraph = try #require(document.getElementsByTag("w:p").first())
            let text = try #require(WordConverter.renderParagraph(paragraph, relationships: [:]))
            let result = ConverterResult(sections: [.init(markdown: text)])
            let html = try DocumentRenderer.render(result, to: .html)
            #expect(!html.contains("<code>"))
            let plain = try DocumentRenderer.render(result, to: .plaintext)
            #expect(plain.contains("`first")); #expect(plain.contains(marker + "`"))
            // Actual Markdown code still retains marker-like text as code.
            let code = ConverterResult(sections: [.init(markdown: "- `first " + marker + "`")])
            #expect(try DocumentRenderer.render(code, to: .html).contains("<code>first " + marker + "</code>"))
        }
    }

    @Test func HTMLTableCanonicalEscapesAreNotDoubled() async throws {
        for (source,expected) in [("*","*"),(#"\*"#,#"\*"#),(#"\|"#,#"\|"#),(#"<code>\\|</code>"#,#"\\|"#)] {
            let input = "<table><tr><th>Value</th></tr><tr><td>" + source + "</td></tr></table>"
            let result = try await PicoDocsEngine.convert(data:Data(input.utf8),filename:"cell.html")
            let html = try DocumentRenderer.render(result,to:.html)
            #expect(html.contains(expected))
            #expect(try DocumentRenderer.render(result,to:.csv) == "Value\n" + expected)
            if expected == "*" { #expect(!html.contains(#"\*"#)) }
        }
    }

    @Test func LibreOfficeAliasSurvivesMultipleReplacementParagraphs() throws {
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:suff w:val=\"space\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num><w:num w:numId=\"2\"><w:abstractNumId w:val=\"1\"/><w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"5\"/></w:lvlOverride></w:num></w:numbering>"
        for libreOffice in [true,false] {
            var entries = [(name:"word/numbering.xml",data:Array(numbering.utf8))]
            if libreOffice { entries.append(("docProps/app.xml",Array("<Properties><Application>LibreOffice</Application></Properties>".utf8))) }
            let resolver = WordListNumbering(archive:try #require(Archive(data:PagesConverterTests.makeZip(entries),accessMode:.read)))
            func prefix(_ id: Int) throws -> String? {
                let document = try SwiftSoup.parse("<w:numPr \(ns)><w:numId w:val=\"\(id)\"/></w:numPr>","",SwiftSoup.Parser.xmlParser())
                return resolver.prefix(numPr:try document.getElementsByTag("w:numPr").first(),style:nil)
            }
            #expect(try prefix(1) == "1. ")
            #expect(try prefix(2) == "5. ")
            #expect(try prefix(2) == "6. ")
            #expect(try prefix(1) == (libreOffice ? "7. " : "2. "))
        }
    }

    @Test func derivedHeadingStylesTakePrecedenceAndConsumeCounters() async throws {
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:suff w:val=\"space\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        let numPr = "<w:numPr><w:numId w:val=\"1\"/></w:numPr>"
        let styles = "<w:styles \(ns)><w:style w:styleId=\"Heading1\"><w:pPr>" + numPr + "</w:pPr></w:style><w:style w:styleId=\"Custom\"><w:basedOn w:val=\"Heading1\"/></w:style><w:style w:styleId=\"Outline\"><w:pPr><w:outlineLvl w:val=\"2\"/></w:pPr></w:style></w:styles>"
        let doc = "<w:document \(ns)><w:body><w:p><w:pPr><w:pStyle w:val=\"Custom\"/></w:pPr><w:r><w:t>Heading</w:t></w:r></w:p><w:p><w:pPr>" + numPr + "</w:pPr><w:r><w:t>Next</w:t></w:r></w:p><w:p><w:pPr><w:pStyle w:val=\"Outline\"/></w:pPr><w:r><w:t>Outline heading</w:t></w:r></w:p></w:body></w:document>"
        let result = try await PicoDocsEngine.convert(data:PagesConverterTests.makeZip([(name:"word/document.xml",data:Array(doc.utf8)),(name:"word/numbering.xml",data:Array(numbering.utf8)),(name:"word/styles.xml",data:Array(styles.utf8))]),filename:"derived.docx")
        #expect(result.markdown().contains("# Heading")); #expect(!result.markdown().contains("1. Heading"))
        #expect(result.markdown().contains("2. Next")); #expect(result.markdown().contains("### Outline heading"))
    }

    @Test func escapedWordLinkLabelsAndTablePipesStayLiteral() async throws {
        let type = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"
        let rels = "<Relationships><Relationship Id=\"link\" Type=\"\(type)\" Target=\"https://example.com\" TargetMode=\"External\"/></Relationships>"
        let doc = "<w:document \(ns) xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><w:body><w:p><w:hyperlink r:id=\"link\"><w:r><w:t>a\\]b</w:t></w:r></w:hyperlink></w:p></w:body></w:document>"
        let linked = try await PicoDocsEngine.convert(data:PagesConverterTests.makeZip([(name:"word/document.xml",data:Array(doc.utf8)),(name:"word/_rels/document.xml.rels",data:Array(rels.utf8))]),filename:"label.docx")
        #expect(try DocumentRenderer.render(linked,to:.plaintext) == #"a\]b"#)
        #expect(try DocumentRenderer.render(linked,to:.html).contains(#"href="https://example.com">a\]b</a>"#))
        for value in [#"\|"#, #"`\\|`"#] {
            let xml = "<w:document \(ns)><w:body><w:tbl><w:tr><w:tc><w:p><w:r><w:t>\(value)</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>"
            let result = try await PicoDocsEngine.convert(data:PagesConverterTests.makeZip([(name:"word/document.xml",data:Array(xml.utf8))]),filename:"pipe.docx")
            let expected = value
            let html = try DocumentRenderer.render(result,to:.html)
            #expect(html.components(separatedBy:"<th>").count - 1 == 1)
            #expect(html.contains(expected))
            #expect(try DocumentRenderer.render(result,to:.csv) == expected)
        }
    }

    @Test func inlineCodeCannotCrossRTFParagraphBoundaries() async throws {
        let result = try await PicoDocsEngine.convert(data:Data(#"{\rtf1\ansi `a\\*\par b`}"#.utf8),filename:"blocks.rtf")
        for format in [ExportFileType.html,.plaintext] {
            #expect(try DocumentRenderer.render(result,to:format).contains(#"`a\*"#))
        }
    }

    @Test func HTMLProseEscapesRemainLiteralAndCodeRemainsVerbatim() async throws {
        let source = #"<p>literal \* regex</p><p><b>\</b>\tail</p><pre>a\*b</pre><code>c\*d</code>"#
        let result = try await PicoDocsEngine.convert(data:Data(source.utf8),filename:"literal.html")
        for format in [ExportFileType.html,.plaintext] {
            let output = try DocumentRenderer.render(result,to:format)
            #expect(output.contains(#"literal \* regex"#)); #expect(output.contains(#"a\*b"#)); #expect(output.contains(#"c\*d"#))
        }
        #expect(try DocumentRenderer.render(result,to:.plaintext).contains(#"\\tail"#))
    }

    @Test func arbitraryOrderedRestartsKeepSeparateLists() throws {
        for source in ["5. A\n\n1. B", "5. A\n\n9. B"] {
            let result = ConverterResult(sections:[.init(markdown:source)])
            #expect(try DocumentRenderer.render(result,to:.html).components(separatedBy:"<ol").count - 1 == 2)
        }
    }

    @Test func nullLevelTextAndStyleAssociationsPreserveCounters() async throws {
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:lvlText w:null=\"1\"/></w:lvl><w:lvl w:ilvl=\"1\"><w:start w:val=\"1\"/><w:numFmt w:val=\"lowerLetter\"/><w:pStyle w:val=\"MyList\"/><w:lvlText w:val=\"%1.%2.\"/><w:suff w:val=\"space\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        let styles = "<w:styles \(ns)><w:style w:styleId=\"MyList\"><w:pPr><w:numPr><w:numId w:val=\"1\"/></w:numPr></w:pPr></w:style></w:styles>"
        let doc = "<w:document \(ns)><w:body><w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/><w:ilvl w:val=\"0\"/></w:numPr></w:pPr><w:r><w:t>Hidden marker</w:t></w:r></w:p><w:p><w:pPr><w:pStyle w:val=\"MyList\"/></w:pPr><w:r><w:t>Child</w:t></w:r></w:p></w:body></w:document>"
        let result = try await PicoDocsEngine.convert(data:PagesConverterTests.makeZip([(name:"word/document.xml",data:Array(doc.utf8)),(name:"word/numbering.xml",data:Array(numbering.utf8)),(name:"word/styles.xml",data:Array(styles.utf8))]),filename:"styles.docx")
        #expect(result.markdown().hasPrefix("Hidden marker"))
        #expect(result.markdown().contains("1.a. Child"))
    }

    @Test func deletedTableItemsDoNotAdvanceVisibleNumbering() async throws {
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:suff w:val=\"space\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        func item(_ text: String) -> String { "<w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>" }
        for wrapper in ["w:del","w:moveFrom"] {
            let doc = "<w:document \(ns)><w:body><w:tbl><w:tr><w:tc><\(wrapper)>" + item("Deleted") + "</\(wrapper)></w:tc></w:tr></w:tbl>" + item("Visible") + "</w:body></w:document>"
            let result = try await PicoDocsEngine.convert(data:PagesConverterTests.makeZip([(name:"word/document.xml",data:Array(doc.utf8)),(name:"word/numbering.xml",data:Array(numbering.utf8))]),filename:"deleted.docx")
            #expect(result.markdown().contains("1. Visible")); #expect(!result.markdown().contains("Deleted"))
        }
    }

    @Test func wordLiteralBackticksAndBackslashesSurviveAcrossRuns() async throws {
        for runs in [#"<w:r><w:t>`C:\tmp`</w:t></w:r>"#, #"<w:r><w:t>`C:</w:t></w:r><w:r><w:t>\tmp`</w:t></w:r>"#, #"<w:r><w:t>``C:</w:t></w:r><w:r><w:t>\tmp``</w:t></w:r>"#] {
            let document = "<w:document \(ns)><w:body><w:p>\(runs)</w:p></w:body></w:document>"
            let result = try await PicoDocsEngine.convert(data:PagesConverterTests.makeZip([(name:"word/document.xml",data:Array(document.utf8))]),filename:"code.docx")
            let source = runs.contains("``") ? #"``C:\tmp``"# : #"`C:\tmp`"#
            #expect(try DocumentRenderer.render(result,to:.plaintext) == source)
            let html = try DocumentRenderer.render(result,to:.html)
            #expect(html.contains(source)); #expect(!html.contains("<code>"))
        }
    }

    @Test func sourceEscapeSentinelsRemainLiteralInProseAndCode() throws {
        let token = "\u{E006}0\u{E007}"
        let note = ConverterResult(sections:[.init(markdown:"Body[^" + token + "]\n\n[^" + token + "]: Note")])
        #expect(try DocumentRenderer.render(note,to:.html).contains("footnote-ref"))
        #expect(try DocumentRenderer.render(note,to:.plaintext).contains("Body[1]"))
        let result = ConverterResult(sections:[.init(markdown:token + " \\* `" + token + "`")])
        #expect(try DocumentRenderer.render(result,to:.plaintext) == token + " * " + token)
        let html = try DocumentRenderer.render(result,to:.html)
        #expect(html.contains(token + " * <code>" + token + "</code>"))
    }

    @Test func fullWidthDecimalLabelsRemainVisible() async throws {
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"10\"/><w:numFmt w:val=\"decimalFullWidth\"/><w:lvlText w:val=\"%1.\"/><w:suff w:val=\"space\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        let document = "<w:document \(ns)><w:body><w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>Item</w:t></w:r></w:p></w:body></w:document>"
        let result = try await PicoDocsEngine.convert(data:PagesConverterTests.makeZip([(name:"word/document.xml",data:Array(document.utf8)),(name:"word/numbering.xml",data:Array(numbering.utf8))]),filename:"fullwidth.docx")
        #expect(result.markdown().contains("１０. Item"))
        for format in [ExportFileType.html,.plaintext] { #expect(try DocumentRenderer.render(result,to:format).contains("１０. Item")) }
    }

    @Test func RTFPairedEscapesAndStyleBoundariesStayLiteral() async throws {
        for literal in [#"\*literal\*"#, #"\`code\`"#, #"\\\*literal\\\*"#] {
            let rtf = #"{\rtf1\ansi "# + literal.replacingOccurrences(of:"\\",with:"\\\\") + "}"
            let result = try await PicoDocsEngine.convert(data:Data(rtf.utf8),filename:"paired.rtf")
            #expect(try DocumentRenderer.render(result,to:.plaintext) == literal)
            #expect(try DocumentRenderer.render(result,to:.html).contains(literal))
        }
        let rtf = #"{\rtf1\ansi \b bold\\\b0  plain}"#
        let result = try await PicoDocsEngine.convert(data:Data(rtf.utf8),filename:"styled.rtf")
        #expect(try DocumentRenderer.render(result,to:.html).contains(#"<strong>bold\</strong>"#))
    }

    @Test func RTFBackslashesSurviveProseAndCode() async throws {
        let paragraphs = [#"literal \* and \\server"#, #"`a\*b` and ``c\*d``"#, "```", #"e\*f"#, "```"]
        let rtf = #"{\rtf1\ansi "# + paragraphs.map { $0.replacingOccurrences(of:"\\",with:"\\\\") }.joined(separator:#"\par "#) + "}"
        let result = try await PicoDocsEngine.convert(data:Data(rtf.utf8),filename:"literal.rtf")
        for format in [ExportFileType.html,.plaintext] {
            let output = try DocumentRenderer.render(result,to:format)
            for text in [#"literal \* and \\server"#, #"a\*b"#, #"c\*d"#, #"e\*f"#] { #expect(output.contains(text)) }
            #expect(!output.contains(#"a\\*b"#)); #expect(!output.contains(#"e\\*f"#))
        }
    }

    @Test func omittedSuffixDefaultsToTabs() async throws {
        for format in ["bullet", "decimal"] {
            let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(format)\"/></w:lvl><w:lvl w:ilvl=\"1\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
            func paragraph(_ level: Int, _ text: String) -> String { "<w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/><w:ilvl w:val=\"\(level)\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>" }
            let document = "<w:document \(ns)><w:body>" + paragraph(0,"Parent") + paragraph(1,"Child") + "</w:body></w:document>"
            let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name:"word/document.xml",data:Array(document.utf8)),(name:"word/numbering.xml",data:Array(numbering.utf8))]), filename:"default-tab.docx")
            let prefix = format == "bullet" ? "-" : "1."
            #expect(result.markdown().contains(prefix + "\tParent\n\n    1.\tChild"))
            #expect(try DocumentRenderer.render(result, to: .plaintext).contains(prefix + "\tParent\n    1.\tChild"))
        }
    }

    @Test func emptyNumberedHeadingsStayInvisibleButConsumeCounters() async throws {
        for explicit in [false,true] {
            let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
            let numPr = "<w:numPr><w:numId w:val=\"1\"/></w:numPr>"
            let styles = "<w:styles \(ns)><w:style w:styleId=\"Heading1\"><w:pPr>\(numPr)</w:pPr></w:style></w:styles>"
            let document = "<w:document \(ns)><w:body><w:p><w:pPr><w:pStyle w:val=\"Heading1\"/>" + (explicit ? numPr : "") + "</w:pPr></w:p><w:p><w:pPr>" + numPr + "</w:pPr><w:r><w:t>Next</w:t></w:r></w:p></w:body></w:document>"
            let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name:"word/document.xml",data:Array(document.utf8)),(name:"word/numbering.xml",data:Array(numbering.utf8)),(name:"word/styles.xml",data:Array(styles.utf8))]), filename:"empty-heading.docx")
            #expect(result.markdown() == "2.\tNext")
        }
    }

    @Test func bulletWithoutSuffixKeepsItsVisibleGlyph() async throws {
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"•\"/><w:suff w:val=\"nothing\"/></w:lvl><w:lvl w:ilvl=\"1\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:suff w:val=\"space\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        func paragraph(_ level: Int, _ content: String) -> String { "<w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/><w:ilvl w:val=\"\(level)\"/></w:numPr></w:pPr><w:r>\(content)</w:r></w:p>" }
        let document = "<w:document \(ns)><w:body>" + paragraph(0,"<w:t>Parent</w:t><w:br/><w:t>Continued</w:t>") + paragraph(1,"<w:t>Child</w:t>") + "</w:body></w:document>"
        let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name: "word/document.xml",data: Array(document.utf8)),(name: "word/numbering.xml",data: Array(numbering.utf8))]), filename: "tabs.docx")
        #expect(result.markdown().contains("- •Parent  \n   Continued"))
        #expect(result.markdown().contains("\n  - Child"))
        #expect(try DocumentRenderer.render(result, to: .plaintext).hasPrefix("- •Parent"))
        #expect(try DocumentRenderer.render(result, to: .html).components(separatedBy: "<ul").count - 1 == 2)
    }

    @Test func bulletTabSuffixControlsNestingAndPlaintextPadding() async throws {
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:suff w:val=\"tab\"/></w:lvl><w:lvl w:ilvl=\"1\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:suff w:val=\"space\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        func paragraph(_ level: Int, _ content: String) -> String { "<w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/><w:ilvl w:val=\"\(level)\"/></w:numPr></w:pPr><w:r>\(content)</w:r></w:p>" }
        let document = "<w:document \(ns)><w:body>" + paragraph(0,"<w:t>Parent</w:t><w:br/><w:t>Continued</w:t>") + paragraph(1,"<w:t>Child</w:t>") + "</w:body></w:document>"
        let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name: "word/document.xml",data: Array(document.utf8)),(name: "word/numbering.xml",data: Array(numbering.utf8))]), filename: "tabs.docx")
        #expect(result.markdown().contains("-\tParent  \n    Continued"))
        #expect(result.markdown().contains("\n    - Child"))
        #expect(try DocumentRenderer.render(result, to: .plaintext).hasPrefix("-\tParent"))
        #expect(try DocumentRenderer.render(result, to: .html).components(separatedBy: "<ul").count - 1 == 2)
    }

    @Test func decimalTabSuffixControlsNestingAndPlaintextPadding() async throws {
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:suff w:val=\"tab\"/></w:lvl><w:lvl w:ilvl=\"1\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:suff w:val=\"space\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        func paragraph(_ level: Int, _ content: String) -> String { "<w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/><w:ilvl w:val=\"\(level)\"/></w:numPr></w:pPr><w:r>\(content)</w:r></w:p>" }
        let document = "<w:document \(ns)><w:body>" + paragraph(0,"<w:t>Parent</w:t><w:br/><w:t>Continued</w:t>") + paragraph(1,"<w:t>Child</w:t>") + "</w:body></w:document>"
        let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name: "word/document.xml",data: Array(document.utf8)),(name: "word/numbering.xml",data: Array(numbering.utf8))]), filename: "tabs.docx")
        #expect(result.markdown().contains("1.\tParent  \n    Continued"))
        #expect(result.markdown().contains("\n    1. Child"))
        #expect(try DocumentRenderer.render(result, to: .plaintext).hasPrefix("1.\tParent"))
        #expect(try DocumentRenderer.render(result, to: .html).components(separatedBy: "<ol").count - 1 == 2)
    }

    @Test func wrappedTextBoxesRemainInNumberingOrder() async throws {
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:suff w:val=\"space\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        func item(_ text: String) -> String { "<w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>" }
        let document = "<w:document \(ns)><w:body>" + item("Before") + "<w:customXml><w:ins><w:p><w:r><w:drawing><w:txbxContent>" + item("Box") + "</w:txbxContent></w:drawing></w:r></w:p></w:ins></w:customXml>" + item("After") + "</w:body></w:document>"
        let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name: "word/document.xml",data: Array(document.utf8)),(name: "word/numbering.xml",data: Array(numbering.utf8))]), filename: "wrapped.docx")
        for text in ["1. Before","2. Box","3. After"] { #expect(result.markdown().contains(text)) }
        #expect(result.markdown().components(separatedBy: "Box").count == 2)
    }

    @Test func linkedSectionRestartsDefaultZeroAndLongLabels() throws {
        let numbering = """
        <w:numbering \(ns) xmlns:w15="http://schemas.microsoft.com/office/word/2012/wordml">
        <w:abstractNum w:abstractNumId="1"><w:numStyleLink w:val="Linked"/></w:abstractNum>
        <w:abstractNum w:abstractNumId="2" w15:restartNumberingAfterBreak="1"><w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:suff w:val="space"/></w:lvl></w:abstractNum>
        <w:abstractNum w:abstractNumId="3" w15:restartNumberingAfterBreak="0"><w:numStyleLink w:val="Linked"/></w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="1"/></w:num>
        <w:num w:numId="2"><w:abstractNumId w:val="2"/></w:num>
        <w:num w:numId="3"><w:abstractNumId w:val="1"/><w:lvlOverride w:ilvl="0"><w:startOverride w:val="1000000000"/></w:lvlOverride></w:num>
        <w:num w:numId="4"><w:abstractNumId w:val="3"/></w:num>
        </w:numbering>
        """
        let styles = "<w:styles \(ns)><w:style w:styleId=\"Linked\"><w:pPr><w:numPr><w:numId w:val=\"2\"/></w:numPr></w:pPr></w:style></w:styles>"
        let archive = try #require(Archive(data: PagesConverterTests.makeZip([(name: "word/numbering.xml",data: Array(numbering.utf8)),(name: "word/styles.xml",data: Array(styles.utf8))]), accessMode: .read))
        let resolver = WordListNumbering(archive: archive)
        func prefix(_ id: Int) throws -> String? {
            let document = try SwiftSoup.parse("<w:numPr \(ns)><w:numId w:val=\"\(id)\"/></w:numPr>", "", SwiftSoup.Parser.xmlParser())
            return resolver.prefix(numPr: try document.getElementsByTag("w:numPr").first(), style: nil)
        }
        #expect(try prefix(1) == "0. "); #expect(try prefix(1) == "1. ")
        #expect(try prefix(4) == "0. ")
        resolver.sectionBreak()
        #expect(try prefix(1) == "0. "); #expect(try prefix(4) == "1. ")
        #expect(try prefix(3) == "- 1000000000. ")
        #expect(MarkdownList.isOrderedMarker("1000000000. Item") == nil)
    }

    @Test func inheritedNumberingUsesParagraphLanguageAndSuffixes() async throws {
        for (suffix, expected) in [("nothing", "un.Item"), ("space", "un. Item"), ("tab", "un.\tItem")] {
            let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"cardinalText\"/><w:lvlText w:val=\"%1.\"/><w:suff w:val=\"\(suffix)\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
            let styles = "<w:styles \(ns)><w:docDefaults><w:rPrDefault><w:rPr><w:lang w:val=\"en-US\"/></w:rPr></w:rPrDefault></w:docDefaults><w:style w:styleId=\"List\"><w:pPr><w:numPr><w:numId w:val=\"1\"/></w:numPr></w:pPr></w:style></w:styles>"
            let document = "<w:document \(ns)><w:body><w:p><w:pPr><w:pStyle w:val=\"List\"/><w:rPr><w:lang w:val=\"fr-FR\"/></w:rPr></w:pPr><w:r><w:t>Item</w:t></w:r></w:p></w:body></w:document>"
            let data = PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8)), (name: "word/styles.xml", data: Array(styles.utf8))])
            let result = try await PicoDocsEngine.convert(data: data, filename: "language.docx")
            #expect(result.markdown().contains(expected))
            #expect(try DocumentRenderer.render(result, to: .plaintext).contains(expected))
        }
    }

    @Test func decimalNoSuffixSurvivesOverrides() async throws {
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:suff w:val=\"space\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/><w:lvlOverride w:ilvl=\"0\"><w:lvl w:ilvl=\"0\"><w:suff w:val=\"nothing\"/></w:lvl></w:lvlOverride></w:num></w:numbering>"
        let document = "<w:document \(ns)><w:body><w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>Item</w:t></w:r></w:p></w:body></w:document>"
        let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8))]), filename: "suffix.docx")
        #expect(result.markdown() == "- 1.Item")
        for format in [ExportFileType.plaintext,.html] { #expect(try DocumentRenderer.render(result, to: format).contains("1.Item")) }
    }

    @Test func textBoxCountersFollowAnchorsAndSectionBreaks() async throws {
        let numbering = "<w:numbering \(ns) xmlns:w15=\"http://schemas.microsoft.com/office/word/2012/wordml\"><w:abstractNum w:abstractNumId=\"1\" w15:restartNumberingAfterBreak=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:suff w:val=\"space\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        func item(_ text: String) -> String { "<w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>" }
        for table in [false,true] {
            let anchor = "<w:p><w:r><w:drawing><w:txbxContent>" + item("Box") + "</w:txbxContent></w:drawing></w:r></w:p>"
            let block = table ? "<w:tbl><w:tr><w:tc>" + anchor + "</w:tc></w:tr></w:tbl>" : anchor
            let document = "<w:document \(ns)><w:body>" + item("Before") + block + item("After") + "<w:p><w:pPr><w:sectPr/></w:pPr></w:p>" + item("Reset") + "</w:body></w:document>"
            let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8))]), filename: "anchor.docx")
            for expected in ["1. Before", "2. Box", "3. After", "1. Reset"] { #expect(result.markdown().contains(expected)) }
            #expect(result.markdown().components(separatedBy: "Box").count == 2)
        }
    }

    @Test func literalLabelsLegalNumberingAndLocalizedText() async throws {
        func convert(format: String, label: String, start: Int = 1, language: String = "en-US", extra: String = "", override: String = "") async throws -> ConverterResult {
            let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"upperRoman\"/><w:suff w:val=\"space\"/></w:lvl><w:lvl w:ilvl=\"1\"><w:start w:val=\"\(start)\"/><w:numFmt w:val=\"\(format)\"/><w:lvlText w:val=\"\(label)\"/>\(extra)<w:suff w:val=\"space\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/>\(override)</w:num></w:numbering>"
            let document = "<w:document \(ns)><w:body><w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/><w:ilvl w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>Item</w:t></w:r></w:p></w:body></w:document>"
            let styles = "<w:styles \(ns)><w:docDefaults><w:rPrDefault><w:rPr><w:lang w:val=\"\(language)\"/></w:rPr></w:rPrDefault></w:docDefaults></w:styles>"
            return try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8)), (name: "word/styles.xml", data: Array(styles.utf8))]), filename: "labels.docx")
        }
        let literal = try await convert(format: "decimal", label: "`%2` _x_ *y* [z]")
        for format in [ExportFileType.html, .plaintext] { #expect(try DocumentRenderer.render(literal, to: format).contains("`1` _x_ *y* [z] Item")) }
        let legal = try await convert(format: "decimal", label: "%1.%2.", extra: "<w:isLgl/>")
        #expect(legal.markdown().contains("1.1. Item"))
        let disabled = try await convert(format: "decimal", label: "%1.%2.", extra: "<w:isLgl/>", override: #"<w:lvlOverride w:ilvl="1"><w:lvl w:ilvl="1"><w:isLgl w:val="0"/></w:lvl></w:lvlOverride>"#)
        #expect(disabled.markdown().contains("I.1. Item"))
        let enabled = try await convert(format: "decimal", label: "%1.%2.", override: #"<w:lvlOverride w:ilvl="1"><w:lvl w:ilvl="1"><w:isLgl/></w:lvl></w:lvlOverride>"#)
        #expect(enabled.markdown().contains("1.1. Item"))
        for (format, start, language, expected) in [("decimalEnclosedParen", 1, "en-US", "⑴"), ("decimalEnclosedParen", 20, "en-US", "⒇"), ("decimalEnclosedParen", 21, "en-US", "21"), ("cardinalText", 1, "en-US", "one"), ("ordinalText", 1, "en-US", "first"), ("ordinalText", 22, "en-GB", "twenty-second"), ("cardinalText", 2, "fr-FR", "deux"), ("ordinalText", 1, "fr-FR", "premier"), ("ordinalText", 5, "fr-FR", "cinquième"), ("ordinalText", 1, "de-DE", "erste"), ("ordinalText", 21, "de-DE", "einundzwanzigste"), ("hex", 10, "en-US", "A"), ("decimalEnclosedFullstop", 1, "en-US", "⒈"), ("decimalEnclosedFullstop", 20, "en-US", "⒛"), ("decimalEnclosedFullstop", 21, "en-US", "21"), ("ordinal", 1, "fr-FR", "1er"), ("ordinal", 1, "de-DE", "1."), ("ordinal", 22, "en-US", "22nd"), ("decimalEnclosedCircle", 1, "en-US", "①"), ("decimalEnclosedCircle", 10, "en-US", "⑩"), ("decimalEnclosedCircle", 20, "en-US", "⑳"), ("decimalEnclosedCircle", 21, "en-US", "21")] {
            let result = try await convert(format: format, label: "%2.", start: start, language: language)
            #expect(try DocumentRenderer.render(result, to: .plaintext).contains(expected + ". Item"), "\(format) \(language): \(result.markdown()) expected \(expected)")
        }
    }

    @Test func imageAltBackslashesAreLiteral() throws {
        let source = #"<w:drawing><wp:docPr descr="\* \` \["/><a:blip r:embed="image"/></w:drawing>"#
        let drawing = try #require(SwiftSoup.parse(source, "", SwiftSoup.Parser.xmlParser()).getElementsByTag("w:drawing").first())
        let markdown = WordConverter.imageMarkdown(in: drawing, relationships: ["image": "media/a.png"])
        let result = ConverterResult(sections: [.init(markdown: markdown)])
        for format in [ExportFileType.html, .plaintext] { #expect(try DocumentRenderer.render(result, to: format).contains(#"\* \` \["#)) }
    }

    @Test func discardedPrefixesDoNotBecomeVisibleParents() async throws {
        let levels = (0...2).map { "<w:lvl w:ilvl=\"\($0)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:suff w:val=\"space\"/></w:lvl>" }.joined()
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\">\(levels)</w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        func paragraph(_ text: String, level: Int, style: String = "") -> String {
            "<w:p><w:pPr>\(style)<w:numPr><w:numId w:val=\"1\"/><w:ilvl w:val=\"\(level)\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>"
        }
        for discarded in ["<w:tbl><w:tr><w:tc>" + paragraph("Table item", level: 1) + "</w:tc></w:tr></w:tbl>", paragraph("Heading", level: 1, style: "<w:pStyle w:val=\"Heading1\"/>")] {
            let document = "<w:document \(ns)><w:body>" + paragraph("Parent", level: 0) + discarded + paragraph("Child", level: 2) + paragraph("Next level one", level: 1) + "</w:body></w:document>"
            let data = PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8))])
            let result = try await PicoDocsEngine.convert(data: data, filename: "discarded.docx")
            #expect(result.markdown().contains("\n   1. Child"))
            #expect(!result.markdown().contains("\n      1. Child"))
            #expect(result.markdown().contains("2. Next level one"))
        }
    }

    @Test func ordinalLabelsAndOrphanLevelsRemainVisibleLists() async throws {
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"2\"><w:start w:val=\"1\"/><w:numFmt w:val=\"ordinal\"/><w:lvlText w:val=\"%3.\"/><w:suff w:val=\"space\"/></w:lvl><w:lvl w:ilvl=\"3\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:suff w:val=\"space\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        func paragraph(_ text: String, level: Int) -> String {
            "<w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/><w:ilvl w:val=\"\(level)\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>"
        }
        let body = (1...23).map { paragraph("Item \($0)", level: 2) }.joined() + paragraph("Child", level: 3)
        let document = "<w:document \(ns)><w:body>\(body)</w:body></w:document>"
        let data = PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "ordinal.docx")
        #expect(result.markdown().hasPrefix("- 1st. Item 1"))
        for label in ["2nd.", "3rd.", "4th.", "11th.", "12th.", "13th.", "21st.", "22nd.", "23rd."] { #expect(result.markdown().contains(label)) }
        #expect(!result.markdown().contains("    - "))
        #expect(result.markdown().contains("\n  1. Child"))
        for format in [ExportFileType.html, .plaintext] {
            let text = try DocumentRenderer.render(result, to: format)
            #expect(text.contains("1st. Item 1")); #expect(text.contains("23rd. Item 23"))
        }
    }

    @Test func sectionBreakClearsLibreOfficeAliasesAndKeepsDecimalZero() throws {
        let numbering = "<w:numbering \(ns) xmlns:w15=\"http://schemas.microsoft.com/office/word/2012/wordml\"><w:abstractNum w:abstractNumId=\"1\" w15:restartNumberingAfterBreak=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimalZero\"/><w:lvlText w:val=\"Section %1:\"/><w:suff w:val=\"space\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num><w:num w:numId=\"2\"><w:abstractNumId w:val=\"1\"/><w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"7\"/></w:lvlOverride></w:num></w:numbering>"
        let data = PagesConverterTests.makeZip([(name: "word/numbering.xml", data: Array(numbering.utf8)), (name: "docProps/app.xml", data: Array("<Properties><Application>LibreOffice</Application></Properties>".utf8))])
        let resolver = WordListNumbering(archive: try #require(Archive(data: data, accessMode: .read)))
        func prefix(_ id: Int) throws -> String? {
            let document = try SwiftSoup.parse("<w:numPr \(ns)><w:numId w:val=\"\(id)\"/></w:numPr>", "", SwiftSoup.Parser.xmlParser())
            return resolver.prefix(numPr: try document.getElementsByTag("w:numPr").first(), style: nil)
        }
        #expect(try prefix(1) == "- Section 01: ")
        resolver.sectionBreak()
        #expect(try prefix(2) == "- Section 07: ")
        #expect(try prefix(1) == "- Section 01: ")
        for value in 2...9 { #expect(try prefix(1) == "- Section 0\(value): ") }
        #expect(try prefix(1) == "- Section 10: ")
    }

    @Test func listChildrenRequireParentContentIndentation() throws {
        for source in ["- first\n - second", "10. first\n 11. second", "  - first\n- second"] {
            let result = ConverterResult(sections: [.init(markdown: source)])
            let html = try DocumentRenderer.render(result, to: .html)
            #expect(html.components(separatedBy: "<li").count - 1 == 2)
            #expect(html.components(separatedBy: source.contains("first") && source.contains("10.") ? "<ol" : "<ul").count - 1 == 1)
        }
        for source in ["- first\n  - child", "10. first\n    - child", "- first\n\t- child"] {
            let result = ConverterResult(sections: [.init(markdown: source)])
            let html = try DocumentRenderer.render(result, to: .html)
            #expect(html.components(separatedBy: "<ul").count - 1 == (source.hasPrefix("10.") ? 1 : 2))
            #expect(html.contains("child"))
        }
    }

    @Test func hiddenParentCountersAdvanceBeforeMarkerSuppression() async throws {
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"none\"/><w:suff w:val=\"space\"/></w:lvl><w:lvl w:ilvl=\"1\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:lvlText w:val=\"%1.%2.\"/><w:suff w:val=\"space\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        func paragraph(_ text: String, level: Int) -> String {
            "<w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/><w:ilvl w:val=\"\(level)\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>"
        }
        let document = "<w:document \(ns)><w:body>" + paragraph("Parent A", level: 0) + paragraph("Child A", level: 1) + paragraph("Parent B", level: 0) + paragraph("Child B", level: 1) + "</w:body></w:document>"
        let data = PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "hidden.docx")
        #expect(result.markdown().contains("1.1. Child A"))
        #expect(result.markdown().contains("2.1. Child B"))
        #expect(!result.markdown().contains("1. Parent A"))
        #expect(!result.markdown().contains("2. Parent B"))
    }

    @Test func tableEscapesAreCanonicalAndDecodedOnce() async throws {
        let csv = try await PicoDocsEngine.convert(data: Data("value\n\\* regex".utf8), filename: "literal.csv")
        let document = #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:tbl><w:tr><w:tc><w:p><w:r><w:t>\* regex</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>"#
        let word = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8))]), filename: "literal.docx")
        #expect(word.markdown().contains(#"\\* regex"#))
        #expect(!word.markdown().contains(#"\\\\* regex"#))
        for result in [csv, word] {
            for format in [ExportFileType.html, .plaintext, .csv] {
                #expect(try DocumentRenderer.render(result, to: format).contains(#"\* regex"#))
            }
        }
    }

    @Test func sectionRestartsLabelsAndDocumentDefaults() async throws {
        let numbering = """
        <w:numbering \(ns) xmlns:w15="http://schemas.microsoft.com/office/word/2012/wordml">
        <w:abstractNum w:abstractNumId="1" w15:restartNumberingAfterBreak="1">
        <w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="Article %1:"/><w:suff w:val="space"/></w:lvl>
        <w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1.%2."/><w:suff w:val="space"/></w:lvl>
        </w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="1"/></w:num>
        </w:numbering>
        """
        let styles = "<w:styles \(ns)><w:docDefaults><w:pPrDefault><w:pPr><w:numPr><w:numId w:val=\"1\"/><w:ilvl w:val=\"0\"/></w:numPr></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type=\"paragraph\" w:styleId=\"Named\"><w:pPr/></w:style></w:styles>"
        func paragraph(_ text: String, properties: String = "") -> String { "<w:p><w:pPr><w:pStyle w:val=\"Named\"/>\(properties)</w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>" }
        let document = "<w:document \(ns)><w:body>" + paragraph("First") + paragraph("Child", properties: "<w:numPr><w:ilvl w:val=\"1\"/></w:numPr>") + paragraph("Second", properties: "<w:sectPr/>") + paragraph("Restarted") + "</w:body></w:document>"
        let data = PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8)), (name: "word/styles.xml", data: Array(styles.utf8))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "sections.docx")
        #expect(result.markdown().contains("Article 1: First"))
        #expect(result.markdown().contains("1.1. Child"))
        #expect(result.markdown().contains("Article 2: Second"))
        #expect(result.markdown().contains("Article 1: Restarted"))
    }

    @Test func literalContinuationAndNestedReadingOrder() throws {
        let xml = try SwiftSoup.parse("<w:p><w:pPr><w:numPr/></w:pPr><w:r><w:t>First</w:t><w:br/><w:t>- literal</w:t><w:br/><w:t>2. literal number</w:t></w:r></w:p>", "", SwiftSoup.Parser.xmlParser())
        let paragraph = try #require(xml.getElementsByTag("w:p").first())
        let markdown = try #require(WordConverter.renderParagraph(paragraph, relationships: [:]))
        let result = ConverterResult(sections: [.init(markdown: markdown)])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.components(separatedBy: "<li>").count == 2)
        #expect(html.contains("- literal"))
        #expect(!html.contains("\\-"))
        let nested = ConverterResult(sections: [.init(markdown: "1. parent[^p]\n   - child[^c]\n   after child[^a]\n2. next\n\n[^p]: Parent\n[^c]: Child\n[^a]: After")])
        let plain = try DocumentRenderer.render(nested, to: .plaintext)
        #expect(plain.contains("1. parent[1]\n   - child[2]\n   after child[3]\n2. next"))
        let nestedHTML = try DocumentRenderer.render(nested, to: .html)
        let childEnd = try #require(nestedHTML.range(of: "</ul>"))
        let after = try #require(nestedHTML.range(of: "after child"))
        #expect(childEnd.upperBound < after.lowerBound)
    }

    @Test func sourceBackslashesSurviveListRendering() throws {
        let xml = try SwiftSoup.parse(#"<w:p><w:pPr><w:numPr/></w:pPr><w:r><w:t>First</w:t><w:br/><w:t>\- literal</w:t><w:br/><w:t>C:\folder\file</w:t></w:r></w:p>"#, "", SwiftSoup.Parser.xmlParser())
        let paragraph = try #require(xml.getElementsByTag("w:p").first())
        let markdown = try #require(WordConverter.renderParagraph(paragraph, relationships: [:]))
        let result = ConverterResult(sections: [.init(markdown: markdown)])
        for format in [ExportFileType.html, .plaintext, .csv] {
            let rendered = try DocumentRenderer.render(result, to: format)
            #expect(rendered.contains(#"\- literal"#))
            #expect(rendered.contains(#"C:\folder\file"#))
        }
    }

    private let ns = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""

    @Test func concreteCountersOverridesDefaultsAndRestarts() throws {
        let levels = """
        <w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:suff w:val="space"/></w:lvl>
        <w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlRestart w:val="0"/><w:suff w:val="space"/></w:lvl>
        <w:lvl w:ilvl="2"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlRestart w:val="1"/><w:suff w:val="space"/></w:lvl>
        """
        let numbering = """
        <w:numbering \(ns)><w:abstractNum w:abstractNumId="1">\(levels)</w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="1"/></w:num>
        <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
        <w:num w:numId="3"><w:abstractNumId w:val="1"/><w:lvlOverride w:ilvl="1"><w:startOverride w:val="5"/></w:lvlOverride></w:num>
        <w:num w:numId="4"><w:abstractNumId w:val="1"/><w:lvlOverride w:ilvl="0"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/><w:suff w:val="space"/></w:lvl></w:lvlOverride></w:num>
        <w:num w:numId="5"><w:abstractNumId w:val="1"/><w:lvlOverride w:ilvl="0"><w:lvl w:ilvl="0"><w:start w:val="7"/></w:lvl></w:lvlOverride></w:num>
        </w:numbering>
        """
        let styles = "<w:styles \(ns)><w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:pPr><w:numPr><w:numId w:val=\"2\"/></w:numPr></w:pPr></w:style></w:styles>"
        let data = PagesConverterTests.makeZip([
            (name: "word/numbering.xml", data: Array(numbering.utf8)),
            (name: "word/styles.xml", data: Array(styles.utf8))
        ])
        let resolver = WordListNumbering(archive: try #require(Archive(data: data, accessMode: .read)))
        func prefix(_ id: Int, _ level: Int = 0) throws -> String? {
            let xml = try SwiftSoup.parse("<w:numPr \(ns)><w:numId w:val=\"\(id)\"/><w:ilvl w:val=\"\(level)\"/></w:numPr>", "", SwiftSoup.Parser.xmlParser())
            return resolver.prefix(numPr: try xml.getElementsByTag("w:numPr").first(), style: nil)
        }
        #expect(try prefix(1) == "1. ")
        #expect(try prefix(2) == "1. ")
        #expect(resolver.prefix(numPr: nil, style: nil) == "2. ")
        #expect(try prefix(3) == "1. ")
        #expect(try prefix(3, 1) == "   5. ")
        #expect(try prefix(4) == "- ")
        #expect(try prefix(5) == "7. ")
        #expect(try prefix(1, 1) == "   1. ")
        #expect(try prefix(1, 2) == "      1. ")
        #expect(try prefix(1, 1) == "   2. ")
        #expect(try prefix(1, 2) == "      2. ")
        #expect(try prefix(1) == "2. ")
        #expect(try prefix(1, 1) == "   3. ")
        #expect(try prefix(1, 2) == "      1. ")
    }

    @Test func emptyItemsAndHeadingsConsumeNumbers() async throws {
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:suff w:val=\"space\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        func paragraph(_ text: String, style: String = "") -> String {
            "<w:p><w:pPr>\(style)<w:numPr><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>"
        }
        let document = "<w:document \(ns)><w:body>" + paragraph("a") + paragraph("") + paragraph("c") + paragraph("heading", style: "<w:pStyle w:val=\"Heading1\"/>") + paragraph("e") + "</w:body></w:document>"
        let file = PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8))])
        let result = try await PicoDocsEngine.convert(data: file, filename: "list.docx")
        #expect(result.markdown().contains("3. c"))
        #expect(result.markdown().contains("5. e"))
    }

    @Test func followupNumberingRegressions() async throws {
        let numbering = """
        <w:numbering \(ns)>
        <w:abstractNum w:abstractNumId="1"><w:numStyleLink w:val="NumberingStyle"/></w:abstractNum>
        <w:abstractNum w:abstractNumId="2"><w:lvl w:ilvl="-1"><w:start w:val="1"/><w:lvlRestart w:val="1"/></w:lvl><w:lvl w:ilvl="0"><w:start w:val="5"/><w:numFmt w:val="decimal"/><w:suff w:val="space"/></w:lvl></w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="1"/></w:num>
        <w:num w:numId="2"><w:abstractNumId w:val="2"/></w:num>
        </w:numbering>
        """
        let styles = "<w:styles \(ns)><w:style w:type=\"numbering\" w:styleId=\"NumberingStyle\"><w:pPr><w:numPr><w:numId w:val=\"2\"/></w:numPr></w:pPr></w:style></w:styles>"
        func item(_ text: String) -> String {
            "<w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>"
        }
        let body = item("Before") + "<w:tbl><w:tr><w:tc>" + item("Inside") + "</w:tc></w:tr></w:tbl>" + item("After")
        let document = "<w:document \(ns)><w:body>\(body)</w:body></w:document>"
        let data = PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8)), (name: "word/styles.xml", data: Array(styles.utf8))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "linked.docx")
        #expect(result.markdown().contains("5. Before"))
        #expect(result.markdown().contains("7. After"))
        for markdown in ["\t- item", "999999999999999999999999999999. item"] {
            let content = ConverterResult(sections: [DocumentSection(markdown: markdown)])
            #expect(try DocumentRenderer.render(content, to: .html).contains("item"))
            #expect(try DocumentRenderer.render(content, to: .plaintext).contains("item"))
        }
    }

    @Test func linkedOverridesAliasesAndRelocatedParts() throws {
        let numbering = """
        <w:numbering \(ns)>
        <w:abstractNum w:abstractNumId="001"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:suff w:val="space"/></w:lvl><w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlRestart w:val="0"/><w:suff w:val="space"/></w:lvl></w:abstractNum>
        <w:abstractNum w:abstractNumId="2"><w:numStyleLink w:val="Linked"/></w:abstractNum>
        <w:abstractNum w:abstractNumId="3"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:suff w:val="space"/></w:lvl></w:abstractNum>
        <w:num w:numId="001"><w:abstractNumId w:val="1"/></w:num>
        <w:num w:numId="2"><w:abstractNumId w:val="1"/><w:lvlOverride w:ilvl="0"><w:startOverride w:val="1"/></w:lvlOverride></w:num>
        <w:num w:numId="3"><w:abstractNumId w:val="2"/><w:lvlOverride w:ilvl="0"><w:lvl w:ilvl="0"><w:lvlRestart w:val="0"/></w:lvl></w:lvlOverride></w:num>
        <w:num w:numId="4"><w:abstractNumId w:val="3"/></w:num>
        </w:numbering>
        """
        let styles = "<w:styles \(ns)><w:style w:styleId=\"Linked\"><w:pPr><w:numPr><w:numId w:val=\"004\"/></w:numPr></w:pPr></w:style></w:styles>"
        let relationships = #"<Relationships><Relationship Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="lists/n.xml"/><Relationship Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="lists/s.xml"/></Relationships>"#
        let data = PagesConverterTests.makeZip([(name: "word/lists/n.xml", data: Array(numbering.utf8)), (name: "word/lists/s.xml", data: Array(styles.utf8)), (name: "word/_rels/document.xml.rels", data: Array(relationships.utf8)), (name: "docProps/app.xml", data: Array("<Properties><Application>LibreOffice</Application></Properties>".utf8))])
        let resolver = WordListNumbering(archive: try #require(Archive(data: data, accessMode: .read)))
        func prefix(_ id: String, _ level: Int = 0) throws -> String? {
            let doc = try SwiftSoup.parse("<w:numPr \(ns)><w:numId w:val=\"\(id)\"/><w:ilvl w:val=\"\(level)\"/></w:numPr>", "", SwiftSoup.Parser.xmlParser())
            return resolver.prefix(numPr: try doc.getElementsByTag("w:numPr").first(), style: nil)
        }
        #expect(try prefix("00") == nil)
        #expect(try prefix("+01") == "1. ")
        #expect(try prefix("1", 1) == "   1. ")
        #expect(try prefix("02") == "1. ")
        #expect(try prefix("1") == "2. ")
        #expect(try prefix("1", 1) == "   2. ")
        #expect(try prefix("3") == "- ")
    }

    @Test func looseNestedListsRenderWithSourceNumbers() throws {
        let result = ConverterResult(sections: [DocumentSection(markdown: "5. First\n\n   1. Child\n\n   2. Child two\n\n6. Second")])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("<ol start=\"5\">"))
        #expect(html.components(separatedBy: "<ol").count == 3)
        #expect(html.contains("Child two</li>\n</ol></li>"))
        let plain = try DocumentRenderer.render(result, to: .plaintext)
        #expect(plain == "5. First\n   1. Child\n   2. Child two\n6. Second")
    }
}
