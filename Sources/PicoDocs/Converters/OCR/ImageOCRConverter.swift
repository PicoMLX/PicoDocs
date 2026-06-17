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
import UniformTypeIdentifiers

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

        // Multi-page TIFFs (e.g. scanner output) pack several pages into one file.
        // Other image types — including animated GIF/PNG and multi-image HEIC —
        // are treated as a single image (frame 0) so an animation doesn't emit a
        // section per frame. (Reaching this converter means the detector matched
        // `info.utType` to `.image`, so the concrete type is known here.)
        let isMultiPage = info.utType?.conforms(to: .tiff) ?? false

        try Task.checkCancellation()
        // Decode + OCR run off the cooperative pool (see `runOffCooperativePool`);
        // only `Data` in / `[String]` out crosses the boundary, so no non-Sendable
        // `CGImage` escapes. One element per frame, in source order (may be "").
        let frameTexts = try await VisionOCRService.runOffCooperativePool { () throws -> [String] in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                throw PicoDocsError.fileCorrupted
            }
            let frameCount = isMultiPage ? max(CGImageSourceGetCount(source), 1) : 1
            let service = VisionOCRService()
            return try (0..<frameCount).map { index in
                guard let image = Self.boundedImage(from: source, at: index) else { return "" }
                return try service.recognizeText(in: image)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard frameTexts.contains(where: { !$0.isEmpty }) else {
            throw PicoDocsError.emptyDocument
        }

        let sections: [DocumentSection]
        if frameTexts.count == 1 {
            sections = [DocumentSection(
                title: info.filename,
                kind: .body,
                markdown: frameTexts[0],
                metadata: ["extractionMethod": "vision-ocr"]
            )]
        } else {
            // One section per non-empty frame, carrying its 1-based page index so
            // multi-page sources stay individually addressable (like PDF pages).
            sections = frameTexts.enumerated().compactMap { index, text in
                text.isEmpty ? nil : DocumentSection(
                    kind: .body,
                    markdown: text,
                    pageRange: (index + 1)...(index + 1),
                    metadata: ["extractionMethod": "vision-ocr"]
                )
            }
        }
        return ConverterResult(title: info.filename, sections: sections)
    }

    /// Longest-side pixel cap for the decoded image. Mirrors the PDF OCR
    /// fallback's cap so an oversized scan / panorama / TIFF can't allocate an
    /// unbounded bitmap before recognition. Vision has ample detail at this size.
    private static let maxOCRPixelsPerSide = 4000

    /// Decodes frame `index` of `source` into a CGImage that is (a) bounded to
    /// `maxOCRPixelsPerSide` on its longer side and (b) rotated upright per its
    /// EXIF orientation.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` (vs. `…CreateImageAtIndex`) lets
    /// ImageIO downsample during decode — so a huge source never fully
    /// materializes — and `…WithTransform` bakes in the orientation tag, without
    /// which camera/phone scans would be OCR'd sideways and return no text.
    /// `…FromImageAlways` decodes from the full image rather than a small embedded
    /// EXIF thumbnail; images already under the cap come back at full resolution.
    private static func boundedImage(from source: CGImageSource, at index: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxOCRPixelsPerSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }
}
#endif
