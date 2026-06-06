//
//  PicoDocument.swift
//  PicoDocs
//
//  Created by Ronald Mannak on 1/12/25.
//

import Foundation
import UniformTypeIdentifiers

/// A class representing a document in the PicoDocs system.
/// This class manages the document's content, metadata, and relationships with other documents.
@MainActor
@Observable
public class PicoDocument {
    
    /// Represents the current state of the document.
    public enum Status: Equatable {
        /// Document is waiting to be fetched
        case awaitingFetch
        /// Document is currently being processed; the associated value is the
        /// fraction complete in `0...1`.
        case inProgress(fraction: Double)
        /// Document has been successfully downloaded
        case downloaded
        /// Document has been successfully parsed
        case parsed
        /// Document processing failed with an error
        case failed(Error)
        
        public static func == (lhs: PicoDocument.Status, rhs: PicoDocument.Status) -> Bool {
            switch (lhs, rhs) {
            case (.awaitingFetch, .awaitingFetch), (.downloaded, .downloaded), (.parsed, .parsed):
                return true
            case let (.inProgress(lhsFraction), .inProgress(rhsFraction)):
                return lhsFraction == rhsFraction
            case let (.failed(lhsError as NSError), .failed(rhsError as NSError)):
                return lhsError == rhsError
            default:
                return false
            }
        }
    }
    
    /// Unique identifier for the document
    public let id: UUID
    
    /// Status of this document
    public var status: Status = .awaitingFetch
    
    /// Date when the document was last fetched from its source
    public var dateLastFetched: Date?

    // MARK: - Content
    ///
    /// Original binary content of the document before processing.
    public var originalContent: Data?

    /// Content converted to a format suitable for LLM processing.
    ///
    /// Most files will contain a single content item in this array. However, certain file formats
    /// are split into multiple chunks during processing:
    /// - Excel files: Each worksheet is stored separately
    /// - EPub files: Each chapter is stored as a separate entry
    ///
    /// - Note: This property may contain multiple strings if the source document has multiple sections
    public var exportedContent: [String]?

    /// Title of the document
    public var title: String?
    
    /// Author of the document
    public var author: String?
    
    /// Image of the cover of the document (for ePub and iWork documents)
    public var cover: Data?

    // MARK: - File Metadata
    
    /// Origin URL of this file
    public let originURL: URL
    
    /// Uniform Type Identifier representing the file type
    public var utType: UTType
    
    /// Name of the file including its extension
    public let filename: String
    
    /// Date when the document was created
    public var dateCreated: Date?
    
    /// Date when the document was last modified
    public var dateModified: Date?
    
    /// Size of the file in bytes
    public var fileSize: Int64 = 0
    
    // MARK: - Children and parent
    
    /// Reference to the parent document if this is a child document
    public var parent: PicoDocument?
    
    /// Array of child documents if this document contains other documents
    public var children: [PicoDocument]?
        
    // MARK: - Init
    
    /// Creates a new PicoDocument instance
    /// - Parameters:
    ///   - url: The URL where the document is located
    ///   - utType: The uniform type identifier for the document. If nil, it will be inferred from the URL's path extension
    ///   - parent: The parent document if this is a child document
    public init(url: URL, utType: UTType? = nil, parent: PicoDocument? = nil) {

        self.id = UUID()
        self.originURL = url
        
        self.utType = utType ?? UTType(filenameExtension: url.pathExtension) ?? .folder
        self.filename = url.lastPathComponent
        if let parent {
            self.parent = parent
            if parent.children == nil {
                parent.children = []
            }
            parent.children?.append(self)
        }

        if !self.utType.isSupported {
            self.status = .failed(PicoDocsError.documentTypeNotSupported)
        }
    }
}

/// Conformance to Equatable protocol
extension PicoDocument: Equatable {
    nonisolated public static func == (lhs: PicoDocument, rhs: PicoDocument) -> Bool {
        lhs.originURL == rhs.originURL
    }
}

/// Conformance to Hashable protocol
extension PicoDocument: Hashable {
    nonisolated public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Conformance to Identifiable protocol
extension PicoDocument: Identifiable {}

/*
extension PicoDocument: Codable {
    
}
*/
