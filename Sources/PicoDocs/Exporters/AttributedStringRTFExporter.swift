//
//  AttributedStringRTFExporter.swift
//  PicoDocs
//
//  Writes RTF (`.rtf`) by building an `NSAttributedString` from the result (see
//  `AttributedStringDocumentBuilder`) and asking Foundation's document writer to
//  serialize it. RTF write support is available across Apple platforms (macOS,
//  iOS, tvOS, visionOS), so this is the lowest-risk binary exporter and round-trips
//  through the existing `RTFConverter`.
//

#if canImport(AppKit) || canImport(UIKit)

import Foundation

public struct AttributedStringRTFExporter: DocumentExporter {

    public init() {}

    public func accepts(_ format: ExportableFileType) -> Bool { format == .rtf }

    public func write(_ result: ConverterResult, format: ExportableFileType) throws -> Data {
        guard format == .rtf else { throw ExporterError.notAccepted }
        try OfficeDocumentBlocks.validateInput(result)
        let attributed = AttributedStringDocumentBuilder.attributedString(from: result, preserveBlockMarkers: true)
        guard attributed.length > 0 else { throw PicoDocsError.emptyDocument }
        var properties: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: NSAttributedString.DocumentType.rtf]
        if let title = result.title { properties[.title] = title }
        if let author = result.author { properties[.author] = author }
        do {
            let data = try attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: properties
            )
            // The writer retains canonical block markers for round trips. Native
            // RTF text has no such provenance and must be escaped as source text.
            guard data.starts(with: Data("{\\rtf".utf8)) else { return data }
            var headerEnd = 5
            while headerEnd < data.count, (0x30...0x39).contains(data[headerEnd]) { headerEnd += 1 }
            var marked = Data(data[..<headerEnd])
            marked.append(Data("{\\*\\picodocsmarkdown1}".utf8))
            marked.append(data[headerEnd...])
            return marked
        } catch {
            throw ExporterError.serializationFailed("RTF serialization failed: \(error.localizedDescription)")
        }
    }
}

#endif
