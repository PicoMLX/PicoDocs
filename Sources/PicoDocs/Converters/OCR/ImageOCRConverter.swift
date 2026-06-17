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

        // Frame count. Only a multi-page container needs a peek; a single image is
        // always one frame, so the common path skips this extra hop.
        let frameCount: Int
        if isMultiPage {
            try Task.checkCancellation()
            frameCount = try await VisionOCRService.runOffCooperativePool { () throws -> Int in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                    throw PicoDocsError.fileCorrupted
                }
                return max(CGImageSourceGetCount(source), 1)
            }
        } else {
            frameCount = 1
        }

        // Each frame's decode + OCR runs off the cooperative pool (see
        // `runOffCooperativePool`); looping here in the async context — rather than
        // inside one offload — lets cancellation be checked between frames (the
        // offloaded work runs on a GCD thread, where `Task.checkCancellation()`
        // can't see cancellation). A per-frame failure is recorded and skipped so
        // one bad page of a multi-page TIFF doesn't lose the rest; a real error is
        // surfaced only when nothing at all was recognized (which also covers a
        // single image that simply failed). One element per frame (may be "").
        var frameTexts: [String] = []
        var firstError: Error?
        for index in 0..<frameCount {
            try Task.checkCancellation()
            do {
                let text = try await VisionOCRService.runOffCooperativePool { () throws -> String in
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                        throw PicoDocsError.fileCorrupted
                    }
                    guard let image = Self.boundedImage(from: source, at: index) else { return "" }
                    return try VisionOCRService().recognizeText(in: image)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                try Task.checkCancellation()
                frameTexts.append(text)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                firstError = firstError ?? error
                frameTexts.append("")
            }
        }

        if frameTexts.allSatisfy({ $0.isEmpty }), let firstError {
            throw firstError
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
