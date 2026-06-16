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
            // A Vision recognition *error* propagates (fails the conversion)
            // rather than being swallowed: that matches the registry's
            // fail-loudly contract and avoids reporting a genuine OCR failure as a
            // misleading `emptyDocument`. A legitimate "no legible text" result is
            // an empty string, not an error, so it correctly skips the page. A
            // page that can't be rasterized at all also skips (render → nil → "").
            #if canImport(Vision)
            if info.enableOCR {
                let boxedPage = UnsafeSendableBox(page)
                let ocrText = try await VisionOCRService.runOffCooperativePool { () throws -> String in
                    guard let image = Self.renderImage(of: boxedPage.value, dpi: Self.ocrRenderDPI) else {
                        return ""
                    }
                    return try VisionOCRService()
                        .recognizeText(in: image)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if !ocrText.isEmpty {
                    sections.append(DocumentSection(
                        kind: .body,
                        markdown: ocrText,
                        pageRange: pageNumber...pageNumber,
                        metadata: ["extractionMethod": "vision-ocr"]
                    ))
                }
            }
            #endif
        }

        guard !sections.isEmpty else { throw PicoDocsError.emptyDocument }

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
    /// the visible area aren't OCR'd into the text. `bounds(for:)` falls back to
    /// the media box when no crop box is set.
    private static func renderImage(of page: PDFPage, dpi: CGFloat) -> CGImage? {
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return nil }

        let scale = min(dpi / 72.0, maxOCRPixelsPerSide / max(box.width, box.height))
        let pixelWidth = Int((box.width * scale).rounded())
        let pixelHeight = Int((box.height * scale).rounded())
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
        context.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }
    #endif
}
#endif
