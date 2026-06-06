//
//  HTMLConverter.swift
//  PicoDocs
//
//  Converts HTML to Markdown via the pure-Swift SwiftSoup walker. Replaces the
//  old behavior where HTML was returned as raw markup (issue #2). Reader-mode
//  cleanup (Readability) is a separate, optional pass added later.
//

import Foundation

public struct HTMLConverter: DocumentConverter {

    public init() {}

    public func accepts(_ info: StreamInfo) -> Bool {
        info.detectedFormat == .html
    }

    public func convert(_ data: Data, info: StreamInfo) async throws -> ConverterResult {
        // Prefer the caller/detector charset, then a document-declared charset
        // (`<meta charset=...>`), then UTF-8.
        let encoding = info.charset ?? Self.sniffHTMLCharset(data) ?? .utf8
        let decoded = String(data: data, encoding: encoding)
            ?? (encoding != .utf8 ? String(data: data, encoding: .utf8) : nil)
        guard let html = decoded else {
            throw ConverterError.decodingFailed
        }

        let (title, markdown) = try HTMLToMarkdown.convert(html: html, baseURI: info.url?.absoluteString)
        guard !markdown.isEmpty else {
            throw PicoDocsError.emptyDocument
        }

        let section = DocumentSection(title: title, kind: .body, markdown: markdown)
        return ConverterResult(title: title, sections: [section])
    }

    /// Sniffs a document-declared charset (`<meta charset="...">` or
    /// `<meta http-equiv="Content-Type" content="...; charset=...">`) from the
    /// raw bytes, so non-UTF-8 HTML that declares its encoding internally decodes
    /// correctly. Reads a Latin-1 view of the head (which always succeeds) to
    /// locate the declaration without needing the encoding up front.
    static func sniffHTMLCharset(_ data: Data) -> String.Encoding? {
        guard let head = String(data: data.prefix(2048), encoding: .isoLatin1) else { return nil }
        let lower = head.lowercased()
        guard let range = lower.range(of: "charset=") else { return nil }
        let name = lower[range.upperBound...]
            .drop { $0 == "\"" || $0 == "'" || $0 == " " }
            .prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        guard !name.isEmpty else { return nil }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(String(name) as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }
}
