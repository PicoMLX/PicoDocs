//
//  SpreadsheetConverter.swift
//  PicoDocs
//
//  Converts XLSX workbooks to Markdown tables — one structured section per
//  worksheet, read by the streaming `SpreadsheetMLPackage` reader. Lifts the
//  proven logic from the old ExcelParser into the converter shape. (The xlsx
//  failure in issue #2 was content-type detection, fixed in Phase 0, not the
//  spreadsheet parsing itself.)
//

import Foundation
import ZIPFoundation

public struct SpreadsheetConverter: DocumentConverter {

    public init() {}

    public func accepts(_ info: StreamInfo) -> Bool {
        info.detectedFormat == .xlsx
    }

    public func convert(_ data: Data, info: StreamInfo) async throws -> ConverterResult {
        try Task.checkCancellation()
        guard let archive = ZIPEntryReader.archive(data) else { throw PicoDocsError.fileCorrupted }
        // A metadata-only handle reuses the same root relationship, XML
        // admission, CRC and cancellation policy as DOCX.
        let properties = try WordConverter.coreProperties(archive)
        let package = try SpreadsheetMLPackage(archive: archive)
        let workbook = try package.workbook()
        // A workbook may have no shared-strings part (e.g. numbers-only, or
        // inline strings); don't fail the whole conversion when it's absent.
        let sharedStrings = try package.sharedStrings(at: workbook.sharedStringsPath)

        var sections: [DocumentSection] = []
        var sheetNames: [String] = []
        var projectionBudget = SpreadsheetProjectionBudget()

        for sheet in workbook.sheets {
            try Task.checkCancellation()
            let rows = try package.rows(ofWorksheetAt: sheet.path)
            let table = try Self.markdownTable(rows: rows, sharedStrings: sharedStrings, sheetName: sheet.name, projectionBudget: &projectionBudget)

            if let name = sheet.name { sheetNames.append(name) }
            sections.append(DocumentSection(
                title: sheet.name,
                kind: .sheet,
                markdown: table.markdown,
                sheetName: sheet.name,
                metadata: ["csv": table.csv]
            ))
        }

        guard !sections.isEmpty else { throw PicoDocsError.emptyDocument }
        let title = properties.title ?? (sheetNames.isEmpty ? info.filename : sheetNames.joined(separator: ", "))
        return ConverterResult(title: title, author: properties.author, sections: sections)
    }

    // MARK: - Markdown table

    static func markdownTable(rows: [SpreadsheetRow], sharedStrings: [String], sheetName: String?, projectionBudget: inout SpreadsheetProjectionBudget, isCancelled: () -> Bool = { Task.isCancelled }) throws -> (markdown: String, csv: String) {
        var columnCount = 0, rowCount = 0
        var valueColumnCount = 0, valueRowCount = 0
        try projectionBudget.reservePhysicalRows(rows.count)
        // Both passes below visit every admitted row and cell (up to a million)
        // before `materializeGrid` checks cancellation, so poll as they go.
        var visits = 0
        var seenRows: Set<Int> = []
        for row in rows {
            try checkpoint(&visits, isCancelled)
            guard row.index > 0, row.index <= 1_048_576, seenRows.insert(row.index).inserted else { throw PicoDocsError.fileCorrupted }
            rowCount = max(rowCount, row.index)
            var seenColumns: Set<Int> = []
            for cell in row.cells {
                try checkpoint(&visits, isCancelled)
                let column = cell.column
                // Bound the set before insertion and reject physical duplicates,
                // including empty cells that consume no decoded-value budget.
                guard column >= 0, column < 16_384 else { throw PicoDocsError.parsingError }
                guard seenColumns.insert(column).inserted else { throw PicoDocsError.fileCorrupted }
                columnCount = max(columnCount, column + 1)
                if cell.hasValue {
                    valueRowCount = max(valueRowCount, row.index)
                    valueColumnCount = max(valueColumnCount, column + 1)
                }
            }
        }
        // Styled-but-empty rows and cells keep their positions, unless they would
        // stretch the grid past the dense bound below: spreadsheet apps format
        // whole columns, and LibreOffice often ends a sheet with a formatted
        // `<row r="1048576">`. Then only cells with a value size the grid.
        if columnCount > 0, rowCount > 1_000_000 / columnCount {
            rowCount = valueRowCount
            columnCount = valueColumnCount
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
            try checkpoint(&visits, isCancelled)
            let rowIndex = row.index
            guard rowIndex > 0 else { throw PicoDocsError.fileCorrupted }
            guard rowIndex <= rowCount else { continue }
            var values = grid[rowIndex] ?? Array(repeating: "", count: columnCount)
            for cell in row.cells {
                try checkpoint(&visits, isCancelled)
                // Cells outside a value-sized grid are empty.
                guard cell.hasValue else { continue }
                let column = cell.column
                guard column >= 0, column < columnCount else { throw PicoDocsError.fileCorrupted }
                let value = cellText(cell, sharedStrings: sharedStrings)
                try projectionBudget.reserveValue(value)
                values[column] = value
            }
            grid[rowIndex] = values
        }
        return try materializeGrid(grid, rows: rowCount, columns: columnCount, sheetName: sheetName)
    }

