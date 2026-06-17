//
//  UTType.swift
//  PicoIndex
//
//  Created by Ronald Mannak on 11/21/24.
//

import Foundation
import UniformTypeIdentifiers

public extension UTType {

    // Custom types. UniformTypeIdentifiers has no built-in static constants for
    // the Office/OOXML formats (`UTType.docx`/`.xlsx`/`.doc` do not exist in the
    // SDK — only the system *identifiers* are registered), so we declare them
    // here. Removing these would break the `.docx`/`.xlsx` references below.
    static let doc = UTType(importedAs: "com.microsoft.word.doc", conformingTo: .data)
    // DOCX/XLSX are OOXML packages = ZIP containers, not XML. Declaring them
    // `conformingTo: .xml` made them conform to the XML / plain-text dispatch
    // paths, a root cause of issue #2 (docx/xlsx misrouted to text handling).
    static let docx = UTType(importedAs: "org.openxmlformats.wordprocessingml.document", conformingTo: .zip)
//    static let xls = UTType(importedAs: "com.microsoft.excel.xls", conformingTo: .spreadsheet)
    static let xlsx = UTType(importedAs: "org.openxmlformats.spreadsheetml.sheet", conformingTo: .zip)
    static let pptx = UTType(importedAs: "org.openxmlformats.presentationml.presentation", conformingTo: .zip)
    static let xhtml = UTType(importedAs: "public.xhtml", conformingTo: .xml)
    static let webloc = UTType(importedAs: "com.apple.web-internet-location")
    // Apple Pages (iWork '13+) is a ZIP package of IWA streams, not XML.
    static let pages = UTType(importedAs: "com.apple.iwork.pages.pages", conformingTo: .zip)

    /// Array of all supported documents
    static let supportedDocumentTypes: [UTType] = {
        var types: [UTType] = [
            .folder, .directory,
            .webloc,
            .doc, .docx, .xlsx,
            .epub, .pages,
            .pdf, .rtf, .rtfd, .text, .flatRTFD, .plainText, .utf8PlainText, .xml,
            .spreadsheet, .commaSeparatedText,
            .internetLocation, .internetShortcut, .url, .urlBookmarkData, .html, .xhtml,
            .sourceCode, .json, .objectiveCSource, .phpScript, .perlScript, .shellScript, .script, .javaScript, .pythonScript, .assemblyLanguageSource,
            .emailMessage, .spreadsheet,
        ]
        #if canImport(Vision)
        // Standalone images are convertible via on-device OCR (ImageOCRConverter),
        // which is registered only where Vision exists — so claim image support
        // under the same gate. `.image` is abstract; `isSupported` matches by
        // conformance, so concrete PNG/JPEG/HEIC/TIFF/… all qualify. Without this,
        // the `PicoDocument(url:)` path marks image files unsupported even though
        // the engine can now OCR them.
        types.append(.image)
        #endif
        return types
    }()


    /// Returns true if type is listed in `supportedDocumentTypes`
    var isSupported: Bool {
        // Match by conformance, not identity. A system-vended UTI (e.g. a `.docx`
        // provided by Files.app) is not necessarily the same instance as our
        // `importedAs` declaration, so the previous `contains(self)` identity
        // check could miss it. Conformance also lets a concrete subtype match
        // its declared supertype (e.g. a specific source-code UTI vs `.sourceCode`).
        Self.supportedDocumentTypes.contains { self.conforms(to: $0) }
    }
}
