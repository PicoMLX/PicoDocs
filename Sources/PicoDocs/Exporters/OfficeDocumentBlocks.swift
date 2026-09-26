import Foundation

/// Office writers share a lossless projection of structured worksheet cells.
/// Markdown remains the fallback for sections without a raw CSV carrier.
enum OfficeDocumentBlocks {
    static func parse(_ result: ConverterResult) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var pending: [String] = []
        func flush() {
            blocks += MarkdownBlockParser.parse(pending.joined(separator: "\n\n"))
            pending.removeAll(keepingCapacity: true)
        }
        for section in result.sections where section.kind != .image {
            if section.kind == .sheet, let csv = section.metadata["csv"] {
                flush()
                let rows = CSVConverter.parseCSV(csv).map { row in
                    row.map { cell in
                        MarkdownBlockParser.normalizedLineEndings(cell).map {
                            #"\`*_{}[]<>"#.contains($0) ? "\\" + String($0) : String($0)
                        }.joined().replacingOccurrences(of: "\n", with: "<br>")
                    }
                }
                if !rows.isEmpty { blocks.append(.table(rows)) }
            } else { pending.append(section.markdown) }
        }
        flush()
        return blocks
    }
}
