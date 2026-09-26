//
//  ConverterTests.swift
//  PicoDocsTests
//
//  End-to-end conversion of the Tier A binary formats (the set that failed in
//  issue #2), the strict-failure rule (a corrupt document errors rather than
//  silently degrading to plain text), and the renderer's format handling.
//

import Foundation
import Testing
@testable import PicoDocs

@Suite("Tier A converters")
struct ConverterTests {

    @Test("DOCX converts to Markdown with heading and body text")
    func docx() async throws {
        let result = try await PicoDocsEngine.convert(data: Fixture.data("sample", "docx"), filename: "sample.docx")
        let md = result.markdown()
        #expect(md.contains("Sample Heading"))
        #expect(md.contains("Hello from a Word document."))
    }

    @Test("DOCX extracts embedded images: inline reference + an image section with bytes")
    func docxImages() async throws {
        let result = try await PicoDocsEngine.convert(data: Fixture.data("image", "docx"), filename: "image.docx")
        let md = result.markdown()
        #expect(md.contains("Before image."))
        #expect(md.contains("![A red dot](image1.png)"))   // alt text + filename, inline at position
        // Referenced once: the .image section's bytes don't render a duplicate.
        #expect(md.components(separatedBy: "image1.png").count == 2)
        let image = result.sections.first { $0.kind == .image }
        #expect(image?.sourcePath == "word/media/image1.png")
        #expect(image?.metadata["mimeType"] == "image/png")
        #expect(image?.metadata["base64"]?.isEmpty == false)
    }

    @Test("DOCX footnotes are extracted as Markdown footnote definitions")
    func docxFootnotes() async throws {
        let md = try await PicoDocsEngine.convert(
            data: Fixture.data("footnote", "docx"), filename: "footnote.docx"
        ).markdown()
        #expect(md.contains("Body text[^fn2]"))                       // inline reference at position
        #expect(md.contains("[^fn2]: This is the footnote text."))     // definition appended
    }

    @Test("HTML export renders DOCX footnotes as superscript links + a notes list")
    func docxFootnotesHTML() async throws {
        let html = try await PicoDocsEngine.export(
            data: Fixture.data("footnote", "docx"), filename: "footnote.docx", to: .html
        )
        #expect(!html.contains("[^fn2]"))                                  // no literal marker
        #expect(html.contains("Body text<sup class=\"footnote-ref\"><a href=\"#fn-fn2\">1</a></sup>"))
        #expect(html.contains("<li id=\"fn-fn2\">"))                       // definition anchor
        #expect(html.contains("This is the footnote text."))
    }

    @Test("Plaintext export renders DOCX footnotes as [N] markers + definitions")
    func docxFootnotesPlaintext() async throws {
        let text = try await PicoDocsEngine.export(
            data: Fixture.data("footnote", "docx"), filename: "footnote.docx", to: .plaintext
        )
        #expect(!text.contains("[^fn2]"))                            // no literal marker
        #expect(text.contains("Body text[1]"))                        // reference renumbered
        #expect(text.contains("[1] This is the footnote text."))      // definition listed
    }

    @Test("DOCX extracts text box content once (deduping the mc:Fallback copy)")
    func docxTextBox() async throws {
        let md = try await PicoDocsEngine.convert(
            data: Fixture.data("textbox", "docx"), filename: "textbox.docx"
        ).markdown()
        #expect(md.contains("Body before."))
        #expect(md.contains("Body after."))
        #expect(md.contains("Text box content."))                           // text box extracted
        #expect(md.components(separatedBy: "Text box content.").count == 2)  // exactly once (Fallback deduped)
    }

    @Test("DOCX text box inside a table cell is emitted once, not duplicated")
    func docxTextBoxInTable() async throws {
        let md = try await PicoDocsEngine.convert(
            data: Fixture.data("textbox-table", "docx"), filename: "textbox-table.docx"
        ).markdown()
        #expect(md.contains("Cell text."))                                   // table cell content
        #expect(md.contains("Table box content."))                           // text box extracted
        #expect(md.components(separatedBy: "Table box content.").count == 2)  // exactly once
    }

    @Test("DOCX keeps a text box whose only copy is in mc:Fallback")
    func docxTextBoxFallbackOnly() async throws {
        let md = try await PicoDocsEngine.convert(
            data: Fixture.data("textbox-fallback-only", "docx"), filename: "textbox-fallback-only.docx"
        ).markdown()
        #expect(md.contains("Intro."))
        #expect(md.contains("Fallback only content."))   // kept (not dropped as a redundant fallback)
    }

    @Test("DOCX renders a table that is inside a text box")
    func docxTextBoxWithTable() async throws {
        let md = try await PicoDocsEngine.convert(
            data: Fixture.data("textbox-with-table", "docx"), filename: "textbox-with-table.docx"
        ).markdown()
        #expect(md.contains("Before box."))
        #expect(md.contains("Inner cell A."))   // table inside the text box still renders its cells
        #expect(md.contains("Inner cell B."))
    }

    @Test("DOCX renders only one AlternateContent branch for a text box")
    func docxTextBoxMultiChoice() async throws {
        let md = try await PicoDocsEngine.convert(
            data: Fixture.data("textbox-multi-choice", "docx"), filename: "textbox-multi-choice.docx"
        ).markdown()
        #expect(md.contains("Choice one box."))    // first choice with a text box wins
        #expect(!md.contains("Choice two box."))    // other branches are not also emitted
        #expect(!md.contains("Fallback box."))
    }

