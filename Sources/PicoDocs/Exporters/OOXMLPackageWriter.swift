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

    /// Preserve valid URI escapes while encoding literal percent characters.
    static func relationshipURI(_ target: String) -> String {
        let protected = target.replacingOccurrences(of: "%(?![0-9A-Fa-f]{2})", with: "%25", options: .regularExpression)
        let allowed = CharacterSet.urlFragmentAllowed.union(.urlQueryAllowed).union(.urlPathAllowed)
            .union(CharacterSet(charactersIn: ":/?#[]@!$&'()*+,;=%"))
        return protected.addingPercentEncoding(withAllowedCharacters: allowed) ?? protected
    }

    private var archive: Archive

    init() throws {
        try Task.checkCancellation()
        guard let archive = Archive(data: Data(), accessMode: .create) else {
            throw ExporterError.serializationFailed("Could not create in-memory OOXML archive")
        }
        self.archive = archive
    }

    /// Adds a UTF-8 XML part at `path` (e.g. "word/document.xml").
    mutating func addXML(_ path: String, _ xml: String) throws {
        try Task.checkCancellation()
        let limit = path == "word/numbering.xml" ? 8 * 1024 * 1024 : 32 * 1024 * 1024
        if path.hasPrefix("word/"), xml.utf8.count > limit {
            throw ExporterError.serializationFailed("OOXML part \(path) exceeds the reader-compatible \(limit)-byte limit")
        }
        try addData(path, Data(xml.utf8))
    }

    /// Adds raw bytes at `path` (e.g. an image under "word/media/").
    mutating func addData(_ path: String, _ data: Data) throws {
        try Task.checkCancellation()
        do {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate,
                provider: { position, size in
                    try Task.checkCancellation()
                    // `Int(position)` tolerates either Int/Int64 provider positions.
                    let start = Int(position)
                    let length = Swift.min(size, data.count - start)
                    guard length > 0 else { return Data() }
                    let lower = data.index(data.startIndex, offsetBy: start)
                    let upper = data.index(lower, offsetBy: length)
                    return data.subdata(in: lower..<upper)
                }
            )
            try Task.checkCancellation()
        } catch let error as CancellationError {
            throw error
        } catch {
            throw ExporterError.serializationFailed("Failed to add part \(path): \(error.localizedDescription)")
        }
    }

    /// Finalizes the package into its bytes.
    func data() throws -> Data {
        try Task.checkCancellation()
        guard let data = archive.data else {
            throw ExporterError.serializationFailed("Could not finalize OOXML archive")
        }
        return data
    }

    mutating func addCoreProperties(_ result: ConverterResult, maximumBytes: Int = 32 * 1024 * 1024) throws {
        try addXML("docProps/core.xml", Self.corePropertiesXML(result, maximumBytes: maximumBytes))
    }

    /// Admit the complete serialized UTF-8 part before escaping or retaining it.
    static func corePropertiesXML(_ result: ConverterResult, maximumBytes: Int) throws -> String {
        try Task.checkCancellation()
        let prefix = xmlDeclaration + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\">"
        let suffix = "</cp:coreProperties>"
        var remaining = maximumBytes
        func admit(_ bytes: Int) throws {
            guard bytes <= remaining else { throw ExporterError.serializationFailed("Core properties exceed the reader-compatible metadata limit") }
            remaining -= bytes
        }
        try admit(prefix.utf8.count + suffix.utf8.count)
        for (tag, value) in [("title", result.title), ("creator", result.author)] {
            guard let value else { continue }
            try admit(("<dc:" + tag + "></dc:" + tag + ">").utf8.count)
            for (index, scalar) in value.unicodeScalars.enumerated() {
                if index.isMultiple(of: 4096) { try Task.checkCancellation() }
                guard isValidXMLScalar(scalar) else { continue }
                try admit(scalar == "&" || scalar == "\r" ? 5 : (scalar == "<" || scalar == ">" ? 4 : scalar.utf8.count))
            }
        }
        let title = result.title.map { "<dc:title>\(Self.escape($0).replacingOccurrences(of: "\r", with: "&#13;"))</dc:title>" } ?? ""
        let author = result.author.map { "<dc:creator>\(Self.escape($0).replacingOccurrences(of: "\r", with: "&#13;"))</dc:creator>" } ?? ""
        try Task.checkCancellation()
        return prefix + title + author + suffix
    }

    static func withCoreContentType(_ xml: String) -> String {
        xml.replacingOccurrences(of: "</Types>", with: "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/></Types>")
    }

    static func withCoreRelationship(_ xml: String) -> String {
        xml.replacingOccurrences(of: "</Relationships>", with: "<Relationship Id=\"coreProperties\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/></Relationships>")
    }

    // MARK: - XML helpers

    /// XML standalone declaration used at the top of every part.
    static let xmlDeclaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    /// Document XML drops forbidden scalars; check the same visible input before export.
    static func sanitizedDocument(_ result: ConverterResult) -> ConverterResult {
        let clean = xmlSafeText
        var result = result
        result.title = result.title.map(clean); result.author = result.author.map(clean)
        for index in result.sections.indices {
            // Image identities become generated Markdown labels/destinations too.
            // Clean both sides of that projection without touching encoded media.
            if result.sections[index].kind == .image {
                result.sections[index].title = result.sections[index].title.map(clean)
                result.sections[index].sourcePath = result.sections[index].sourcePath.map(clean)
                continue
            }
            result.sections[index].markdown = clean(result.sections[index].markdown)
            result.sections[index].title = result.sections[index].title.map(clean)
            result.sections[index].sheetName = result.sections[index].sheetName.map(clean)
            if let name = result.sections[index].metadata["sheetName"] { result.sections[index].metadata["sheetName"] = clean(name) }
            if let csv = result.sections[index].metadata["csv"] { result.sections[index].metadata["csv"] = clean(csv) }
        }
        return result
    }

    static func xmlSafeText(_ text: String) -> String {
        var output = ""
        for scalar in text.unicodeScalars where isValidXMLScalar(scalar) { output.unicodeScalars.append(scalar) }
        return output
    }

    /// Escapes text content for an XML element body.
    ///
    /// Also drops scalars that XML 1.0 forbids (most C0 control characters, plus the
    /// surrogate/`FFFE`/`FFFF` ranges). LLM output and text extracted from PDFs can
    /// carry stray `NUL`/vertical-tab/etc.; left in, they'd make `document.xml`,
    /// worksheet, or slide parts non-well-formed and Office would reject the file.
    /// Raw `write(markdown:)` input doesn't pass through `sanitizeUnicode`, so this
    /// is the single choke point that guarantees valid XML bodies.
    static func escape(_ text: String) -> String {
        let sanitized = String(String.UnicodeScalarView(text.unicodeScalars.filter(isValidXMLScalar)))
        return sanitized.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Whether a scalar is allowed in an XML 1.0 document (tab/LF/CR, then the
    /// permitted BMP and supplementary ranges).
    static func isValidXMLScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return v == 0x9 || v == 0xA || v == 0xD ||
            (v >= 0x20 && v <= 0xD7FF) ||
            (v >= 0xE000 && v <= 0xFFFD) ||
            (v >= 0x10000 && v <= 0x10FFFF)
    }

    /// Escapes a value for an XML attribute (adds quote escaping).
    static func escapeAttribute(_ text: String) -> String {
        escape(text)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
