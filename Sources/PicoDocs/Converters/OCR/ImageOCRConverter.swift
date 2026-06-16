//
//  ImageOCRConverter.swift
//  PicoDocs
//
//  Converts a standalone image (screenshot, scan, photo) by running on-device
//  Vision OCR over it, making the detector's existing `.image` classification
//  actually convertible. Registered only where Vision is available (see
//  `DocumentConverterRegistry.makeDefault`). Honors `StreamInfo.enableOCR`.
//

#if canImport(Vision)
import Foundation
import CoreGraphics
import ImageIO

public struct ImageOCRConverter: DocumentConverter {

    public init() {}

    public func accepts(_ info: StreamInfo) -> Bool {
        info.detectedFormat == .image
    }

    public func convert(_ data: Data, info: StreamInfo) async throws -> ConverterResult {
        // OCR is the only way to get text out of an image; if the caller disabled
        // it, decline so the input surfaces as unsupported (its pre-OCR behavior)
        // rather than as an empty success.
        guard info.enableOCR else { throw ConverterError.notAccepted }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PicoDocsError.fileCorrupted
        }

        try Task.checkCancellation()
        let text = try VisionOCRService()
            .recognizeText(in: image)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { throw PicoDocsError.emptyDocument }

        let section = DocumentSection(
            title: info.filename,
            kind: .body,
            markdown: text,
            metadata: ["extractionMethod": "vision-ocr"]
        )
        return ConverterResult(title: info.filename, sections: [section])
    }
}
#endif
