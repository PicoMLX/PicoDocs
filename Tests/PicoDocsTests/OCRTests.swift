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
}
#endif
