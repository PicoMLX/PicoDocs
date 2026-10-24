//
//  ExternalDocxFixtures.swift
//  PicoDocsTests
//
//  DOCX files written by Apple's Office Open XML writer (Cocoa's
//  NSAttributedString, through `textutil` on macOS 27), not by PicoDocs, so the
//  editor's fidelity tests see markup PicoDocs' own exporter never produces:
//  every run carries `xml:space="preserve"`, empty `<w:t>` runs sit around
//  tabs, bullets are literal tab-bullet-tab runs, and non-standard elements
//  such as `w:sz-cs` appear in run properties.
//
//  They're embedded as base64 because the tooling that added them writes text
//  files only. Each decodes to the exact bytes `textutil` wrote, checked by
//  SHA-256. Regenerate with:
//
//    textutil -convert docx report.html -output textutil-report.docx
//    textutil -convert docx tabs.rtf -output textutil-tabs.docx
//
//  report.html:
//    <h1>Quarterly Report</h1>
//    <p>Revenue grew <b>12%</b> to <span style="color:#C00000;font-family:Georgia">$4.2M</span> in <i>Q3</i>, ahead of plan.</p>
//    <p>Owner: Jane Doe<br>Reviewer: Sam Lee</p>
//    <p>Tom &amp; Jerry &lt;3 caf&#xE9; and cafe&#x301; na&#xEF;ve 日本語 😀 Ελληνικά</p>
//    <p>The <b>qu</b><i>ick</i> brown fox jumps over the lazy dog.</p>
//    <ul><li>First item</li><li>Second item</li></ul>
//    <table border="1"><tr><td>Cell A</td><td>Cell B</td></tr></table>
//    <p>DRAFT notes. DRAFT summary. DRAFT end.</p>
//  (inside <html><head><meta charset="utf-8"><title>Quarterly Report</title></head><body>…</body></html>)
//
//  tabs.rtf:
//    {\rtf1\ansi\ansicpg1252\cocoartf2822
//    {\fonttbl\f0\fswiss Helvetica;\f1\froman Georgia;}
//    {\colortbl;\red0\green0\blue0;\red192\green0\blue0;}
//    \f0\fs24 Name:\tab Jane Doe\line Role:\tab Analyst\par
//    Total:\tab {\f1\cf2 $4.2M}\tab {\b final}\par
//    Caf\u233 ? cr\u232 ?me br\u251 ?l\u233 ?e\par
//    }
//

import CryptoKit
import Foundation

enum ExternalDocxFixture {

    struct Mismatch: Error, CustomStringConvertible {
        let name: String
        var description: String { "Embedded fixture \(name) doesn't decode to the recorded bytes" }
    }

    /// `textutil-report.docx`: headings, mixed run formatting, a phrase split
    /// across bold and italic runs, a line break, references and multi-byte
    /// and combining text, a bullet list, a flattened table, repeated text.
    static func textutilReport() throws -> Data {
        try decode(reportBase64, sha256: "dd3c1dfb8d5941b25daa8586a6c90114c852b7f93ae66aac99dc98d93c477fa3", name: "textutil-report.docx")
    }

    /// `textutil-tabs.docx`: tabs, a line break, font and color runs, accents.
    static func textutilTabs() throws -> Data {
        try decode(tabsBase64, sha256: "dbdb0649d39c1d66fb24b02d04f6f68eca84cbf90c60ec644d940b7c1b21f2fb", name: "textutil-tabs.docx")
    }

    private static func decode(_ base64: String, sha256: String, name: String) throws -> Data {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw Mismatch(name: name)
        }
        return data
    }

    private static let reportBase64 = """
    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
    AAAA
    """

    private static let tabsBase64 = """
    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
    """
}
