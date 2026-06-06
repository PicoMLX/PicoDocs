//
//  DocumentSection.swift
//  PicoDocs
//
//  A single, provenance-carrying chunk of a converted document. Replacing the
//  old `[String]` content model with structured sections keeps citation,
//  chunking, and debugging information attached to the text for RAG use.
//

import Foundation

/// The role a `DocumentSection` plays in its source document.
public enum SectionKind: String, Sendable, Equatable, Codable {
    case body
    case heading
    case paragraph
    case table
    case list
    case code
    case image
    case sheet
    case slide
    case chapter
    case metadata
}

/// One logical piece of a converted document, rendered to Markdown plus the
/// provenance needed to trace it back to the source.
public struct DocumentSection: Sendable, Identifiable, Equatable, Codable {

    public let id: UUID

    /// Optional human-readable title (sheet name, chapter title, heading text).
    public var title: String?

    /// What kind of content this section holds.
    public var kind: SectionKind

    /// The section's content as Markdown (the canonical representation).
    public var markdown: String

    /// Source locator, e.g. a zip entry path or a file path.
    public var sourcePath: String?

    /// Page range in the source (PDF), if applicable.
    public var pageRange: ClosedRange<Int>?

    /// Sheet name (spreadsheets), if applicable.
    public var sheetName: String?

    /// 1-based slide number (presentations), if applicable.
    public var slideNumber: Int?

    /// Free-form structured metadata (e.g. table rows preserved for lossless
    /// CSV export, EXIF fields, etc.).
    public var metadata: [String: String]

    public init(
        id: UUID = UUID(),
        title: String? = nil,
        kind: SectionKind = .body,
        markdown: String,
        sourcePath: String? = nil,
        pageRange: ClosedRange<Int>? = nil,
        sheetName: String? = nil,
        slideNumber: Int? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.markdown = markdown
        self.sourcePath = sourcePath
        self.pageRange = pageRange
        self.sheetName = sheetName
        self.slideNumber = slideNumber
        self.metadata = metadata
    }
}
