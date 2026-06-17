//
//  OCRTests.swift
//  PicoDocsTests
//
//  On-device Vision OCR: the standalone image converter and the PDF fallback for
//  image-only pages. Fixtures are generated in-process (text rendered to a
//  bitmap, and an image-only PDF) so the expected text is known and no binaries
//  are committed. Gated on `canImport(Vision)` — these only build/run on Apple
//  platforms where Vision is available (the CI target, macOS).
//

#if canImport(Vision)
import Foundation
import Testing
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
#if canImport(PDFKit)
import PDFKit
#endif
@testable import PicoDocs

@Suite("OCR (Vision)")
struct OCRTests {

    @Test("Image OCR converter extracts text from an image")
    func imageOCR() async throws {
        let png = Self.pngData(Self.makeTextImage("Hello Vision World"))
        let result = try await PicoDocsEngine.convert(data: png, filename: "scan.png")
        let md = result.markdown()
        #expect(md.localizedCaseInsensitiveContains("Hello"))
        #expect(md.localizedCaseInsensitiveContains("World"))
        #expect(result.sections.first?.metadata["extractionMethod"] == "vision-ocr")
    }

    @Test("Image input with OCR disabled surfaces as unsupported")
    func imageOCRDisabled() async throws {
        let png = Self.pngData(Self.makeTextImage("Hello Vision World"))
        await #expect(throws: PicoDocsError.self) {
            _ = try await PicoDocsEngine.convert(data: png, filename: "scan.png", enableOCR: false)
        }
    }

    @Test("Multi-page TIFF OCRs every page, not just the first")
    func multiPageTIFF() async throws {
        let tiff = Self.tiffData([
            Self.makeTextImage("First TIFF Page"),
            Self.makeTextImage("Second TIFF Page"),
        ])
        let result = try await PicoDocsEngine.convert(data: tiff, filename: "scan.tiff")
        let md = result.markdown()
        #expect(md.localizedCaseInsensitiveContains("First"))
        #expect(md.localizedCaseInsensitiveContains("Second"))
        // One section per page (vs. the single-frame path's one section).
        #expect(result.sections.filter { $0.metadata["extractionMethod"] == "vision-ocr" }.count >= 2)
    }

    #if canImport(PDFKit)
    @Test("PDF OCR fallback recovers text from an image-only page")
    func pdfOCRFallback() async throws {
        let pdf = Self.imageOnlyPDF(Self.makeTextImage("Scanned Invoice Page"))
        let result = try await PicoDocsEngine.convert(data: pdf, filename: "scan.pdf")
        let md = result.markdown()
        #expect(md.localizedCaseInsensitiveContains("Invoice"))
        #expect(md.localizedCaseInsensitiveContains("Page"))
        #expect(result.sections.contains { $0.metadata["extractionMethod"] == "vision-ocr" })
    }

    @Test("Image-only PDF with OCR disabled yields no text")
    func pdfOCRDisabled() async throws {
        let pdf = Self.imageOnlyPDF(Self.makeTextImage("Scanned Invoice Page"))
        await #expect(throws: PicoDocsError.self) {
            _ = try await PicoDocsEngine.convert(data: pdf, filename: "scan.pdf", enableOCR: false)
        }
    }

    @Test("PDF mixes a selectable-text page with an OCR'd image-only page")
    func pdfMixedPages() async throws {
        let pdf = Self.textThenImagePDF(
            text: "Selectable Layer Text",
            image: Self.makeTextImage("Scanned Second Page")
        )
        let result = try await PicoDocsEngine.convert(data: pdf, filename: "mixed.pdf")
        let methods = Set(result.sections.compactMap { $0.metadata["extractionMethod"] })
        #expect(methods.contains("pdfkit"))
        #expect(methods.contains("vision-ocr"))
        let md = result.markdown()
        #expect(md.localizedCaseInsensitiveContains("Selectable"))
        #expect(md.localizedCaseInsensitiveContains("Scanned"))
    }

    @Test("PDF OCR renders the crop box, ignoring content outside it")
    func pdfCropBox() async throws {
        // "VISIBLE" in the bottom half, "HIDDEN" in the top half (origin bottom-left).
        let image = Self.makeStackedImage(lower: "VISIBLE", upper: "HIDDEN")
        let document = PDFDocument(data: Self.imageOnlyPDF(image))!
        let page = document.page(at: 0)!
        // Crop to the bottom half, excluding the upper "HIDDEN".
        page.setBounds(
            CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height / 2)),
            for: .cropBox
        )
        let cropped = document.dataRepresentation()!

        let md = try await PicoDocsEngine.convert(data: cropped, filename: "cropped.pdf").markdown()
        #expect(md.localizedCaseInsensitiveContains("VISIBLE"))
        #expect(!md.localizedCaseInsensitiveContains("HIDDEN"))
    }

    @Test("PDF page rotation swaps the rendered OCR bitmap dimensions")
    func pdfRotationRendersSwappedDimensions() throws {
        // 4:1 landscape page; rotating 90° must yield a portrait OCR bitmap. Without
        // honoring the page rotation the bitmap stays landscape and clips content.
        let document = PDFDocument(data: Self.imageOnlyPDF(Self.makeTextImage("X", width: 800, height: 200)))!
        let page = document.page(at: 0)!

        let upright = try #require(PDFConverter.renderImage(of: page, dpi: 72))
        #expect(upright.width > upright.height)

        page.rotation = 90
        let rotated = try #require(PDFConverter.renderImage(of: page, dpi: 72))
        #expect(rotated.height > rotated.width)
    }
    #endif

    // MARK: - Fixture generation

    /// Renders `text` as crisp black-on-white into a CGImage (origin bottom-left).
    private static func makeTextImage(_ text: String, width: Int = 1000, height: Int = 260, fontSize: CGFloat = 72) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1),
        ]
        let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 30, y: CGFloat(height) / 2 - fontSize / 3)
        CTLineDraw(line, context)
        return context.makeImage()!
    }

    /// PNG-encodes a CGImage.
    private static func pngData(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        _ = CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// Builds a single-page PDF whose only content is `image` — no text layer, so
    /// PDFKit extraction comes up empty and the OCR fallback runs.
    private static func imageOnlyPDF(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        var mediaBox = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        context.beginPDFPage(nil)
        context.draw(image, in: mediaBox)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// Encodes `pages` as a single multi-page TIFF.
    private static func tiffData(_ pages: [CGImage]) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.tiff.identifier as CFString, pages.count, nil
        )!
        for page in pages { CGImageDestinationAddImage(destination, page, nil) }
        _ = CGImageDestinationFinalize(destination)
        return data as Data
    }

    #if canImport(PDFKit)
    /// Two-page PDF: page 1 is a real selectable-text layer (drawn with CoreText,
    /// so `PDFPage.string` extracts it), page 2 is image-only (forces OCR).
    private static func textThenImagePDF(text: String, image: CGImage) -> Data {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        var mediaBox = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!

        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1),
        ]
        let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 40, y: mediaBox.height / 2)
        CTLineDraw(line, context)
        context.endPDFPage()

        context.beginPDFPage(nil)
        context.draw(image, in: mediaBox)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// Image with `lower` text in the bottom half and `upper` in the top half
    /// (origin bottom-left), so a crop box over the bottom half excludes `upper`.
    private static func makeStackedImage(lower: String, upper: String, width: Int = 1000, halfHeight: Int = 260, fontSize: CGFloat = 72) -> CGImage {
        let height = halfHeight * 2
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        func draw(_ string: String, baselineY: CGFloat) {
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1),
            ]
            let attributed = CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary)!
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 30, y: baselineY)
            CTLineDraw(line, context)
        }
        let half = CGFloat(halfHeight)
        draw(lower, baselineY: half / 2 - fontSize / 3)         // bottom half
        draw(upper, baselineY: half + half / 2 - fontSize / 3)  // top half
        return context.makeImage()!
    }
    #endif
}
#endif
