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
        let attributed = AttributedStringDocumentBuilder.attributedString(from: result)
        var properties: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: NSAttributedString.DocumentType.rtf]
        if let title = result.title { properties[.title] = title }
        if let author = result.author { properties[.author] = author }
        do {
            return try attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: properties
            )
        } catch {
            throw ExporterError.serializationFailed("RTF serialization failed: \(error.localizedDescription)")
        }
    }
}

#endif
