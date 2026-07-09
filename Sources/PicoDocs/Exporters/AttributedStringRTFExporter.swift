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
        do {
            return try attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
        } catch {
            throw ExporterError.serializationFailed("RTF serialization failed: \(error.localizedDescription)")
        }
    }
}

#endif