    @Test("DOCX hyperlink wrapping an image keeps the image (renderer-safe)")
    func docxLinkedImage() async throws {
        let md = try await PicoDocsEngine.convert(
            data: Fixture.data("linked-image", "docx"), filename: "linked-image.docx"
        ).markdown()
        #expect(md.contains("![A red dot](image1.png)"))
        // We don't emit a nested linked image the renderers can't parse.
        #expect(!md.contains("https://example.com"))
    }

    @Test("HTML export embeds extracted DOCX images as data URLs")
    func docxImageHTML() async throws {
        let html = try await PicoDocsEngine.export(
            data: Fixture.data("image", "docx"), filename: "image.docx", to: .html
        )
        #expect(html.contains("<img src=\"data:image/png;base64,"))
        #expect(!html.contains("src=\"image1.png\""))
    }

    @Test("HTML embedding leaves basename-colliding images unresolved, embeds unique ones")
    func htmlImageEmbedCollision() throws {
        // Body refers to images by basename; two *distinct* images sharing a
        // basename (e.g. body media + a note part's own media) are ambiguous in
        // the body HTML, so neither is embedded (an honest broken ref beats a
        // confidently wrong image). A uniquely-named image still embeds.
        let body = DocumentSection(kind: .body, markdown: "![a](image1.png)\n\n![b](image2.png)")
        let dupA = DocumentSection(
            kind: .image, markdown: "![a](image1.png)", sourcePath: "word/media/image1.png",
            metadata: ["mimeType": "image/png", "base64": "AAAA"]
        )
        let dupB = DocumentSection(
            kind: .image, markdown: "![a](image1.png)", sourcePath: "word/notes/media/image1.png",
            metadata: ["mimeType": "image/png", "base64": "BBBB"]
        )
        let unique = DocumentSection(
            kind: .image, markdown: "![b](image2.png)", sourcePath: "word/media/image2.png",
            metadata: ["mimeType": "image/png", "base64": "CCCC"]
        )
        let result = ConverterResult(title: "t", sections: [body, dupA, dupB, unique])
        let html = try DocumentRenderer.render(result, to: .html)
        // Ambiguous basename: neither image embedded, ref left unresolved.
        #expect(!html.contains("base64,AAAA"))
        #expect(!html.contains("base64,BBBB"))
        #expect(html.contains("src=\"image1.png\""))
        // Unique basename: embedded as a data URL.
        #expect(html.contains("src=\"data:image/png;base64,CCCC\""))
        #expect(!html.contains("src=\"image2.png\""))
    }

