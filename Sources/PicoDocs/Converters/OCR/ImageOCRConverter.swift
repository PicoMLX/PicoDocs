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

        try Task.checkCancellation()
        // Decode + OCR both run off the cooperative pool (see
        // `runOffCooperativePool`); only `Data` in / `String` out crosses the
        // boundary, so no non-Sendable `CGImage` escapes.
        let text = try await VisionOCRService.runOffCooperativePool {
            guard let image = Self.decodeBoundedImage(from: data) else {
                throw PicoDocsError.fileCorrupted
            }
            return try VisionOCRService()
                .recognizeText(in: image)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !text.isEmpty else { throw PicoDocsError.emptyDocument }

        let section = DocumentSection(
            title: info.filename,
            kind: .body,
            markdown: text,
            metadata: ["extractionMethod": "vision-ocr"]
        )
        return ConverterResult(title: info.filename, sections: [section])
    }

    /// Longest-side pixel cap for the decoded image. Mirrors the PDF OCR
    /// fallback's cap so an oversized scan / panorama / TIFF can't allocate an
    /// unbounded bitmap before recognition. Vision has ample detail at this size.
    private static let maxOCRPixelsPerSide = 4000

    /// Decodes `data` to a CGImage that is (a) bounded to `maxOCRPixelsPerSide` on
    /// its longer side and (b) rotated upright per its EXIF orientation.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` (vs. `…CreateImageAtIndex`) lets
    /// ImageIO downsample during decode — so a huge source never fully
    /// materializes — and `…WithTransform` bakes in the orientation tag, without
    /// which camera/phone scans would be OCR'd sideways and return no text.
    /// `…FromImageAlways` decodes from the full image rather than a small embedded
    /// EXIF thumbnail; images already under the cap come back at full resolution.
    private static func decodeBoundedImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxOCRPixelsPerSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
#endif
