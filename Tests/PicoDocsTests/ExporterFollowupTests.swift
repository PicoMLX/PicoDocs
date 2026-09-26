import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

struct ExporterFollowupTests {
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
        #expect(try xml(pptx, "ppt/slides/slide1.xml").contains("first\nsecond"))
        #if canImport(AppKit) || canImport(UIKit)
        let rtf = try PicoDocsEngine.write(result, to: .rtf)
        let text = String(decoding: rtf, as: UTF8.self)
        #expect(text.contains("Review title"))
        #expect(text.contains("Review author"))
        #expect(!text.contains("<br>"))
        #endif
    }
}
