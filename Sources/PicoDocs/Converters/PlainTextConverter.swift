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
        case .plainText, .csv, .json, .xml, .unknown, .none:
            return true
        default:
            return false
        }
    }

    public func convert(_ data: Data, info: StreamInfo) async throws -> ConverterResult {
        let encoding = info.charset ?? .utf8
        guard let text = String(data: data, encoding: encoding) ?? String(data: data, encoding: .utf8) else {
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
