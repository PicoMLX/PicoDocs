//
//  UTType.swift
//  PicoIndex
//
//  Created by Ronald Mannak on 11/21/24.
//

import Foundation
import UniformTypeIdentifiers

public extension UTType {

    // Custom types
    static let doc = UTType(importedAs: "com.microsoft.word.doc", conformingTo: .data)
    // DOCX/XLSX are OOXML packages = ZIP containers, not XML. Declaring them
    // `conformingTo: .xml` made them conform to the XML / plain-text dispatch
    // paths, a root cause of issue #2 (docx/xlsx misrouted to text handling).
    static let docx = UTType(importedAs: "org.openxmlformats.wordprocessingml.document", conformingTo: .zip)
//    static let xls = UTType(importedAs: "com.microsoft.excel.xls", conformingTo: .spreadsheet)
    static let xlsx = UTType(importedAs: "org.openxmlformats.spreadsheetml.sheet", conformingTo: .zip)
    static let xhtml = UTType(importedAs: "public.xhtml", conformingTo: .xml)
    static let webloc = UTType(importedAs: "com.apple.web-internet-location")

    /// Array of all supported documents
    static let supportedDocumentTypes = [
        .folder, .directory,
        .webloc,
        .doc, .docx, .xlsx,
        .epub,
        .pdf, .rtf, .rtfd, .text, .flatRTFD, .plainText, .utf8PlainText, xml,
        .spreadsheet, .commaSeparatedText,
        .internetLocation, .internetShortcut, .url, .urlBookmarkData, .html, .xhtml,
        .sourceCode, .json, .objectiveCSource, .phpScript, .perlScript, .shellScript, .script, .javaScript, .pythonScript, .assemblyLanguageSource,
        .emailMessage, .spreadsheet,
    ]


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