    @Test("DOCX part-path resolution honors the owning part's base directory")
    func docxResolvePartPath() {
        // Body part / standard-location notes: targets are relative to `word`.
        #expect(WordConverter.resolvePartPath("media/image1.png", relativeTo: "word")
            == "word/media/image1.png")
        // A notes part in a subfolder resolves `../media/...` against `word/notes`
        // — i.e. back up to `word/media`, not the package root (the round-3 fix).
        #expect(WordConverter.resolvePartPath("../media/image1.png", relativeTo: "word/notes")
            == "word/media/image1.png")
        // A package-absolute target (leading "/") ignores the base directory.
        #expect(WordConverter.resolvePartPath("/word/media/image1.png", relativeTo: "word/notes")
            == "word/media/image1.png")
    }

    @Test("DOCX lists: numbered, bulleted, nested, restarted, and numbering switched off")
    func docxLists() async throws {
        // Saved by LibreOffice Writer's Word exporter: paragraphs outside a list
        // carry `w:numId="0"`, and the restart is a new `w:num` with a
        // `startOverride` whose follow-up item returns to the original `w:num`.
        let markdown = try await PicoDocsEngine.convert(data: Fixture.data("lists", "docx"), filename: "lists.docx").markdown()
        #expect(markdown == """
        # Lists

        1. First step

        2. Second step

           1. Sub-step a

           2. Sub-step b

        3. Third step

        An interlude paragraph.

        - Apples

          - Conference

        - Pears

        1. Restarted one

        2. Restarted two

        End.
        """)
    }

    @Test("DOCX lists: style numbering, start overrides, unnumbered levels, missing definitions")
    func docxListEdgeCases() async throws {
        let w = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""
        func paragraph(_ text: String, style: String? = nil, numID: String? = nil, level: Int? = nil) -> String {
            var properties = style.map { "<w:pStyle w:val=\"\($0)\"/>" } ?? ""
            if numID != nil || level != nil {
                properties += "<w:numPr>" + (level.map { "<w:ilvl w:val=\"\($0)\"/>" } ?? "")
                    + (numID.map { "<w:numId w:val=\"\($0)\"/>" } ?? "") + "</w:numPr>"
            }
            let runs = text.components(separatedBy: "\n").map { "<w:r><w:t>\($0)</w:t></w:r>" }.joined(separator: "<w:r><w:br/></w:r>")
            return "<w:p><w:pPr>\(properties)</w:pPr>\(runs)</w:p>"
        }
        let document = "<?xml version=\"1.0\"?><w:document \(w)><w:body>" + [
            paragraph("Styled one", style: "ListNumber"),             // numbering from the style…
            paragraph("Styled two", style: "MyList"),                 // …or its basedOn parent
            paragraph("Styled nested", style: "ListNumber", level: 1),
            paragraph("From five", numID: "7"),                       // startOverride 5
            paragraph("Six\nwith a manual break", numID: "7"),
            paragraph("Unnumbered level", numID: "8"),                // numFmt none
        ].joined() + "</w:body></w:document>"
        let numbering = """
        <?xml version="1.0"?><w:numbering \(w)>\
        <w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/></w:lvl>\
        <w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="lowerLetter"/></w:lvl></w:abstractNum>\
        <w:abstractNum w:abstractNumId="2"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum>\
        <w:abstractNum w:abstractNumId="3"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="none"/></w:lvl></w:abstractNum>\
        <w:num w:numId="5"><w:abstractNumId w:val="1"/></w:num>\
        <w:num w:numId="7"><w:abstractNumId w:val="2"/><w:lvlOverride w:ilvl="0"><w:startOverride w:val="5"/></w:lvlOverride></w:num>\
        <w:num w:numId="8"><w:abstractNumId w:val="3"/></w:num>\
        </w:numbering>
        """
        let styles = """
        <?xml version="1.0"?><w:styles \(w)>\
        <w:style w:type="paragraph" w:styleId="ListNumber"><w:pPr><w:numPr><w:numId w:val="5"/></w:numPr></w:pPr></w:style>\
        <w:style w:type="paragraph" w:styleId="MyList"><w:basedOn w:val="ListNumber"/></w:style>\
        </w:styles>
        """
        let docx = PagesConverterTests.makeZip([
            (name: "word/document.xml", data: Array(document.utf8)),
            (name: "word/numbering.xml", data: Array(numbering.utf8)),
            (name: "word/styles.xml", data: Array(styles.utf8)),
        ])
        let markdown = try await PicoDocsEngine.convert(data: docx, filename: "edge.docx").markdown()
        #expect(markdown == """
        1. Styled one

        2. Styled two

           - a. Styled nested

        5. From five

        6. Six  
           with a manual break

        Unnumbered level
        """)

        // Without numbering.xml or styles.xml, a paragraph naming a `w:numId`
        // still reads as a (bullet) list item; one relying on its style doesn't.
        let bare = PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8))])
        let bareMarkdown = try await PicoDocsEngine.convert(data: bare, filename: "bare.docx").markdown()
        #expect(bareMarkdown.hasPrefix("Styled one\n\nStyled two\n\nStyled nested\n\n- From five\n\n- Six"))
    }

    @Test("DOCX reads paragraph, run, and cell properties from the element itself")
    func docxOwnProperties() async throws {
        // An anchor paragraph whose run holds a text box: the box's paragraph is a
        // bold Heading 1 list item, and a cell holds a nested table with a gridSpan.
        // None of that may leak onto the anchor paragraph or the outer cell.
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"><w:body>
        <w:p><w:r><w:t>Anchor text</w:t><w:drawing><wp:anchor><a:graphic><a:graphicData><wps:wsp><wps:txbx><w:txbxContent>\
        <w:p><w:pPr><w:pStyle w:val="Heading1"/><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>\
        <w:r><w:rPr><w:b/></w:rPr><w:t>Box heading</w:t></w:r></w:p>\
        </w:txbxContent></wps:txbx></wps:wsp></a:graphicData></a:graphic></wp:anchor></w:drawing></w:r></w:p>
        <w:tbl>\
        <w:tr><w:tc><w:p><w:r><w:t>Outer A</w:t></w:r></w:p>\
        <w:tbl><w:tr><w:tc><w:tcPr><w:gridSpan w:val="3"/></w:tcPr><w:p><w:r><w:t>Inner</w:t></w:r></w:p></w:tc></w:tr></w:tbl><w:p/></w:tc>\
        <w:tc><w:p><w:r><w:t>Outer B</w:t></w:r></w:p></w:tc></w:tr>\
        <w:tr><w:tc><w:p><w:r><w:t>1</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>2</w:t></w:r></w:p></w:tc></w:tr>\
        </w:tbl>
        </w:body></w:document>
        """
        let docx = PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8))])
        let markdown = try await PicoDocsEngine.convert(data: docx, filename: "anchor.docx").markdown()
        let blocks = markdown.components(separatedBy: "\n\n")
        #expect(blocks.first == "Anchor text")                       // not "# **Anchor text**"
        #expect(blocks.contains("# **Box heading**"))                // the box keeps its own style
        #expect(markdown.contains("| Outer A<br>Inner | Outer B |\n| --- | --- |\n| 1 | 2 |"))
    }

    @Test("XLSX keeps each value in its column across blank cells")
    func xlsxSparseCells() async throws {
        // Blank cells are absent from a worksheet row. B2, A3, D* and row 4 are
        // empty; E1/E2 sit past an entirely empty column D.
        func cell(_ ref: String, _ text: String) -> String {
            "<c r=\"\(ref)\" t=\"inlineStr\"><is><t>\(text)</t></is></c>"
        }
        let sheet = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        <row r="1">\(cell("A1", "Name"))\(cell("B1", "Team"))\(cell("C1", "Score"))\(cell("E1", "Note"))</row>
        <row r="2">\(cell("A2", "Alice"))<c r="C2"><v>42</v></c>\(cell("E2", "late"))</row>
        <row r="3">\(cell("B3", "Ops"))<c r="C3"><v>7</v></c></row>
        <row r="5"><c r="A5" s="1"/></row>
        </sheetData></worksheet>
        """
        let workbook = Self.xlsx(sheetXML: sheet)
        let markdown = try await PicoDocsEngine.convert(data: workbook, filename: "sparse.xlsx").markdown()
        #expect(markdown.contains("""
        | Name | Team | Score | Note |
        | --- | --- | --- | --- |
        | Alice |  | 42 | late |
        |  | Ops | 7 |  |
        """))
        // The empty styled row adds nothing.
        #expect(!markdown.contains("|  |  |  |  |"))
    }

    /// A minimal single-sheet XLSX package ("Sheet1") around `sheetXML`.
    static func xlsx(sheetXML: String) -> Data {
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
        </Relationships>
        """
        let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>
        """
        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>\
        </Relationships>
        """
        return PagesConverterTests.makeZip([
            (name: "_rels/.rels", data: Array(rels.utf8)),
            (name: "xl/workbook.xml", data: Array(workbook.utf8)),
            (name: "xl/_rels/workbook.xml.rels", data: Array(workbookRels.utf8)),
            (name: "xl/worksheets/sheet1.xml", data: Array(sheetXML.utf8)),
        ])
    }

    @Test("XLSX converts each sheet's cells to Markdown")
    func xlsx() async throws {
        let md = try await PicoDocsEngine.convert(data: Fixture.data("sample", "xlsx"), filename: "sample.xlsx").markdown()
        #expect(md.contains("Name"))
        #expect(md.contains("Score"))
        #expect(md.contains("Alice"))
    }

    @Test("CSV converts to a Markdown table and round-trips back to CSV")
    func csvInput() async throws {
        let csv = "Name,Score\nAlice,42\n\"Bob, Jr\",7"
        let result = try await PicoDocsEngine.convert(data: Data(csv.utf8), filename: "data.csv")
        let md = result.markdown()
        #expect(md.contains("| Name | Score |"))
        #expect(md.contains("| Alice | 42 |"))
        #expect(md.contains("| Bob, Jr | 7 |"))   // comma inside a quoted field stays one cell
        let roundTrip = try DocumentRenderer.render(result, to: .csv)
        #expect(roundTrip.contains("Name,Score"))
        #expect(roundTrip.contains("\"Bob, Jr\",7"))
    }

    @Test("CSV round-trip preserves quoted whitespace and embedded newlines")
    func csvRoundTripFidelity() async throws {
        let csv = "Name,Note\nAlice,\"hello\nworld\"\nBob,\" 007 \""
        let result = try await PicoDocsEngine.convert(data: Data(csv.utf8), filename: "d.csv")
        let out = try DocumentRenderer.render(result, to: .csv)
        #expect(out.contains("\"hello\nworld\""))   // embedded newline preserved
        #expect(out.contains("\" 007 \""))           // quoted leading/trailing spaces preserved
    }

    @Test("CSV parser keeps a final quoted empty record")
    func csvFinalEmptyRecord() {
        let rows = CSVConverter.parseCSV("value\n\"\"")
        #expect(rows.count == 2)
        #expect(rows.last == [""])
    }

    @Test("CSV cell with a backslash and a pipe round-trips through the Markdown table")
    func csvBackslashPipeCell() async throws {
        let csv = "Col\na\\b|c"   // value: a\b|c (backslash, then a literal pipe)
        let result = try await PicoDocsEngine.convert(data: Data(csv.utf8), filename: "t.csv")
        #expect(result.markdown().contains("a\\\\b\\|c"))   // escaped in the table as a\\b\|c
        let text = try DocumentRenderer.render(result, to: .plaintext)
        #expect(text.contains("a\\b|c"))                     // unescaped back to a\b|c
    }

    @Test("EPUB converts spine chapters and reads metadata")
    func epub() async throws {
        let result = try await PicoDocsEngine.convert(data: Fixture.data("sample", "epub"), filename: "sample.epub")
        #expect(result.markdown().contains("Hello from an EPUB chapter."))
        #expect(result.title == "Sample EPUB")
    }

    @Test("RTF converts to Markdown with paragraphs and emphasis")
    func rtf() async throws {
        let rtf = "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Times New Roman;}}Hello \\b world\\b0 . This is \\i italic\\i0  text.\\par Second paragraph here.\\par}"
        let md = try await PicoDocsEngine.convert(data: Data(rtf.utf8), filename: "sample.rtf").markdown()
        #expect(md.contains("**world**"))
        #expect(md.contains("*italic*"))
        #expect(md.contains("Second paragraph here."))
        // Control tables are skipped, and no raw control words leak through.
        #expect(!md.contains("Times New Roman"))
        #expect(!md.contains("\\rtf"))
    }

    @Test("RTF keeps a \\uN char and skips its \\'hh fallback (no duplicate)")
    func rtfUnicodeFallback() async throws {
        // A U+2019 right single quote written as the control word u8217, with a
        // hex-escape CP1252 fallback, must yield one quote -- not the quote plus
        // the raw fallback byte.
        let rtf = "{\\rtf1\\ansi\\uc1 It\\u8217\\'92s fine.\\par}"
        let md = try await PicoDocsEngine.convert(data: Data(rtf.utf8), filename: "q.rtf").markdown()
        #expect(md.contains("It\u{2019}s fine."))
        #expect(!md.contains("\u{0092}"))
    }

    @Test("RTF hex escapes decode via Windows-1252, not raw Latin-1")
    func rtfWindows1252() async throws {
        // 0x93/0x94 are CP1252 curly double quotes; 0x97 is an em dash. As raw
        // Latin-1 these would be invisible C1 control characters.
        let rtf = "{\\rtf1\\ansi \\'93quoted\\'94 and a dash\\'97here.\\par}"
        let md = try await PicoDocsEngine.convert(data: Data(rtf.utf8), filename: "q.rtf").markdown()
        #expect(md.contains("\u{201C}quoted\u{201D}"))
        #expect(md.contains("\u{2014}"))
    }

    @Test("RTF reassembles multibyte DBCS \\'hh escapes (Shift-JIS) into characters")
    func rtfDBCSShiftJIS() async throws {
        // \ansicpg932 = Shift-JIS, a double-byte code page. Each CJK character is
        // two consecutive \'hh escapes: あ = 0x82 0xA0, 日 = 0x93 0xFA,
        // 本 = 0x96 0x7B. Decoded one byte at a time these would be mojibake.
        let rtf = "{\\rtf1\\ansi\\ansicpg932 \\'82\\'a0\\'93\\'fa\\'96\\'7b done.\\par}"
        let md = try await PicoDocsEngine.convert(data: Data(rtf.utf8), filename: "jp.rtf").markdown()
        #expect(md.contains("\u{3042}\u{65E5}\u{672C}"))   // あ日本
        #expect(md.contains("done."))
    }

    @Test("RTF DBCS character split across a raw line-wrap newline stays intact")
    func rtfDBCSAcrossNewline() async throws {
        // RTF wraps long lines with raw CRLFs; a double-byte char can land across
        // one (日 = 0x93 0xFA emitted as \'93 <CRLF> \'fa). The raw newline must
        // not flush the byte buffer mid-character.
        let rtf = "{\\rtf1\\ansi\\ansicpg932 \\'93\r\n\\'fa done.\\par}"
        let md = try await PicoDocsEngine.convert(data: Data(rtf.utf8), filename: "jp.rtf").markdown()
        #expect(md.contains("\u{65E5}"))   // 日
        #expect(md.contains("done."))
    }

    @Test("RTF DBCS run keeps valid characters before a malformed trailing byte")
    func rtfDBCSPartialTail() async throws {
        // あ (0x82 0xA0) followed by a dangling lead byte 0x82: the whole run fails
        // to decode, but the valid leading character must survive (the bad byte
        // alone falls back) rather than corrupting the entire run.
        let rtf = "{\\rtf1\\ansi\\ansicpg932 \\'82\\'a0\\'82 X\\par}"
        let md = try await PicoDocsEngine.convert(data: Data(rtf.utf8), filename: "jp.rtf").markdown()
        #expect(md.contains("\u{3042}"))   // あ preserved
        #expect(md.contains("X"))
    }

    @Test("RTF combines \\uN surrogate pairs into astral characters")
    func rtfSurrogatePair() async throws {
        // U+1F600 as a UTF-16 surrogate pair (\uc0 means no fallback bytes).
        let rtf = "{\\rtf1\\ansi\\uc0\\u-10179\\u-8704 done.\\par}"
        let md = try await PicoDocsEngine.convert(data: Data(rtf.utf8), filename: "e.rtf").markdown()
        #expect(md.contains("\u{1F600}"))
        #expect(md.contains("done."))
    }

    @Test("RTF paragraph breaks inside skipped destinations don't split the body")
    func rtfIgnoredDestinationParagraphs() async throws {
        let rtf = "{\\rtf1\\ansi Hello{\\footnote\\par ignored}world.\\par}"
        let md = try await PicoDocsEngine.convert(data: Data(rtf.utf8), filename: "f.rtf").markdown()
        #expect(md.contains("Helloworld."))
    }

    @Test("A mislabeled .rtf without the RTF header throws (strict failure)")
    func rtfMislabeledThrows() async throws {
        let notRTF = Data("this is not actually an RTF file".utf8)
        await #expect(throws: (any Error).self) {
            _ = try await PicoDocsEngine.convert(data: notRTF, filename: "notes.rtf")
        }
    }

    @Test("RTF special-character control words become punctuation")
    func rtfSpecialChars() async throws {
        let rtf = "{\\rtf1\\ansi A\\emdash B, \\bullet item, \\ldblquote q\\rdblquote .\\par}"
        let md = try await PicoDocsEngine.convert(data: Data(rtf.utf8), filename: "s.rtf").markdown()
        #expect(md.contains("A\u{2014}B"))            // em dash
        #expect(md.contains("\u{2022}"))              // bullet
        #expect(md.contains("\u{201C}q\u{201D}"))     // curly double quotes
    }

    @Test("RTF honors a declared non-1252 code page for hex escapes")
    func rtfCodePage1251() async throws {
        // CP1251: 0xE0 -> U+0430, 0xE1 -> U+0431 (Cyrillic a/b).
        let rtf = "{\\rtf1\\ansi\\ansicpg1251 \\'e0\\'e1 done.\\par}"
        let md = try await PicoDocsEngine.convert(data: Data(rtf.utf8), filename: "c.rtf").markdown()
        #expect(md.contains("\u{0430}\u{0431}"))
    }

    @Test("RTF \\line is a hard break and \\page separates content")
    func rtfLineAndPageBreaks() async throws {
        let rtf = "{\\rtf1\\ansi Line one\\line Line two.\\page Next page.\\par}"
        let md = try await PicoDocsEngine.convert(data: Data(rtf.utf8), filename: "l.rtf").markdown()
        #expect(md.contains("Line one  \nLine two."))   // hard break preserved
        #expect(md.contains("Next page."))
        #expect(!md.contains("Line two.Next page."))     // \page kept them separate
    }

    @Test("RTF \\binN binary payload doesn't corrupt brace parsing")
    func rtfBinaryPayload() async throws {
        // The byte after \bin1 is a '}' that must not close the \pict group.
        let rtf = "{\\rtf1\\ansi Before {\\pict\\bin1 }X} After.\\par}"
        let md = try await PicoDocsEngine.convert(data: Data(rtf.utf8), filename: "b.rtf").markdown()
        #expect(md.contains("Before"))
        #expect(md.contains("After."))
        #expect(!md.contains("X"))
    }

    @Test("A corrupt DOCX throws instead of degrading to plain text")
    func corruptDocxIsStrict() async throws {
        // Detected as .docx by the filename hint, but the bytes aren't a zip — the
        // registry must surface the failure, not fall through to PlainTextConverter.
        let bogus = Data("this is definitely not a zip archive".utf8)
        await #expect(throws: (any Error).self) {
            _ = try await PicoDocsEngine.convert(data: bogus, filename: "broken.docx")
        }
    }

    #if canImport(PDFKit)
    @Test("PDF extracts text via PDFKit")
    func pdf() async throws {
        let result = try await PicoDocsEngine.convert(
            data: Fixture.data("TSLA-Q3-2024-Update", "pdf"),
            filename: "TSLA-Q3-2024-Update.pdf"
        )
        #expect(!result.markdown().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    #endif
}

