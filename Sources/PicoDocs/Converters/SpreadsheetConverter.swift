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

                let markdown = Self.markdownTable(rows: rows, sharedStrings: sharedStrings, sheetName: name)
                guard !markdown.isEmpty else { continue }

                if let name { sheetNames.append(name) }
                sections.append(DocumentSection(
                    title: name,
                    kind: .sheet,
                    markdown: markdown,
                    sheetName: name
                ))
            }
        }

        guard !sections.isEmpty else { throw PicoDocsError.emptyDocument }
        let title = sheetNames.isEmpty ? info.filename : sheetNames.joined(separator: ", ")
        return ConverterResult(title: title, sections: sections)
    }

    // MARK: - Markdown table

    private static func markdownTable(rows: [Row], sharedStrings: SharedStrings?, sheetName: String?) -> String {
        // Worksheet rows are sparse: a blank cell is simply absent from `<row>`, so
        // a cell's column comes from its reference (`C3`), not its position in the
        // row — placing cells by position shifts every value after a gap into the
        // wrong column. Columns and rows that are empty throughout are dropped, so
        // the table stays compact (a stray value in column XFD doesn't produce
        // thousands of empty columns) while every value keeps its column.
        let origin = ColumnReference("A")!
        var grid: [[(column: Int, text: String)]] = []
        var usedColumns = Set<Int>()
        for row in rows {
            var cells: [(column: Int, text: String)] = []
            for cell in row.cells {
                let text = cellText(cell, sharedStrings: sharedStrings)
                guard !text.isEmpty else { continue }
                let column = origin.distance(to: cell.reference.column)
                cells.append((column, text))
                usedColumns.insert(column)
            }
            if !cells.isEmpty { grid.append(cells) }
        }
        let columns = usedColumns.sorted()
        guard !columns.isEmpty else { return "" }
        let position = Dictionary(uniqueKeysWithValues: columns.enumerated().map { ($1, $0) })

        var out = ""
        if let sheetName, !sheetName.isEmpty {
            out += "## \(sheetName)\n\n"
        }
        for (index, cells) in grid.enumerated() {
            var values = Array(repeating: "", count: columns.count)
            for cell in cells { values[position[cell.column]!] = cell.text }
            out += "| " + values.joined(separator: " | ") + " |\n"
            if index == 0 {
                out += "| " + Array(repeating: "---", count: columns.count).joined(separator: " | ") + " |\n"
            }
        }
        return out
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
        // Spreadsheet values are literal; escape inline syntax and table pipes, then flatten newlines
        // (including Windows CRLF and bare CR, common in Excel-on-Windows files).
        return raw.map { #"\`*_{}[]<>()#+-.!|"#.contains($0) ? "\\" + String($0) : String($0) }.joined()
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
