//
//  SpreadsheetConverter.swift
//  PicoDocs
//
//  Converts XLSX workbooks to Markdown tables via CoreXLSX — one structured
//  section per worksheet. Lifts the proven logic from the old ExcelParser into
//  the converter shape. (The xlsx failure in issue #2 was content-type
//  detection, fixed in Phase 0, not the spreadsheet parsing itself.)
//

import Foundation
import CoreXLSX

public struct SpreadsheetConverter: DocumentConverter {

    public init() {}

    public func accepts(_ info: StreamInfo) -> Bool {
        info.detectedFormat == .xlsx
    }

    public func convert(_ data: Data, info: StreamInfo) async throws -> ConverterResult {
        let file = try XLSXFile(data: data)
        // A workbook may have no shared-strings part (e.g. numbers-only, or
        // inline strings); don't fail the whole conversion when it's absent.
        let sharedStrings = try? file.parseSharedStrings()

        var sections: [DocumentSection] = []
        var sheetNames: [String] = []

        for workbook in try file.parseWorkbooks() {
            for (name, path) in try file.parseWorksheetPathsAndNames(workbook: workbook) {
                try Task.checkCancellation()
                let worksheet = try file.parseWorksheet(at: path)
                guard let rows = worksheet.data?.rows, !rows.isEmpty else { continue }

                let table = try Self.markdownTable(rows: rows, sharedStrings: sharedStrings, sheetName: name)
                guard !table.markdown.isEmpty else { continue }

                if let name { sheetNames.append(name) }
                sections.append(DocumentSection(
                    title: name,
                    kind: .sheet,
                    markdown: table.markdown,
                    sheetName: name,
                    metadata: ["csv": table.csv]
                ))
            }
        }

        guard !sections.isEmpty else { throw PicoDocsError.emptyDocument }
        let title = sheetNames.isEmpty ? info.filename : sheetNames.joined(separator: ", ")
        return ConverterResult(title: title, sections: sections)
    }

    // MARK: - Markdown table

    private static func markdownTable(rows: [Row], sharedStrings: SharedStrings?, sheetName: String?) throws -> (markdown: String, csv: String) {
        let origin = ColumnReference("A")!
        let columnCount = (rows.flatMap(\.cells).map { origin.distance(to: $0.reference.column) }.max() ?? -1) + 1
        guard columnCount > 0 else { return ("", "") }
        let rowCount = rows.map { Int(clamping: $0.reference) }.max() ?? 0
        // Bound dense materialization: sparse files can point at the final Excel
        // coordinate with only a few bytes of XML.
        guard columnCount <= 16_384, rowCount > 0, rowCount <= 1_048_576,
              rowCount <= 1_000_000 / columnCount else { throw PicoDocsError.parsingError }
        var grid: [Int: [String]] = [:]
        for row in rows {
            let rowIndex = Int(clamping: row.reference)
            guard rowIndex > 0 else { throw PicoDocsError.fileCorrupted }
            var values = grid[rowIndex] ?? Array(repeating: "", count: columnCount)
            for cell in row.cells {
                let column = origin.distance(to: cell.reference.column)
                guard column >= 0, column < columnCount else { throw PicoDocsError.fileCorrupted }
                values[column] = cellText(cell, sharedStrings: sharedStrings)
            }
            grid[rowIndex] = values
        }
        var out = "", csvRows: [String] = []
        if let sheetName, !sheetName.isEmpty { out += "## \(sheetName)\n\n" }
        for index in 1...rowCount {
            let values = grid[index] ?? Array(repeating: "", count: columnCount)
            csvRows.append(values.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ","))
            out += "| " + values.map(markdownCell).joined(separator: " | ") + " |\n"
            if index == 1 { out += "| " + Array(repeating: "---", count: columnCount).joined(separator: " | ") + " |\n" }
        }
        return (out, csvRows.joined(separator: "\n"))
    }

    private static func cellText(_ cell: Cell, sharedStrings: SharedStrings?) -> String {
        let raw: String
        if let sharedStrings, let stringValue = cell.stringValue(sharedStrings) {
            raw = stringValue
        } else if let inlineString = cell.inlineString?.text {
            raw = inlineString
        } else if let value = cell.value {
            raw = value
        } else {
            raw = ""
        }
        return SpreadsheetMLText.decode(raw)
    }

    private static func markdownCell(_ raw: String) -> String {
        // Markdown table cells are single-line; escape pipes and flatten newlines
        // (including Windows CRLF and bare CR, common in Excel-on-Windows files).
        let canonical = raw.map { #"\`*_[]<>"#.contains($0) ? "\\" + String($0) : String($0) }.joined()
        return MarkdownTableCell.escapeDelimiters(canonical)
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
