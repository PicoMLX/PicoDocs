//
//  PDFConverter.swift
//  PicoDocs
//
//  Extracts text from PDFs via PDFKit, one section per page (carrying pageRange).
//  Pages with no selectable text (scanned / image-only PDFs) fall back to
//  on-device Vision OCR when `StreamInfo.enableOCR` is set and Vision is
//  available; each section records which path produced it in
//  `metadata["extractionMethod"]` ("pdfkit" or "vision-ocr").
//
//  PDFKit is unavailable on tvOS/watchOS, so the whole converter is gated on
//  `canImport(PDFKit)` (the registry skips it where it can't compile).
//

#if canImport(PDFKit)
import Foundation
import PDFKit
#if canImport(Vision)
import CoreGraphics
#endif

public struct PDFConverter: DocumentConverter {

    public init() {}

    public func accepts(_ info: StreamInfo) -> Bool {
        info.detectedFormat == .pdf
    }

    public func convert(_ data: Data, info: StreamInfo) async throws -> ConverterResult {
        guard let document = PDFDocument(data: data) else {
            throw PicoDocsError.fileCorrupted
        }
        // A password-protected PDF parses but stays locked; pages yield no text.
        guard !document.isLocked else {
            throw PicoDocsError.noAccess
        }

        var sections: [DocumentSection] = []
        // First per-page OCR failure, if any (see the OCR fallback below).
        // Surfaced only when nothing else was extracted, so a real Vision error
        // isn't reported as a misleading `emptyDocument`.
        var firstOCRError: Error?
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let pageNumber = index + 1

            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                sections.append(DocumentSection(
                    kind: .body,
                    markdown: text,
                    pageRange: pageNumber...pageNumber,
                    metadata: ["extractionMethod": "pdfkit"]
                ))
                continue
            }

            // No selectable text on this page — likely scanned or exported as an
            // image. Fall back to on-device OCR when enabled and available.
            //
            // Render + recognize run off the cooperative pool (both are
            // synchronous and CPU-heavy). `PDFPage` isn't `Sendable`, so it's
            // transferred into the single off-pool closure via `UnsafeSendableBox`
            // — safe because nothing else touches it meanwhile.
            //
            // Per-page error handling: a Vision failure on one page is recorded
            // and skipped rather than failing the whole document, so one bad page
            // in a long scan doesn't discard all the good ones. If no page yields
            // text and at least one hit a real error, that error is surfaced after
            // the loop (instead of a misleading `emptyDocument`). A legitimate "no
            // legible text" page is an empty string and just skips; an unrenderable
            // page (render → nil → "") skips too. Cancellation still propagates.
            #if canImport(Vision)
            if info.enableOCR {
                let boxedPage = UnsafeSendableBox(page)
                do {
                    let ocrText = try await VisionOCRService.runOffCooperativePool { () throws -> String in
                        guard let image = Self.renderImage(of: boxedPage.value, dpi: Self.ocrRenderDPI) else {
                            return ""
                        }
                        return try VisionOCRService()
                            .recognizeText(in: image)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    // The offload runs on a GCD thread and won't throw on
                    // cancellation; check here so a cancel during OCR is honored
                    // (and caught below) even on the last page.
                    try Task.checkCancellation()
                    if !ocrText.isEmpty {
                        sections.append(DocumentSection(
                            kind: .body,
                            markdown: ocrText,
                            pageRange: pageNumber...pageNumber,
                            metadata: ["extractionMethod": "vision-ocr"]
                        ))
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    firstOCRError = firstOCRError ?? error
                }
            }
            #endif
        }

        if sections.isEmpty {
            // Nothing extracted. If OCR was attempted and genuinely failed,
            // surface that error rather than a misleading "empty document".
            if let firstOCRError { throw firstOCRError }
            throw PicoDocsError.emptyDocument
        }

        let attributes = document.documentAttributes
        let title = (attributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let author = (attributes?[PDFDocumentAttribute.authorAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ConverterResult(
            title: (title?.isEmpty == false) ? title : info.filename,
            author: (author?.isEmpty == false) ? author : nil,
            sections: sections
        )
    }

    #if canImport(Vision)
    /// Render resolution for OCR. 300 DPI is a common scan resolution and gives
    /// Vision ample detail; `renderImage` additionally caps the pixel dimensions
    /// so an unusually large page can't allocate an unbounded bitmap.
    private static let ocrRenderDPI: CGFloat = 300
    private static let maxOCRPixelsPerSide: CGFloat = 4000

    /// Renders `page` to an opaque RGB bitmap at `dpi`, capped to
    /// `maxOCRPixelsPerSide` on the longer side. Uses the crop box (the visible
    /// page) rather than the media box, so trim/bleed or redacted margins outside
    /// the visible area aren't OCR'd into the text; `bounds(for:)` falls back to
    /// the media box when no crop box is set.
    ///
    /// The page's `/Rotate` is honored (`draw(with:to:)` ignores it) by rotating
    /// the finished bitmap — see `rotated(_:clockwiseDegrees:)`. Doing it as a
    /// post-step keeps the proven, test-covered non-rotated draw path untouched,
    /// rather than relying on `transform(_:for:)` whose coordinate/flip behavior
    /// in a raw bottom-left `CGBitmapContext` we can't verify here.
    ///
    /// Internal (not private) so the rotation sizing can be unit-tested.
    static func renderImage(of page: PDFPage, dpi: CGFloat) -> CGImage? {
        let box: PDFDisplayBox = .cropBox
        let bounds = page.bounds(for: box)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let scale = min(dpi / 72.0, maxOCRPixelsPerSide / max(bounds.width, bounds.height))
        let pixelWidth = Int((bounds.width * scale).rounded())
        let pixelHeight = Int((bounds.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0,
              let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }

        // Scanned pages are often unpainted (transparent) where there's no ink;
        // fill white so OCR sees dark-on-light text.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: box, to: context)
        guard let unrotated = context.makeImage() else { return nil }
        return rotated(unrotated, clockwiseDegrees: page.rotation)
    }

    /// Applies a PDF `/Rotate` (clockwise, always a multiple of 90°) to a finished
    /// bitmap. Lossless for quarter turns; any other value returns `image` as-is.
    private static func rotated(_ image: CGImage, clockwiseDegrees: Int) -> CGImage? {
        let degrees = ((clockwiseDegrees % 360) + 360) % 360
        guard degrees == 90 || degrees == 180 || degrees == 270 else { return image }

        let width = image.width, height = image.height
        let quarterTurned = degrees == 90 || degrees == 270
        guard let context = CGContext(
            data: nil,
            width: quarterTurned ? height : width,
            height: quarterTurned ? width : height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }

        // Rotate about the output centre. CGContext.rotate is counter-clockwise for
        // positive angles, so negate for the clockwise `/Rotate`.
        context.translateBy(x: CGFloat(context.width) / 2, y: CGFloat(context.height) / 2)
        context.rotate(by: -CGFloat(degrees) * .pi / 180)
        context.draw(image, in: CGRect(
            x: -CGFloat(width) / 2, y: -CGFloat(height) / 2,
            width: CGFloat(width), height: CGFloat(height)
        ))
        return context.makeImage() ?? image
    }
    #endif
}
#endif
