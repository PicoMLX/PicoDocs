import Foundation
import Testing
@testable import PicoDocs

struct OfficeThirteenthStackReviewTests {
    @Test func canonicalRTFDoesNotTrimSemanticWhitespace() throws {
        for value in [160, 8199, 8239] {
            let rtf = "{\\rtf1{\\*\\picodocsmarkdown1}Word\\u" + String(value) + "?\\par}"
            #expect(RTFConverter.markdown(fromRTF: rtf) == "Word" + String(UnicodeScalar(value)!))
        }
        #expect(RTFConverter.markdown(fromRTF: #"{\rtf1{\*\picodocsmarkdown1}\~\par}"#) == "\u{00A0}")
    }
    @Test func CSVNamesAreAdmittedEvenWhenRawTablesBypassMarkdown() throws {
        let name = String(repeating: "x", count: 64 * 1024 * 1024 + 1)
        let result = ConverterResult(sections: [
            .init(kind: .sheet, markdown: "", sheetName: name, metadata: ["csv": "A"]),
            .init(kind: .sheet, markdown: "", sheetName: "Second", metadata: ["csv": "B"])
        ])
        #expect(throws: PicoDocsError.fileCorrupted) { _ = try DocumentRenderer.render(result, to: .csv) }
    }
}

extension OfficeThirteenthStackReviewTests {
    @Test func nestedLinksDoNotRepeatedlyCopyAnInactiveOuterLabel() {
        let payload = String(repeating: "x", count: 128 * 1024)
        let text = String(repeating: "[", count: 63) + "[" + payload + "](inner)" + String(repeating: "](outer)", count: 63)
        let metrics = MarkdownInlineParser.ParseMetrics()
        let nodes = MarkdownInlineParser.parse(text, metrics: metrics)
        #expect(nodes.plainText == String(repeating: "[", count: 63) + payload + String(repeating: "](outer)", count: 63))
        #expect(metrics.copiedLabelBytes == payload.utf8.count)
        #expect(MarkdownInlineParser.parse("[a [b](x](outer))") == [.link(label: [.text("a [b](x")], destination: "outer"), .text(")")])
        let image = MarkdownInlineParser.parse("[![a [b](inner)](image)](outer)")
        #expect(image == [.link(label: [.image(alt: "a b", source: "image")], destination: "outer")])
    }
    @Test func CSVNamesAdmitEscapedFieldBytesBeforeReplacement() throws {
        #expect(try DocumentRenderer.boundedCSVField("a\"b", maximumBytes: 6) == "\"a\"\"b\"")
        #expect(throws: PicoDocsError.fileCorrupted) { _ = try DocumentRenderer.boundedCSVField("a\"b", maximumBytes: 5) }
    }
    @Test func DBCSInstructionBytesAreBoundedBeforeDecoding() {
        let field = RTFConverter.Field()
        field.appendInstruction("HYPERLINK ")
        #expect(field.admitBufferedInstructionByte(65_525))
        #expect(!field.admitBufferedInstructionByte(65_526))
        #expect(field.instruction.isEmpty)
        #expect(!field.admitBufferedInstructionByte(0))
        let valid = #"{\rtf1\ansi\ansicpg932{\field{\*\fldinst HYPERLINK "https://example.test/\'82\'a0"}{\fldrslt Label}}}"#
        #expect(RTFConverter.markdown(fromRTF: valid).contains("[Label](https://example.test/あ)"))
        let huge = #"{\rtf1\ansi\ansicpg932{\field{\*\fldinst HYPERLINK ""# + String(repeating: #"\'61"#, count: 65_537) + #""}{\fldrslt Label}}}"#
        #expect(RTFConverter.markdown(fromRTF: huge) == "Label")
    }
    @Test func PPTXModelAndSingleSlideSerializationHonorCancellation() async throws {
        let models = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try PPTXExporter.bodyLines([.paragraph("Text")])
            return true
        }
        await #expect(throws: CancellationError.self) { _ = try await models.value }
        let serialization = Task.detached {
            var relationships = PPTXExporter.SlideRelationships()
            withUnsafeCurrentTask { $0?.cancel() }
            return try PPTXExporter.slideXML(.init(title: "Slide", body: [.init(text: "Body")]), fragmentSlides: [:], relationships: &relationships)
        }
        await #expect(throws: CancellationError.self) { _ = try await serialization.value }
    }
}
