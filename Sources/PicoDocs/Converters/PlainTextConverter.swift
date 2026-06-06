//
//  PlainTextConverter.swift
//  PicoDocs
//
//  Generic fallback converter. Decodes the input as text and emits it as a
//  single Markdown body section. Registered at generic priority so it only runs
//  after more specific converters decline. (Structure-aware CSV/JSON/XML
//  converters arrive in later phases; for now they fall through to here.)
//

import Foundation

public struct PlainTextConverter: DocumentConverter {

    public init() {}

    public func accepts(_ info: StreamInfo) -> Bool {
        switch info.detectedFormat {
        case .plainText, .csv, .json, .xml:
            return true
        default:
            // Only accept formats positively identified as text. In particular
            // reject .unknown, which can be a NUL-containing binary blob made of
            // otherwise-valid UTF-8 bytes — decoding it would emit garbage into
            // downstream conversion / RAG pipelines.
            return false
        }
    }

    public func convert(_ data: Data, info: StreamInfo) async throws -> ConverterResult {
        let encoding = info.charset ?? .utf8
        // Try the declared encoding, falling back to UTF-8 only when it differs.
        let decoded = String(data: data, encoding: encoding)
            ?? (encoding != .utf8 ? String(data: data, encoding: .utf8) : nil)
        guard let text = decoded else {
            // Not decodable as text — defer to another converter.
            throw ConverterError.notAccepted
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PicoDocsError.emptyDocument
        }
        let section = DocumentSection(title: info.filename, kind: .body, markdown: text)
        return ConverterResult(title: info.filename, sections: [section])
    }
}
