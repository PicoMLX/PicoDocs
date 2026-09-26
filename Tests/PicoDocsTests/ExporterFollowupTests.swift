import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

struct ExporterFollowupTests {
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
