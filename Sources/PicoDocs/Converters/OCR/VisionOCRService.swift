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
/// targets — the async `RecognizeTextRequest` is iOS 18 / macOS 15, past our
/// deployment floor), so callers run it via `runOffCooperativePool` to keep the
/// blocking work off the Swift concurrency cooperative thread pool.
struct VisionOCRService: Sendable {

    /// Discretizes Vision's normalized (0...1) y-coordinate into fixed rows so
    /// observations on the same visual line group together. Also the minimum y
    /// gap that counts as a new line.
    private static let rowHeight: CGFloat = 0.012

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
        //
        // y is bucketed into discrete rows rather than compared with an epsilon
        // (`abs(a.y - b.y) > threshold`): an epsilon compare is NOT transitive
        // (a≈b, b≈c, but a≉c) and so isn't the strict weak ordering `sorted(by:)`
        // requires — violating it is undefined behavior and can trap. Bucketing
        // sorts by the tuple (row, x), which is a proper ordering.
        let rowHeight = Self.rowHeight
        return observations
            .sorted { lhs, rhs in
                let l = lhs.boundingBox, r = rhs.boundingBox
                let rowL = (l.origin.y / rowHeight).rounded(.down)
                let rowR = (r.origin.y / rowHeight).rounded(.down)
                if rowL != rowR { return rowL > rowR }   // higher y first (top of page)
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

    /// Runs synchronous, CPU-bound OCR work (image decode / page rasterization +
    /// Vision recognition) on a background dispatch queue, bridged back via a
    /// checked continuation.
    ///
    /// `VNImageRequestHandler.perform` is synchronous and can run for hundreds of
    /// ms to seconds. Calling it directly from an `async` converter would occupy
    /// a cooperative thread-pool thread for that whole duration; the pool is
    /// width-limited (~core count), so under concurrent/batch conversion that can
    /// starve unrelated tasks. Offloading keeps the pool responsive. The decode /
    /// rasterization belongs inside `work` too, so that heavy step is off-pool as
    /// well and only `Sendable` values cross the boundary.
    static func runOffCooperativePool<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result(catching: work))
            }
        }
    }
}

/// Hands a non-`Sendable` value to a single background closure. Safe because the
/// value is transferred, not shared: it is read by exactly one
/// `runOffCooperativePool` closure and never touched concurrently. Used to pass a
/// `PDFPage` (PDFKit types aren't `Sendable`) into the off-pool OCR closure.
struct UnsafeSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
#endif
