//
//  ConverterResult.swift
//  PicoDocs
//
//  The canonical, structured output of a `DocumentConverter`. Rendering to a
//  specific `ExportFileType` (Markdown, plaintext, …) is the renderer's job —
//  converters always produce this structured form.
//

import Foundation

public struct ConverterResult: Sendable, Equatable, Codable {

    /// Document title, if the source provided one.
    public var title: String?

    /// Document author, if the source provided one.
    public var author: String?

    /// Cover image data (e.g. EPUB cover), if any.
    public var cover: Data?

    /// The document's content as ordered, provenance-carrying sections.
    public var sections: [DocumentSection]

    public init(
        title: String? = nil,
        author: String? = nil,
        cover: Data? = nil,
        sections: [DocumentSection] = []
    ) {
        self.title = title
        self.author = author
        self.cover = cover
        self.sections = sections
    }

    /// Convenience: the whole document as a single Markdown string.
    public func markdown() -> String {
        sections.map(\.markdown).joined(separator: "\n\n")
    }
}
