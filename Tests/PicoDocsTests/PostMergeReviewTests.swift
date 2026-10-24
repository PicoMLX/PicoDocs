import Foundation
import Testing
@testable import PicoDocs

/// Regressions for the review of the merged Numbers/Office stack.
struct PostMergeReviewTests {
    @Test func nestedImageLabelsStayWithinTheCopyBudget() {
        // Each nested image copies and reparses its whole label; 40 levels around
        // one payload used to copy ~40× the payload before any writer budget ran.
        let payload = String(repeating: "x", count: 256 * 1024)
        let text = String(repeating: "![", count: 40) + payload + String(repeating: "](i)", count: 40)
        let metrics = MarkdownInlineParser.ParseMetrics()
        let nodes = MarkdownInlineParser.parse(text, metrics: metrics)
        #expect(metrics.labelByteBudget == 4 * text.utf8.count + 65_536)
        #expect(metrics.copiedLabelBytes <= 4 * text.utf8.count + 65_536)
        #expect(nodes.plainText.contains(payload))
        if case .image = nodes.first {} else { Issue.record("outer image should still parse: \(nodes)") }
        // Ordinary nesting stays far inside the budget.
        #expect(MarkdownInlineParser.parse("[![a *b*](img)](url)") == [.link(label: [.image(alt: "a b", source: "img")], destination: "url")])
    }

    @Test func labelByteCountsDoNotMaterializeCharacters() {
        let text = MarkdownInlineParser.IndexedText("aé🎉" + String(repeating: "z", count: 600) + "ü")
        #expect(text.utf8Count(0..<3) == 1 + 2 + 4)
        #expect(text.utf8Count(1..<604) == 2 + 4 + 600 + 2)
        #expect(text.utf8Count(5..<5) == 0)
    }

    @Test func worksheetScansPollCancellationInBothPasses() throws {
        let rowsXML = (1...200).map { "<row r=\"\($0)\"><c r=\"A\($0)\"><v>\($0)</v></c></row>" }.joined()
        let sheet = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>"# + rowsXML + "</sheetData></worksheet>"
        let rows = try SpreadsheetMLPackage.worksheetRows(Data(sheet.utf8))
        #expect(rows.count == 200)
        // 200 rows of one cell are 400 visits per pass, polled every 64 visits:
        // polls 1–6 fall in the validation pass and 7–12 in the materializing pass.
        for cancelAt in [3, 8] {
            var polls = 0
            var budget = SpreadsheetProjectionBudget()
            #expect(throws: CancellationError.self) {
                _ = try SpreadsheetConverter.markdownTable(rows: rows, sharedStrings: [], sheetName: nil, projectionBudget: &budget, isCancelled: { polls += 1; return polls >= cancelAt })
            }
            #expect(polls == cancelAt)
        }
        var polls = 0
        var budget = SpreadsheetProjectionBudget()
        let table = try SpreadsheetConverter.markdownTable(rows: rows, sharedStrings: [], sheetName: nil, projectionBudget: &budget, isCancelled: { polls += 1; return false })
        #expect(polls == 12)
        #expect(table.markdown.contains("| 200 |"))
    }

    #if canImport(AppKit)
    @Test func optInDOCXExporterRechecksCancellationAfterSerializing() throws {
        let source = ConverterResult(sections: [.init(markdown: "Body")])
        // Checks run on entry, before serializing, and after serializing; cancel
        // only at the last one, after Foundation has produced the package.
        var checks = 0
        #expect(throws: CancellationError.self) {
            _ = try AttributedStringDOCXExporter().write(source, format: .docx, isCancelled: { checks += 1; return checks >= 3 })
        }
        #expect(checks == 3)
        #expect(!(try AttributedStringDOCXExporter().write(source, format: .docx)).isEmpty)
    }
    #endif
}
