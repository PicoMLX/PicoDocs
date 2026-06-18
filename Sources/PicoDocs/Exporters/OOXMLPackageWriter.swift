//
//  OOXMLPackageWriter.swift
//  PicoDocs
//
//  A tiny in-memory wrapper over ZIPFoundation's write mode, shared by the OOXML
//  exporters (DOCX/XLSX/PPTX). OOXML files are a ZIP ("package") of XML "parts"
//  plus media; this assembles one entirely in memory (no temp files), which keeps
//  the exporters' `write(...) -> Data` pure and usable from any context.
//
//  The read side (`WordConverter`/`EPUBConverter`) opens archives with
//  `Archive(data:accessMode:.read)`; this is the symmetric `.create` path.
//

import Foundation
import ZIPFoundation

struct OOXMLPackageWriter {

    private var archive: Archive

    init() throws {
        guard let archive = Archive(data: Data(), accessMode: .create) else {
            throw ExporterError.serializationFailed("Could not create in-memory OOXML archive")
        }
        self.archive = archive
    }

    /// Adds a UTF-8 XML part at `path` (e.g. "word/document.xml").
    mutating func addXML(_ path: String, _ xml: String) throws {
        try addData(path, Data(xml.utf8))
    }

    /// Adds raw bytes at `path` (e.g. an image under "word/media/").
    mutating func addData(_ path: String, _ data: Data) throws {
        do {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate,
                provider: { position, size in
                    // `Int(position)` tolerates either Int/Int64 provider positions.
                    let start = Int(position)
                    let length = Swift.min(size, data.count - start)
                    guard length > 0 else { return Data() }
                    let lower = data.index(data.startIndex, offsetBy: start)
                    let upper = data.index(lower, offsetBy: length)
                    return data.subdata(in: lower..<upper)
                }
            )
        } catch {
            throw ExporterError.serializationFailed("Failed to add part \(path): \(error.localizedDescription)")
        }
    }

    /// Finalizes the package into its bytes.
    func data() throws -> Data {
        guard let data = archive.data else {
            throw ExporterError.serializationFailed("Could not finalize OOXML archive")
        }
        return data
    }

    // MARK: - XML helpers

    /// XML standalone declaration used at the top of every part.
    static let xmlDeclaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    /// Escapes text content for an XML element body.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Escapes a value for an XML attribute (adds quote escaping).
    static func escapeAttribute(_ text: String) -> String {
        escape(text)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
