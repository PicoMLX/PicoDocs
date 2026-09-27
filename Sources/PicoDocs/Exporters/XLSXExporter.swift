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
        let result = PicoDocsEngine.withSynthesizedImageReferences(result)

        var sheets: [(name: String, rows: [[String]])] = []
        var usedNames = Set<String>()
        for section in result.sections where section.kind != .image {
            let rows = Self.rows(for: section)
            guard rows.allSatisfy({ $0.allSatisfy { $0.utf16.count <= 32_767 } }) else {
                throw ExporterError.serializationFailed("Worksheet cell exceeds Excel's 32,767-character limit")
            }
            try Self.validateDimensions(rows: rows.count, columns: rows.map(\.count).max() ?? 0)
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
        try pkg.addCoreProperties(result)
        try pkg.addXML("[Content_Types].xml", OOXMLPackageWriter.withCoreContentType(Self.contentTypes(sheetCount: sheets.count)))
        try pkg.addXML("_rels/.rels", OOXMLPackageWriter.withCoreRelationship(Self.rootRels))
        try pkg.addXML("xl/workbook.xml", Self.workbookXML(sheets: sheets))
        try pkg.addXML("xl/_rels/workbook.xml.rels", Self.workbookRels(sheetCount: sheets.count))
        for (i, sheet) in sheets.enumerated() {
            try pkg.addXML("xl/worksheets/sheet\(i + 1).xml", Self.worksheetXML(rows: sheet.rows))
        }
        return try pkg.data()
    }

    static func validateDimensions(rows: Int, columns: Int) throws {
        guard rows >= 0, columns >= 0, rows <= 1_048_576, columns <= 16_384 else {
            throw ExporterError.serializationFailed("Worksheet exceeds SpreadsheetML row or column limits")
        }
        guard columns == 0 || rows <= 1_000_000 / columns else {
            throw ExporterError.serializationFailed("Worksheet exceeds the supported 1,000,000-cell projection budget")
        }
    }

    // MARK: - Rows

    private static func rows(for section: DocumentSection) -> [[String]] {
        if let csv = section.metadata["csv"], !csv.isEmpty {
            return CSVConverter.parseCSV(csv)
        }
        var blocks = MarkdownBlockParser.parse(section.markdown)
        // `SpreadsheetConverter` prefixes each sheet's Markdown with `## <sheetName>`
        // while also carrying the name in `section.sheetName`. Without this guard that
        // redundant title would become cell A1 and push the real data down a row,
        // corrupting an XLSX round-trip. Drop only a *leading* heading that echoes the
        // sheet name/title, and only on `.sheet` sections: a titled body/chapter
        // (`# Intro` under title "Intro") keeps its heading row, as do genuine
        // in-body headings.
        if section.kind == .sheet,
           case .heading(_, let text)? = blocks.first,
           let title = section.sheetName ?? section.title,
           (text == title || plain(text) == title) {
            blocks.removeFirst()
        }
        var rows: [[String]] = []
        for block in blocks {
            switch block {
            case .table(let tableRows):
                // Cells carry inline Markdown (`**Total**`, `[label](url)`); write the
                // visible value, as every other block does, not the syntax.
                rows += tableRows.map { $0.map { MarkdownInlineParser.parse($0, tableCell: true).plainText } }
            case .heading(_, let text):
                rows.append([plain(text)])
            case .paragraph(let text):
                for line in text.components(separatedBy: "\n") where !line.isEmpty {
                    rows.append([plain(line)])
                }
            case .list(let list):
                rows += list.plaintext(inline: plain).components(separatedBy: "\n").map { [$0] }
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
    // MARK: - Sheet naming

    private static func uniqueSheetName(_ section: DocumentSection, index: Int, used: inout Set<String>) -> String {
        let raw = section.sheetName ?? section.title ?? "Sheet\(index)"
        var name = sanitizeSheetName(raw)
        if name.isEmpty { name = "Sheet\(index)" }
        var candidate = name
        var suffix = 2
        while used.contains(candidate.lowercased()) {
            let tail = " (\(suffix))"
            candidate = truncateSheetName(name, limit: 31 - tail.utf16.count) + tail
            suffix += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    private static func truncateSheetName(_ name: String, limit: Int) -> String {
        var result = "", length = 0
        for character in name {
            let text = String(character)
            guard length + text.utf16.count <= limit else { break }
            result += text; length += text.utf16.count
        }
        return result
    }

    /// Excel sheet names: ≤31 UTF-16 units and none of `: \ / ? * [ ]`.
    private static func sanitizeSheetName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: ":\\/?*[]")
        // Map scalars (not characters) so multi-scalar grapheme clusters — flag
        // emoji, skin-tone modifiers, family sequences — survive intact; rebuilding
        // a String from the scalar view re-segments them into single characters.
        let space: Unicode.Scalar = " "
        let cleanedScalars = name.unicodeScalars.filter(OOXMLPackageWriter.isValidXMLScalar).map { invalid.contains($0) || [9, 10, 13].contains($0.value) ? space : $0 }
        let cleaned = String(String.UnicodeScalarView(cleanedScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return truncateSheetName(cleaned, limit: 31).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
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
                cells += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(OOXMLPackageWriter.escape(SpreadsheetMLText.encode(value)).replacingOccurrences(of: "\r", with: "&#13;"))</t></is></c>"
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
