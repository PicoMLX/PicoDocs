import Foundation
import Testing
import ZIPFoundation
import SwiftSoup
#if canImport(AppKit)
import AppKit
#endif
@testable import PicoDocs

struct ExporterFollowupTests {
    @Test func importedImagesKeepPackageIdentity() async throws {
        let namespaces = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main""#
        let document = "<w:document \(namespaces)><w:body><w:p>" + ["a","b"].map { "<w:r><w:drawing><a:blip r:embed=\"\($0)\"/></w:drawing></w:r>" }.joined() + "</w:p></w:body></w:document>"
        let rels = #"<Relationships><Relationship Id="a" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/charts/logo.png"/><Relationship Id="b" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/headers/logo.png"/></Relationships>"#
        let data = PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/_rels/document.xml.rels", data: Array(rels.utf8)), (name: "word/media/charts/logo.png", data: [1]), (name: "word/media/headers/logo.png", data: [2])])
        let result = try await PicoDocsEngine.convert(data: data, filename: "images.docx")
        #expect(result.markdown().contains("word/media/charts/logo.png")); #expect(result.markdown().contains("word/media/headers/logo.png"))
        let output = try PicoDocsEngine.write(result, to: .docx)
        #expect(try xml(output, "word/document.xml").components(separatedBy: "<w:drawing>").count - 1 == 2)
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("base64,AQ==")); #expect(html.contains("base64,Ag=="))
    }

    @Test func tableBlockStylesAndContentControlsRemainStructural() async throws {
        let ns = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main""#
        let cells = ["Heading1","Quote","PicoCodeBlock"].map { "<w:tc><w:p><w:pPr><w:pStyle w:val=\"\($0)\"/></w:pPr><w:r><w:t>Cell \($0)</w:t></w:r></w:p></w:tc>" }.joined()
        func item(_ text: String, level: Int) -> String { "<w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/><w:ilvl w:val=\"\(level)\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>" }
        let document = "<w:document \(ns)><w:body><w:tbl><w:tr>\(cells)</w:tr></w:tbl>" + item("Parent", level: 0) + "<w:sdt><w:sdtContent>" + item("Child", level: 1) + "</w:sdtContent></w:sdt>" + item("Next", level: 0) + "</w:body></w:document>"
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:numFmt w:val=\"decimal\"/></w:lvl><w:lvl w:ilvl=\"1\"><w:numFmt w:val=\"bullet\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8))]), filename: "structure.docx")
        #expect(result.markdown().contains("| Cell Heading1 | Cell Quote | Cell PicoCodeBlock |"))
        #expect(result.markdown().contains("1. Parent\n   - Child\n2. Next"))
        let output = try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml")
        #expect(output.contains(#"<w:ilvl w:val="1"/>"#)); #expect(!output.contains("# Cell")); #expect(!output.contains("&gt; Cell")); #expect(!output.contains("```"))
    }

    @Test func emptyListItemsRoundTrip() async throws {
        for source in ["-", "2.", "- first\n-\n- third"] {
            let result = try await PicoDocsEngine.convert(data: PicoDocsEngine.write(markdown: source, to: .docx), filename: "empty-item.docx")
            let second = try PicoDocsEngine.write(result, to: .docx)
            let count = try xml(second, "word/document.xml").components(separatedBy: "<w:numPr>").count - 1
            #expect(count == (source.contains("first") ? 3 : 1))
        }
    }

    @Test func spreadsheetTokensAndLiteralCrossFormatCells() async throws {
        let literal = "*value* [label](url) _x000A_ _x005F_"
        let source = ConverterResult(sections: [.init(kind: .sheet, markdown: "", metadata: ["csv": literal])])
        let xlsx = try PicoDocsEngine.write(source, to: .xlsx)
        let worksheet = try xml(xlsx, "xl/worksheets/sheet1.xml")
        #expect(worksheet.contains("_x005F_x000A_ _x005F_x005F_"))
        let result = try await PicoDocsEngine.convert(data: xlsx, filename: "tokens.xlsx")
        #expect(result.sections.first?.metadata["csv"] == "\"" + literal + "\"")
        for (format,path,tag) in [(ExportableFileType.docx,"word/document.xml","w:t"),(.pptx,"ppt/slides/slide1.xml","a:t")] {
            let content = try xml(PicoDocsEngine.write(result, to: format), path)
            let parsed = try SwiftSoup.parse(content, "", SwiftSoup.Parser.xmlParser())
            let visible = try parsed.getElementsByTag(tag).array().map { $0.getChildNodes().compactMap { ($0 as? TextNode)?.getWholeText() }.joined() }.joined()
            #expect(visible.contains(literal)); #expect(!content.contains("hyperlink")); #expect(!content.contains("hlinkClick"))
        }
        #expect(SpreadsheetMLText.decode(SpreadsheetMLText.encode("_x000A_\u{1}😀")) == "_x000A_\u{1}😀")
    }

    @Test func codeTypefaceSoftBreaksAndHyperlinkTargets() throws {
        let code = try xml(PicoDocsEngine.write(markdown: "Use **[`code`](https://example.com)** here", to: .pptx), "ppt/slides/slide1.xml")
        #expect(code.contains(#"<a:rPr b="1"><a:latin typeface="Courier New"/><a:hlinkClick"#))
        for (format,path,tag) in [(ExportableFileType.docx,"word/document.xml","w:t"),(.pptx,"ppt/slides/slide1.xml","a:t")] {
            let content = try xml(PicoDocsEngine.write(markdown: "one \ntwo", to: format), path)
            let parsed = try SwiftSoup.parse(content, "", SwiftSoup.Parser.xmlParser())
            let visible = try parsed.getElementsByTag(tag).array().map { $0.getChildNodes().compactMap { ($0 as? TextNode)?.getWholeText() }.joined() }.joined()
            #expect(visible == "one two")
        }
        #if canImport(AppKit)
        let attributed = AttributedStringDocumentBuilder.attributedString(from: ConverterResult(sections: [.init(markdown: "one \ntwo")]))
        #expect(attributed.string.trimmingCharacters(in: .whitespacesAndNewlines) == "one two")
        #endif
        #expect(MarkdownInlineParser.parse("[^docs](https://example.com)") == [.link(label: [.text("^docs")], destination: "https://example.com")])
        for (raw,escaped) in [("100%","100%25"),("%ZZ","%25ZZ"),("a%20b","a%20b")] {
            for (format,path) in [(ExportableFileType.docx,"word/_rels/document.xml.rels"),(.pptx,"ppt/slides/_rels/slide1.xml.rels")] {
                let rels = try xml(PicoDocsEngine.write(markdown: "[^docs](https://example.test/" + raw + ")", to: format), path)
                #expect(rels.contains("https://example.test/" + escaped))
            }
        }
    }

    @Test func sparseSpreadsheetCoordinatesSurviveOfficeRoundTrip() async throws {
        let base = try PicoDocsEngine.write(markdown: "| A | B | C |\n| --- | --- |", to: .xlsx)
        let archive = try #require(Archive(data: base, accessMode: .read))
        let worksheet = #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>First</t></is></c><c r="C1" t="inlineStr"><is><t>Third</t></is></c></row><row r="3"><c r="B3" t="inlineStr"><is><t>Middle</t></is></c></row></sheetData></worksheet>"#
        var entries: [(name: String, data: [UInt8])] = []
        for entry in archive {
            var bytes = Data(); _ = try archive.extract(entry) { bytes.append($0) }
            entries.append((entry.path, entry.path == "xl/worksheets/sheet1.xml" ? Array(worksheet.utf8) : Array(bytes)))
        }
        let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip(entries), filename: "sparse.xlsx")
        #expect(result.sections.first?.metadata["csv"] == "\"First\",\"\",\"Third\"\n\"\",\"\",\"\"\n\"\",\"Middle\",\"\"")
        let output = try xml(PicoDocsEngine.write(result, to: .xlsx), "xl/worksheets/sheet1.xml")
        #expect(output.contains(#"r="C1" t="inlineStr"><is><t xml:space="preserve">Third"#))
        #expect(output.contains(#"r="B3" t="inlineStr"><is><t xml:space="preserve">Middle"#))
    }

    @Test func inlineSentinelsAndOptionalLinkTitlesStayDistinct() throws {
        for source in ["\u{E020}0\u{E021} `code`", "\u{E010}0\u{E011} \\*"] {
            let expected = source.replacingOccurrences(of: "`code`", with: "code").replacingOccurrences(of: "\\*", with: "*")
            #expect(MarkdownInlineParser.parse(source).plainText == expected)
            let document = try SwiftSoup.parse(xml(PicoDocsEngine.write(markdown: source, to: .docx), "word/document.xml"), "", SwiftSoup.Parser.xmlParser())
            let visible = try document.getElementsByTag("w:t").array().map { $0.getChildNodes().compactMap { ($0 as? TextNode)?.getWholeText() }.joined() }.joined()
            #expect(visible == expected)
        }
        for source in [#"[Label](https://example.com "Home")"#, #"[Label](<https://example.com> "Home")"#, #"[Label](https://example.com 'Home')"#, #"[Label](https://example.com (Home))"#, #"[Label](https://example.com/a_(b) "Home (extra)")"#] {
            let nodes = MarkdownInlineParser.parse(source)
            let expected = source.contains("a_(b)") ? "https://example.com/a_(b)" : "https://example.com"
            #expect(nodes == [.link(label: [.text("Label")], destination: expected)])
            for (format, path) in [(ExportableFileType.docx, "word/_rels/document.xml.rels"), (.pptx, "ppt/slides/_rels/slide1.xml.rels")] {
                let rels = try xml(PicoDocsEngine.write(markdown: source, to: format), path)
                #expect(rels.contains(expected)); #expect(!rels.contains("Home"))
            }
        }
    }

    @Test func literalWordRunsSurviveOfficeTranscoding() async throws {
        let literals = [#"[label](https://example.com) *stars* `code` ![image](x) \*"#, "# Heading", "1. List", "- Bullet", "---"]
        let paragraphs = literals.map { "<w:p><w:r><w:t>" + $0 + "</w:t></w:r></w:p>" }.joined()
        let document = #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>"# + paragraphs + "</w:body></w:document>"
        let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8))]), filename: "literal.docx")
        let exported = try PicoDocsEngine.write(result, to: .docx)
        let output = try xml(exported, "word/document.xml")
        #expect(!output.contains("<w:hyperlink")); #expect(!output.contains("<w:numPr>")); #expect(!output.contains("<w:drawing>"))
        for literal in literals { #expect(output.contains(literal)) }
        let recovered = try await PicoDocsEngine.convert(data: exported, filename: "again.docx")
        let plain = try DocumentRenderer.render(recovered, to: .plaintext)
        for literal in literals { #expect(plain.contains(literal)) }
    }

    @Test func titleOnlySlidesAndPathQualifiedTitleImages() throws {
        let slide = ConverterResult(sections: [.init(title: "Agenda", kind: .slide, markdown: "", slideNumber: 1)])
        #expect(try xml(PicoDocsEngine.write(slide, to: .pptx), "ppt/slides/slide1.xml").contains(">Agenda</a:t>"))
        let images = ConverterResult(sections: ["charts/logo.png", "headers/logo.png"].enumerated().map { index, title in
            .init(title: title, kind: .image, markdown: "", metadata: ["base64": Data([UInt8(index + 1)]).base64EncodedString(), "mimeType": "image/png"])
        })
        let docx = try PicoDocsEngine.write(images, to: .docx)
        #expect(try xml(docx, "word/document.xml").components(separatedBy: "<w:drawing>").count - 1 == 2)
        let archive = try #require(Archive(data: docx, accessMode: .read))
        #expect(archive.filter { $0.path.hasPrefix("word/media/") }.count == 2)
    }

    @Test func listContinuationHardBreaksAndItalicCode() throws {
        let source = "- first\n  second  \n  third"
        let docx = try PicoDocsEngine.write(markdown: source, to: .docx)
        #expect(try xml(docx, "word/document.xml").contains("<w:br/>"))
        let pptx = try PicoDocsEngine.write(markdown: source, to: .pptx)
        #expect(try xml(pptx, "ppt/slides/slide1.xml").contains("first second</a:t></a:r><a:br/>"))
        #if canImport(AppKit)
        for source in ["*`code`*", "***`code`***"] {
            let string = AttributedStringDocumentBuilder.attributedString(from: ConverterResult(sections: [.init(markdown: source)]))
            let font = try #require(string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            #expect(font.fontDescriptor.symbolicTraits.contains(.italic))
            #expect(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
            if source.hasPrefix("***") { #expect(font.fontDescriptor.symbolicTraits.contains(.bold)) }
        }
        let list = AttributedStringDocumentBuilder.attributedString(from: ConverterResult(sections: [.init(markdown: source)]))
        #expect(list.string.contains("first second\nthird"))
        #endif
    }

    @Test func importedSheetValuesHaveLosslessRoundTripCarrier() async throws {
        let csv = #""*value*","`code`","[label](url)","\*literal\*"," edge ","line"# + "\r\nbreak\""
        let original = ConverterResult(sections: [.init(title: "`Code`", kind: .sheet, markdown: "", metadata: ["csv": csv])])
        let first = try PicoDocsEngine.write(original, to: .xlsx)
        let recovered = try await PicoDocsEngine.convert(data: first, filename: "literal.xlsx")
        #expect(recovered.sections.first?.metadata["csv"] == csv)
        let second = try PicoDocsEngine.write(recovered, to: .xlsx)
        #expect(try xml(second, "xl/worksheets/sheet1.xml") == xml(first, "xl/worksheets/sheet1.xml"))
        #expect(try DocumentRenderer.render(recovered, to: .csv) == csv)
        let echoed = ConverterResult(sections: [.init(title: "`Code`", kind: .sheet, markdown: "## `Code`\n\n| Value |\n| --- |\n| Actual |")])
        let sheet = try xml(PicoDocsEngine.write(echoed, to: .xlsx), "xl/worksheets/sheet1.xml")
        #expect(sheet.components(separatedBy: "<row ").count - 1 == 2)
        #expect(!sheet.contains(">Code</t>"))
    }

    @Test func canonicalLineEndingsFencesAndTabMarkers() throws {
        let expected: [MarkdownBlock] = [.heading(1, "Title"), .code("code"), .paragraph("after")]
        for newline in ["\r\n", "\r", "\n"] {
            #expect(MarkdownBlockParser.parse(["# Title", "", "```", "code", "```", "after"].joined(separator: newline)) == expected)
        }
        for source in ["~~~\n[^n]: literal\n~~~", "````\n```\n[^n]: literal\n````"] {
            for format in [ExportFileType.html, .plaintext] {
                let text = try DocumentRenderer.render(ConverterResult(sections: [.init(markdown: source)]), to: format)
                #expect(text.contains("[^n]: literal"))
            }
        }
        for marker in ["-", "*", "+", "2."] {
            let data = try PicoDocsEngine.write(markdown: marker + "\tfirst\n\tcontinued", to: .docx)
            #expect(try xml(data, "word/document.xml").contains("<w:numPr>"))
        }
        let sibling = try PicoDocsEngine.write(markdown: "- first\n - second", to: .pptx)
        #expect(try !xml(sibling, "ppt/slides/slide1.xml").contains(#"lvl="1""#))
    }

    @Test func inlineCodeNormalizesItsOwnSlideNewlines() throws {
        let data = try PicoDocsEngine.write(markdown: "`one\\\ntwo` and `one  \ntwo`\n\n- `list\\\n  continuation`", to: .pptx)
        let slide = try xml(data, "ppt/slides/slide1.xml")
        #expect(slide.contains(#">one\ two</a:t>"#))
        #expect(slide.contains(">one   two</a:t>"))
        #expect(!slide.contains("<a:br/>"))
        #expect(MarkdownInlineParser.parse(#"[x](<https://e.test/a\>b\~c>)"#) == [.link(label: [.text("x")], destination: "https://e.test/a>b~c")])
        let linked = try PicoDocsEngine.write(markdown: #"[x](<https://e.test/a\>b\~c>)"#, to: .docx)
        #expect(try xml(linked, "word/_rels/document.xml.rels").contains("https://e.test/a%3Eb~c"))
    }

    @Test func CSVCRLFRecordsAndCarriageReturnsStayLossless() throws {
        let csv = "A,B\r\n\"one\rtwo\",\"three\r\nfour\"\r\nlast,value"
        let result = ConverterResult(sections: [.init(kind: .sheet, markdown: "", metadata: ["csv": csv])])
        let sheet = try xml(PicoDocsEngine.write(result, to: .xlsx), "xl/worksheets/sheet1.xml")
        #expect(sheet.components(separatedBy: "<row ").count - 1 == 3)
        #expect(sheet.contains("one&#13;two"))
        #expect(sheet.contains("three&#13;\nfour"))
        #expect(sheet.contains(#"r="B3""#))
    }

    @Test func sheetNamesRespectUTF16BudgetAndGraphemeBoundaries() throws {
        let flag = "🇺🇸", family = "👨‍👩‍👧‍👦"
        let result = ConverterResult(sections: [flag, flag, family].map { .init(title: String(repeating: $0, count: 31), markdown: "value") })
        let workbook = try xml(PicoDocsEngine.write(result, to: .xlsx), "xl/workbook.xml")
        let document = try SwiftSoup.parse(workbook, "", SwiftSoup.Parser.xmlParser())
        let names = try document.getElementsByTag("sheet").array().map { try $0.attr("name") }
        #expect(names.count == 3)
        #expect(names.allSatisfy { $0.utf16.count <= 31 })
        #expect(names[0] == String(repeating: flag, count: 7))
        #expect(names[1] == String(repeating: flag, count: 6) + " (2)")
        #expect(names[2] == String(repeating: family, count: 2))
    }

    @Test func nestedEmphasisSharedClosersAndAllPunctuationEscapes() {
        #expect(MarkdownInlineParser.parse("**bold *italic***") == [.strong([.text("bold "), .emphasis([.text("italic")])])])
        #expect(MarkdownInlineParser.parse("*italic **bold***") == [.emphasis([.text("italic "), .strong([.text("bold")])])])
        #expect(MarkdownInlineParser.parse("**before *inside `code`* after**").plainText == "before inside code after")
        #expect(MarkdownInlineParser.parse(#"Cost: \$5, literal \~text\~ and \>"#).plainText == "Cost: $5, literal ~text~ and >")
        #expect(MarkdownInlineParser.parse(#"[\$5](https://example.com) and `\$5`"#).plainText == #"$5 and \$5"#)
    }

    @Test func slideHyperlinksNumberBoundsAndTabContinuations() throws {
        let source = "# [Title](https://example.com/title)\n\nVisit **[bold](https://example.com/a?x=1&y=2)**\n\n0. Zero\n32768. Large\n\n- first\n\tcontinued\n\t- [child](https://example.com/child)"
        let data = try PicoDocsEngine.write(markdown: source, to: .pptx)
        let slide = try xml(data, "ppt/slides/slide1.xml")
        let rels = try xml(data, "ppt/slides/_rels/slide1.xml.rels")
        #expect(slide.components(separatedBy: "<a:hlinkClick ").count - 1 == 3)
        #expect(slide.contains(#"<a:rPr b="1"><a:hlinkClick"#))
        #expect(rels.contains(#"Target="https://example.com/a?x=1&amp;y=2" TargetMode="External""#))
        #expect(rels.contains("/title")); #expect(rels.contains("/child"))
        #expect(!slide.contains(#"startAt="0""#)); #expect(!slide.contains(#"startAt="32768""#))
        #expect(slide.contains(">0. </a:t>")); #expect(slide.contains(">32768. </a:t>"))
        #expect(slide.contains(">first continued</a:t>"))
        #expect(slide.contains(#"<a:pPr lvl="1"><a:buChar"#))
        let docx = try PicoDocsEngine.write(markdown: "- first\n\tcontinued", to: .docx)
        let document = try xml(docx, "word/document.xml")
        #expect(document.components(separatedBy: "<w:p>").count - 1 == 1)
        #expect(document.contains("continued"))
    }

    @Test func unsupportedMediaExtensionUsesKnownMIME() throws {
        let image = DocumentSection(kind: .image, markdown: "", sourcePath: "avatar.dat", metadata: ["base64": "AQID", "mimeType": "image/png"])
        let data = try PicoDocsEngine.write(ConverterResult(sections: [.init(markdown: "![Avatar](avatar.dat)"), image]), to: .docx)
        let archive = try #require(Archive(data: data, accessMode: .read))
        #expect(archive["word/media/avatar.png"] != nil)
        #expect(archive["word/media/avatar.dat"] == nil)
        #expect(try xml(data, "[Content_Types].xml").contains(#"Extension="png" ContentType="image/png""#))
    }

    @Test func structuredEmphasisFlankingAndLiteralPaths() {
        #expect(MarkdownInlineParser.parse("**before `code` after**") == [.strong([.text("before "), .code("code"), .text(" after")])])
        #expect(MarkdownInlineParser.parse("*see [link](https://example.com)*") == [.emphasis([.text("see "), .link(label: [.text("link")], destination: "https://example.com")])])
        #expect(MarkdownInlineParser.parse("2 * 3 * 4").plainText == "2 * 3 * 4")
        #expect(MarkdownInlineParser.parse(#"![x](C:\images\pic.png)"#) == [.image(alt: "x", source: #"C:\images\pic.png"#)])
    }

    @Test func listStartsAndNestingSurviveOfficeRoundTrips() async throws {
        let source = "3. Parent\n   1. Child\n      - Grandchild\n4. Next"
        var result = ConverterResult(sections: [.init(markdown: source)])
        for _ in 0..<2 {
            let docx = try PicoDocsEngine.write(result, to: .docx)
            let document = try xml(docx, "word/document.xml")
            #expect(document.contains(#"w:ilvl w:val="1""#))
            #expect(document.contains(#"w:ilvl w:val="2""#))
            #expect(try xml(docx, "word/numbering.xml").contains(#"w:startOverride w:val="3""#))
            result = try await PicoDocsEngine.convert(data: docx, filename: "nested.docx")
            #expect(result.markdown().contains("3. Parent\n   1. Child\n      - Grandchild\n4. Next"))
        }
        let pptx = try PicoDocsEngine.write(result, to: .pptx)
        let slide = try xml(pptx, "ppt/slides/slide1.xml")
        #expect(slide.contains(#"<a:pPr lvl="1"><a:buAutoNum type="arabicPeriod" startAt="1""#))
        #expect(slide.contains(#"startAt="3""#))
    }

    @Test func imagePathsCSVMetadataCellLimitsAndSlideGaps() throws {
        for (path, title, reference) in [(#"C:\images\pic.png"#, "pic.png", #"C:\images\pic.png"#), ("", "logo.png", "logo.png")] {
            let image = DocumentSection(title: title, kind: .image, markdown: "", sourcePath: path, metadata: ["base64": "AQID", "mimeType": "image/png"])
            let result = ConverterResult(sections: [.init(markdown: "![Image](\(reference))"), image])
            let data = try PicoDocsEngine.write(result, to: .docx)
            #expect(try xml(data, "word/document.xml").contains("<w:drawing>"))
            let archive = try #require(Archive(data: data, accessMode: .read))
            for entry in archive where entry.path.hasPrefix("word/media/") {
                #expect(!entry.path.contains("\\"))
                #expect(!entry.path.contains(":"))
            }
        }
        let csvOnly = ConverterResult(sections: [.init(kind: .sheet, markdown: "", metadata: ["csv": "A,B\n1,2"])])
        #expect(try xml(PicoDocsEngine.write(csvOnly, to: .xlsx), "xl/worksheets/sheet1.xml").contains(">A</t>"))
        #expect(throws: ExporterError.self) { try PicoDocsEngine.write(markdown: String(repeating: "x", count: 32_768), to: .xlsx) }
        let deck = ConverterResult(sections: [.init(kind: .slide, markdown: "Third", slideNumber: 3), .init(kind: .slide, markdown: "First", slideNumber: 1)])
        let pptx = try PicoDocsEngine.write(deck, to: .pptx)
        #expect(try xml(pptx, "ppt/slides/slide1.xml").contains("First"))
        #expect(try xml(pptx, "ppt/slides/slide2.xml").contains("<a:p/>"))
        #expect(try xml(pptx, "ppt/slides/slide3.xml").contains("Third"))
    }

    @Test func slideBreaksSpaceCodeAndTableNumbering() async throws {
        let pptx = try PicoDocsEngine.write(markdown: "first\nsecond\n\nfirst\\\nsecond", to: .pptx)
        let slide = try xml(pptx, "ppt/slides/slide1.xml")
        #expect(slide.contains("first second</a:t>"))
        #expect(slide.contains("first</a:t></a:r><a:br/><a:r><a:t>second"))
        var result = ConverterResult(sections: [.init(markdown: "` `")])
        for _ in 0..<3 {
            result = try await PicoDocsEngine.convert(data: PicoDocsEngine.write(result, to: .docx), filename: "space.docx")
            #expect(MarkdownInlineParser.parse(result.markdown()) == [.code(" ")])
        }
        let ns = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main""#
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:numFmt w:val=\"decimal\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        func paragraph(_ text: String) -> String { "<w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>" }
        let document = "<w:document \(ns)><w:body>" + paragraph("Before") + "<w:tbl><w:tr><w:tc>" + paragraph("Inside") + "</w:tc></w:tr></w:tbl>" + paragraph("After") + "</w:body></w:document>"
        let data = PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8))])
        let numbered = try await PicoDocsEngine.convert(data: data, filename: "table.docx").markdown()
        #expect(numbered.contains("2. Inside"))
        #expect(numbered.contains("3. After"))
    }

    @Test func completeCodeDelimitersAndMalformedDestinations() async throws {
        #expect(MarkdownInlineParser.parse("Use ``a`b`` now") == [.text("Use "), .code("a`b"), .text(" now")])
        #expect(MarkdownInlineParser.parse("`` `x` ``") == [.code("`x`")])
        let fenced = "````\n```\ncontent\n```\n````"
        #expect(MarkdownBlockParser.parse(fenced) == [.code("```\ncontent\n```")])
        #expect(MarkdownBlockParser.parse("~~~\n```\n~~~") == [.code("```")])
        let incomplete = String(repeating: "[](", count: 20_000)
        #expect(MarkdownInlineParser.parse(incomplete).plainText == incomplete)
        let markdown = "Use ``a`b`` now\n\n" + fenced
        let docx = try PicoDocsEngine.write(markdown: markdown, to: .docx)
        let recovered = try await PicoDocsEngine.convert(data: docx, filename: "code.docx")
        #expect(recovered.markdown().contains("``a`b``"))
        #expect(recovered.markdown().contains(fenced))
    }

    @Test func quotesListsSlideMarkersAndTitleImages() async throws {
        let source = "> Quoted\n\n1. Plan\n2. Ship\n\n- Bullet"
        let data = try PicoDocsEngine.write(markdown: source, to: .docx)
        let recovered = try await PicoDocsEngine.convert(data: data, filename: "roundtrip.docx")
        #expect(recovered.markdown().contains("> Quoted"))
        #expect(recovered.markdown().contains("1. Plan"))
        #expect(recovered.markdown().contains("2. Ship"))
        #expect(recovered.markdown().contains("- Bullet"))
        let second = try PicoDocsEngine.write(recovered, to: .docx)
        let reread = try await PicoDocsEngine.convert(data: second, filename: "second.docx")
        #expect(reread.markdown().contains("2. Ship"))
        let slide = try xml(PicoDocsEngine.write(markdown: source, to: .pptx), "ppt/slides/slide1.xml")
        #expect(slide.contains(#"<a:buAutoNum type="arabicPeriod" startAt="1"/>"#))
        #expect(slide.contains(#"<a:buAutoNum type="arabicPeriod" startAt="2"/>"#))
        #expect(slide.contains("<a:buChar"))
        let image = ConverterResult(sections: [.init(title: "icons/logo.png", kind: .image, markdown: "", metadata: ["base64": Data([1,2,3]).base64EncodedString(), "mimeType": "image/png"])])
        #expect(try xml(PicoDocsEngine.write(image, to: .docx), "word/document.xml").contains("<w:drawing>"))
    }

    @Test func sheetWhitespaceAndAttributedBreaks() throws {
        let sheets = ConverterResult(sections: ["A B", "A\nB", "A\tB", "A\rB"].map { .init(title: $0, kind: .sheet, markdown: "x") })
        let workbook = try xml(PicoDocsEngine.write(sheets, to: .xlsx), "xl/workbook.xml")
        #expect(workbook.components(separatedBy: #"name="A B""#).count == 2)
        #expect(workbook.contains(#"name="A B (2)""#))
        #if canImport(AppKit) || canImport(UIKit)
        let result = ConverterResult(sections: [.init(markdown: "first\nsecond\n\nfirst\\\nsecond\n\nfirst  \nsecond")])
        let text = AttributedStringDocumentBuilder.attributedString(from: result).string
        #expect(text.contains("first second"))
        #expect(text.components(separatedBy: "first\nsecond").count == 3)
        #expect(!text.contains("\\"))
        #endif
    }

    private func xml(_ data: Data, _ path: String) throws -> String {
        let archive = try #require(Archive(data: data, accessMode: .read))
        let entry = try #require(archive[path])
        var bytes = Data()
        _ = try archive.extract(entry) { bytes.append($0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    @Test func inlineLiteralEscapesFootnotesAndUnmatchedOpeners() {
        #expect(MarkdownInlineParser.parse(#"\*literal\*"#) == [.text("*literal*")])
        #expect(MarkdownInlineParser.parse(#"*a\*b*"#) == [.emphasis([.text("a*b")])])
        #expect(MarkdownInlineParser.parse(#"\[not a link](url)"#).plainText == "[not a link](url)")
        #expect(MarkdownInlineParser.parse("Claim[^1]\n[^1]: Source").plainText == "Claim[^1]\n[^1]: Source")
        let unfinished = String(repeating: "[^", count: 20_000)
        #expect(MarkdownInlineParser.parse(unfinished).plainText == unfinished)
    }

    @Test func docxStylesCodeAndHyperlinks() async throws {
        let markdown = "# Heading\n\n> Quote\n\nUse `x` here.\n\n```\n  let x = 1\nprint(x)\n```\n\n[Link](<https://example.com/a b?q=x y&v=1>)"
        let data = try PicoDocsEngine.write(markdown: markdown, to: .docx)
        let styles = try xml(data, "word/styles.xml")
        #expect(styles.contains(#"w:styleId="Heading1""#))
        #expect(styles.contains(#"w:styleId="Quote""#))
        #expect(styles.contains(#"w:styleId="PicoCodeBlock""#))
        let rels = try xml(data, "word/_rels/document.xml.rels")
        #expect(rels.contains("/styles"))
        #expect(rels.contains("https://example.com/a%20b?q=x%20y&amp;v=1"))
        let recovered = try await PicoDocsEngine.convert(data: data, filename: "out.docx")
        #expect(recovered.markdown().contains("Use `x` here."))
        #expect(recovered.markdown().contains("```\n  let x = 1\nprint(x)\n```"))
    }

    @Test func mediaIdentitySurvivesSecondExportAndReservedExtensions() async throws {
        for name in ["chart#1.png", "chart.xml", "chart.rels"] {
            let image = DocumentSection(kind: .image, markdown: "", sourcePath: name, metadata: ["mimeType": "image/png", "base64": Data([1, 2, 3]).base64EncodedString()])
            let first = try PicoDocsEngine.write(ConverterResult(sections: [image]), to: .docx)
            let recovered = try await PicoDocsEngine.convert(data: first, filename: "one.docx")
            let second = try PicoDocsEngine.write(recovered, to: .docx)
            #expect(try xml(second, "word/document.xml").contains("<w:drawing>"))
            let types = try xml(first, "[Content_Types].xml")
            #expect(types.components(separatedBy: #"Extension="xml""#).count == 2)
            #expect(types.components(separatedBy: #"Extension="rels""#).count == 2)
        }
    }

    @Test func emptyWorksheetsAndSpreadsheetLimits() throws {
        let sheets = ConverterResult(sections: [DocumentSection(title: "Empty", kind: .sheet, markdown: ""), DocumentSection(title: "Data", kind: .sheet, markdown: "Value")])
        let data = try PicoDocsEngine.write(sheets, to: .xlsx)
        let workbook = try xml(data, "xl/workbook.xml")
        #expect(workbook.contains(#"name="Empty""#))
        #expect(workbook.contains(#"name="Data""#))
        let oversized = ConverterResult(sections: [DocumentSection(markdown: "data", metadata: ["csv": Array(repeating: "x", count: 16_385).joined(separator: ",")])])
        #expect(throws: ExporterError.self) { try PicoDocsEngine.write(oversized, to: .xlsx) }
        #expect(throws: ExporterError.self) { try XLSXExporter.validateDimensions(rows: 1_048_577, columns: 1) }
        try XLSXExporter.validateDimensions(rows: 1_048_576, columns: 16_384)
    }

    @Test func metadataAndCanonicalTableBreaks() throws {
        let result = ConverterResult(title: "Review title", author: "Review author", sections: [DocumentSection(markdown: "| first<br>second |\n| --- |")])
        for format in [ExportableFileType.docx, .xlsx, .pptx] {
            let data = try PicoDocsEngine.write(result, to: format)
            let core = try xml(data, "docProps/core.xml")
            #expect(core.contains("<dc:title>Review title</dc:title>"))
            #expect(core.contains("<dc:creator>Review author</dc:creator>"))
            #expect(try xml(data, "_rels/.rels").contains("metadata/core-properties"))
        }
        let pptx = try PicoDocsEngine.write(result, to: .pptx)
        #expect(try xml(pptx, "ppt/slides/slide1.xml").contains("first</a:t></a:r><a:br/><a:r><a:t>second"))
        #if canImport(AppKit) || canImport(UIKit)
        let rtf = try PicoDocsEngine.write(result, to: .rtf)
        let text = String(decoding: rtf, as: UTF8.self)
        #expect(text.contains("Review title"))
        #expect(text.contains("Review author"))
        #expect(!text.contains("<br>"))
        #endif
    }
}
