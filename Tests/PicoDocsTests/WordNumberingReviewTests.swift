import Foundation
import Testing
import ZIPFoundation
import SwiftSoup
@testable import PicoDocs

struct WordNumberingReviewTests {
    @Test func bulletWithoutSuffixKeepsItsVisibleGlyph() async throws {
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"•\"/><w:suff w:val=\"nothing\"/></w:lvl><w:lvl w:ilvl=\"1\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        func paragraph(_ level: Int, _ content: String) -> String { "<w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/><w:ilvl w:val=\"\(level)\"/></w:numPr></w:pPr><w:r>\(content)</w:r></w:p>" }
        let document = "<w:document \(ns)><w:body>" + paragraph(0,"<w:t>Parent</w:t><w:br/><w:t>Continued</w:t>") + paragraph(1,"<w:t>Child</w:t>") + "</w:body></w:document>"
        let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name: "word/document.xml",data: Array(document.utf8)),(name: "word/numbering.xml",data: Array(numbering.utf8))]), filename: "tabs.docx")
        #expect(result.markdown().contains("- •Parent  \n   Continued"))
        #expect(result.markdown().contains("\n  - Child"))
        #expect(try DocumentRenderer.render(result, to: .plaintext).hasPrefix("- •Parent"))
        #expect(try DocumentRenderer.render(result, to: .html).components(separatedBy: "<ul").count - 1 == 2)
    }

    @Test func bulletTabSuffixControlsNestingAndPlaintextPadding() async throws {
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:suff w:val=\"tab\"/></w:lvl><w:lvl w:ilvl=\"1\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        func paragraph(_ level: Int, _ content: String) -> String { "<w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/><w:ilvl w:val=\"\(level)\"/></w:numPr></w:pPr><w:r>\(content)</w:r></w:p>" }
        let document = "<w:document \(ns)><w:body>" + paragraph(0,"<w:t>Parent</w:t><w:br/><w:t>Continued</w:t>") + paragraph(1,"<w:t>Child</w:t>") + "</w:body></w:document>"
        let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name: "word/document.xml",data: Array(document.utf8)),(name: "word/numbering.xml",data: Array(numbering.utf8))]), filename: "tabs.docx")
        #expect(result.markdown().contains("-\tParent  \n    Continued"))
        #expect(result.markdown().contains("\n    - Child"))
        #expect(try DocumentRenderer.render(result, to: .plaintext).hasPrefix("-\tParent"))
        #expect(try DocumentRenderer.render(result, to: .html).components(separatedBy: "<ul").count - 1 == 2)
    }

    @Test func decimalTabSuffixControlsNestingAndPlaintextPadding() async throws {
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:suff w:val=\"tab\"/></w:lvl><w:lvl w:ilvl=\"1\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        func paragraph(_ level: Int, _ content: String) -> String { "<w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/><w:ilvl w:val=\"\(level)\"/></w:numPr></w:pPr><w:r>\(content)</w:r></w:p>" }
        let document = "<w:document \(ns)><w:body>" + paragraph(0,"<w:t>Parent</w:t><w:br/><w:t>Continued</w:t>") + paragraph(1,"<w:t>Child</w:t>") + "</w:body></w:document>"
        let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name: "word/document.xml",data: Array(document.utf8)),(name: "word/numbering.xml",data: Array(numbering.utf8))]), filename: "tabs.docx")
        #expect(result.markdown().contains("1.\tParent  \n    Continued"))
        #expect(result.markdown().contains("\n    1. Child"))
        #expect(try DocumentRenderer.render(result, to: .plaintext).hasPrefix("1.\tParent"))
        #expect(try DocumentRenderer.render(result, to: .html).components(separatedBy: "<ol").count - 1 == 2)
    }

    @Test func wrappedTextBoxesRemainInNumberingOrder() async throws {
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        func item(_ text: String) -> String { "<w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>" }
        let document = "<w:document \(ns)><w:body>" + item("Before") + "<w:customXml><w:ins><w:p><w:r><w:drawing><w:txbxContent>" + item("Box") + "</w:txbxContent></w:drawing></w:r></w:p></w:ins></w:customXml>" + item("After") + "</w:body></w:document>"
        let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name: "word/document.xml",data: Array(document.utf8)),(name: "word/numbering.xml",data: Array(numbering.utf8))]), filename: "wrapped.docx")
        for text in ["1. Before","2. Box","3. After"] { #expect(result.markdown().contains(text)) }
        #expect(result.markdown().components(separatedBy: "Box").count == 2)
    }

    @Test func linkedSectionRestartsDefaultZeroAndLongLabels() throws {
        let numbering = """
        <w:numbering \(ns) xmlns:w15="http://schemas.microsoft.com/office/word/2012/wordml">
        <w:abstractNum w:abstractNumId="1"><w:numStyleLink w:val="Linked"/></w:abstractNum>
        <w:abstractNum w:abstractNumId="2" w15:restartNumberingAfterBreak="1"><w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/></w:lvl></w:abstractNum>
        <w:abstractNum w:abstractNumId="3" w15:restartNumberingAfterBreak="0"><w:numStyleLink w:val="Linked"/></w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="1"/></w:num>
        <w:num w:numId="2"><w:abstractNumId w:val="2"/></w:num>
        <w:num w:numId="3"><w:abstractNumId w:val="1"/><w:lvlOverride w:ilvl="0"><w:startOverride w:val="1000000000"/></w:lvlOverride></w:num>
        <w:num w:numId="4"><w:abstractNumId w:val="3"/></w:num>
        </w:numbering>
        """
        let styles = "<w:styles \(ns)><w:style w:styleId=\"Linked\"><w:pPr><w:numPr><w:numId w:val=\"2\"/></w:numPr></w:pPr></w:style></w:styles>"
        let archive = try #require(Archive(data: PagesConverterTests.makeZip([(name: "word/numbering.xml",data: Array(numbering.utf8)),(name: "word/styles.xml",data: Array(styles.utf8))]), accessMode: .read))
        let resolver = WordListNumbering(archive: archive)
        func prefix(_ id: Int) throws -> String? {
            let document = try SwiftSoup.parse("<w:numPr \(ns)><w:numId w:val=\"\(id)\"/></w:numPr>", "", SwiftSoup.Parser.xmlParser())
            return resolver.prefix(numPr: try document.getElementsByTag("w:numPr").first(), style: nil)
        }
        #expect(try prefix(1) == "0. "); #expect(try prefix(1) == "1. ")
        #expect(try prefix(4) == "0. ")
        resolver.sectionBreak()
        #expect(try prefix(1) == "0. "); #expect(try prefix(4) == "1. ")
        #expect(try prefix(3) == "- 1000000000. ")
        #expect(MarkdownList.isOrderedMarker("1000000000. Item") == nil)
    }

    @Test func inheritedNumberingUsesParagraphLanguageAndSuffixes() async throws {
        for (suffix, expected) in [("nothing", "un.Item"), ("space", "un. Item"), ("tab", "un.\tItem")] {
            let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"cardinalText\"/><w:lvlText w:val=\"%1.\"/><w:suff w:val=\"\(suffix)\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
            let styles = "<w:styles \(ns)><w:docDefaults><w:rPrDefault><w:rPr><w:lang w:val=\"en-US\"/></w:rPr></w:rPrDefault></w:docDefaults><w:style w:styleId=\"List\"><w:pPr><w:numPr><w:numId w:val=\"1\"/></w:numPr></w:pPr></w:style></w:styles>"
            let document = "<w:document \(ns)><w:body><w:p><w:pPr><w:pStyle w:val=\"List\"/><w:rPr><w:lang w:val=\"fr-FR\"/></w:rPr></w:pPr><w:r><w:t>Item</w:t></w:r></w:p></w:body></w:document>"
            let data = PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8)), (name: "word/styles.xml", data: Array(styles.utf8))])
            let result = try await PicoDocsEngine.convert(data: data, filename: "language.docx")
            #expect(result.markdown().contains(expected))
            #expect(try DocumentRenderer.render(result, to: .plaintext).contains(expected))
        }
    }

    @Test func decimalNoSuffixSurvivesOverrides() async throws {
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:suff w:val=\"space\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/><w:lvlOverride w:ilvl=\"0\"><w:lvl w:ilvl=\"0\"><w:suff w:val=\"nothing\"/></w:lvl></w:lvlOverride></w:num></w:numbering>"
        let document = "<w:document \(ns)><w:body><w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>Item</w:t></w:r></w:p></w:body></w:document>"
        let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8))]), filename: "suffix.docx")
        #expect(result.markdown() == "- 1.Item")
        for format in [ExportFileType.plaintext,.html] { #expect(try DocumentRenderer.render(result, to: format).contains("1.Item")) }
    }

    @Test func textBoxCountersFollowAnchorsAndSectionBreaks() async throws {
        let numbering = "<w:numbering \(ns) xmlns:w15=\"http://schemas.microsoft.com/office/word/2012/wordml\"><w:abstractNum w:abstractNumId=\"1\" w15:restartNumberingAfterBreak=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        func item(_ text: String) -> String { "<w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>" }
        for table in [false,true] {
            let anchor = "<w:p><w:r><w:drawing><w:txbxContent>" + item("Box") + "</w:txbxContent></w:drawing></w:r></w:p>"
            let block = table ? "<w:tbl><w:tr><w:tc>" + anchor + "</w:tc></w:tr></w:tbl>" : anchor
            let document = "<w:document \(ns)><w:body>" + item("Before") + block + item("After") + "<w:p><w:pPr><w:sectPr/></w:pPr></w:p>" + item("Reset") + "</w:body></w:document>"
            let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8))]), filename: "anchor.docx")
            for expected in ["1. Before", "2. Box", "3. After", "1. Reset"] { #expect(result.markdown().contains(expected)) }
            #expect(result.markdown().components(separatedBy: "Box").count == 2)
        }
    }

    @Test func literalLabelsLegalNumberingAndLocalizedText() async throws {
        func convert(format: String, label: String, start: Int = 1, language: String = "en-US", extra: String = "", override: String = "") async throws -> ConverterResult {
            let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"upperRoman\"/></w:lvl><w:lvl w:ilvl=\"1\"><w:start w:val=\"\(start)\"/><w:numFmt w:val=\"\(format)\"/><w:lvlText w:val=\"\(label)\"/>\(extra)</w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/>\(override)</w:num></w:numbering>"
            let document = "<w:document \(ns)><w:body><w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/><w:ilvl w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>Item</w:t></w:r></w:p></w:body></w:document>"
            let styles = "<w:styles \(ns)><w:docDefaults><w:rPrDefault><w:rPr><w:lang w:val=\"\(language)\"/></w:rPr></w:rPrDefault></w:docDefaults></w:styles>"
            return try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8)), (name: "word/styles.xml", data: Array(styles.utf8))]), filename: "labels.docx")
        }
        let literal = try await convert(format: "decimal", label: "`%2` _x_ *y* [z]")
        for format in [ExportFileType.html, .plaintext] { #expect(try DocumentRenderer.render(literal, to: format).contains("`1` _x_ *y* [z] Item")) }
        let legal = try await convert(format: "decimal", label: "%1.%2.", extra: "<w:isLgl/>")
        #expect(legal.markdown().contains("1.1. Item"))
        let disabled = try await convert(format: "decimal", label: "%1.%2.", extra: "<w:isLgl/>", override: #"<w:lvlOverride w:ilvl="1"><w:lvl w:ilvl="1"><w:isLgl w:val="0"/></w:lvl></w:lvlOverride>"#)
        #expect(disabled.markdown().contains("I.1. Item"))
        let enabled = try await convert(format: "decimal", label: "%1.%2.", override: #"<w:lvlOverride w:ilvl="1"><w:lvl w:ilvl="1"><w:isLgl/></w:lvl></w:lvlOverride>"#)
        #expect(enabled.markdown().contains("1.1. Item"))
        for (format, start, language, expected) in [("cardinalText", 1, "en-US", "one"), ("ordinalText", 1, "en-US", "first"), ("ordinalText", 22, "en-GB", "twenty-second"), ("cardinalText", 2, "fr-FR", "deux")] {
            let result = try await convert(format: format, label: "%2.", start: start, language: language)
            #expect(try DocumentRenderer.render(result, to: .plaintext).contains(expected + ". Item"))
        }
    }

    @Test func imageAltBackslashesAreLiteral() throws {
        let source = #"<w:drawing><wp:docPr descr="\* \` \["/><a:blip r:embed="image"/></w:drawing>"#
        let drawing = try #require(SwiftSoup.parse(source, "", SwiftSoup.Parser.xmlParser()).getElementsByTag("w:drawing").first())
        let markdown = WordConverter.imageMarkdown(in: drawing, relationships: ["image": "media/a.png"])
        let result = ConverterResult(sections: [.init(markdown: markdown)])
        for format in [ExportFileType.html, .plaintext] { #expect(try DocumentRenderer.render(result, to: format).contains(#"\* \` \["#)) }
    }

    @Test func discardedPrefixesDoNotBecomeVisibleParents() async throws {
        let levels = (0...2).map { "<w:lvl w:ilvl=\"\($0)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/></w:lvl>" }.joined()
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\">\(levels)</w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        func paragraph(_ text: String, level: Int, style: String = "") -> String {
            "<w:p><w:pPr>\(style)<w:numPr><w:numId w:val=\"1\"/><w:ilvl w:val=\"\(level)\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>"
        }
        for discarded in ["<w:tbl><w:tr><w:tc>" + paragraph("Table item", level: 1) + "</w:tc></w:tr></w:tbl>", paragraph("Heading", level: 1, style: "<w:pStyle w:val=\"Heading1\"/>")] {
            let document = "<w:document \(ns)><w:body>" + paragraph("Parent", level: 0) + discarded + paragraph("Child", level: 2) + paragraph("Next level one", level: 1) + "</w:body></w:document>"
            let data = PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8))])
            let result = try await PicoDocsEngine.convert(data: data, filename: "discarded.docx")
            #expect(result.markdown().contains("\n   1. Child"))
            #expect(!result.markdown().contains("\n      1. Child"))
            #expect(result.markdown().contains("2. Next level one"))
        }
    }

    @Test func ordinalLabelsAndOrphanLevelsRemainVisibleLists() async throws {
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"2\"><w:start w:val=\"1\"/><w:numFmt w:val=\"ordinal\"/><w:lvlText w:val=\"%3.\"/></w:lvl><w:lvl w:ilvl=\"3\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        func paragraph(_ text: String, level: Int) -> String {
            "<w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/><w:ilvl w:val=\"\(level)\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>"
        }
        let body = (1...23).map { paragraph("Item \($0)", level: 2) }.joined() + paragraph("Child", level: 3)
        let document = "<w:document \(ns)><w:body>\(body)</w:body></w:document>"
        let data = PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "ordinal.docx")
        #expect(result.markdown().hasPrefix("- 1st. Item 1"))
        for label in ["2nd.", "3rd.", "4th.", "11th.", "12th.", "13th.", "21st.", "22nd.", "23rd."] { #expect(result.markdown().contains(label)) }
        #expect(!result.markdown().contains("    - "))
        #expect(result.markdown().contains("\n  1. Child"))
        for format in [ExportFileType.html, .plaintext] {
            let text = try DocumentRenderer.render(result, to: format)
            #expect(text.contains("1st. Item 1")); #expect(text.contains("23rd. Item 23"))
        }
    }

    @Test func sectionBreakClearsLibreOfficeAliasesAndKeepsDecimalZero() throws {
        let numbering = "<w:numbering \(ns) xmlns:w15=\"http://schemas.microsoft.com/office/word/2012/wordml\"><w:abstractNum w:abstractNumId=\"1\" w15:restartNumberingAfterBreak=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimalZero\"/><w:lvlText w:val=\"Section %1:\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num><w:num w:numId=\"2\"><w:abstractNumId w:val=\"1\"/><w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"7\"/></w:lvlOverride></w:num></w:numbering>"
        let data = PagesConverterTests.makeZip([(name: "word/numbering.xml", data: Array(numbering.utf8)), (name: "docProps/app.xml", data: Array("<Properties><Application>LibreOffice</Application></Properties>".utf8))])
        let resolver = WordListNumbering(archive: try #require(Archive(data: data, accessMode: .read)))
        func prefix(_ id: Int) throws -> String? {
            let document = try SwiftSoup.parse("<w:numPr \(ns)><w:numId w:val=\"\(id)\"/></w:numPr>", "", SwiftSoup.Parser.xmlParser())
            return resolver.prefix(numPr: try document.getElementsByTag("w:numPr").first(), style: nil)
        }
        #expect(try prefix(1) == "- Section 01: ")
        resolver.sectionBreak()
        #expect(try prefix(2) == "- Section 07: ")
        #expect(try prefix(1) == "- Section 01: ")
        for value in 2...9 { #expect(try prefix(1) == "- Section 0\(value): ") }
        #expect(try prefix(1) == "- Section 10: ")
    }

    @Test func listChildrenRequireParentContentIndentation() throws {
        for source in ["- first\n - second", "10. first\n 11. second", "  - first\n- second"] {
            let result = ConverterResult(sections: [.init(markdown: source)])
            let html = try DocumentRenderer.render(result, to: .html)
            #expect(html.components(separatedBy: "<li").count - 1 == 2)
            #expect(html.components(separatedBy: source.contains("first") && source.contains("10.") ? "<ol" : "<ul").count - 1 == 1)
        }
        for source in ["- first\n  - child", "10. first\n    - child", "- first\n\t- child"] {
            let result = ConverterResult(sections: [.init(markdown: source)])
            let html = try DocumentRenderer.render(result, to: .html)
            #expect(html.components(separatedBy: "<ul").count - 1 == (source.hasPrefix("10.") ? 1 : 2))
            #expect(html.contains("child"))
        }
    }

    @Test func hiddenParentCountersAdvanceBeforeMarkerSuppression() async throws {
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"none\"/></w:lvl><w:lvl w:ilvl=\"1\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:lvlText w:val=\"%1.%2.\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        func paragraph(_ text: String, level: Int) -> String {
            "<w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/><w:ilvl w:val=\"\(level)\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>"
        }
        let document = "<w:document \(ns)><w:body>" + paragraph("Parent A", level: 0) + paragraph("Child A", level: 1) + paragraph("Parent B", level: 0) + paragraph("Child B", level: 1) + "</w:body></w:document>"
        let data = PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "hidden.docx")
        #expect(result.markdown().contains("1.1. Child A"))
        #expect(result.markdown().contains("2.1. Child B"))
        #expect(!result.markdown().contains("1. Parent A"))
        #expect(!result.markdown().contains("2. Parent B"))
    }

    @Test func tableEscapesAreCanonicalAndDecodedOnce() async throws {
        let csv = try await PicoDocsEngine.convert(data: Data("value\n\\* regex".utf8), filename: "literal.csv")
        let document = #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:tbl><w:tr><w:tc><w:p><w:r><w:t>\* regex</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>"#
        let word = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8))]), filename: "literal.docx")
        #expect(word.markdown().contains(#"\\* regex"#))
        #expect(!word.markdown().contains(#"\\\\* regex"#))
        for result in [csv, word] {
            for format in [ExportFileType.html, .plaintext, .csv] {
                #expect(try DocumentRenderer.render(result, to: format).contains(#"\* regex"#))
            }
        }
    }

    @Test func sectionRestartsLabelsAndDocumentDefaults() async throws {
        let numbering = """
        <w:numbering \(ns) xmlns:w15="http://schemas.microsoft.com/office/word/2012/wordml">
        <w:abstractNum w:abstractNumId="1" w15:restartNumberingAfterBreak="1">
        <w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="Article %1:"/></w:lvl>
        <w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1.%2."/></w:lvl>
        </w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="1"/></w:num>
        </w:numbering>
        """
        let styles = "<w:styles \(ns)><w:docDefaults><w:pPrDefault><w:pPr><w:numPr><w:numId w:val=\"1\"/><w:ilvl w:val=\"0\"/></w:numPr></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type=\"paragraph\" w:styleId=\"Named\"><w:pPr/></w:style></w:styles>"
        func paragraph(_ text: String, properties: String = "") -> String { "<w:p><w:pPr><w:pStyle w:val=\"Named\"/>\(properties)</w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>" }
        let document = "<w:document \(ns)><w:body>" + paragraph("First") + paragraph("Child", properties: "<w:numPr><w:ilvl w:val=\"1\"/></w:numPr>") + paragraph("Second", properties: "<w:sectPr/>") + paragraph("Restarted") + "</w:body></w:document>"
        let data = PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8)), (name: "word/styles.xml", data: Array(styles.utf8))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "sections.docx")
        #expect(result.markdown().contains("Article 1: First"))
        #expect(result.markdown().contains("1.1. Child"))
        #expect(result.markdown().contains("Article 2: Second"))
        #expect(result.markdown().contains("Article 1: Restarted"))
    }

    @Test func literalContinuationAndNestedReadingOrder() throws {
        let xml = try SwiftSoup.parse("<w:p><w:pPr><w:numPr/></w:pPr><w:r><w:t>First</w:t><w:br/><w:t>- literal</w:t><w:br/><w:t>2. literal number</w:t></w:r></w:p>", "", SwiftSoup.Parser.xmlParser())
        let paragraph = try #require(xml.getElementsByTag("w:p").first())
        let markdown = try #require(WordConverter.renderParagraph(paragraph, relationships: [:]))
        let result = ConverterResult(sections: [.init(markdown: markdown)])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.components(separatedBy: "<li>").count == 2)
        #expect(html.contains("- literal"))
        #expect(!html.contains("\\-"))
        let nested = ConverterResult(sections: [.init(markdown: "1. parent[^p]\n   - child[^c]\n   after child[^a]\n2. next\n\n[^p]: Parent\n[^c]: Child\n[^a]: After")])
        let plain = try DocumentRenderer.render(nested, to: .plaintext)
        #expect(plain.contains("1. parent[1]\n   - child[2]\n   after child[3]\n2. next"))
        let nestedHTML = try DocumentRenderer.render(nested, to: .html)
        let childEnd = try #require(nestedHTML.range(of: "</ul>"))
        let after = try #require(nestedHTML.range(of: "after child"))
        #expect(childEnd.upperBound < after.lowerBound)
    }

    @Test func sourceBackslashesSurviveListRendering() throws {
        let xml = try SwiftSoup.parse(#"<w:p><w:pPr><w:numPr/></w:pPr><w:r><w:t>First</w:t><w:br/><w:t>\- literal</w:t><w:br/><w:t>C:\folder\file</w:t></w:r></w:p>"#, "", SwiftSoup.Parser.xmlParser())
        let paragraph = try #require(xml.getElementsByTag("w:p").first())
        let markdown = try #require(WordConverter.renderParagraph(paragraph, relationships: [:]))
        let result = ConverterResult(sections: [.init(markdown: markdown)])
        for format in [ExportFileType.html, .plaintext, .csv] {
            let rendered = try DocumentRenderer.render(result, to: format)
            #expect(rendered.contains(#"\- literal"#))
            #expect(rendered.contains(#"C:\folder\file"#))
        }
    }

    private let ns = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""

    @Test func concreteCountersOverridesDefaultsAndRestarts() throws {
        let levels = """
        <w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/></w:lvl>
        <w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlRestart w:val="0"/></w:lvl>
        <w:lvl w:ilvl="2"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlRestart w:val="1"/></w:lvl>
        """
        let numbering = """
        <w:numbering \(ns)><w:abstractNum w:abstractNumId="1">\(levels)</w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="1"/></w:num>
        <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
        <w:num w:numId="3"><w:abstractNumId w:val="1"/><w:lvlOverride w:ilvl="1"><w:startOverride w:val="5"/></w:lvlOverride></w:num>
        <w:num w:numId="4"><w:abstractNumId w:val="1"/><w:lvlOverride w:ilvl="0"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl></w:lvlOverride></w:num>
        <w:num w:numId="5"><w:abstractNumId w:val="1"/><w:lvlOverride w:ilvl="0"><w:lvl w:ilvl="0"><w:start w:val="7"/></w:lvl></w:lvlOverride></w:num>
        </w:numbering>
        """
        let styles = "<w:styles \(ns)><w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:pPr><w:numPr><w:numId w:val=\"2\"/></w:numPr></w:pPr></w:style></w:styles>"
        let data = PagesConverterTests.makeZip([
            (name: "word/numbering.xml", data: Array(numbering.utf8)),
            (name: "word/styles.xml", data: Array(styles.utf8))
        ])
        let resolver = WordListNumbering(archive: try #require(Archive(data: data, accessMode: .read)))
        func prefix(_ id: Int, _ level: Int = 0) throws -> String? {
            let xml = try SwiftSoup.parse("<w:numPr \(ns)><w:numId w:val=\"\(id)\"/><w:ilvl w:val=\"\(level)\"/></w:numPr>", "", SwiftSoup.Parser.xmlParser())
            return resolver.prefix(numPr: try xml.getElementsByTag("w:numPr").first(), style: nil)
        }
        #expect(try prefix(1) == "1. ")
        #expect(try prefix(2) == "1. ")
        #expect(resolver.prefix(numPr: nil, style: nil) == "2. ")
        #expect(try prefix(3) == "1. ")
        #expect(try prefix(3, 1) == "   5. ")
        #expect(try prefix(4) == "- ")
        #expect(try prefix(5) == "7. ")
        #expect(try prefix(1, 1) == "   1. ")
        #expect(try prefix(1, 2) == "      1. ")
        #expect(try prefix(1, 1) == "   2. ")
        #expect(try prefix(1, 2) == "      2. ")
        #expect(try prefix(1) == "2. ")
        #expect(try prefix(1, 1) == "   3. ")
        #expect(try prefix(1, 2) == "      1. ")
    }

    @Test func emptyItemsAndHeadingsConsumeNumbers() async throws {
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        func paragraph(_ text: String, style: String = "") -> String {
            "<w:p><w:pPr>\(style)<w:numPr><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>"
        }
        let document = "<w:document \(ns)><w:body>" + paragraph("a") + paragraph("") + paragraph("c") + paragraph("heading", style: "<w:pStyle w:val=\"Heading1\"/>") + paragraph("e") + "</w:body></w:document>"
        let file = PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8))])
        let result = try await PicoDocsEngine.convert(data: file, filename: "list.docx")
        #expect(result.markdown().contains("3. c"))
        #expect(result.markdown().contains("5. e"))
    }

    @Test func followupNumberingRegressions() async throws {
        let numbering = """
        <w:numbering \(ns)>
        <w:abstractNum w:abstractNumId="1"><w:numStyleLink w:val="NumberingStyle"/></w:abstractNum>
        <w:abstractNum w:abstractNumId="2"><w:lvl w:ilvl="-1"><w:start w:val="1"/><w:lvlRestart w:val="1"/></w:lvl><w:lvl w:ilvl="0"><w:start w:val="5"/><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="1"/></w:num>
        <w:num w:numId="2"><w:abstractNumId w:val="2"/></w:num>
        </w:numbering>
        """
        let styles = "<w:styles \(ns)><w:style w:type=\"numbering\" w:styleId=\"NumberingStyle\"><w:pPr><w:numPr><w:numId w:val=\"2\"/></w:numPr></w:pPr></w:style></w:styles>"
        func item(_ text: String) -> String {
            "<w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>"
        }
        let body = item("Before") + "<w:tbl><w:tr><w:tc>" + item("Inside") + "</w:tc></w:tr></w:tbl>" + item("After")
        let document = "<w:document \(ns)><w:body>\(body)</w:body></w:document>"
        let data = PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8)), (name: "word/styles.xml", data: Array(styles.utf8))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "linked.docx")
        #expect(result.markdown().contains("5. Before"))
        #expect(result.markdown().contains("7. After"))
        for markdown in ["\t- item", "999999999999999999999999999999. item"] {
            let content = ConverterResult(sections: [DocumentSection(markdown: markdown)])
            #expect(try DocumentRenderer.render(content, to: .html).contains("item"))
            #expect(try DocumentRenderer.render(content, to: .plaintext).contains("item"))
        }
    }

    @Test func linkedOverridesAliasesAndRelocatedParts() throws {
        let numbering = """
        <w:numbering \(ns)>
        <w:abstractNum w:abstractNumId="001"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/></w:lvl><w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlRestart w:val="0"/></w:lvl></w:abstractNum>
        <w:abstractNum w:abstractNumId="2"><w:numStyleLink w:val="Linked"/></w:abstractNum>
        <w:abstractNum w:abstractNumId="3"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/></w:lvl></w:abstractNum>
        <w:num w:numId="001"><w:abstractNumId w:val="1"/></w:num>
        <w:num w:numId="2"><w:abstractNumId w:val="1"/><w:lvlOverride w:ilvl="0"><w:startOverride w:val="1"/></w:lvlOverride></w:num>
        <w:num w:numId="3"><w:abstractNumId w:val="2"/><w:lvlOverride w:ilvl="0"><w:lvl w:ilvl="0"><w:lvlRestart w:val="0"/></w:lvl></w:lvlOverride></w:num>
        <w:num w:numId="4"><w:abstractNumId w:val="3"/></w:num>
        </w:numbering>
        """
        let styles = "<w:styles \(ns)><w:style w:styleId=\"Linked\"><w:pPr><w:numPr><w:numId w:val=\"004\"/></w:numPr></w:pPr></w:style></w:styles>"
        let relationships = #"<Relationships><Relationship Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="lists/n.xml"/><Relationship Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="lists/s.xml"/></Relationships>"#
        let data = PagesConverterTests.makeZip([(name: "word/lists/n.xml", data: Array(numbering.utf8)), (name: "word/lists/s.xml", data: Array(styles.utf8)), (name: "word/_rels/document.xml.rels", data: Array(relationships.utf8)), (name: "docProps/app.xml", data: Array("<Properties><Application>LibreOffice</Application></Properties>".utf8))])
        let resolver = WordListNumbering(archive: try #require(Archive(data: data, accessMode: .read)))
        func prefix(_ id: String, _ level: Int = 0) throws -> String? {
            let doc = try SwiftSoup.parse("<w:numPr \(ns)><w:numId w:val=\"\(id)\"/><w:ilvl w:val=\"\(level)\"/></w:numPr>", "", SwiftSoup.Parser.xmlParser())
            return resolver.prefix(numPr: try doc.getElementsByTag("w:numPr").first(), style: nil)
        }
        #expect(try prefix("00") == nil)
        #expect(try prefix("+01") == "1. ")
        #expect(try prefix("1", 1) == "   1. ")
        #expect(try prefix("02") == "1. ")
        #expect(try prefix("1") == "2. ")
        #expect(try prefix("1", 1) == "   2. ")
        #expect(try prefix("3") == "- ")
    }

    @Test func looseNestedListsRenderWithSourceNumbers() throws {
        let result = ConverterResult(sections: [DocumentSection(markdown: "5. First\n\n   1. Child\n\n   2. Child two\n\n6. Second")])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("<ol start=\"5\">"))
        #expect(html.components(separatedBy: "<ol").count == 3)
        #expect(html.contains("Child two</li>\n</ol></li>"))
        let plain = try DocumentRenderer.render(result, to: .plaintext)
        #expect(plain == "5. First\n   1. Child\n   2. Child two\n6. Second")
    }
}
