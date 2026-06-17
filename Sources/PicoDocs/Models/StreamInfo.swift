//
//  StreamInfo.swift
//  PicoDocs
//
//  Describes an input stream/blob: where it came from and what we think it is.
//  Detection (`ContentTypeDetector`) runs once and stamps `detectedFormat` /
//  `confidence` here, so converters can trust it instead of re-sniffing.
//

import Foundation
import UniformTypeIdentifiers

/// A coarse classification of an input, resolved by `ContentTypeDetector`.
public enum DetectedFormat: String, Sendable, Equatable, Codable, CaseIterable {
    case pdf
    case docx
    case xlsx
    case pptx
    case epub
    case html
    case rtf
    case plainText
    case csv
    case json
    case xml
    case zip
    case image
    case audio
    case unknown
}

/// Metadata about an input passed to converters. A value type so it can cross
/// actor boundaries freely.
public struct StreamInfo: Sendable, Equatable {

    /// Original filename, if known (e.g. "report.docx").
    public var filename: String?

    /// Normalized, lowercased file extension without a leading dot (e.g. "docx").
    public var fileExtension: String?

    /// MIME type from an HTTP response or `UTType.preferredMIMEType`, if known.
    public var mimeType: String?

    /// Best-guess uniform type, if resolvable.
    public var utType: UTType?

    /// Origin URL; drives base-URL resolution for relative links (HTML/EPUB).
    public var url: URL?

    /// Text encoding hint (from HTTP `textEncodingName`, a BOM, or `<meta>`).
    public var charset: String.Encoding?

    /// Format resolved by `ContentTypeDetector`. `nil` until detection has run.
    public var detectedFormat: DetectedFormat?

    /// Confidence in `detectedFormat`: 1.0 for magic-byte matches, lower for
    /// extension/MIME-based guesses.
    public var confidence: Double

    /// Whether HTML conversion should run the Readability extraction pass
    /// (reader-mode: keep the main article, drop nav/ads/boilerplate). Defaults
    /// to `true`; set `false` to convert the full document body verbatim.
    /// Ignored by non-HTML converters.
    public var enhanceReadability: Bool

    /// Whether converters may run on-device OCR (Apple Vision) to recover text
    /// the source doesn't expose as selectable text: image-only / scanned PDF
    /// pages, and standalone images. Defaults to `true`; set `false` to skip OCR
    /// (faster — image inputs then surface as unsupported). No-op where Vision is
    /// unavailable.
    public var enableOCR: Bool

    /// Whether extracted text is run through `UnicodeSanitizer` (NFC + removal of
    /// invisible/control characters, folding Unicode whitespace/line separators to
    /// ASCII). Defaults to `true`; applied by `PicoDocsEngine.convert` to the
    /// result's text. Preserves visible typography (smart quotes, dashes, accents).
    public var sanitizeUnicode: Bool

    public init(
        filename: String? = nil,
        fileExtension: String? = nil,
        mimeType: String? = nil,
        utType: UTType? = nil,
        url: URL? = nil,
        charset: String.Encoding? = nil,
        detectedFormat: DetectedFormat? = nil,
        confidence: Double = 0,
        enhanceReadability: Bool = true,
        enableOCR: Bool = true,
        sanitizeUnicode: Bool = true
    ) {
        self.filename = filename
        self.fileExtension = fileExtension
        self.mimeType = mimeType
        self.utType = utType
        self.url = url
        self.charset = charset
        self.detectedFormat = detectedFormat
        self.confidence = confidence
        self.enhanceReadability = enhanceReadability
        self.enableOCR = enableOCR
        self.sanitizeUnicode = sanitizeUnicode
    }
}
