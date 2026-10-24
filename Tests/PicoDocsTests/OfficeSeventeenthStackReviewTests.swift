import Foundation
import Testing
@testable import PicoDocs

struct OfficeSeventeenthStackReviewTests {
    @Test(arguments: [("https://example.com/a b", "https://example.com/a%20b"), ("https://example.com/100%?q=%2F", "https://example.com/100%25?q=%2F")])
    func externalPPTXTargetsAreAlreadyEncoded(_ pair: (String, String)) throws {
        let markdown = "[link](<\(pair.0)>)"
        let source = ConverterResult(sections: [.init(kind: .slide, markdown: "## Slide\n\n" + markdown + "\n\n**Notes:** " + markdown, metadata: ["notes": markdown])])
        let data = try PPTXExporter().write(source, format: .pptx)
        for path in ["ppt/slides/_rels/slide1.xml.rels", "ppt/notesSlides/_rels/notesSlide1.xml.rels"] {
            let xml = try OfficeStackReviewTests.xml(data, path)
            #expect(xml.contains("Target=\"\(pair.1)\" TargetMode=\"External\""))
            #expect(!xml.contains("Target=\"\(pair.0)\""))
        }
    }

    @Test(arguments: [ExportableFileType.docx, .xlsx])
    func coreMetadataRetainsEdgeWhitespace(_ format: ExportableFileType) async throws {
        let title = " \t\rTitle\r\t ", author = "\r Author \t"
        var source = ConverterResult(title: title, author: author, sections: [.init(markdown: "Body")])
        for _ in 0..<2 {
            switch format {
            case .docx:
                source = try await WordConverter().convert(WordprocessingMLExporter().write(source, format: format), info: StreamInfo(detectedFormat: .docx))
            default:
                source = try await SpreadsheetConverter().convert(XLSXExporter().write(source, format: format), info: StreamInfo(detectedFormat: .xlsx))
            }
            #expect(source.title == title)
            #expect(source.author == author)
        }
    }
}
