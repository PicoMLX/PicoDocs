//
//  WordEditableTextTests.swift
//  PicoDocsTests
//
//  The DOCX editable-text snapshot and its offset map, checked on hand-written
//  `word/document.xml` bodies: what text appears, what's editable, which
//  boundaries separate runs, and that every editable segment maps back to the
//  exact raw bytes it came from.
//

import Foundation
import Testing
@testable import PicoDocs

@Suite("WordEditableText (DOCX snapshot and offset map)")
struct WordEditableTextTests {

    // MARK: - Helpers

    private func xml(_ body: String) -> [UInt8] {
        Array("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>\(body)</w:body></w:document>
        """.utf8)
    }

    private func snapshot(_ body: String) throws -> WordEditableText {
        try WordEditableText(documentXML: xml(body))
    }

    /// Each segment as `run:<text>` or `<boundary kind>:<text>`.
    private func layout(_ snapshot: WordEditableText) -> [String] {
        let text = snapshot.text as NSString
        return snapshot.segments.map { segment in
            let slice = text.substring(with: NSRange(location: segment.range.lowerBound, length: segment.range.count))
            switch segment.content {
            case .run: return "run:" + slice
            case .boundary(let kind): return "\(kind.rawValue):" + slice
            }
        }
    }

    private func runs(_ snapshot: WordEditableText) -> [WordEditableText.Run] {
        snapshot.segments.compactMap { if case .run(let run) = $0.content { return run } else { return nil } }
    }

    // MARK: - Text and layout

    @Test("Paragraphs join with a newline; runs join with nothing; empty paragraphs add nothing")
    func paragraphsAndRuns() throws {
        let snapshot = try snapshot("""
        <w:p><w:r><w:t>Hel</w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>lo</w:t></w:r></w:p>\
        <w:p/><w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr></w:p>\
        <w:p><w:r><w:t>World</w:t></w:r></w:p>
        """)
        #expect(snapshot.text == "Hello\nWorld")
        #expect(layout(snapshot) == ["run:Hel", "run:lo", "paragraph:\n", "run:World"])
    }

    @Test("Run tabs and breaks are boundaries; tab stops in paragraph properties are not text")
    func tabsAndBreaks() throws {
        let snapshot = try snapshot("""
        <w:p><w:pPr><w:tabs><w:tab w:val="left" w:pos="720"/></w:tabs></w:pPr>\
        <w:r><w:t>a</w:t><w:tab/><w:t>b</w:t><w:br/><w:t>c</w:t><w:cr/><w:t>d</w:t><w:ptab w:relativeTo="margin" w:alignment="right" w:leader="none"/><w:t>e</w:t></w:r></w:p>
        """)
        #expect(snapshot.text == "a\tb\nc\nd\te")
        #expect(layout(snapshot) == ["run:a", "tab:\t", "run:b", "lineBreak:\n", "run:c", "lineBreak:\n", "run:d", "tab:\t", "run:e"])
    }

    @Test("Non-breaking and soft hyphens show as their characters but stay fixed")
    func hyphens() throws {
        let snapshot = try snapshot("<w:p><w:r><w:t>e</w:t><w:noBreakHyphen/><w:t>mail hyphen</w:t><w:softHyphen/><w:t>ation</w:t></w:r></w:p>")
        #expect(snapshot.text == "e\u{2011}mail hyphen\u{AD}ation")
        #expect(layout(snapshot) == ["run:e", "object:\u{2011}", "run:mail hyphen", "object:\u{AD}", "run:ation"])
    }

    @Test("Table cells are separate paragraphs")
    func tableCells() throws {
        let snapshot = try snapshot("""
        <w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/></w:tblPr><w:tblGrid><w:gridCol w:w="100"/></w:tblGrid>\
        <w:tr><w:tc><w:tcPr/><w:p><w:r><w:t>A</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>B</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """)
        #expect(layout(snapshot) == ["run:A", "paragraph:\n", "run:B"])
    }

    @Test("Without xml:space=preserve, a run's edge whitespace isn't shown or mapped")
    func xmlSpace() throws {
        let body = #"<w:p><w:r><w:t> a b </w:t></w:r><w:r><w:t xml:space="preserve"> c </w:t></w:r><w:r><w:t xml:space='default'>&#32;d</w:t></w:r></w:p>"#
        let bytes = xml(body)
        let snapshot = try WordEditableText(documentXML: bytes)
        #expect(snapshot.text == "a b c d")
        let runs = runs(snapshot)
        #expect(String(decoding: bytes[runs[0].content], as: UTF8.self) == " a b ")
        #expect(String(decoding: bytes[runs[0].visible], as: UTF8.self) == "a b")
        #expect(!runs[0].preservesSpace && runs[0].spaceValue == nil)
        #expect(String(decoding: bytes[runs[1].visible], as: UTF8.self) == " c ")
        #expect(runs[1].preservesSpace)
        #expect(String(decoding: bytes[runs[2].visible], as: UTF8.self) == "d")
        #expect(runs[2].spaceValue.map { String(decoding: bytes[$0], as: UTF8.self) } == "default")
    }

    @Test("A whitespace-only run without preserve shows nothing and doesn't split its neighbors")
    func whitespaceOnlyRun() throws {
        let snapshot = try snapshot("<w:p><w:r><w:t>a</w:t></w:r><w:r><w:t>  </w:t></w:r><w:r><w:t>b</w:t></w:r></w:p>")
        #expect(layout(snapshot) == ["run:a", "run:b"])
    }

    // MARK: - Non-editable and excluded content

    @Test("Hidden runs are left out, with a boundary in their place")
    func hiddenText() throws {
        let snapshot = try snapshot("""
        <w:p><w:pPr><w:rPr><w:vanish/></w:rPr></w:pPr>\
        <w:r><w:t>see</w:t></w:r><w:r><w:rPr><w:vanish/></w:rPr><w:t>secret</w:t><w:tab/></w:r>\
        <w:r><w:t>me</w:t></w:r><w:r><w:rPr><w:vanish w:val="0"/></w:rPr><w:t>!</w:t></w:r></w:p>
        """)
        #expect(snapshot.text == "seeme!")
        #expect(layout(snapshot) == ["run:see", "hiddenText:", "run:me", "run:!"])
    }

    @Test("Hyperlink text is shown but not editable")
    func hyperlink() throws {
        let snapshot = try snapshot("""
        <w:p><w:r><w:t xml:space="preserve">Visit </w:t></w:r><w:hyperlink r:id="rId5"><w:r><w:t>our site</w:t></w:r></w:hyperlink>\
        <w:r><w:t xml:space="preserve"> today</w:t></w:r><w:hyperlink w:anchor="x"/><w:r><w:t>!</w:t></w:r></w:p>
        """)
        #expect(layout(snapshot) == ["run:Visit ", "hyperlink:our site", "run: today", "hyperlink:", "run:!"])
    }

    @Test("A complex field shows its result, not its instruction, and the result isn't editable")
    func complexField() throws {
        let snapshot = try snapshot("""
        <w:p><w:r><w:t xml:space="preserve">Page </w:t></w:r><w:r><w:fldChar w:fldCharType="begin"/></w:r>\
        <w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r><w:r><w:fldChar w:fldCharType="separate"/></w:r>\
        <w:r><w:t>3</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r><w:r><w:t xml:space="preserve"> of </w:t></w:r>\
        <w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText>NUMPAGES</w:instrText></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r>\
        <w:r><w:t>9</w:t></w:r></w:p>
        """)
        #expect(snapshot.text == "Page 3 of 9")
        #expect(layout(snapshot) == ["run:Page ", "field:3", "run: of ", "field:", "run:9"])
    }

    @Test("Simple fields and content controls are shown but not editable")
    func simpleFieldAndContentControl() throws {
        let snapshot = try snapshot("""
        <w:p><w:fldSimple w:instr=" DATE "><w:r><w:t>today</w:t></w:r></w:fldSimple>\
        <w:sdt><w:sdtPr><w:alias w:val="Name"/><w:text/></w:sdtPr><w:sdtContent><w:r><w:t>Jane</w:t></w:r></w:sdtContent></w:sdt></w:p>\
        <w:sdt><w:sdtContent><w:p><w:r><w:t>Block</w:t></w:r></w:p></w:sdtContent></w:sdt>\
        <w:p><w:r><w:t>free</w:t></w:r></w:p>
        """)
        #expect(layout(snapshot) == ["field:today", "contentControl:Jane", "paragraph:\n", "contentControl:Block", "paragraph:\n", "run:free"])
    }

    @Test("Tracked insertions are shown but not editable; deletions are left out")
    func trackedChanges() throws {
        let snapshot = try snapshot("""
        <w:p><w:r><w:t xml:space="preserve">The </w:t></w:r>\
        <w:del w:id="1" w:author="A" w:date="2026-01-01T00:00:00Z"><w:r><w:delText>old</w:delText></w:r></w:del>\
        <w:ins w:id="2" w:author="A" w:date="2026-01-01T00:00:00Z"><w:r><w:t>new</w:t></w:r></w:ins>\
        <w:r><w:t xml:space="preserve"> plan</w:t></w:r><w:del w:id="3" w:author="A"><w:r><w:delText>!!</w:delText></w:r></w:del>\
        <w:r><w:t>.</w:t></w:r>\
        <w:r><w:rPr><w:b/><w:rPrChange w:id="4" w:author="A"><w:rPr/></w:rPrChange></w:rPr><w:t>Bold</w:t></w:r></w:p>
        """)
        #expect(snapshot.text == "The new plan.Bold")
        #expect(layout(snapshot) == ["run:The ", "trackedChange:new", "run: plan", "trackedChange:", "run:.", "trackedChange:Bold"])
    }

    @Test("Drawings, text boxes, alternate content and note references are left out, with a boundary")
    func objects() throws {
        let snapshot = try snapshot("""
        <w:p><w:r><w:t>before</w:t></w:r><w:r><w:drawing><wp:inline><a:graphic><a:graphicData><wps:wsp><wps:txbx>\
        <w:txbxContent><w:p><w:r><w:t>boxed</w:t></w:r></w:p></w:txbxContent></wps:txbx></wps:wsp></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>\
        <w:r><w:t>after</w:t></w:r><mc:AlternateContent><mc:Choice Requires="wps"><w:r><w:t>choice</w:t></w:r></mc:Choice>\
        <mc:Fallback><w:r><w:t>fallback</w:t></w:r></mc:Fallback></mc:AlternateContent>\
        <w:r><w:t>note</w:t></w:r><w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr><w:footnoteReference w:id="1"/></w:r><w:r><w:t>s</w:t></w:r></w:p>
        """)
        #expect(snapshot.text == "beforeafternotes")
        #expect(layout(snapshot) == ["run:before", "object:", "run:after", "object:", "run:note", "object:", "run:s"])
    }

    @Test("Proofing marks, bookmarks, comment ranges and page-break hints don't split runs")
    func spannableMarkup() throws {
        let snapshot = try snapshot("""
        <w:p><w:r><w:t>Hel</w:t></w:r><w:proofErr w:type="spellStart"/><w:bookmarkStart w:id="0" w:name="_GoBack"/>\
        <w:r><w:lastRenderedPageBreak/><w:t>lo</w:t></w:r><w:bookmarkEnd w:id="0"/><w:commentRangeStart w:id="1"/>\
        <w:r><w:t>!</w:t></w:r><w:commentRangeEnd w:id="1"/></w:p>
        """)
        #expect(layout(snapshot) == ["run:Hel", "run:lo", "run:!"])
    }

    // MARK: - Byte mapping

    @Test("Entity and character references decode, and each maps to its own raw bytes")
    func references() throws {
        let bytes = xml("<w:p><w:r><w:t>A &amp; B &#x1F600; &#233;&lt;</w:t></w:r></w:p>")
        let snapshot = try WordEditableText(documentXML: bytes)
        #expect(snapshot.text == "A & B 😀 é<")
        let pieces = try #require(runs(snapshot).first).pieces
        let references = pieces.filter { !$0.isLiteral }.map { String(decoding: bytes[$0.bytes], as: UTF8.self) }
        #expect(references == ["&amp;", "&#x1F600;", "&#233;", "&lt;"])
        #expect(pieces.first { String(decoding: bytes[$0.bytes], as: UTF8.self) == "&#x1F600;" }?.utf16Count == 2)
    }

    @Test("A combining mark in its own run gets its own segment, in UTF-16 offsets")
    func combiningMarkAcrossRuns() throws {
        let bytes = xml("<w:p><w:r><w:t>na\u{EF}ve cafe</w:t></w:r><w:r><w:rPr><w:i/></w:rPr><w:t>\u{301} 日本</w:t></w:r></w:p>")
        let snapshot = try WordEditableText(documentXML: bytes)
        #expect(snapshot.text == "na\u{EF}ve cafe\u{301} 日本")
        #expect(snapshot.segments.map(\.range) == [0..<10, 10..<14])
        let second = try #require(runs(snapshot).last)
        #expect(second.pieces.count == 1 && second.pieces[0].utf16Count == 4)
        #expect(second.pieces[0].bytes.count == 2 + 1 + 3 + 3)
    }

    @Test("Segments tile the text, and every run's pieces reproduce its text from raw bytes")
    func mapConsistency() throws {
        let bytes = xml("""
        <w:p><w:r><w:t xml:space="preserve"> Tom &amp; Jerry </w:t></w:r><w:hyperlink r:id="rId1"><w:r><w:t>link</w:t></w:r></w:hyperlink>\
        <w:r><w:t>  edge  </w:t><w:tab/><w:t>&quot;quoted&quot; 😀</w:t></w:r></w:p><w:p><w:r><w:t>end</w:t></w:r></w:p>
        """)
        let snapshot = try WordEditableText(documentXML: bytes)
        let text = snapshot.text as NSString
        var cursor = 0
        for segment in snapshot.segments {
            #expect(segment.range.lowerBound == cursor)
            cursor = segment.range.upperBound
            guard case .run(let run) = segment.content else { continue }
            #expect(run.pieces.reduce(0) { $0 + $1.utf16Count } == segment.range.count)
            #expect(run.content.contains(run.visible.lowerBound) && run.visible.upperBound <= run.content.upperBound)
            let decoded = run.pieces.map { piece -> String in
                let raw = String(decoding: bytes[piece.bytes], as: UTF8.self)
                guard !piece.isLiteral else { return raw }
                return ["&amp;": "&", "&quot;": "\"", "&lt;": "<", "&gt;": ">", "&apos;": "'"][raw] ?? raw
            }.joined()
            #expect(decoded == text.substring(with: NSRange(location: segment.range.lowerBound, length: segment.range.count)))
        }
        #expect(cursor == text.length)
        #expect(snapshot.text == " Tom & Jerry linkedge\t\"quoted\" 😀\nend")
    }

    // MARK: - Rejected input

    @Test("Malformed or unsafe XML is rejected as corrupted")
    func malformed() throws {
        #expect(throws: PicoDocsError.fileCorrupted) { try snapshot("<w:p><w:r><w:t>a</w:r></w:t></w:p>") }
        #expect(throws: PicoDocsError.fileCorrupted) { try snapshot("<w:p><w:r><w:t>a &nbsp; b</w:t></w:r></w:p>") }
        #expect(throws: PicoDocsError.fileCorrupted) { try snapshot("<w:p><w:r><w:t>a & b</w:t></w:r></w:p>") }
        #expect(throws: PicoDocsError.fileCorrupted) { try snapshot("<w:p><w:r><w:t>&#xD800;</w:t></w:r></w:p>") }
        #expect(throws: PicoDocsError.fileCorrupted) { try snapshot("<w:p><w:r><w:t>open") }
        #expect(throws: PicoDocsError.fileCorrupted) {
            try WordEditableText(documentXML: Array("<!DOCTYPE w [<!ENTITY x \"y\">]><w:document/>".utf8))
        }
        var invalidUTF8 = xml("<w:p><w:r><w:t>Xa</w:t></w:r></w:p>")
        let marker = try #require(invalidUTF8.firstIndex(of: UInt8(ascii: "X")))
        invalidUTF8[marker] = 0xC3
        invalidUTF8[marker + 1] = 0x28
        #expect(throws: PicoDocsError.fileCorrupted) { try WordEditableText(documentXML: invalidUTF8) }
    }

    @Test("A part that isn't UTF-8 is unsupported, since its bytes couldn't be preserved")
    func nonUTF8() throws {
        let declared = Array("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><w:document/>".utf8)
        #expect(throws: PicoDocsError.documentTypeNotSupported) { try WordEditableText(documentXML: declared) }
        let utf16 = [UInt8](Data([0xFF, 0xFE]) + "<w:document/>".data(using: .utf16LittleEndian)!)
        #expect(throws: PicoDocsError.documentTypeNotSupported) { try WordEditableText(documentXML: utf16) }
        let lowercase = Array("<?xml version='1.0' encoding='utf-8'?><w:document/>".utf8)
        #expect(try WordEditableText(documentXML: lowercase).text.isEmpty)
    }
}
