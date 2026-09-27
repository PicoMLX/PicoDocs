import Foundation

/// Office writers share a lossless projection of structured worksheet cells.
/// Markdown remains the fallback for sections without a raw CSV carrier.
enum OfficeDocumentBlocks {
    static func parse(_ result: ConverterResult, includeSlideTitles: Bool = true) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var pending: [String] = []
        func flush() {
            blocks += MarkdownBlockParser.parse(pending.joined(separator: "\n\n"))
            pending.removeAll(keepingCapacity: true)
        }
        for section in result.sections where section.kind != .image {
            if [.sheet, .table].contains(section.kind), let csv = section.metadata["csv"] ?? (section.kind == .sheet && section.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : nil) {
                flush()
                if section.kind == .sheet, let title = section.sheetName ?? section.metadata["sheetName"] ?? section.title, !title.isEmpty {
                    let escaped = title.map { #"\`*_{}[]<>"#.contains($0) ? "\\" + String($0) : String($0) }.joined()
                    blocks.append(.heading(2, escaped))
                }
                let rows = CSVConverter.parseCSV(csv).map { row in
                    row.map { cell in
                        MarkdownBlockParser.normalizedLineEndings(cell).map {
                            #"\`*_{}[]<>"#.contains($0) ? "\\" + String($0) : String($0)
                        }.joined().replacingOccurrences(of: "\n", with: "<br>")
                    }
                }
                if !rows.isEmpty { blocks.append(.table(rows)) }
                else if csv.isEmpty {
                    // Legacy carriers serialized a single empty cell as empty CSV.
                    for block in MarkdownBlockParser.parse(section.markdown) {
                        if case .table = block { blocks.append(block) }
                    }
                }
            } else if includeSlideTitles, section.kind == .slide, let title = section.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flush()
                let parsed = MarkdownBlockParser.parse(section.markdown)
                let normalized = MarkdownBlockParser.normalizedLineEndings(title).replacingOccurrences(of: "\n", with: " ")
                let alreadyPresent = parsed.first.map { block in
                    if case .heading(_, let text) = block { return MarkdownInlineParser.parse(text).plainText == normalized }
                    return false
                } ?? false
                if !alreadyPresent {
                    let escaped = normalized.map { #"\`*_{}[]<>"#.contains($0) ? "\\" + String($0) : String($0) }.joined()
                    blocks.append(.heading(2, escaped))
                }
                blocks += parsed
            } else { pending.append(section.markdown) }
        }
        flush()
        return blocks
    }
}
