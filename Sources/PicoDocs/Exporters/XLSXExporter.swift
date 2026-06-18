//
//  XLSXExporter.swift
//  PicoDocs
//
//  Hand-rolled SpreadsheetML (XLSX) writer — CoreXLSX (the read dependency) cannot
//  write, so this builds the package directly on `OOXMLPackageWriter`. One sheet per
//  document section: a section's lossless `metadata["csv"]` is used when present,
//  otherwise its Markdown is flattened to rows (tables become rows; prose/list/code
//  lines become single-cell rows, mirroring `DocumentRenderer.renderCSV` so nothing
//  is dropped). Cells are emitted as inline strings so values round-trip exactly
//  through `SpreadsheetConverter`; numeric typing is a later refinement.
//

import Foundation

public struct XLSXExporter: DocumentExporter {

    public init() {}

    public func accepts(_ format: ExportableFileType) -> Bool { format == .xlsx }

    public func write(_ result: ConverterResult, format: ExportableFileType) throws -> Data {
        guard format == .xlsx else { throw ExporterError.notAccepted }

        var sheets: [(name: String, rows: [[String]])] = []
        var usedNames = Set<String>()
        for section in result.sections where section.kind != .image {
            let rows = Self.rows(for: section)
            guard !rows.isEmpty else { continue }
            let name = Self.uniqueSheetName(section, index: sheets.count + 1, used: &usedNames)
            sheets.append((name, rows))
        }
        if sheets.isEmpty {
            // The engine guards fully-empty input; this only triggers for content
            // that flattens to nothing. Emit a single empty sheet rather than an
            // invalid (sheet-less) workbook.
            sheets = [("Sheet1", [[""]])]
        }

        var pkg = try OOXMLPackageWriter()
        try pkg.addXML("[Content_Types].xml", Self.contentTypes(sheetCount: sheets.count))
        try pkg.addXML("_rels/.rels", Self.rootRels)
        try pkg.addXML("xl/workbook.xml", Self.workbookXML(sheets: sheets))
        try pkg.addXML("xl/_rels/workbook.xml.rels", Self.workbookRels(sheetCount: sheets.count))
        for (i, sheet) in sheets.enumerated() {
            try pkg.addXML("xl/worksheets/sheet\(i + 1).xml", Self.worksheetXML(rows: sheet.rows))
        }
        return try pkg.data()
    }

    // MARK: - Rows

    private static func rows(for section: DocumentSection) -> [[String]] {
        if let csv = section.metadata["csv"], !csv.isEmpty {
            return parseCSV(csv)
        }
        var rows: [[String]] = []
        for block in MarkdownBlockParser.parse(section.markdown) {
            switch block {
            case .table(let tableRows):
                rows += tableRows
            case .heading(_, let text):
                rows.append([plain(text)])
            case .paragraph(let text):
                for line in text.components(separatedBy: "\n") where !line.isEmpty {
                    rows.append([plain(line)])
                }
            case .list(_, let items):
                for item in items { rows.append([plain(item)]) }
            case .code(let code):
                for line in code.components(separatedBy: "\n") { rows.append([line]) }
            case .blockquote(let lines):
                for line in lines { rows.append([plain(line)]) }
            case .rule:
                continue
            }
        }
        return rows
    }

    private static func plain(_ markdown: String) -> String {
        MarkdownInlineParser.parse(markdown).plainText
    }

    /// Minimal RFC-4180 CSV parser: handles quoted fields with embedded commas,
    /// quotes (`""`), and newlines.
    private static func parseCSV(_ csv: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(csv)
        var i = 0
        func endField() { row.append(field); field = "" }
        func endRow() { endField(); rows.append(row); row = [] }
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 2; continue }
                    inQuotes = false; i += 1; continue
                }
                field.append(c); i += 1
            } else {
                switch c {
                case "\"": inQuotes = true; i += 1
                case ",": endField(); i += 1
                case "\r":
                    if i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                    endRow(); i += 1
                case "\n": endRow(); i += 1
                default: field.append(c); i += 1
                }
            }
        }
        // Flush the trailing field/row unless the input ended exactly on a newline.
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    // MARK: - Sheet naming

    private static func uniqueSheetName(_ section: DocumentSection, index: Int, used: inout Set<String>) -> String {
        let raw = section.sheetName ?? section.title ?? "Sheet\(index)"
        var name = sanitizeSheetName(raw)
        if name.isEmpty { name = "Sheet\(index)" }
        var candidate = name
        var suffix = 2
        while used.contains(candidate.lowercased()) {
            let tail = " (\(suffix))"
            candidate = String(name.prefix(31 - tail.count)) + tail
            suffix += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    /// Excel sheet names: ≤31 chars and none of `: \ / ? * [ ]`.
    private static func sanitizeSheetName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: ":\\/?*[]")
        let cleaned = String(name.unicodeScalars.map { invalid.contains($0) ? Character(" ") : Character($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(31))
    }

    // MARK: - Package parts

    private static let rootRels = OOXMLPackageWriter.xmlDeclaration + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
    </Relationships>
    """

    private static func contentTypes(sheetCount: Int) -> String {
        var overrides = "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
        for i in 1...sheetCount {
            overrides += "<Override PartName=\"/xl/worksheets/sheet\(i).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        return OOXMLPackageWriter.xmlDeclaration + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\(overrides)</Types>
        """
    }

    private static func workbookXML(sheets: [(name: String, rows: [[String]])]) -> String {
        var sheetTags = ""
        for (i, sheet) in sheets.enumerated() {
            sheetTags += "<sheet name=\"\(OOXMLPackageWriter.escapeAttribute(sheet.name))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
        }
        return OOXMLPackageWriter.xmlDeclaration + """
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets>\(sheetTags)</sheets></workbook>
        """
    }

    private static func workbookRels(sheetCount: Int) -> String {
        var rels = ""
        for i in 1...sheetCount {
            rels += "<Relationship Id=\"rId\(i)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i).xml\"/>"
        }
        return OOXMLPackageWriter.xmlDeclaration + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)</Relationships>
        """
    }

    private static func worksheetXML(rows: [[String]]) -> String {
        var data = ""
        for (r, row) in rows.enumerated() {
            let rowNumber = r + 1
            var cells = ""
            for (c, value) in row.enumerated() {
                let ref = "\(columnName(c + 1))\(rowNumber)"
                cells += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(OOXMLPackageWriter.escape(value))</t></is></c>"
            }
            data += "<row r=\"\(rowNumber)\">\(cells)</row>"
        }
        return OOXMLPackageWriter.xmlDeclaration + """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <sheetData>\(data)</sheetData></worksheet>
        """
    }

    /// 1-based column index to its spreadsheet letter (1 -> A, 27 -> AA).
    private static func columnName(_ index: Int) -> String {
        var n = index
        var name = ""
        while n > 0 {
            let remainder = (n - 1) % 26
            name = String(UnicodeScalar(65 + remainder)!) + name
            n = (n - 1) / 26
        }
        return name
    }
}
