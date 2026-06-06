//
//  PDFConverter.swift
//  PicoDocs
//
//  Extracts text from PDFs via PDFKit, one section per page (carrying pageRange).
//  PDFKit is unavailable on tvOS/watchOS, so the whole converter is gated on
//  `canImport(PDFKit)` (the registry skips it where it can't compile).
//

#if canImport(PDFKit)
import Foundation
import PDFKit

public struct PDFConverter: DocumentConverter {

    public init() {}

    public func accepts(_ info: StreamInfo) -> Bool {
        info.detectedFormat == .pdf
    }

    public func convert(_ data: Data, info: StreamInfo) async throws -> ConverterResult {
        guard let document = PDFDocument(data: data) else {
            throw PicoDocsError.fileCorrupted
        }

        var sections: [DocumentSection] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let pageNumber = index + 1
            sections.append(DocumentSection(
                kind: .body,
                markdown: text,
                pageRange: pageNumber...pageNumber
            ))
        }

        guard !sections.isEmpty else { throw PicoDocsError.emptyDocument }

        let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        return ConverterResult(
            title: (title?.isEmpty == false) ? title : info.filename,
            sections: sections
        )
    }
}
#endif
