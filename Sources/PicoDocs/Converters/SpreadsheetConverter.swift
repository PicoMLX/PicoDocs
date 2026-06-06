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
        // Use the widest row as the column count so ragged rows still produce a
        // valid (rectangular) Markdown table.
        let columnCount = rows.map { $0.cells.count }.max() ?? 0
        guard columnCount > 0 else { return "" }

        var out = ""
        if let sheetName, !sheetName.isEmpty {
            out += "## \(sheetName)\n\n"
        }
        for (index, row) in rows.enumerated() {
            var values = row.cells.map { cellText($0, sharedStrings: sharedStrings) }
            while values.count < columnCount { values.append("") }
            out += "| " + values.joined(separator: " | ") + " |\n"
            if index == 0 {
                out += "| " + Array(repeating: "---", count: columnCount).joined(separator: " | ") + " |\n"
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
        // Markdown table cells are single-line; escape pipes and flatten newlines
        // (including Windows CRLF and bare CR, common in Excel-on-Windows files).
        return raw
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
