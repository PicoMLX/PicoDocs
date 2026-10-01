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
        var projectionBudget = SpreadsheetProjectionBudget()

        for workbook in try file.parseWorkbooks() {
            for (name, path) in try file.parseWorksheetPathsAndNames(workbook: workbook) {
                try Task.checkCancellation()
                let worksheet = try file.parseWorksheet(at: path)
                let rows = worksheet.data?.rows ?? []

                let table = try Self.markdownTable(rows: rows, sharedStrings: sharedStrings, sheetName: name, projectionBudget: &projectionBudget)

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

    private static func markdownTable(rows: [Row], sharedStrings: SharedStrings?, sheetName: String?, projectionBudget: inout SpreadsheetProjectionBudget) throws -> (markdown: String, csv: String) {
        let origin = ColumnReference("A")!
        var columnCount = 0, rowCount = 0
        try projectionBudget.reservePhysicalRows(rows.count)
        var seenRows: Set<UInt> = []
        for row in rows {
            guard row.reference > 0, row.reference <= 1_048_576, seenRows.insert(row.reference).inserted else { throw PicoDocsError.fileCorrupted }
            rowCount = max(rowCount, Int(clamping: row.reference))
            var seenColumns: Set<Int> = []
            for cell in row.cells {
                guard cell.reference.row == row.reference else { throw PicoDocsError.fileCorrupted }
                let column = origin.distance(to: cell.reference.column)
                // Bound the set before insertion and reject physical duplicates,
                // including empty cells that consume no decoded-value budget.
                guard column >= 0, column < 16_384 else { throw PicoDocsError.parsingError }
                guard seenColumns.insert(column).inserted else { throw PicoDocsError.fileCorrupted }
                columnCount = max(columnCount, column + 1)
            }
        }
        guard columnCount > 0 else {
            try projectionBudget.reserveGrid(rows: 0, columns: 0, name: sheetName)
            return ("", "")
        }
        // Bound dense materialization: sparse files can point at the final Excel
        // coordinate with only a few bytes of XML.
        guard columnCount <= 16_384, rowCount > 0, rowCount <= 1_048_576,
              rowCount <= 1_000_000 / columnCount else { throw PicoDocsError.parsingError }
        // Reserve both serialized projections plus the decoded cell storage before
        // expanding repeated shared strings. The budget is shared by all sheets.
        try projectionBudget.reserveGrid(rows: rowCount, columns: columnCount, name: sheetName)
        // Imported grids must fit the same retained storage used when re-exported.
        try projectionBudget.reserveWriterStorage(rows: rowCount, columns: columnCount)
        var grid: [Int: [String]] = [:]
        for row in rows {
            let rowIndex = Int(clamping: row.reference)
            guard rowIndex > 0 else { throw PicoDocsError.fileCorrupted }
            var values = grid[rowIndex] ?? Array(repeating: "", count: columnCount)
            for cell in row.cells {
                let column = origin.distance(to: cell.reference.column)
                guard column >= 0, column < columnCount else { throw PicoDocsError.fileCorrupted }
                let value = cellText(cell, sharedStrings: sharedStrings)
                try projectionBudget.reserveValue(value)
                values[column] = value
            }
            grid[rowIndex] = values
        }
        return try materializeGrid(grid, rows: rowCount, columns: columnCount, sheetName: sheetName)
    }

    static func materializeGrid(_ grid: [Int: [String]], rows rowCount: Int, columns columnCount: Int, sheetName: String?) throws -> (markdown: String, csv: String) {
        try Task.checkCancellation()
        guard rowCount > 0 else { return ("", "") }
        var out = "", csvRows: [String] = []
        if let sheetName, !sheetName.isEmpty { out += "## \(sheetName)\n\n" }
        for index in 1...rowCount {
            if index % 64 == 0 { try Task.checkCancellation() }
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
        let canonical = MarkdownLiteral.escapePunctuation(raw, characters: #"\`*_{}[]<>|"#)
        return canonical
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
