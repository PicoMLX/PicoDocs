import Foundation
import Testing
@testable import PicoDocs

struct OfficeSixteenthStackReviewTests {
    @Test func RTFTitleAndAuthorSurviveTwoCycles() async throws {
        let title = "Report {Title} 🧪", author = "A \\ B あ"
        var source = ConverterResult(title: title, author: author, sections: [.init(markdown: "Body")])
        for _ in 0..<2 {
            let data = try AttributedStringRTFExporter().write(source, format: .rtf)
            source = try await RTFConverter().convert(data, info: StreamInfo(filename: "fallback.rtf", detectedFormat: .rtf))
            #expect(source.title == title)
            #expect(source.author == author)
            #expect(source.markdown().contains("Body"))
        }
    }

    @Test(arguments: [ExportableFileType.docx, .xlsx, .pptx])
    func corePropertiesRetainCarriageReturns(_ format: ExportableFileType) async throws {
        let title = "A\rB\r\nC", author = "X\rY"
        let source = ConverterResult(title: title, author: author, sections: [.init(markdown: "Content")])
        let imported: ConverterResult
        switch format {
        case .docx: imported = try await WordConverter().convert(WordprocessingMLExporter().write(source, format: format), info: StreamInfo(detectedFormat: .docx))
        case .xlsx: imported = try await SpreadsheetConverter().convert(XLSXExporter().write(source, format: format), info: StreamInfo(detectedFormat: .xlsx))
        default: imported = try await PowerPointConverter().convert(PPTXExporter().write(source, format: format), info: StreamInfo(detectedFormat: .pptx))
        }
        #expect(imported.title == title)
        #expect(imported.author == author)
    }

    @Test func looseListContinuationRetainsASeparateParagraph() throws {
        let source = ConverterResult(sections: [.init(markdown: "- one\n- two\n\n  continuation")])
        let html = try DocumentRenderer.render(source, to: .html)
        #expect(html.contains("<p>continuation</p>"))
        #expect(!html.contains("two continuation"))
    }
}

extension OfficeSixteenthStackReviewTests {
    @Test func RTFMetadataUsesParsedInfoScopesAndExistingDecoders() async throws {
        let rtf = #"{\rtf1\ansi\ansicpg932{\pict{\info{\title Fake}}}{\info{\title A\{B\}\u233?}{\author \'82\'a0}}Body}"#
        let source = try await RTFConverter().convert(Data(rtf.utf8), info: StreamInfo(filename: "fallback", detectedFormat: .rtf))
        #expect(source.title == "A{B}é")
        #expect(source.author == "あ")
        #expect(source.markdown() == "Body")
        let exact = RTFConverter.Metadata(maximumBytes: 3)
        exact.append("é", field: "title"); exact.append("A", field: "author")
        try exact.check()
        exact.append("B", field: "author")
        #expect(throws: PicoDocsError.fileCorrupted) { try exact.check() }
    }

    @Test func RTFLiteralEscapingUsesOneAccumulator() throws {
        let text = String(repeating: "a", count: 9 * 1024 * 1024)
        #expect(try AttributedStringDocumentBuilder.escapedText(text, punctuation: #"\`*_{}[]<>()#+-.!|~"#) == text)
        #expect(try AttributedStringDocumentBuilder.escapedText("*x* é 🧪", punctuation: "*") == #"\*x\* é 🧪"#)
    }

    @Test(arguments: ["&<é>", "# Heading\n\n[link](https://example.test) [^f]\n\n[^f]: Footnote", "- item\n\n  continuation\n  - child", "| A | B |\n| --- | --- |\n| x | y |", "> Quote\n> next\n\n```\ncode\nnext\n```\n\n---"])
    func DOCXPartAdmissionIncludesEverySerializedWrapper(_ markdown: String) throws {
        let source = ConverterResult(sections: [.init(markdown: markdown)])
        let xml = try OfficeStackReviewTests.xml(WordprocessingMLExporter().write(source, format: .docx), "word/document.xml")
        #expect(try WordprocessingMLExporter(maximumDocumentBytes: xml.utf8.count).write(source, format: .docx).count > 0)
        #expect(throws: ExporterError.self) { _ = try WordprocessingMLExporter(maximumDocumentBytes: xml.utf8.count - 1).write(source, format: .docx) }
    }

    @Test func DOCXTextExpansionIsAdmittedBeforeEscaping() throws {
        var exact = WordprocessingMLExporter.DocumentXMLBudget(maximumBytes: 11)
        try exact.reserveText("&<é")
        #expect(exact.remainingBytes == 0)
        var short = WordprocessingMLExporter.DocumentXMLBudget(maximumBytes: 10)
        #expect(throws: ExporterError.self) { try short.reserveText("&<é") }
        var part = WordprocessingMLExporter.DocumentXMLBudget(maximumBytes: 32 * 1024 * 1024)
        let amplified = String(repeating: "&", count: 9 * 1024 * 1024)
        #expect(throws: ExporterError.self) { try part.reserveText(amplified) }
    }

    @Test func corePropertiesChargeCarriageReturnEntitiesExactly() throws {
        let source = ConverterResult(title: "A\rB", author: "X\r\nY", sections: [])
        let xml = try OOXMLPackageWriter.corePropertiesXML(source, maximumBytes: 4096)
        #expect(xml.contains("A&#13;B"))
        #expect(xml.contains("X&#13;\nY"))
        #expect(try OOXMLPackageWriter.corePropertiesXML(source, maximumBytes: xml.utf8.count) == xml)
        #expect(throws: ExporterError.self) { _ = try OOXMLPackageWriter.corePropertiesXML(source, maximumBytes: xml.utf8.count - 1) }
    }
}
