import Foundation
import Testing
import ZIPFoundation
import SwiftSoup
@testable import PicoDocs

struct OfficeSeventhStackReviewTests {
    @Test func SVGNamespaceDeclarationsCanBeInherited() async throws {
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10"/>"#.utf8)
        let source = ConverterResult(sections: [.init(kind: .image, markdown: "", sourcePath: "vector.svg", metadata: ["base64": svg.base64EncodedString(), "mimeType": "image/svg+xml"])])
        let exported = try PicoDocsEngine.write(source, to: .docx)
        let inherited = try PowerPointThirdStackReviewTests.replacing(exported, part: "word/document.xml") { xml in
            xml.replacingOccurrences(of: "xmlns:asvg=\"http://schemas.microsoft.com/office/drawing/2016/SVG/main\"", with: "")
                .replacingOccurrences(of: "<w:document ", with: "<w:document xmlns:asvg=\"http://schemas.microsoft.com/office/drawing/2016/SVG/main\" ")
        }
        let result = try await PicoDocsEngine.convert(data: inherited, filename: "inherited.docx")
        #expect(result.sections.first { $0.kind == .image }?.metadata["base64"] == svg.base64EncodedString())
        #expect(result.markdown().contains("vector.svg"))
        let alias = try PowerPointThirdStackReviewTests.replacing(inherited, part: "word/document.xml") { $0.replacingOccurrences(of: "asvg:", with: "vector:").replacingOccurrences(of: "xmlns:asvg", with: "xmlns:vector") }
        let aliased = try await PicoDocsEngine.convert(data: alias, filename: "alias.docx")
        #expect(aliased.sections.first { $0.kind == .image }?.metadata["base64"] == svg.base64EncodedString())
    }

    @Test func CSVInnerFenceLinesRestoreOwnedWhitespace() throws {
        let source = ConverterResult(sections: [.init(markdown: "````\n```&#32;inner\n````", metadata: ["preservedWhitespace": "1"])])
        #expect(try DocumentRenderer.render(source, to: .csv) == "``` inner")
    }

    @Test func XLSXWriterHonorsPreCancelledTasks() async throws {
        let source = ConverterResult(sections: [.init(markdown: "| A |\n| --- |\n| B |")])
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try XLSXExporter().write(source, format: .xlsx)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let serializer = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try XLSXExporter.worksheetXML(rows: [["value"]])
        }
        await #expect(throws: CancellationError.self) { _ = try await serializer.value }
    }

    @Test func RTFFontMetadataHasCountAndAggregateAdmission() async throws {
        let count = RTFFontTable(maximumFonts: 2)
        count.append("Courier", font: 1); count.finish(1)
        count.markMonospace(2); try count.check()
        #expect(count.isMonospace(1)); #expect(count.isMonospace(2))
        count.admit(3)
        #expect(throws: PicoDocsError.fileCorrupted) { try count.check() }
        let exact = RTFFontTable(maximumFonts: 1, maximumBytes: 129)
        exact.append("X", font: 0); try exact.check()
        exact.append("Y", font: 0)
        #expect(throws: PicoDocsError.fileCorrupted) { try exact.check() }
        let entries = (0..<4_097).map { "{\\f" + String($0) + " Helvetica;}" }.joined()
        let data = Data(("{\\rtf1{\\fonttbl" + entries + "}Body}").utf8)
        await #expect(throws: PicoDocsError.fileCorrupted) {
            _ = try await RTFConverter().convert(data, info: StreamInfo(detectedFormat: .rtf))
        }
        let long = "Courier" + String(repeating: "x", count: 100_000)
        let rtf = "{\\rtf1{\\fonttbl{\\f1 " + long + ";}}{\\field{\\*\\fldinst HYPERLINK \"https://example.test\"}{\\fldrslt \\f1 API}}}"
        #expect(RTFConverter.markdown(fromRTF: rtf) == "[`API`](https://example.test)")
    }

    @Test func repeatedImageDrawingsKeepOneMediaPartAndTheirCachedAspectRatio() throws {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xC0, 0, 8, 8, 0, 10, 0, 20, 1, 0xFF, 0xD9])
        let body = Array(repeating: "![image](photo.jpg)", count: 500).joined(separator: " ")
        let source = ConverterResult(sections: [.init(markdown: body), .init(kind: .image, markdown: "", sourcePath: "photo.jpg", metadata: ["base64": bytes.base64EncodedString(), "mimeType": "image/jpeg"])])
        let data = try PicoDocsEngine.write(source, to: .docx)
        let xml = try OfficeStackReviewTests.xml(data, "word/document.xml")
        #expect(xml.components(separatedBy: "<wp:extent cx=\"4572000\" cy=\"2286000\"/>").count - 1 == 500)
        let archive = try Archive(data: data, accessMode: .read)
        #expect(archive.filter { $0.path.hasPrefix("word/media/") }.count == 1)
    }

    @Test func numberingPreviewCanResetOnlyItsRenderState() throws {
        let data = try PicoDocsEngine.write(markdown: "1. First\n2. Second", to: .docx)
        let archive = try Archive(data: data, accessMode: .read)
        let document = try SwiftSoup.parse(OfficeStackReviewTests.xml(data, "word/document.xml"), "", SwiftSoup.Parser.xmlParser())
        let properties = try #require(document.getElementsByTag("w:numPr").first())
        let numbering = WordListNumbering(archive: archive)
        #expect(numbering.isResolvable)
        let first = numbering.prefix(numPr: properties, style: nil)
        let second = numbering.prefix(numPr: properties, style: nil)
        #expect(first != second)
        numbering.resetRenderingState()
        #expect(numbering.prefix(numPr: properties, style: nil) == first)
        #expect(numbering.isResolvable)
    }
}
