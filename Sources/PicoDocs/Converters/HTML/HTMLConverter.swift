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
        let encoding = info.charset ?? .utf8
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
}
