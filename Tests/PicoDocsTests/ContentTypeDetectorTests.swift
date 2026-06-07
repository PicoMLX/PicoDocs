//
//  ContentTypeDetectorTests.swift
//  PicoDocsTests
//
//  The issue #2 regression guard: content-based detection must classify the
//  formats that previously failed (docx/xlsx/epub were declared as XML, HTML
//  wasn't recognized). Detection is content-first, so most cases need no
//  filename hint at all.
//

import Foundation
import Testing
@testable import PicoDocs

@Suite("Content type detection (issue #2 regression guard)")
struct ContentTypeDetectorTests {

    private func detect(_ data: Data, filename: String? = nil, mimeType: String? = nil) -> DetectedFormat? {
        let info = StreamInfo(filename: filename, mimeType: mimeType)
        return ContentTypeDetector.classify(data, info: info).detectedFormat
    }

    // MARK: - Magic bytes / content sniff (no filename needed)

    @Test("PDF detected by %PDF magic")
    func pdfByMagic() {
        #expect(detect(Data("%PDF-1.7\nfake pdf body".utf8)) == .pdf)
    }

    @Test("HTML detected by content sniff")
    func htmlBySniff() {
        #expect(detect(Data("<!DOCTYPE html><html><body><p>Hi</p></body></html>".utf8)) == .html)
    }

    @Test("RTF detected by control-word magic")
    func rtfByMagic() {
        #expect(detect(Data("{\\rtf1\\ansi hello}".utf8)) == .rtf)
    }

    @Test("Plain prose stays plain text")
    func plainText() {
        #expect(detect(Data("just some plain text, nothing special here".utf8)) == .plainText)
    }

    // MARK: - ZIP central-directory subtyping (the core issue #2 bug)

    @Test("DOCX detected from zip entries, no filename hint")
    func docxByZipEntries() throws {
        #expect(try detect(Fixture.data("sample", "docx")) == .docx)
    }

    @Test("XLSX detected from zip entries, no filename hint")
    func xlsxByZipEntries() throws {
        #expect(try detect(Fixture.data("sample", "xlsx")) == .xlsx)
    }

    @Test("EPUB detected from zip entries, no filename hint")
    func epubByZipEntries() throws {
        #expect(try detect(Fixture.data("sample", "epub")) == .epub)
    }

    // MARK: - Hint fallback for magic-less documents

    @Test("A .docx filename routes to docx even when the bytes aren't a zip")
    func docxByHintWhenCorrupt() {
        #expect(detect(Data("not actually a zip".utf8), filename: "broken.docx") == .docx)
    }
}
