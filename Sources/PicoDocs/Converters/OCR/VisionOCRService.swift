//
//  VisionOCRService.swift
//  PicoDocs
//
//  On-device OCR via Apple's Vision framework. System-provided, so there is no
//  model bundle or third-party dependency — recognition runs entirely on the
//  device. Shared by `PDFConverter` (fallback for image-only pages) and
//  `ImageOCRConverter` (standalone images). Apple-platform only: the whole file
//  is gated on `canImport(Vision)`.
//

#if canImport(Vision)
import Foundation
import CoreGraphics
import Vision

/// Recognizes text in a `CGImage` using Vision's `VNRecognizeTextRequest`.
///
/// Stateless and `Sendable`. The recognition call is synchronous and
/// CPU-intensive (Vision offers no async variant on the platforms PicoDocs
/// targets), so callers invoke it from inside their own `async`
/// `convert(_:info:)`.
struct VisionOCRService: Sendable {

    /// Recognized text as lines in natural reading order (top-to-bottom, then
    /// left-to-right). Empty when the image holds no legible text.
    func recognizeLines(in image: CGImage, languages: [String]? = nil) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if let languages { request.recognitionLanguages = languages }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        guard let observations = request.results else { return [] }
        // Vision's bounding boxes are normalized (0...1) with a bottom-left
        // origin. Sort top-to-bottom then left-to-right so multi-column or
        // out-of-order observations assemble into a sensible reading order.
        return observations
            .sorted { lhs, rhs in
                let l = lhs.boundingBox, r = rhs.boundingBox
                if abs(l.origin.y - r.origin.y) > 0.012 { return l.origin.y > r.origin.y }
                return l.origin.x < r.origin.x
            }
            .compactMap { $0.topCandidates(1).first?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Recognized text as a single newline-joined string (see `recognizeLines`).
    func recognizeText(in image: CGImage, languages: [String]? = nil) throws -> String {
        try recognizeLines(in: image, languages: languages).joined(separator: "\n")
    }
}
#endif
