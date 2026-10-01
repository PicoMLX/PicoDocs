//
//  NumbersConverter.swift
//  PicoDocs
//
//  Converts Apple Numbers (`.numbers`, iWork '13+) spreadsheets to Markdown,
//  reusing the in-module iWork Archive (IWA) decoder and table reconstruction
//  built for Pages and Keynote. A `.numbers` is the same ZIP/IWA container; its
//  `Document.iwa` holds the TN.DocumentArchive (type 1) whose field 1 lists the
//  sheets in tab order, and each TN.SheetArchive (type 2) carries its name
//  (field 1) and drawables (field 2) — the tables, whose cells live in the
//  `Tables/*.iwa` tiles and datalists.
//
//  Output mirrors SpreadsheetConverter: one `.sheet` section per sheet, headed
//  `## <sheet name>`, holding that sheet's tables as Markdown grids in drawable
//  order. Each table is attributed to the sheet it's reachable from (as Keynote
//  attributes tables to slides). Text boxes, charts, and images on sheets are
//  not extracted.
//

import Foundation
import ZIPFoundation

public struct NumbersConverter: DocumentConverter {

    /// TN.DocumentArchive and TN.SheetArchive message types.
    private static let documentArchiveType: UInt64 = 1
    private static let sheetArchiveType: UInt64 = 2

    public init() {}

    public func accepts(_ info: StreamInfo) -> Bool {
        info.detectedFormat == .numbers
    }

    public func convert(_ data: Data, info: StreamInfo) async throws -> ConverterResult {
        guard let archive = Archive(data: data, accessMode: .read) else {
            throw PicoDocsError.fileCorrupted
        }
        let components = try PagesConverter.iwaComponents(in: archive)
        guard !components.isEmpty else {
            // Likely a legacy iWork '09 package — not supported.
            throw PicoDocsError.documentTypeNotSupported
        }

        // Decompress every component once. The document stream holds the sheet
        // list, so its failure is corruption; auxiliary streams are skipped
        // leniently (a table whose tiles are lost is simply not reconstructed).
        var streams: [[UInt8]] = []
        var documentStream: [UInt8]?
        for component in components {
            try Task.checkCancellation()
            do {
                let stream = try Snappy.decompressIWA(component.bytes)
                if component.name.hasSuffix("Document.iwa") { documentStream = stream }
                streams.append(stream)
            } catch {
                if component.name.hasSuffix("Document.iwa") { throw PicoDocsError.fileCorrupted }
            }
        }
        guard let documentStream else { throw PicoDocsError.fileCorrupted }

        let sheets = Self.sheets(in: IWAArchive.objects(in: documentStream))
        let tablesBySheet = IWATable.tablesBySlide(slideIDs: sheets.map(\.id), in: streams, excludingSubgraphs: [])

        var sections: [DocumentSection] = []
        for sheet in sheets {
            guard let tables = tablesBySheet[sheet.id], !tables.isEmpty else { continue }
            var markdown = tables.joined(separator: "\n\n")
            if let name = sheet.name { markdown = "## \(name)\n\n" + markdown }
            sections.append(DocumentSection(title: sheet.name, kind: .sheet, markdown: markdown, sheetName: sheet.name))
        }
        // Sheets couldn't be resolved (unexpected layout): keep every table
        // rather than dropping the workbook's content.
        if sections.isEmpty {
            sections = IWATable.markdownTables(from: streams).map { DocumentSection(kind: .sheet, markdown: $0) }
        }

        guard !sections.isEmpty else { throw PicoDocsError.emptyDocument }
        let title = (info.filename?.isEmpty == false) ? info.filename : nil
        return ConverterResult(title: title, sections: sections)
    }

    /// The workbook's sheets in tab order: the TN.DocumentArchive's sheet
    /// references (field 1), falling back to the sheet archives' stream order.
    /// Each sheet's name is its archive's field 1.
    static func sheets(in objects: [IWAArchive.Object]) -> [(id: UInt64, name: String?)] {
        let sheetObjects = objects.filter { $0.type == sheetArchiveType }
        let byID = Dictionary(sheetObjects.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })

        var order: [UInt64] = []
        if let document = objects.first(where: { $0.type == documentArchiveType }) {
            var reader = ProtobufReader(document.payload)
            while let field = reader.next() {
                guard field.number == 1, case .length(let reference) = field.value,
                      let id = referencedID(reference), byID[id] != nil, !order.contains(id) else { continue }
                order.append(id)
            }
        }
        if order.isEmpty { order = sheetObjects.map(\.identifier) }
        return order.map { ($0, byID[$0].flatMap(sheetName)) }
    }

    private static func sheetName(_ sheet: IWAArchive.Object) -> String? {
        var reader = ProtobufReader(sheet.payload)
        while let field = reader.next() {
            if field.number == 1, case .length(let bytes) = field.value,
               let name = String(bytes: bytes, encoding: .utf8), !name.isEmpty {
                return name
            }
        }
        return nil
    }

    /// The object id in a TSP.Reference (`{1: identifier}`).
    private static func referencedID(_ bytes: [UInt8]) -> UInt64? {
        var reader = ProtobufReader(bytes)
        while let field = reader.next() {
            if field.number == 1, case .varint(let id) = field.value { return id }
        }
        return nil
    }
}