    /// Counts one row or cell visit and polls `isCancelled` every 64 visits.
    private static func checkpoint(_ visits: inout Int, _ isCancelled: () -> Bool) throws {
        visits += 1
        if visits % 64 == 0, isCancelled() { throw CancellationError() }
    }

    static func materializeGrid(_ grid: [Int: [String]], rows rowCount: Int, columns columnCount: Int, sheetName: String?) throws -> (markdown: String, csv: String) {
        try Task.checkCancellation()
        guard rowCount > 0 else { return ("", "") }
        var out = "", csvRows: [String] = []
        if let sheetName, !sheetName.isEmpty { out += "## \(sheetName)\n\n" }
        for index in 1...rowCount {
            if index % 64 == 0 { try Task.checkCancellation() }
            let values = grid[index] ?? Array(repeating: "", count: columnCount)
            csvRows.append(values.map(csvField).joined(separator: ","))
            out += "| " + values.map(markdownCell).joined(separator: " | ") + " |\n"
            if index == 1 { out += "| " + Array(repeating: "---", count: columnCount).joined(separator: " | ") + " |\n" }
        }
        return (out, csvRows.joined(separator: "\n"))
    }

    private static func cellText(_ cell: SpreadsheetCell, sharedStrings: [String]) -> String {
        switch cell.content {
        case .empty:
            return ""
        case .sharedString(let index):
            // Bounds-checked: pre-release Office 2007 files index past the table.
            guard sharedStrings.indices.contains(index) else { return "" }
            return SpreadsheetMLText.decode(sharedStrings[index])
        case .text(let raw):
            return SpreadsheetMLText.decode(raw)
        }
    }

    private static func csvField(_ value: String) -> String {
        guard value.utf8.contains(UInt8(ascii: "\"")) else { return "\"" + value + "\"" }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func markdownCell(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        // Most cells hold no Markdown punctuation, line break or edge whitespace,
        // and one byte scan returns them unchanged: the escaped punctuation is
        // ASCII, and space and tab are the only ASCII members of `.whitespaces`.
        let utf8 = raw.utf8
        if let first = utf8.first, let last = utf8.last,
           first < 0x80, first != 0x20, first != 0x09, last < 0x80, last != 0x20, last != 0x09,
           !utf8.contains(where: needsMarkdownCellRewrite) {
            return raw
        }
        // Markdown table cells are single-line; escape pipes and flatten newlines
        // (including Windows CRLF and bare CR, common in Excel-on-Windows files).
        let canonical = MarkdownLiteral.escapePunctuation(raw, characters: #"\`*_{}[]<>|"#)
        return canonical
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func needsMarkdownCellRewrite(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x0A, 0x0D, UInt8(ascii: "\\"), UInt8(ascii: "`"), UInt8(ascii: "*"), UInt8(ascii: "_"), UInt8(ascii: "{"),
             UInt8(ascii: "}"), UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "<"), UInt8(ascii: ">"), UInt8(ascii: "|"):
            return true
        default:
            return false
        }
    }
}
