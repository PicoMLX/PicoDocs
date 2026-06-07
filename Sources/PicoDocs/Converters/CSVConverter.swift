//
//  CSVConverter.swift
//  PicoDocs
//
//  Converts CSV to a Markdown table (RFC 4180: quoted fields, escaped quotes,
//  embedded commas/newlines). Producing a real table — rather than raw comma
//  lines — gives better Markdown/HTML/CSV exports and round-trips through the
//  CSV renderer. Registered at specific priority so it handles `.csv` ahead of
//  the generic plain-text converter.
//

import Foundation

public struct CSVConverter: DocumentConverter {

    public init() {}

    public func accepts(_ info: StreamInfo) -> Bool {
        info.detectedFormat == .csv
    }

    public func convert(_ data: Data, info: StreamInfo) async throws -> ConverterResult {
        let encoding = info.charset ?? .utf8
        let decoded = String(data: data, encoding: encoding)
            ?? (encoding != .utf8 ? String(data: data, encoding: .utf8) : nil)
        guard let text = decoded else {
            throw ConverterError.decodingFailed
        }
        let rows = Self.parseCSV(text)
        let table = Self.markdownTable(rows)
        guard !table.isEmpty else { throw PicoDocsError.emptyDocument }
        return ConverterResult(
            title: info.filename,
            sections: [DocumentSection(title: info.filename, kind: .table, markdown: table)]
        )
    }

    // MARK: - CSV parsing (RFC 4180)

    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let characters = Array(text)
        var i = 0

        func endField() { row.append(field); field = "" }
        func endRow() { endField(); rows.append(row); row = [] }

        while i < characters.count {
            let character = characters[i]
            if inQuotes {
                if character == "\"" {
                    if i + 1 < characters.count, characters[i + 1] == "\"" {
                        field.append("\"")   // escaped quote ("")
                        i += 2
                    } else {
                        inQuotes = false
                        i += 1
                    }
                } else {
                    field.append(character)
                    i += 1
                }
                continue
            }
            switch character {
            case "\"":
                inQuotes = true
                i += 1
            case ",":
                endField()
                i += 1
            case "\r":
                if i + 1 < characters.count, characters[i + 1] == "\n" { i += 1 }   // CRLF
                endRow()
                i += 1
            case "\n":
                endRow()
                i += 1
            default:
                field.append(character)
                i += 1
            }
        }
        // Flush the final field/row, ignoring a trailing newline's empty row.
        if !field.isEmpty || !row.isEmpty {
            endRow()
        }
        return rows
    }

    // MARK: - Markdown table

    static func markdownTable(_ rows: [[String]]) -> String {
        let columnCount = rows.map(\.count).max() ?? 0
        guard columnCount > 0 else { return "" }

        func cell(_ value: String) -> String {
            value
                .replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        func pad(_ row: [String]) -> [String] {
            row.map(cell) + Array(repeating: "", count: max(0, columnCount - row.count))
        }

        var out = "| " + pad(rows[0]).joined(separator: " | ") + " |\n"
        out += "| " + Array(repeating: "---", count: columnCount).joined(separator: " | ") + " |"
        for row in rows.dropFirst() {
            out += "\n| " + pad(row).joined(separator: " | ") + " |"
        }
        return out
    }
}
