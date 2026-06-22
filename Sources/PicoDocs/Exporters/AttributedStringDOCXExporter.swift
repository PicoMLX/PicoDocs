//
//  AttributedStringDOCXExporter.swift
//  PicoDocs
//
//  An *optional, opt-in* DOCX writer that uses Apple's `NSAttributedString`
//  `.officeOpenXML` serializer (macOS only). It is intentionally NOT registered in
//  `DocumentExporterRegistry.default`: the hand-rolled `WordprocessingMLExporter`
//  is the primary, all-platform DOCX writer and the round-trip oracle. The repo
//  already moved *off* the `NSAttributedString` DOCX path on the read side because
//  it was "lossy, font-size heading guessing, and a hard throw on iOS"
//  (`WordConverter.swift`), so this is kept only for opt-in use and comparison
//  testing — register it explicitly via `registry.registering(...)` if you want it.
//
//  `.officeOpenXML` writing is macOS-only; on other Apple platforms this throws
//  `.platformUnavailable` so a registry can fall through.
//

#if canImport(AppKit) || canImport(UIKit)

import Foundation

public struct AttributedStringDOCXExporter: DocumentExporter {

    public init() {}

    public func accepts(_ format: ExportableFileType) -> Bool { format == .docx }

    public func write(_ result: ConverterResult, format: ExportableFileType) throws -> Data {
        guard format == .docx else { throw ExporterError.notAccepted }
        #if canImport(AppKit)
        let attributed = AttributedStringDocumentBuilder.attributedString(from: result)
        do {
            return try attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
            )
        } catch {
            throw ExporterError.serializationFailed("DOCX (officeOpenXML) serialization failed: \(error.localizedDescription)")
        }
        #else
        // officeOpenXML writing is unavailable on iOS/tvOS/visionOS.
        throw ExporterError.platformUnavailable
        #endif
    }
}

#endif