@Suite("Document renderer")
struct DocumentRendererTests {

    @Test("Markdown rendering joins sections")
    func markdown() throws {
        let result = ConverterResult(title: "T", sections: [
            DocumentSection(kind: .body, markdown: "# Hi"),
            DocumentSection(kind: .body, markdown: "second"),
        ])
        let rendered = try DocumentRenderer.render(result, to: .markdown)
        #expect(rendered.contains("# Hi"))
        #expect(rendered.contains("second"))
    }

    @Test("HTML rendering converts headings, emphasis, links, and tables")
    func html() throws {
        let result = ConverterResult(title: "Doc", sections: [
            DocumentSection(kind: .body, markdown: "# Title\n\nHello **world** and a [link](https://example.com).\n\n| A | B |\n| --- | --- |\n| 1 | 2 |"),
        ])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("<h1>Title</h1>"))
        #expect(html.contains("<strong>world</strong>"))
        #expect(html.contains("<a href=\"https://example.com\">link</a>"))
        #expect(html.contains("<th>A</th>"))
        #expect(html.contains("<td>1</td>"))
    }

    @Test("HTML rendering escapes special characters including quotes")
    func htmlEscaping() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "1 < 2 & 3 > 0 with \"quotes\" and 'single'"),
        ])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("1 &lt; 2 &amp; 3 &gt; 0 with &quot;quotes&quot; and &#39;single&#39;"))
    }

    @Test("HTML rendering escapes quotes in link URLs (no attribute breakout)")
    func htmlLinkURLEscaping() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "[x](https://e.com/a\" onmouseover=\"alert(1))"),
        ])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(!html.contains("a\" onmouseover=\"alert"))   // the raw quote cannot close href
        #expect(html.contains("&quot;"))
    }

    @Test("HTML rendering neutralizes script URLs in links and images")
    func htmlScriptURLsNeutralized() throws {
        let markdown = """
        [a](javascript:alert) [**b**](JaVaScRiPt:alert) [c](java\tscript:alert)
        [d](vbscript:msgbox) [e](data:text/html;base64,PHNjcmlwdD4=)
        ![f](javascript:alert) ![g](data:image/svg+xml;base64,PHN2Zz4=)
        [ok](https://example.com) [mail](mailto:a@example.com) [rel](docs/a:b.html) [frag](#top)
        ![pic](chart.png)
        """
        let html = try DocumentRenderer.render(ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: markdown),
        ]), to: .html)
        #expect(!html.lowercased().contains("javascript:"))
        #expect(!html.contains("java\tscript"))
        #expect(!html.contains("vbscript:"))
        #expect(!html.contains("data:text/html"))
        // The visible text (and its emphasis) survives; only the URL is dropped.
        #expect(html.contains("<p>a <strong>b</strong> c<br>\nd e<br>\nf <img"))
        // Safe destinations still render as live links/images.
        #expect(html.contains("<img src=\"data:image/svg+xml;base64,PHN2Zz4=\" alt=\"g\">"))
        #expect(html.contains("<a href=\"https://example.com\">ok</a>"))
        #expect(html.contains("<a href=\"mailto:a@example.com\">mail</a>"))
        #expect(html.contains("<a href=\"docs/a:b.html\">rel</a>"))
        #expect(html.contains("<a href=\"#top\">frag</a>"))
        #expect(html.contains("<img src=\"chart.png\" alt=\"pic\">"))
    }

    @Test("Table cells round-trip backslashes and escaped pipes")
    func tableCellBackslashEscaping() throws {
        // Cell value `a\b|c`, escaped in the table as `a\\b\|c`.
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "| K | V |\n| --- | --- |\n| key | a\\\\b\\|c |"),
        ])
        // Plaintext re-parses the table: `\\` -> `\`, `\|` -> `|`, and the escaped
        // pipe does not split the cell.
        #expect(try DocumentRenderer.render(result, to: .plaintext).contains("a\\b|c"))
        // HTML keeps the literal backslash and pipe in the cell.
        #expect(try DocumentRenderer.render(result, to: .html).contains("<td>a\\b|c</td>"))
    }

    @Test("Table row without a closing delimiter keeps a trailing escaped pipe")
    func tableCellTrailingEscapedPipe() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "| K | V |\n| --- | --- |\n| key | a\\|"),
        ])
        // The trailing `\|` is a literal pipe, not the (absent) closing delimiter.
        #expect(try DocumentRenderer.render(result, to: .plaintext).contains("key\ta|"))
    }

    @Test("Footnote references inside code spans are not rewritten (HTML)")
    func footnoteCodeSpanHTML() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "Body[^fn1] and code `[^fn1]` here.\n\n[^fn1]: note"),
        ])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("<code>[^fn1]</code>"))                          // code span kept literal
        #expect(html.contains("Body<sup class=\"footnote-ref\"><a href=\"#fn-fn1\">1</a></sup>"))
        #expect(html.components(separatedBy: "<sup class=\"footnote-ref\">").count == 2)   // only the real ref
    }

    @Test("Footnote references inside code spans are not rewritten (plaintext)")
    func footnoteCodeSpanPlaintext() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "Body[^fn1] code `[^fn1]`.\n\n[^fn1]: note"),
        ])
        let text = try DocumentRenderer.render(result, to: .plaintext)
        #expect(text.contains("Body[1] code [^fn1]."))   // real ref -> [1]; code span literal
        #expect(text.contains("[1] note"))
    }

    @Test("Footnote definitions inside code fences stay as code")
    func footnoteDefinitionInFence() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "Intro[^fn1]\n\n```\n[^fn1]: not a real note\n```\n\n[^fn1]: real note"),
        ])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("<pre><code>[^fn1]: not a real note</code></pre>"))   // fenced def preserved
        #expect(html.contains("<li id=\"fn-fn1\">real note</li>"))                   // real def extracted
        #expect(html.contains("Intro<sup class=\"footnote-ref\">"))
    }

    @Test("Footnote ids are HTML-escaped in attributes (no breakout)")
    func footnoteIdEscapedHTML() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "Ref[^a\"x]more\n\n[^a\"x]: note text"),
        ])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("href=\"#fn-a&quot;x\""))     // quote escaped in the ref link
        #expect(html.contains("<li id=\"fn-a&quot;x\">"))   // and in the definition anchor
        #expect(!html.contains("#fn-a\"x"))                 // no raw-quote attribute breakout
    }

    @Test("Repeated footnote references produce no duplicate element ids")
    func footnoteRepeatedReferenceHTML() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "First[^fn1] then again[^fn1].\n\n[^fn1]: note"),
        ])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(!html.contains("id=\"fnref-"))                                            // references carry no id
        #expect(html.components(separatedBy: "<sup class=\"footnote-ref\">").count == 3)   // both refs rendered
        #expect(html.contains("<li id=\"fn-fn1\">note</li>"))
    }

    @Test("Footnote numbering ignores code markers and drops unreferenced notes")
    func footnoteNumberingIgnoresCode() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "Intro `[^a]` then[^b].\n\n[^a]: Note A\n[^b]: Note B"),
        ])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("then<sup class=\"footnote-ref\"><a href=\"#fn-b\">1</a></sup>"))  // b is 1 (code `[^a]` ignored)
        #expect(html.contains("<code>[^a]</code>"))            // code marker preserved
        #expect(html.contains("<li id=\"fn-b\">Note B</li>"))   // b rendered
        #expect(!html.contains("Note A"))                       // a referenced only in code -> dropped
    }

    @Test("Footnote references inside note bodies are rendered")
    func footnoteNestedReferenceHTML() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "Body[^a]\n\n[^a]: see [^b]\n[^b]: other"),
        ])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("Body<sup class=\"footnote-ref\"><a href=\"#fn-a\">1</a></sup>"))
        #expect(html.contains("<li id=\"fn-a\">see <sup class=\"footnote-ref\"><a href=\"#fn-b\">2</a></sup></li>"))
        #expect(html.contains("<li id=\"fn-b\">other</li>"))
    }

    @Test("A footnote token consumed by a link is not orphaned")
    func footnoteConsumedByLink() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "[see[^fn1](https://e.com)\n\n[^fn1]: note"),
        ])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("<a href=\"https://e.com\">see[^fn1</a>"))   // link wins; label stays literal
        #expect(!html.contains("<section class=\"footnotes\">"))            // no orphaned note section
    }

    @Test("A footnote label defined twice renders only once")
    func footnoteDuplicateDefinition() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "Body[^a]\n\n[^a]: first\n[^a]: second"),
        ])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.components(separatedBy: "<li id=\"fn-a\">").count == 2)   // exactly one definition
        #expect(html.contains("<li id=\"fn-a\">first</li>"))                    // first definition wins
        #expect(!html.contains("second"))
    }

    @Test("Footnote definitions indented up to three spaces are recognized")
    func footnoteIndentedDefinition() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "Body[^a]\n\n   [^a]: note"),   // 3-space indent
        ])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("Body<sup class=\"footnote-ref\"><a href=\"#fn-a\">1</a></sup>"))
        #expect(html.contains("<li id=\"fn-a\">note</li>"))
        #expect(!html.contains("[^a]: note"))   // extracted, not left literal in the body
    }

    @Test("Body footnote references keep document order ahead of nested ones")
    func footnoteNestedNumberingOrder() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "Body[^a] then[^b]\n\n[^a]: see [^c]\n[^b]: b\n[^c]: c"),
        ])
        let html = try DocumentRenderer.render(result, to: .html)
        // Body refs are 1 then 2 (not 1 then 3); the note-only ref [^c] is 3.
        #expect(html.contains("Body<sup class=\"footnote-ref\"><a href=\"#fn-a\">1</a></sup> then<sup class=\"footnote-ref\"><a href=\"#fn-b\">2</a></sup>"))
        #expect(html.contains("<li id=\"fn-a\">see <sup class=\"footnote-ref\"><a href=\"#fn-c\">3</a></sup></li>"))
        #expect(html.contains("<li id=\"fn-b\">b</li>"))
        #expect(html.contains("<li id=\"fn-c\">c</li>"))
    }

    @Test("Multi-paragraph footnotes keep blank-line continuations out of the body")
    func footnoteMultiParagraph() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "Body[^a]\n\n[^a]: first\n\n    second"),
        ])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("second</li>"))     // continuation captured inside the note
        #expect(!html.contains("<p>second</p>"))   // not leaked as a body paragraph
    }

    @Test("HTML rendering handles combined and nested emphasis")
    func htmlEmphasis() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "***both*** and **bold *inner* bold**"),
        ])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("<strong><em>both</em></strong>"))
        #expect(html.contains("<strong>bold <em>inner</em> bold</strong>"))
    }

    @Test("Code spans keep Markdown metacharacters literal")
    func htmlCodeSpan() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "Use `*value*` literally."),
        ])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("<code>*value*</code>"))
        #expect(!html.contains("<em>value</em>"))
    }

    @Test("CSV keeps all-dash data rows after the header separator")
    func csvAllDashDataRow() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .sheet, markdown: "| A | B |\n| --- | --- |\n| - | - |\n| 1 | 2 |"),
        ])
        let csv = try DocumentRenderer.render(result, to: .csv)
        #expect(csv.contains("A,B"))
        #expect(csv.contains("-,-"))      // the all-dash DATA row is preserved
        #expect(csv.contains("1,2"))
    }

    @Test("Plaintext rendering strips Markdown syntax")
    func plaintext() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "# Heading\n\nHello **world** with a [link](https://example.com)."),
        ])
        let text = try DocumentRenderer.render(result, to: .plaintext)
        #expect(text.contains("Heading"))
        #expect(text.contains("Hello world with a link."))
        #expect(!text.contains("**"))
        #expect(!text.contains("#"))
        #expect(!text.contains("]("))
    }

    @Test("CSV rendering turns Markdown tables into CSV rows")
    func csv() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .sheet, markdown: "| Name | Score |\n| --- | --- |\n| Alice | 42 |\n| Bob, Jr | 7 |"),
        ])
        let csv = try DocumentRenderer.render(result, to: .csv)
        #expect(csv.contains("Name,Score"))
        #expect(csv.contains("Alice,42"))
        #expect(csv.contains("\"Bob, Jr\",7"))   // a field with a comma is quoted
    }

    @Test("XML rendering wraps sections with escaped content")
    func xml() throws {
        let result = ConverterResult(title: "T & U", sections: [
            DocumentSection(title: "S", kind: .body, markdown: "a < b"),
        ])
        let xml = try DocumentRenderer.render(result, to: .xml)
        #expect(xml.contains("<?xml version=\"1.0\""))
        #expect(xml.contains("title=\"T &amp; U\""))
        #expect(xml.contains("<section kind=\"body\" title=\"S\">"))
        #expect(xml.contains("a &lt; b"))
    }

    @Test("Emphasis characters in a link URL aren't rewritten; label emphasis is kept")
    func htmlLinkURLEmphasis() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "[x](https://e.com/*id*) and [**bold**](https://e.com)"),
        ])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("href=\"https://e.com/*id*\""))   // URL kept literal
        #expect(!html.contains("<em>id</em>"))
        #expect(html.contains("<a href=\"https://e.com\"><strong>bold</strong></a>"))
    }

    @Test("HTML handles angle-bracket link destinations with spaces and parens")
    func htmlAngleBracketLink() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "[label](<https://e.com/a b(1)>)"),
        ])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("<a href=\"https://e.com/a b(1)\">label</a>"))
    }

    @Test("CSV preserves fenced code lines instead of splitting them")
    func csvCodeFence() throws {
        let result = ConverterResult(sections: [
            DocumentSection(kind: .body, markdown: "Code:\n\n```\n| grep foo | wc -l |\n```"),
        ])
        let csv = try DocumentRenderer.render(result, to: .csv)
        #expect(csv.contains("| grep foo | wc -l |"))
        #expect(!csv.contains("grep foo,wc -l"))
    }
}
