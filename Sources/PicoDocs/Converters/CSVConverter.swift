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
        // A single-line Markdown table cell is great for display/RAG but can't
        // hold embedded newlines or leading/trailing spaces. Keep a lossless,
        // canonical CSV serialization in metadata so CSV export round-trips those
        // values exactly (the renderer prefers it over re-parsing the table).
        let section = DocumentSection(
            title: info.filename,
            kind: .table,
            markdown: table,
            metadata: ["csv": Self.serializeCSV(rows)]
        )
        return ConverterResult(title: info.filename, sections: [section])
    }

    /// Serializes rows to canonical RFC 4180 CSV (quoting fields that contain a
    /// comma, quote, or newline), preserving cell values exactly.
    static func serializeCSV(_ rows: [[String]]) -> String {
        rows.map { row in row.map(csvField).joined(separator: ",") }.joined(separator: "\n")
    }

    private static func csvField(_ value: String) -> String {
        // Quote on delimiters/quotes/newlines, and also on leading/trailing
        // whitespace (otherwise parsers that strip unquoted fields would drop it).
        let hasEdgeWhitespace = value.first == " " || value.last == " "
            || value.first == "\t" || value.last == "\t"
        if hasEdgeWhitespace
            || value.contains(",") || value.contains("\"")
            || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    // MARK: - CSV parsing (RFC 4180)

    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        // Whether the current record has begun a field (content, a quote, or a
        // comma). Distinguishes a real final empty field (e.g. a closing `""`)
        // from "nothing after the last newline", which must not be emitted.
        var fieldStarted = false

        // Iterate the unicode-scalar view (delimiters are ASCII) rather than
        // materializing a `[Character]`, to avoid a full copy of large inputs.
        let scalars = text.unicodeScalars
        var index = scalars.startIndex

        func endField() { row.append(field); field = "" }
        func endRow() { endField(); rows.append(row); row = []; fieldStarted = false }

        while index < scalars.endIndex {
            let scalar = scalars[index]
            if inQuotes {
                fieldStarted = true
                if scalar == "\"" {
                    let next = scalars.index(after: index)
                    if next < scalars.endIndex, scalars[next] == "\"" {
                        field.unicodeScalars.append("\"")   // escaped quote ("")
                        index = scalars.index(after: next)
                    } else {
                        inQuotes = false
                        index = next
                    }
                } else {
                    field.unicodeScalars.append(scalar)
                    index = scalars.index(after: index)
                }
                continue
            }
            switch scalar {
            case "\"":
                inQuotes = true
                fieldStarted = true
                index = scalars.index(after: index)
            case ",":
                fieldStarted = true
                endField()
                index = scalars.index(after: index)
            case "\r":
                endRow()
                let next = scalars.index(after: index)
                index = (next < scalars.endIndex && scalars[next] == "\n")   // CRLF
                    ? scalars.index(after: next) : next
            case "\n":
                endRow()
                index = scalars.index(after: index)
            default:
                fieldStarted = true
                field.unicodeScalars.append(scalar)
                index = scalars.index(after: index)
            }
        }
        // Flush the final record, but skip a phantom row from a trailing newline
        // (nothing started since the last row end).
        if fieldStarted || !field.isEmpty || !row.isEmpty {
            endRow()
        }
        return rows
    }

    // MARK: - Markdown table

    static func markdownTable(_ rows: [[String]]) -> String {
        let columnCount = rows.map(\.count).max() ?? 0
        guard columnCount > 0 else { return "" }

        func cell(_ value: String) -> String {
            MarkdownTableCell.escapeDelimiters(value)
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
