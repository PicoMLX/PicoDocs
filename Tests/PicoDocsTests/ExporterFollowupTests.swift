import Foundation
import Testing
import ZIPFoundation
import SwiftSoup
#if canImport(AppKit)
import AppKit
#endif
@testable import PicoDocs

struct ExporterFollowupTests {
    @Test func inlinePlaceholdersKeepSourceDelimiterFlanking() {
        for source in ["[x](u)_em_", "`x`_em_", "_em_[x](u)", "_em_`x`", #"\*_em_"#] {
            #expect(MarkdownInlineParser.parse(source).contains(.emphasis([.text("em")])))
        }
        #expect(MarkdownInlineParser.parse("a_em_") == [.text("a_em_")])
        #expect(!MarkdownInlineParser.parse("_a\nb_").isEmpty)
    }

    @Test func portableTIFFAndWebPHeadersKeepImageAspectRatios() throws {
        func integer(_ value: UInt32, _ count: Int, little: Bool = true) -> [UInt8] {
            let bytes = (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
            return little ? bytes : bytes.reversed()
        }
        var images: [(String, Data)] = []
        for little in [true, false] {
            for type: UInt32 in [3, 4] {
                var bytes: [UInt8] = little ? [0x49, 0x49, 42, 0] : [0x4D, 0x4D, 0, 42]
                bytes += integer(80, 4, little: little)
                bytes += Array(repeating: 0, count: 72)
                bytes += integer(2, 2, little: little)
                for (tag, value): (UInt32, UInt32) in [(256, 20), (257, 60)] {
                    bytes += integer(tag, 2, little: little) + integer(type, 2, little: little) + integer(1, 4, little: little)
                    bytes += integer(value, type == 3 ? 2 : 4, little: little)
                    if type == 3 { bytes += [0, 0] }
                }
                bytes += [0, 0, 0, 0]
                images.append(("tiff", Data(bytes)))
            }
        }
        func webp(_ kind: String, _ payload: [UInt8]) -> Data {
            let chunk = Array(kind.utf8) + integer(UInt32(payload.count), 4) + payload + (payload.count.isMultiple(of: 2) ? [] : [0])
            return Data(Array("RIFF".utf8) + integer(UInt32(chunk.count + 4), 4) + Array("WEBP".utf8) + chunk)
        }
        images.append(("webp", webp("VP8X", [0,0,0,0] + integer(19,3) + integer(59,3))))
        images.append(("webp", webp("VP8L", [0x2F] + integer(19 | (59 << 14), 4))))
        images.append(("webp", webp("VP8 ", [0,0,0,0x9D,1,0x2A] + integer(20,2) + integer(60,2))))
        for (ext, data) in images {
            let size = try #require(OfficeImageDimensions.read(data))
            #expect(size.0 == 20 && size.1 == 60)
            let result = ConverterResult(sections: [.init(kind: .image, markdown: "", sourcePath: "image." + ext, metadata: ["mimeType": "image/" + ext, "base64": data.base64EncodedString()])])
            let doc = try SwiftSoup.parse(xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml"), "", SwiftSoup.Parser.xmlParser())
            let extent = try #require(doc.getElementsByTag("wp:extent").first())
            let width = try #require(Double(extent.attr("cx"))), height = try #require(Double(extent.attr("cy")))
            #expect(abs(width / height - 1.0 / 3.0) < 0.001)
            #expect(OfficeImageDimensions.read(Data(data.prefix(12))) == nil)
        }
    }

    @Test func RTFFieldsKeepHyperlinkTargetsAndFormattedLabels() async throws {
        let rtf = #"{\rtf1 Before {\field{\*\fldinst HYPERLINK "https://example.test/a(b)"}{\fldrslt {\b Docs}}} after}"#
        let result = try await PicoDocsEngine.convert(data: Data(rtf.utf8), filename: "fields.rtf")
        #expect(result.markdown().contains("[**Docs**](<https://example.test/a(b)>)"))
        #expect(try DocumentRenderer.render(result, to: .html).contains(#"href="https://example.test/a(b)""#))
        #expect(try DocumentRenderer.render(result, to: .plaintext) == "Before Docs after")
        let ignored = #"{\rtf1 Visible {\*\unknown {\field{\*\fldinst HYPERLINK "https://hidden"}{\fldrslt Secret}}}}"#
        #expect(RTFConverter.markdown(fromRTF: ignored) == "Visible")
        #if canImport(AppKit)
        let generated = try PicoDocsEngine.write(markdown: "[Docs](https://example.test)", to: .rtf)
        let recovered = try await PicoDocsEngine.convert(data: generated, filename: "generated.rtf")
        #expect(recovered.markdown().contains("[Docs](https://example.test)"))
        #endif
    }

    #if canImport(AppKit)
    @Test func RTFUnorderedListsRoundTripWithNestedMarkers() async throws {
        let source = "- Parent\n  - Child\n- Next"
        let generated = try PicoDocsEngine.write(markdown: source, to: .rtf)
        let result = try await PicoDocsEngine.convert(data: generated, filename: "lists.rtf")
        #expect(result.markdown().contains("- Parent")); #expect(result.markdown().contains("  - Child"))
        #expect(result.markdown().contains("- Next")); #expect(!result.markdown().contains("•"))
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.components(separatedBy: "<ul>").count - 1 == 2)
        let docx = try PicoDocsEngine.write(result, to: .docx)
        #expect(try xml(docx, "word/document.xml").contains("<w:numPr>"))
    }
    #endif


    @Test func WordMediaBudgetIsSharedAcrossBodyAndNotes() throws {
        let body = try SwiftSoup.parse(#"<w:body><a:blip r:embed="body"/></w:body>"#, "", SwiftSoup.Parser.xmlParser())
        let note = #"<w:footnotes><w:footnote w:id="1"><a:blip r:embed="note"/></w:footnote></w:footnotes>"#
        for sameImage in [false, true] {
            let target = sameImage ? "media/a.png" : "media/b.png"
            let rels = "<Relationships><Relationship Id=\"note\" Type=\"rel/image\" Target=\"" + target + "\"/></Relationships>"
            let data = PagesConverterTests.makeZip([(name: "word/media/a.png", data: Array(repeating: 1, count: 6)), (name: "word/media/b.png", data: Array(repeating: 2, count: 6)), (name: "word/footnotes.xml", data: Array(note.utf8)), (name: "word/_rels/footnotes.xml.rels", data: Array(rels.utf8))])
            let archive = try #require(Archive(data: data, accessMode: .read))
            for budget in [WordConverter.MediaBudget(maxBytes: 10), WordConverter.MediaBudget(maxImages: 1)] {
                let images = try WordConverter.extractImages(from: body, relationships: ["body": "media/a.png"], archive: archive, budget: budget)
                #expect(images.count == 1)
                if sameImage { #expect(try WordConverter.extractNoteImages(archive, budget: budget).isEmpty) }
                else { #expect(throws: PicoDocsError.parsingError) { try WordConverter.extractNoteImages(archive, budget: budget) } }
            }
        }
    }

    @Test func spreadsheetEncodeFastPathRetainsEscapesAndControls() {
        for source in ["ordinary", "_x0041_", "_xFFFF_\u{0001}", "tab\tline\n", "emoji 😀", "\u{FFFE}"] {
            #expect(SpreadsheetMLText.decode(SpreadsheetMLText.encode(source)) == source)
        }
    }

    @Test func XLSXDimensionsRespectTheReaderCellBudget() throws {
        try XLSXExporter.validateDimensions(rows: 1_000, columns: 1_000)
        #expect(throws: ExporterError.self) { try XLSXExporter.validateDimensions(rows: 1_001, columns: 1_000) }
        #expect(throws: ExporterError.self) { try XLSXExporter.validateDimensions(rows: Int.max, columns: Int.max) }
    }

    @Test func XLSXListProjectionKeepsMarkersAndContentIndentation() throws {
        let data = try PicoDocsEngine.write(markdown: "3. Third\n   - child\n4. Fourth", to: .xlsx)
        let sheet = try xml(data, "xl/worksheets/sheet1.xml")
        #expect(sheet.contains(">3. Third</t>"))
        #expect(sheet.contains(">   - child</t>"))
        #expect(sheet.contains(">4. Fourth</t>"))
    }


    @Test func emptyCSVCellSurvivesOfficeProjection() async throws {
        let converted = try await PicoDocsEngine.convert(data: Data("\"\"".utf8), filename: "empty.csv")
        let legacy = ConverterResult(sections: [.init(kind: .table, markdown: "|  |\n| --- |", metadata: ["csv": ""])])
        for result in [converted, legacy] {
            #expect(OfficeDocumentBlocks.parse(result).contains { if case .table(let rows) = $0 { return rows == [[""]] }; return false })
            #expect(try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml").contains("<w:tbl>"))
        }
        #expect(CSVConverter.parseCSV(CSVConverter.serializeCSV([[""]])) == [[""]])
        #expect(OfficeDocumentBlocks.parse(ConverterResult(sections: [.init(kind: .table, markdown: "", metadata: ["csv": ""])] )).isEmpty)
    }

    @Test func slideBodyHeadingsReceiveJumpTargets() throws {
        let source = "# Start\n[go](#details) [again](#details-1)\n# Other\n### Details\n# Last\n#### Details"
        let pptx = try PicoDocsEngine.write(markdown: source, to: .pptx)
        let rels = try xml(pptx, "ppt/slides/_rels/slide1.xml.rels")
        #expect(rels.contains("Target=\"slide2.xml\""))
        #expect(rels.contains("Target=\"slide3.xml\""))
    }

    @Test func tableLinkLabelsRetainHardBreaks() throws {
        let result = ConverterResult(sections: [.init(markdown: "| [first<br>second](https://example.com) |\n| --- |")])
        #expect(try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml").contains("<w:br/>"))
        #expect(try xml(PicoDocsEngine.write(result, to: .pptx), "ppt/slides/slide1.xml").contains("<a:br/>"))
        #expect(try xml(PicoDocsEngine.write(result, to: .xlsx), "xl/worksheets/sheet1.xml").contains("first\nsecond"))
        #if canImport(AppKit)
        #expect(AttributedStringDocumentBuilder.attributedString(from: result).string.contains("first\nsecond"))
        #endif
        #expect(MarkdownInlineParser.parse("[`<br>`](url)", tableCell: true).plainText == "<br>")
        #expect(MarkdownInlineParser.parse(#"[\<br>](url)"#, tableCell: true).plainText == "<br>")
    }

    @Test func underscoreRulesInterruptParagraphs() throws {
        let blocks = MarkdownBlockParser.parse("paragraph\n___")
        #expect(blocks.count == 2)
        #expect(blocks.contains { if case .rule = $0 { return true }; return false })
        #expect(try DocumentRenderer.render(ConverterResult(sections: [.init(markdown: "paragraph\n___")]), to: .html).contains("<hr>"))
    }

    @Test func markerlessWordParagraphRemainsListContinuation() async throws {
        let numbering = "<w:numbering xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:abstractNum w:abstractNumId=\"0\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/></w:lvl><w:lvl w:ilvl=\"1\"><w:numFmt w:val=\"none\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num></w:numbering>"
        func paragraph(_ text: String, _ level: Int) -> String { "<w:p><w:pPr><w:numPr><w:ilvl w:val=\"\(level)\"/><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>" }
        let document = "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>" + paragraph("Parent", 0) + paragraph("Continuation", 1) + paragraph("Next", 0) + "</w:body></w:document>"
        let data = PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "list.docx")
        let markdown = result.sections.map(\.markdown).joined(separator: "\n")
        #expect(markdown.contains("1. Parent\n\n   Continuation\n2. Next"))
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("Continuation")); #expect(!html.contains("</ol>\n<p>Continuation"))
        let pptx = try xml(PicoDocsEngine.write(result, to: .pptx), "ppt/slides/slide1.xml")
        #expect(pptx.contains("<a:buNone/>")); #expect(pptx.contains("Continuation"))
    }

    @Test func escapedFootnoteIDsMatchReferencesAndDefinitions() throws {
        let result = ConverterResult(sections: [.init(markdown: #"Claim[^a\*b]"# + "\n\n" + #"[^a\*b]: Note"#)])
        #expect(try DocumentRenderer.render(result, to: .plaintext) == "Claim[1]\n\n[1] Note")
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("href=\"#fn-a*b\"")); #expect(html.contains("id=\"fn-a*b\""))
        let literal = ConverterResult(sections: [.init(markdown: #"\[^a\*b] `[^a\*b]`"# + "\n\n" + #"[^a\*b]: Note"#)])
        #expect(!(try DocumentRenderer.render(literal, to: .html)).contains("<sup"))
    }


    @Test func publicWorksheetNamesProjectIntoOfficeDocuments() throws {
        for csv: String? in [nil, "value"] {
            let result = ConverterResult(sections: [.init(kind: .sheet, markdown: "", sheetName: "Template", metadata: csv.map { ["csv": $0] } ?? [:])])
            #expect(try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml").contains("Template"))
            #expect(try xml(PicoDocsEngine.write(result, to: .pptx), "ppt/slides/slide1.xml").contains("Template"))
            #if canImport(AppKit)
            #expect(AttributedStringDocumentBuilder.attributedString(from: result).string.contains("Template"))
            #endif
        }
    }

    @Test func portableJPEGDimensionsWalkMetadataAndProgressiveFrames() throws {
        for marker: UInt8 in [0xC0, 0xC2] {
            let metadata = [UInt8](repeating: 0, count: 1024)
            let bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE1, 0x04, 0x02] + metadata + [0xFF, marker, 0, 11, 8, 0, 60, 0, 20, 1, 1, 0x11, 0]
            let size = try #require(OfficeImageDimensions.read(Data(bytes)))
            #expect(size.0 == 20 && size.1 == 60)
            #expect(OfficeImageDimensions.read(Data(bytes.dropLast(5))) == nil)
        }
        #expect(OfficeImageDimensions.read(Data([0xFF, 0xD8, 0xFF, 0xE1, 0xFF, 0xFF])) == nil)
        #if canImport(AppKit)
        for (width, height) in [(20, 20), (10, 30), (40, 10)] {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [:]))
            let size = try #require(OfficeImageDimensions.read(jpeg))
            #expect(size.0 == Double(width) && size.1 == Double(height))
        }
        #endif
    }

    @Test func officeBreaksRetainBackslashParity() throws {
        for count in 1...4 {
            let source = "foo" + String(repeating: "\\", count: count) + "\nbar"
            let nodes = MarkdownInlineParser.parse(source)
            #expect(nodes.contains(.lineBreak(hard: !count.isMultiple(of: 2))))
            #expect(nodes.plainText == "foo" + String(repeating: "\\", count: count / 2) + "\nbar")
            let result = ConverterResult(sections: [.init(markdown: source)])
            let docx = try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml")
            #expect(docx.contains("<w:br/>") == !count.isMultiple(of: 2))
            #expect(docx.contains("foo" + String(repeating: "\\", count: count / 2)))
            let pptx = try xml(PicoDocsEngine.write(result, to: .pptx), "ppt/slides/slide1.xml")
            #expect(pptx.contains("<a:br/>") == !count.isMultiple(of: 2))
            #if canImport(AppKit)
            let expected = "foo" + String(repeating: "\\", count: count / 2) + (count.isMultiple(of: 2) ? " " : "\n") + "bar"
            #expect(AttributedStringDocumentBuilder.attributedString(from: result).string.contains(expected))
            #endif
        }
    }

    @Test func tableBreaksRespectCodeAndEscapesInEveryOfficeWriter() throws {
        for cell in ["`<br>`", #"\<br>"#] {
            let result = ConverterResult(sections: [.init(markdown: "| " + cell + " |\n| --- |")])
            let docx = try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml")
            #expect(docx.contains("&lt;br&gt;")); #expect(!docx.contains("<w:br/>"))
            let pptx = try xml(PicoDocsEngine.write(result, to: .pptx), "ppt/slides/slide1.xml")
            #expect(pptx.contains("&lt;br&gt;")); #expect(!pptx.contains("<a:br/>"))
            #expect(try xml(PicoDocsEngine.write(result, to: .xlsx), "xl/worksheets/sheet1.xml").contains("&lt;br&gt;"))
            #if canImport(AppKit)
            #expect(AttributedStringDocumentBuilder.attributedString(from: result).string.contains("<br>"))
            #endif
        }
    }

    @Test func rawCSVTableCarrierPreservesCellWhitespaceAndNewlines() async throws {
        let csv = "\" leading \ntrailing \""
        let converted = try await PicoDocsEngine.convert(data: Data(csv.utf8), filename: "cells.csv")
        for result in [converted, ConverterResult(sections: [.init(kind: .table, markdown: "", metadata: ["csv": csv])])] {
            let docx = try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml")
            #expect(docx.contains("> leading </w:t>")); #expect(docx.contains(">trailing </w:t>")); #expect(docx.contains("<w:br/>"))
            let pptx = try xml(PicoDocsEngine.write(result, to: .pptx), "ppt/slides/slide1.xml")
            #expect(pptx.contains("> leading </a:t>")); #expect(pptx.contains(">trailing </a:t>")); #expect(pptx.contains("<a:br/>"))
            #if canImport(AppKit)
            #expect(AttributedStringDocumentBuilder.attributedString(from: result).string.contains(" leading \ntrailing "))
            #endif
        }
    }

    @Test func optionalWordPartsHaveEnforcedExtractionLimits() throws {
        let data = PagesConverterTests.makeZip([(name: "word/numbering.xml", data: [UInt8](repeating: 32, count: 8 * 1024 * 1024 + 1))])
        let archive = try #require(Archive(data: data, accessMode: .read))
        #expect(WordListNumbering(archive: archive).failure != nil)
        let small = try #require(Archive(data: PagesConverterTests.makeZip([(name: "part", data: [1, 2, 3])]), accessMode: .read))
        #expect(WordConverter.readEntry(small, path: "part", maxBytes: 2) == nil)
        #expect(WordConverter.readEntry(small, path: "part", maxBytes: 3) == Data([1, 2, 3]))
    }

    @Test func backslashPairsKeepInlineDelimitersActive() throws {
        for count in 1...4 {
            let prefix = String(repeating: "\\", count: count)
            let result = ConverterResult(sections: [.init(markdown: prefix + "*em*")])
            let expected = String(repeating: "\\", count: count / 2) + (count.isMultiple(of: 2) ? "em" : "*em*")
            for format in [ExportFileType.plaintext, .csv] { #expect(try DocumentRenderer.render(result, to: format) == expected) }
            #expect(try DocumentRenderer.render(result, to: .html).contains("<em>em</em>") == count.isMultiple(of: 2))
        }
        let links = ConverterResult(sections: [.init(markdown: #"\\[Link](https://example.com)"#)])
        #expect(try DocumentRenderer.render(links, to: .html).contains(#"\<a href="https://example.com">Link</a>"#))
        let notes = ConverterResult(sections: [.init(markdown: #"\\[^n]"# + "\n\n[^n]: Note")])
        #expect(try DocumentRenderer.render(notes, to: .html).contains("<sup"))
    }

    @Test func csvFencesNormalizeCRLFAndCR() throws {
        for newline in ["\n", "\r\n", "\r"] {
            let source = ["```", "a|b", "```", "| c | d |", "| --- | --- |"].joined(separator: newline)
            #expect(try DocumentRenderer.render(ConverterResult(sections: [.init(markdown: source)]), to: .csv) == "a|b\nc,d")
        }
    }

    @Test func exporterErrorsExposeTheirExplanation() throws {
        let result = ConverterResult(sections: [.init(markdown: "", metadata: ["csv": String(repeating: "x", count: 32_768)])])
        do {
            _ = try PicoDocsEngine.write(result, to: .xlsx)
            Issue.record("Expected the worksheet cell limit to be enforced")
        } catch ExporterError.serializationFailed(let message) {
            #expect(!message.isEmpty)
            #expect(ExporterError.serializationFailed(message).localizedDescription == message)
        }
    }

    @Test func portableVectorAndCarrierDimensionsPreserveAspectRatio() throws {
        let vectors = [#"<svg viewBox="0 0 20 60"/>"#, #"<svg width="2in" height="1in" viewBox="0 0 10 10"/>"#, #"<svg width="100%" height="100%" viewBox="0,0,20,20"/>"#]
        for (source, ratio) in zip(vectors, [1.0 / 3, 2, 1]) {
            let data = Data(source.utf8)
            let (cx, cy) = WordprocessingMLExporter.imageExtents(data)
            #expect(abs(Double(cx) / Double(cy) - ratio) < 0.00001)
            let result = ConverterResult(sections: [.init(kind: .image, markdown: "", sourcePath: "vector.svg", metadata: ["base64": data.base64EncodedString(), "mimeType": "image/svg+xml"])])
            #expect(try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml").contains("<wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/>"))
        }
        var emf = Data(repeating: 0, count: 88)
        func put(_ value: UInt32, offset: Int, count: Int, into data: inout Data) {
            for index in 0..<count { data[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
        }
        put(1, offset: 0, count: 4, into: &emf)
        put(0x464D4520, offset: 40, count: 4, into: &emf)
        put(20, offset: 32, count: 4, into: &emf)
        put(60, offset: 36, count: 4, into: &emf)
        var wmf = Data(repeating: 0, count: 22)
        put(0x9AC6CDD7, offset: 0, count: 4, into: &wmf)
        put(20, offset: 10, count: 2, into: &wmf)
        put(60, offset: 12, count: 2, into: &wmf)
        for data in [emf, wmf] {
            let (cx, cy) = WordprocessingMLExporter.imageExtents(data)
            #expect(abs(Double(cx) / Double(cy) - 1.0 / 3) < 0.00001)
        }
        let (cx, cy) = WordprocessingMLExporter.imageExtents(Data([1, 2, 3]), metadata: ["width": "30", "height": "10"])
        #expect(cx == 3 * cy)
        #expect(OfficeImageDimensions.read(Data(#"<svg width="NaN" height="0"/>"#.utf8)) == nil)
        _ = WordprocessingMLExporter.imageExtents(Data(#"<svg width="1e-320" height="1e-320"/>"#.utf8))
    }

    @Test func imageOnlyBookmarkedHeadingsAllocateCanonicalSlugs() async throws {
        let document = #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"><w:body><w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:bookmarkStart w:id="1" w:name="rawBookmark"/><w:r><w:drawing><wp:inline><wp:docPr id="1" name="Picture" descr="Chart"/><a:blip r:embed="image"/></wp:inline></w:drawing></w:r></w:p><w:p><w:hyperlink w:anchor="rawBookmark"><w:r><w:t>Link</w:t></w:r></w:hyperlink></w:p></w:body></w:document>"#
        let relationships = #"<Relationships><Relationship Id="image" Target="media/chart.png" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"/></Relationships>"#
        let data = PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/_rels/document.xml.rels", data: Array(relationships.utf8)), (name: "word/media/chart.png", data: [1, 2, 3])])
        let result = try await PicoDocsEngine.convert(data: data, filename: "heading.docx")
        #expect(result.markdown().contains("[Link](#chart)"))
        #expect(try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml").contains(#"w:anchor="heading_1""#))
    }

    @Test func flattenedTableHeadingsDoNotAllocateFragments() async throws {
        let heading = #"<w:pPr><w:pStyle w:val="Heading1"/></w:pPr>"#
        let xml = #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>"# + "<w:tbl><w:tr><w:tc><w:p>" + heading + "<w:r><w:t>Details</w:t></w:r></w:p></w:tc></w:tr></w:tbl><w:p>" + heading + #"<w:bookmarkStart w:id="1" w:name="details"/><w:r><w:t>Details</w:t></w:r><w:bookmarkEnd w:id="1"/></w:p><w:p><w:hyperlink w:anchor="details"><w:r><w:t>Link</w:t></w:r></w:hyperlink></w:p></w:body></w:document>"#
        let result = try await PicoDocsEngine.convert(data:PagesConverterTests.makeZip([(name:"word/document.xml",data:Array(xml.utf8))]),filename:"table-heading.docx")
        #expect(result.markdown().contains("[Link](#details)"))
        #expect(!result.markdown().contains("#details-1"))
    }

    @Test func namedEmptySheetsTranscodeToOfficeHeadings() async throws {
        let workbook = try PicoDocsEngine.write(ConverterResult(sections:[.init(title:"Template",kind:.sheet,markdown:"")]),to:.xlsx)
        let recovered = try await PicoDocsEngine.convert(data:workbook,filename:"empty.xlsx")
        #expect(try xml(PicoDocsEngine.write(recovered,to:.docx),"word/document.xml").contains("Template"))
        #expect(try xml(PicoDocsEngine.write(recovered,to:.pptx),"ppt/slides/slide1.xml").contains("Template"))
        #if canImport(AppKit)
        #expect(!(try PicoDocsEngine.write(recovered,to:.rtf)).isEmpty)
        #endif
    }

    #if canImport(AppKit)
    @Test func embeddedImagesFitWithoutChangingAspectRatio() throws {
        for (width,height) in [(20,20),(10,30),(40,10)] {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
            let data = try #require(bitmap.representation(using:.png,properties:[:]))
            let (cx,cy) = WordprocessingMLExporter.imageExtents(data)
            #expect(abs(Double(cx) / Double(cy) - Double(width) / Double(height)) < 0.00001)
            #expect(cx <= 4_572_000); #expect(cy <= 3_429_000)
            let result = ConverterResult(sections:[.init(kind:.image,markdown:"",sourcePath:"image.png",metadata:["base64":data.base64EncodedString(),"mimeType":"image/png"])])
            let document = try xml(PicoDocsEngine.write(result,to:.docx),"word/document.xml")
            #expect(document.contains("<wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/>"))
            #expect(document.contains("<a:ext cx=\"\(cx)\" cy=\"\(cy)\"/>"))
        }
    }
    #endif

    @Test func exportedWordFragmentsSurviveImportAndSecondExport() async throws {
        let source = "[Details](#details) [Again](#details-1)\n\n# Details\n\n# Details"
        let first = try PicoDocsEngine.write(markdown:source,to:.docx)
        let recovered = try await PicoDocsEngine.convert(data:first,filename:"anchors.docx")
        #expect(recovered.markdown().contains("[Details](#details)"))
        #expect(recovered.markdown().contains("[Again](#details-1)"))
        let second = try xml(PicoDocsEngine.write(recovered,to:.docx),"word/document.xml")
        #expect(second.contains(#"w:anchor="heading_1""#)); #expect(second.contains(#"w:anchor="heading_2""#))
    }

    @Test func presentationFragmentsBecomeInternalSlideJumps() throws {
        let source = "# Start\n\n[Details](#details) [again](#details-1) [missing](#absent)\n\n# Details\n\nFirst\n\n# Details\n\nSecond"
        let data = try PicoDocsEngine.write(markdown:source,to:.pptx)
        let slide = try xml(data,"ppt/slides/slide1.xml")
        #expect(slide.components(separatedBy:#"action="ppaction://hlinksldjump""#).count - 1 == 2)
        let relationships = try xml(data,"ppt/slides/_rels/slide1.xml.rels")
        #expect(relationships.contains(#"/slide" Target="slide2.xml""#))
        #expect(relationships.contains(#"/slide" Target="slide3.xml""#))
        #expect(!relationships.contains("External")); #expect(!relationships.contains("#"))
    }

    @Test func mixedEmphasisClosesPastUnmatchedFrames() {
        #expect(MarkdownInlineParser.parse("*foo _bar* baz_") == [.emphasis([.text("foo _bar")]),.text(" baz_")])
        #expect(MarkdownInlineParser.parse("_foo *bar_ baz*") == [.emphasis([.text("foo *bar")]),.text(" baz*")])
        #expect(MarkdownInlineParser.parse("**foo _bar** baz_") == [.strong([.text("foo _bar")]),.text(" baz_")])
    }

    @Test func worksheetNamesSurviveOfficeProjection() throws {
        let result = ConverterResult(sections:[.init(title:"Ignored",kind:.sheet,markdown:"## A *literal*\n\nOne",metadata:["sheetName":"A *literal*","csv":"One"]),.init(title:"Second",kind:.sheet,markdown:"## Second\n\nTwo",metadata:["csv":"Two"])])
        let word = try xml(PicoDocsEngine.write(result,to:.docx),"word/document.xml")
        #expect(word.contains("A *literal*")); #expect(word.contains("Second"))
        let slides = try PicoDocsEngine.write(result,to:.pptx)
        #expect(try xml(slides,"ppt/slides/slide1.xml").contains("A *literal*"))
        #expect(try xml(slides,"ppt/slides/slide2.xml").contains("Second"))
        #if canImport(AppKit) || canImport(UIKit)
        let attributed = AttributedStringDocumentBuilder.attributedString(from:result).string
        #expect(attributed.contains("A *literal*")); #expect(attributed.contains("Second"))
        #endif
    }

    @Test func looseListParagraphsRetainTheirItemAndNesting() throws {
        let source = "- parent\n  - first\n\n    continuation"
        let blocks = MarkdownBlockParser.parse(source)
        guard case .list(let list) = try #require(blocks.first) else { Issue.record("Expected list"); return }
        let paragraphs = list.paragraphs()
        #expect(paragraphs.count == 3)
        #expect(paragraphs.last?.continuation == true); #expect(paragraphs.last?.level == 1)
        let word = try xml(PicoDocsEngine.write(markdown:source,to:.docx),"word/document.xml")
        #expect(word.contains("continuation")); #expect(word.contains(#"w:left="1440""#))
        let slide = try xml(PicoDocsEngine.write(markdown:source,to:.pptx),"ppt/slides/slide1.xml")
        #expect(slide.contains(#"<a:pPr lvl="1"><a:buNone/></a:pPr>"#))
    }

    @Test func innerLinkDeactivatesOuterLinkWithoutNestedHyperlinks() throws {
        let source = "[outer [inner](https://inner.test)](https://outer.test)"
        #expect(MarkdownInlineParser.parse(source) == [.text("[outer "),.link(label:[.text("inner")],destination:"https://inner.test"),.text("](https://outer.test)")])
        let word = try PicoDocsEngine.write(markdown:source,to:.docx)
        #expect(try xml(word,"word/document.xml").components(separatedBy:"<w:hyperlink ").count - 1 == 1)
        #expect(!(try xml(word,"word/_rels/document.xml.rels")).contains("https://outer.test"))
        #expect(MarkdownInlineParser.parse("[**text** ![alt](image.png)](url)") == [.link(label:[.strong([.text("text")]),.text(" "),.image(alt:"alt",source:"image.png")],destination:"url")])
    }

    @Test func underscoreEmphasisUsesFlankingAndPreservesIdentifiers() throws {
        #expect(MarkdownInlineParser.parse("_italic_") == [.emphasis([.text("italic")])])
        #expect(MarkdownInlineParser.parse("__bold__") == [.strong([.text("bold")])])
        #expect(MarkdownInlineParser.parse("_**both**_") == [.emphasis([.strong([.text("both")])])])
        #expect(MarkdownInlineParser.parse("foo_bar_baz foo__bar__baz").plainText == "foo_bar_baz foo__bar__baz")
        #expect(MarkdownInlineParser.parse(#"\_literal\_"#) == [.text("_literal_")])
        let document = try xml(PicoDocsEngine.write(markdown:"_italic_ __bold__",to:.docx),"word/document.xml")
        #expect(document.contains("<w:i/>")); #expect(document.contains("<w:b/>"))
        let slide = try xml(PicoDocsEngine.write(markdown:"_italic_ __bold__",to:.pptx),"ppt/slides/slide1.xml")
        #expect(slide.contains(#"i="1""#)); #expect(slide.contains(#"b="1""#))
    }

    @Test func bracketedLinkLabelsAndLiteralCodeClosers() {
        #expect(MarkdownInlineParser.parse("[API [v2]](https://example.com)") == [.link(label:[.text("API [v2]")],destination:"https://example.com")])
        #expect(MarkdownInlineParser.parse("![API [v2]](image.png)") == [.image(alt:"API [v2]",source:"image.png")])
        #expect(MarkdownInlineParser.parse("[API `]` v2](url)") == [.link(label:[.text("API "),.code("]"),.text(" v2")],destination:"url")])
        // CommonMark 0.31.2 example 338: backslashes cannot escape a code closer.
        #expect(MarkdownInlineParser.parse(#"`open\` tail"#) == [.code("open\\"),.text(" tail")])
        #expect(MarkdownInlineParser.parse(#"\`open\` tail"#) == [.text("`open` tail")])
        #expect(MarkdownInlineParser.parse("[not a `link](/foo`)") == [.text("[not a "),.code("link](/foo"),.text(")")])
    }

    @Test func blankSlidesAndNestedContinuationsRetainStructure() throws {
        let blank = ConverterResult(sections:[.init(kind:.slide,markdown:"",slideNumber:1),.init(kind:.slide,markdown:"",slideNumber:3)])
        let deck = try PicoDocsEngine.write(blank,to:.pptx)
        #expect(try xml(deck,"ppt/presentation.xml").components(separatedBy:"<p:sldId ").count - 1 == 3)
        let slide = try xml(PicoDocsEngine.write(markdown:"- parent\n  - child\n    - grandchild\n    continuation",to:.pptx),"ppt/slides/slide1.xml")
        #expect(slide.contains(#"<a:pPr lvl="1"><a:buNone/></a:pPr>"#))
        #expect(slide.contains("continuation"))
    }

    @Test func documentFragmentLinksTargetUniqueHeadingBookmarks() throws {
        let source = "[Details](#details) [second](#details-1) [unicode](#caf%C3%A9) [missing](#unknown)\n\n# Details\n\n## Details\n\n# Café"
        let data = try PicoDocsEngine.write(markdown:source,to:.docx)
        let document = try xml(data,"word/document.xml")
        for index in 1...3 {
            #expect(document.contains("<w:hyperlink w:anchor=\"heading_\(index)\">"))
            #expect(document.contains("w:name=\"heading_\(index)\""))
        }
        #expect(document.components(separatedBy:"<w:bookmarkStart ").count - 1 == 3)
        #expect(document.components(separatedBy:"<w:bookmarkEnd ").count - 1 == 3)
        #expect(!(try xml(data,"word/_rels/document.xml.rels")).contains("/hyperlink"))
        #expect(document.contains("missing"))
    }

    @Test func emptyWorksheetsSurviveTranscoding() async throws {
        for includeData in [false,true] {
            var sections = [DocumentSection(title:"Template",kind:.sheet,markdown:"")]
            if includeData { sections.append(.init(title:"Data",kind:.sheet,markdown:"Value")) }
            let first = try PicoDocsEngine.write(ConverterResult(sections:sections),to:.xlsx)
            let second = try await PicoDocsEngine.transcode(data:first,filename:"empty.xlsx",to:.xlsx,sanitizeUnicode:true)
            let workbook = try xml(second,"xl/workbook.xml")
            #expect(workbook.contains(#"name="Template""#))
            if includeData { #expect(workbook.contains(#"name="Data""#)) }
        }
    }

    @Test func spreadsheetWhitespaceSurvivesEveryOfficeProjection() async throws {
        let result = ConverterResult(sections:[.init(title:"Data",kind:.sheet,markdown:"lossy placeholder",metadata:["csv":"\"  first\nsecond  \""])])
        let xlsx = try PicoDocsEngine.write(result,to:.xlsx)
        let recovered = try await PicoDocsEngine.convert(data:xlsx,filename:"spaces.xlsx")
        let docx = try xml(PicoDocsEngine.write(recovered,to:.docx),"word/document.xml")
        #expect(docx.contains(">  first</w:t>")); #expect(docx.contains(">second  </w:t>")); #expect(docx.contains("<w:br/>"))
        let pptx = try xml(PicoDocsEngine.write(recovered,to:.pptx),"ppt/slides/slide1.xml")
        #expect(pptx.contains(#"<a:t xml:space="preserve">  first</a:t>"#))
        #expect(pptx.contains(#"<a:t xml:space="preserve">second  </a:t>"#)); #expect(pptx.contains("<a:br/>"))
        #if canImport(AppKit) || canImport(UIKit)
        #expect(AttributedStringDocumentBuilder.attributedString(from:recovered).string.contains("  first\nsecond  "))
        #endif
    }

    @Test func recoveryAndSynthesizedImagesKeepSlideOrder() throws {
        let recovery = ConverterResult(sections:[.init(kind:.body,markdown:"Recovered first"),.init(kind:.table,markdown:"| Table |\n| --- |",slideNumber:1)])
        let data = try PicoDocsEngine.write(recovery,to:.pptx)
        #expect(try xml(data,"ppt/slides/slide1.xml").contains("Recovered first"))
        #expect(try xml(data,"ppt/slides/slide2.xml").contains("Table"))
        let image = DocumentSection(title:"Image alt",kind:.image,markdown:"",sourcePath:"image.png",slideNumber:1,metadata:["mimeType":"image/png","base64":"AQID"])
        let deck = try PicoDocsEngine.write(ConverterResult(sections:[.init(kind:.slide,markdown:"",slideNumber:1),image]),to:.pptx)
        #expect(try xml(deck,"ppt/slides/slide1.xml").contains("Image alt"))
        #expect(try xml(deck,"ppt/presentation.xml").components(separatedBy:"<p:sldId ").count - 1 == 1)
    }

    @Test func numberingAndCodeRunPropertiesUseSchemaOrder() throws {
        let data = try PicoDocsEngine.write(markdown:"- Bullet\n\n1. Ordered\n\n***`code`***",to:.docx)
        let numbering = try SwiftSoup.parse(xml(data,"word/numbering.xml"),"",SwiftSoup.Parser.xmlParser())
        let names = try #require(numbering.getElementsByTag("w:numbering").first()).children().array().map { $0.tagName().lowercased() }
        #expect(names == ["w:abstractnum","w:abstractnum","w:num","w:num"])
        let document = try SwiftSoup.parse(xml(data,"word/document.xml"),"",SwiftSoup.Parser.xmlParser())
        let props = try #require(document.getElementsByTag("w:rPr").first { (try? $0.getElementsByTag("w:rStyle").isEmpty()) == false })
        #expect(props.children().array().map { $0.tagName().lowercased() } == ["w:rstyle","w:rfonts","w:b","w:i"])
    }

    @Test func tableCellsDoNotShareInlineDelimitersAndCodeKeepsSpaces() throws {
        let result = ConverterResult(sections:[.init(markdown:"| *open | close* |\n| --- | --- |")])
        let slide = try xml(PicoDocsEngine.write(result,to:.pptx),"ppt/slides/slide1.xml")
        #expect(slide.contains("*open")); #expect(slide.contains("close*")); #expect(!slide.contains(#"i="1""#))
        let code = try xml(PicoDocsEngine.write(markdown:"```\n  x  \n```",to:.pptx),"ppt/slides/slide1.xml")
        #expect(code.contains(#"<a:t xml:space="preserve">  x  </a:t>"#))
        #if canImport(AppKit) || canImport(UIKit)
        #expect(AttributedStringDocumentBuilder.attributedString(from:result).string.contains("*open\tclose*"))
        #endif
    }

    @Test func decodedAnglesInImageNamesStayBoundToCarriers() async throws {
        let document = #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body><w:p><w:r><w:drawing><a:blip r:embed="image"/></w:drawing></w:r></w:p></w:body></w:document>"#
        let rels = #"<Relationships><Relationship Id="image" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/a%3Eb%20c.png"/></Relationships>"#
        let data = PagesConverterTests.makeZip([(name:"word/document.xml",data:Array(document.utf8)),(name:"word/_rels/document.xml.rels",data:Array(rels.utf8)),(name:"word/media/a>b c.png",data:[1,2,3])])
        let result = try await PicoDocsEngine.convert(data:data,filename:"angle.docx")
        #expect(try xml(PicoDocsEngine.write(result,to:.docx),"word/document.xml").contains("<w:drawing>"))
        #expect(!((try xml(PicoDocsEngine.write(result,to:.pptx),"ppt/slides/slide1.xml")).contains("a&gt;b c.png")))
    }

    @Test func CSVUsesTheSharedFenceGrammar() throws {
        for (markdown, expected) in [("~~~\na|b\n~~~","a|b"),("````\na|b\n```\nc|d\n````","a|b\n```\nc|d")] {
            let output = try DocumentRenderer.render(ConverterResult(sections:[.init(markdown:markdown)]),to:.csv)
            #expect(output == expected)
        }
    }

    @Test func customExportersReceiveCanonicalImageSections() throws {
        struct InspectingExporter: DocumentExporter {
            func accepts(_ format: ExportableFileType) -> Bool { true }
            func write(_ result: ConverterResult, format: ExportableFileType) throws -> Data {
                #expect(result.sections.count == 3)
                #expect(result.sections.allSatisfy { $0.kind == .image && $0.markdown.isEmpty })
                #expect(result.sections.map(\.sourcePath) == ["same.png","same.png",nil])
                return Data([42])
            }
        }
        let images = ["same.png","same.png",nil].map { name in DocumentSection(kind:.image,markdown:"",sourcePath:name,metadata:["base64":"AQID"]) }
        let registry = DocumentExporterRegistry.default.registering(InspectingExporter(),priority:DocumentExporterRegistry.Priority.override)
        #expect(try PicoDocsEngine.write(ConverterResult(sections:images),to:.docx,registry:registry) == Data([42]))
    }

    @Test func mediaNamesAreUniqueIgnoringCase() throws {
        let images = ["logo.png","Logo.png"].map { name in DocumentSection(kind:.image,markdown:"",sourcePath:name,metadata:["mimeType":"image/png","base64":"AQID"]) }
        let data = try PicoDocsEngine.write(ConverterResult(sections:images),to:.docx)
        let archive = try #require(Archive(data:data,accessMode:.read))
        let names = archive.filter { $0.path.hasPrefix("word/media/") }.map { $0.path.lowercased() }
        #expect(names.count == 2); #expect(Set(names).count == 2)
    }

    @Test func percentTripletsInImageNamesAreDecodedOnce() async throws {
        for filename in ["sales%20chart.png", "literal%2Fname.png", "double%2520name.png"] {
            let image = DocumentSection(kind: .image, markdown: "", sourcePath: filename, metadata: ["mimeType": "image/png", "base64": Data([1,2,3]).base64EncodedString()])
            let first = try PicoDocsEngine.write(ConverterResult(sections: [image]), to: .docx)
            let recovered = try await PicoDocsEngine.convert(data: first, filename: "images.docx")
            let carrier = try #require(recovered.sections.first { $0.kind == .image })
            #expect(carrier.sourcePath?.hasSuffix(filename) == true)
            #expect(carrier.metadata["base64"] == Data([1,2,3]).base64EncodedString())
            let second = try PicoDocsEngine.write(recovered, to: .docx)
            #expect(try xml(second, "word/document.xml").contains("<w:drawing>"))
        }
    }

    @Test func entirelyEmptyNamedWorkbookCanBeWritten() throws {
        let result = ConverterResult(sections: [.init(title: "Template", kind: .sheet, markdown: "")])
        let data = try PicoDocsEngine.write(result, to: .xlsx)
        #expect(try xml(data, "xl/workbook.xml").contains(#"name="Template""#))
        #expect(try xml(data, "xl/worksheets/sheet1.xml").contains("<sheetData>"))
        #expect(try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml").contains("Template"))
    }

    @Test func emphasizedCodeAndFencedCodeFonts() async throws {
        let data = try PicoDocsEngine.write(markdown: "**`bold`** *`italic`* ***`both`***", to: .docx)
        let recovered = try await PicoDocsEngine.convert(data: data, filename: "code.docx")
        #expect(recovered.markdown().contains("**`bold`**"))
        #expect(recovered.markdown().contains("*`italic`*"))
        #expect(recovered.markdown().contains("***`both`***"))
        let pptx = try PicoDocsEngine.write(markdown: "```swift\nlet x = 1\nprint(x)\n```", to: .pptx)
        let slide = try xml(pptx, "ppt/slides/slide1.xml")
        #expect(slide.components(separatedBy: "Courier New").count - 1 == 2)
    }

    @Test func imageLabelsAndWhitespacePaths() throws {
        #expect(MarkdownInlineParser.parse("![**Bold** and `code`](image.png)") == [.image(alt: "Bold and code", source: "image.png")])
        let image = DocumentSection(title: "**literal**", kind: .image, markdown: "", sourcePath: "assets/company logo.png", metadata: ["mimeType": "image/png", "base64": Data([1,2,3]).base64EncodedString()])
        for format in [ExportableFileType.docx, .pptx] {
            let data = try PicoDocsEngine.write(ConverterResult(sections: [image]), to: format)
            let part = try xml(data, format == .docx ? "word/document.xml" : "ppt/slides/slide1.xml")
            if format == .docx { #expect(part.contains("<w:drawing>")) }
            if format == .pptx { #expect(!part.contains("company logo.png")) }
            #expect(part.contains("**literal**"))
        }
    }

    @Test func importedImagesKeepPackageIdentity() async throws {
        let namespaces = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main""#
        let document = "<w:document \(namespaces)><w:body><w:p>" + ["a","b"].map { "<w:r><w:drawing><a:blip r:embed=\"\($0)\"/></w:drawing></w:r>" }.joined() + "</w:p></w:body></w:document>"
        let rels = #"<Relationships><Relationship Id="a" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/charts/logo.png"/><Relationship Id="b" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/headers/logo.png"/></Relationships>"#
        let data = PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/_rels/document.xml.rels", data: Array(rels.utf8)), (name: "word/media/charts/logo.png", data: [1]), (name: "word/media/headers/logo.png", data: [2])])
        let result = try await PicoDocsEngine.convert(data: data, filename: "images.docx")
        #expect(result.markdown().contains("word/media/charts/logo.png")); #expect(result.markdown().contains("word/media/headers/logo.png"))
        let output = try PicoDocsEngine.write(result, to: .docx)
        #expect(try xml(output, "word/document.xml").components(separatedBy: "<w:drawing>").count - 1 == 2)
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("base64,AQ==")); #expect(html.contains("base64,Ag=="))
    }

    @Test func tableBlockStylesAndContentControlsRemainStructural() async throws {
        let ns = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main""#
        let cells = ["Heading1","Quote","PicoCodeBlock"].map { "<w:tc><w:p><w:pPr><w:pStyle w:val=\"\($0)\"/></w:pPr><w:r><w:t>Cell \($0)</w:t></w:r></w:p></w:tc>" }.joined()
        func item(_ text: String, level: Int) -> String { "<w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/><w:ilvl w:val=\"\(level)\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>" }
        let document = "<w:document \(ns)><w:body><w:tbl><w:tr>\(cells)</w:tr></w:tbl>" + item("Parent", level: 0) + "<w:sdt><w:sdtContent>" + item("Child", level: 1) + "</w:sdtContent></w:sdt>" + item("Next", level: 0) + "</w:body></w:document>"
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:numFmt w:val=\"decimal\"/></w:lvl><w:lvl w:ilvl=\"1\"><w:numFmt w:val=\"bullet\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8))]), filename: "structure.docx")
        #expect(result.markdown().contains("| Cell Heading1 | Cell Quote | Cell PicoCodeBlock |"))
        #expect(result.markdown().contains("1. Parent\n   - Child\n2. Next"))
        let output = try xml(PicoDocsEngine.write(result, to: .docx), "word/document.xml")
        #expect(output.contains(#"<w:ilvl w:val="1"/>"#)); #expect(!output.contains("# Cell")); #expect(!output.contains("&gt; Cell")); #expect(!output.contains("```"))
    }

    @Test func emptyListItemsRoundTrip() async throws {
        for source in ["-", "2.", "- first\n-\n- third"] {
            let result = try await PicoDocsEngine.convert(data: PicoDocsEngine.write(markdown: source, to: .docx), filename: "empty-item.docx")
            let second = try PicoDocsEngine.write(result, to: .docx)
            let count = try xml(second, "word/document.xml").components(separatedBy: "<w:numPr>").count - 1
            #expect(count == (source.contains("first") ? 3 : 1))
        }
    }

    @Test func spreadsheetTokensAndLiteralCrossFormatCells() async throws {
        let literal = "*value* [label](url) _x000A_ _x005F_"
        let source = ConverterResult(sections: [.init(kind: .sheet, markdown: "", metadata: ["csv": literal])])
        let xlsx = try PicoDocsEngine.write(source, to: .xlsx)
        let worksheet = try xml(xlsx, "xl/worksheets/sheet1.xml")
        #expect(worksheet.contains("_x005F_x000A_ _x005F_x005F_"))
        let result = try await PicoDocsEngine.convert(data: xlsx, filename: "tokens.xlsx")
        #expect(result.sections.first?.metadata["csv"] == "\"" + literal + "\"")
        for (format,path,tag) in [(ExportableFileType.docx,"word/document.xml","w:t"),(.pptx,"ppt/slides/slide1.xml","a:t")] {
            let content = try xml(PicoDocsEngine.write(result, to: format), path)
            let parsed = try SwiftSoup.parse(content, "", SwiftSoup.Parser.xmlParser())
            let visible = try parsed.getElementsByTag(tag).array().map { $0.getChildNodes().compactMap { ($0 as? TextNode)?.getWholeText() }.joined() }.joined()
            #expect(visible.contains(literal)); #expect(!content.contains("hyperlink")); #expect(!content.contains("hlinkClick"))
        }
        #expect(SpreadsheetMLText.decode(SpreadsheetMLText.encode("_x000A_\u{1}😀")) == "_x000A_\u{1}😀")
    }

    @Test func codeTypefaceSoftBreaksAndHyperlinkTargets() throws {
        let code = try xml(PicoDocsEngine.write(markdown: "Use **[`code`](https://example.com)** here", to: .pptx), "ppt/slides/slide1.xml")
        #expect(code.contains(#"<a:rPr b="1"><a:latin typeface="Courier New"/><a:hlinkClick"#))
        for (format,path,tag) in [(ExportableFileType.docx,"word/document.xml","w:t"),(.pptx,"ppt/slides/slide1.xml","a:t")] {
            let content = try xml(PicoDocsEngine.write(markdown: "one \ntwo", to: format), path)
            let parsed = try SwiftSoup.parse(content, "", SwiftSoup.Parser.xmlParser())
            let visible = try parsed.getElementsByTag(tag).array().map { $0.getChildNodes().compactMap { ($0 as? TextNode)?.getWholeText() }.joined() }.joined()
            #expect(visible == "one two")
        }
        #if canImport(AppKit)
        let attributed = AttributedStringDocumentBuilder.attributedString(from: ConverterResult(sections: [.init(markdown: "one \ntwo")]))
        #expect(attributed.string.trimmingCharacters(in: .whitespacesAndNewlines) == "one two")
        #endif
        #expect(MarkdownInlineParser.parse("[^docs](https://example.com)") == [.link(label: [.text("^docs")], destination: "https://example.com")])
        for (raw,escaped) in [("100%","100%25"),("%ZZ","%25ZZ"),("a%20b","a%20b")] {
            for (format,path) in [(ExportableFileType.docx,"word/_rels/document.xml.rels"),(.pptx,"ppt/slides/_rels/slide1.xml.rels")] {
                let rels = try xml(PicoDocsEngine.write(markdown: "[^docs](https://example.test/" + raw + ")", to: format), path)
                #expect(rels.contains("https://example.test/" + escaped))
            }
        }
    }

    @Test func sparseSpreadsheetCoordinatesSurviveOfficeRoundTrip() async throws {
        let base = try PicoDocsEngine.write(markdown: "| A | B | C |\n| --- | --- |", to: .xlsx)
        let archive = try #require(Archive(data: base, accessMode: .read))
        let worksheet = #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>First</t></is></c><c r="C1" t="inlineStr"><is><t>Third</t></is></c></row><row r="3"><c r="B3" t="inlineStr"><is><t>Middle</t></is></c></row></sheetData></worksheet>"#
        var entries: [(name: String, data: [UInt8])] = []
        for entry in archive {
            var bytes = Data(); _ = try archive.extract(entry) { bytes.append($0) }
            entries.append((entry.path, entry.path == "xl/worksheets/sheet1.xml" ? Array(worksheet.utf8) : Array(bytes)))
        }
        let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip(entries), filename: "sparse.xlsx")
        #expect(result.sections.first?.metadata["csv"] == "\"First\",\"\",\"Third\"\n\"\",\"\",\"\"\n\"\",\"Middle\",\"\"")
        let output = try xml(PicoDocsEngine.write(result, to: .xlsx), "xl/worksheets/sheet1.xml")
        #expect(output.contains(#"r="C1" t="inlineStr"><is><t xml:space="preserve">Third"#))
        #expect(output.contains(#"r="B3" t="inlineStr"><is><t xml:space="preserve">Middle"#))
    }

    @Test func inlineSentinelsAndOptionalLinkTitlesStayDistinct() throws {
        for source in ["\u{E020}0\u{E021} `code`", "\u{E010}0\u{E011} \\*"] {
            let expected = source.replacingOccurrences(of: "`code`", with: "code").replacingOccurrences(of: "\\*", with: "*")
            #expect(MarkdownInlineParser.parse(source).plainText == expected)
            let document = try SwiftSoup.parse(xml(PicoDocsEngine.write(markdown: source, to: .docx), "word/document.xml"), "", SwiftSoup.Parser.xmlParser())
            let visible = try document.getElementsByTag("w:t").array().map { $0.getChildNodes().compactMap { ($0 as? TextNode)?.getWholeText() }.joined() }.joined()
            #expect(visible == expected)
        }
        for source in [#"[Label](https://example.com "Home")"#, #"[Label](<https://example.com> "Home")"#, #"[Label](https://example.com 'Home')"#, #"[Label](https://example.com (Home))"#, #"[Label](https://example.com/a_(b) "Home (extra)")"#] {
            let nodes = MarkdownInlineParser.parse(source)
            let expected = source.contains("a_(b)") ? "https://example.com/a_(b)" : "https://example.com"
            #expect(nodes == [.link(label: [.text("Label")], destination: expected)])
            for (format, path) in [(ExportableFileType.docx, "word/_rels/document.xml.rels"), (.pptx, "ppt/slides/_rels/slide1.xml.rels")] {
                let rels = try xml(PicoDocsEngine.write(markdown: source, to: format), path)
                #expect(rels.contains(expected)); #expect(!rels.contains("Home"))
            }
        }
    }

    @Test func literalWordRunsSurviveOfficeTranscoding() async throws {
        let literals = [#"[label](https://example.com) *stars* `code` ![image](x) \*"#, "# Heading", "1. List", "- Bullet", "---"]
        let paragraphs = literals.map { "<w:p><w:r><w:t>" + $0 + "</w:t></w:r></w:p>" }.joined()
        let document = #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>"# + paragraphs + "</w:body></w:document>"
        let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8))]), filename: "literal.docx")
        let exported = try PicoDocsEngine.write(result, to: .docx)
        let output = try xml(exported, "word/document.xml")
        #expect(!output.contains("<w:hyperlink")); #expect(!output.contains("<w:numPr>")); #expect(!output.contains("<w:drawing>"))
        for literal in literals { #expect(output.contains(literal)) }
        let recovered = try await PicoDocsEngine.convert(data: exported, filename: "again.docx")
        let plain = try DocumentRenderer.render(recovered, to: .plaintext)
        for literal in literals { #expect(plain.contains(literal)) }
    }

    @Test func titleOnlySlidesAndPathQualifiedTitleImages() throws {
        let slide = ConverterResult(sections: [.init(title: "Agenda", kind: .slide, markdown: "", slideNumber: 1)])
        #expect(try xml(PicoDocsEngine.write(slide, to: .pptx), "ppt/slides/slide1.xml").contains(">Agenda</a:t>"))
        let images = ConverterResult(sections: ["charts/logo.png", "headers/logo.png"].enumerated().map { index, title in
            .init(title: title, kind: .image, markdown: "", metadata: ["base64": Data([UInt8(index + 1)]).base64EncodedString(), "mimeType": "image/png"])
        })
        let docx = try PicoDocsEngine.write(images, to: .docx)
        #expect(try xml(docx, "word/document.xml").components(separatedBy: "<w:drawing>").count - 1 == 2)
        let archive = try #require(Archive(data: docx, accessMode: .read))
        #expect(archive.filter { $0.path.hasPrefix("word/media/") }.count == 2)
    }

    @Test func listContinuationHardBreaksAndItalicCode() throws {
        let source = "- first\n  second  \n  third"
        let docx = try PicoDocsEngine.write(markdown: source, to: .docx)
        #expect(try xml(docx, "word/document.xml").contains("<w:br/>"))
        let pptx = try PicoDocsEngine.write(markdown: source, to: .pptx)
        #expect(try xml(pptx, "ppt/slides/slide1.xml").contains("first second</a:t></a:r><a:br/>"))
        #if canImport(AppKit)
        for source in ["*`code`*", "***`code`***"] {
            let string = AttributedStringDocumentBuilder.attributedString(from: ConverterResult(sections: [.init(markdown: source)]))
            let font = try #require(string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            #expect(font.fontDescriptor.symbolicTraits.contains(.italic))
            #expect(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
            if source.hasPrefix("***") { #expect(font.fontDescriptor.symbolicTraits.contains(.bold)) }
        }
        let list = AttributedStringDocumentBuilder.attributedString(from: ConverterResult(sections: [.init(markdown: source)]))
        #expect(list.string.contains("first second\nthird"))
        #endif
    }

    @Test func importedSheetValuesHaveLosslessRoundTripCarrier() async throws {
        let csv = #""*value*","`code`","[label](url)","\*literal\*"," edge ","line"# + "\r\nbreak\""
        let original = ConverterResult(sections: [.init(title: "`Code`", kind: .sheet, markdown: "", metadata: ["csv": csv])])
        let first = try PicoDocsEngine.write(original, to: .xlsx)
        let recovered = try await PicoDocsEngine.convert(data: first, filename: "literal.xlsx")
        #expect(recovered.sections.first?.metadata["csv"] == csv)
        let second = try PicoDocsEngine.write(recovered, to: .xlsx)
        #expect(try xml(second, "xl/worksheets/sheet1.xml") == xml(first, "xl/worksheets/sheet1.xml"))
        #expect(try DocumentRenderer.render(recovered, to: .csv) == csv)
        let echoed = ConverterResult(sections: [.init(title: "`Code`", kind: .sheet, markdown: "## `Code`\n\n| Value |\n| --- |\n| Actual |")])
        let sheet = try xml(PicoDocsEngine.write(echoed, to: .xlsx), "xl/worksheets/sheet1.xml")
        #expect(sheet.components(separatedBy: "<row ").count - 1 == 2)
        #expect(!sheet.contains(">Code</t>"))
    }

    @Test func canonicalLineEndingsFencesAndTabMarkers() throws {
        let expected: [MarkdownBlock] = [.heading(1, "Title"), .code("code"), .paragraph("after")]
        for newline in ["\r\n", "\r", "\n"] {
            #expect(MarkdownBlockParser.parse(["# Title", "", "```", "code", "```", "after"].joined(separator: newline)) == expected)
        }
        for source in ["~~~\n[^n]: literal\n~~~", "````\n```\n[^n]: literal\n````"] {
            for format in [ExportFileType.html, .plaintext] {
                let text = try DocumentRenderer.render(ConverterResult(sections: [.init(markdown: source)]), to: format)
                #expect(text.contains("[^n]: literal"))
            }
        }
        for marker in ["-", "*", "+", "2."] {
            let data = try PicoDocsEngine.write(markdown: marker + "\tfirst\n\tcontinued", to: .docx)
            #expect(try xml(data, "word/document.xml").contains("<w:numPr>"))
        }
        let sibling = try PicoDocsEngine.write(markdown: "- first\n - second", to: .pptx)
        #expect(try !xml(sibling, "ppt/slides/slide1.xml").contains(#"lvl="1""#))
    }

    @Test func inlineCodeNormalizesItsOwnSlideNewlines() throws {
        let data = try PicoDocsEngine.write(markdown: "`one\\\ntwo` and `one  \ntwo`\n\n- `list\\\n  continuation`", to: .pptx)
        let slide = try xml(data, "ppt/slides/slide1.xml")
        #expect(slide.contains(#">one\ two</a:t>"#))
        #expect(slide.contains(">one   two</a:t>"))
        #expect(!slide.contains("<a:br/>"))
        #expect(MarkdownInlineParser.parse(#"[x](<https://e.test/a\>b\~c>)"#) == [.link(label: [.text("x")], destination: "https://e.test/a>b~c")])
        let linked = try PicoDocsEngine.write(markdown: #"[x](<https://e.test/a\>b\~c>)"#, to: .docx)
        #expect(try xml(linked, "word/_rels/document.xml.rels").contains("https://e.test/a%3Eb~c"))
    }

    @Test func CSVCRLFRecordsAndCarriageReturnsStayLossless() throws {
        let csv = "A,B\r\n\"one\rtwo\",\"three\r\nfour\"\r\nlast,value"
        let result = ConverterResult(sections: [.init(kind: .sheet, markdown: "", metadata: ["csv": csv])])
        let sheet = try xml(PicoDocsEngine.write(result, to: .xlsx), "xl/worksheets/sheet1.xml")
        #expect(sheet.components(separatedBy: "<row ").count - 1 == 3)
        #expect(sheet.contains("one&#13;two"))
        #expect(sheet.contains("three&#13;\nfour"))
        #expect(sheet.contains(#"r="B3""#))
    }

    @Test func sheetNamesRespectUTF16BudgetAndGraphemeBoundaries() throws {
        let flag = "🇺🇸", family = "👨‍👩‍👧‍👦"
        let result = ConverterResult(sections: [flag, flag, family].map { .init(title: String(repeating: $0, count: 31), markdown: "value") })
        let workbook = try xml(PicoDocsEngine.write(result, to: .xlsx), "xl/workbook.xml")
        let document = try SwiftSoup.parse(workbook, "", SwiftSoup.Parser.xmlParser())
        let names = try document.getElementsByTag("sheet").array().map { try $0.attr("name") }
        #expect(names.count == 3)
        #expect(names.allSatisfy { $0.utf16.count <= 31 })
        #expect(names[0] == String(repeating: flag, count: 7))
        #expect(names[1] == String(repeating: flag, count: 6) + " (2)")
        #expect(names[2] == String(repeating: family, count: 2))
    }

    @Test func nestedEmphasisSharedClosersAndAllPunctuationEscapes() {
        #expect(MarkdownInlineParser.parse("**bold *italic***") == [.strong([.text("bold "), .emphasis([.text("italic")])])])
        #expect(MarkdownInlineParser.parse("*italic **bold***") == [.emphasis([.text("italic "), .strong([.text("bold")])])])
        #expect(MarkdownInlineParser.parse("**before *inside `code`* after**").plainText == "before inside code after")
        #expect(MarkdownInlineParser.parse(#"Cost: \$5, literal \~text\~ and \>"#).plainText == "Cost: $5, literal ~text~ and >")
        #expect(MarkdownInlineParser.parse(#"[\$5](https://example.com) and `\$5`"#).plainText == #"$5 and \$5"#)
    }

    @Test func slideHyperlinksNumberBoundsAndTabContinuations() throws {
        let source = "# [Title](https://example.com/title)\n\nVisit **[bold](https://example.com/a?x=1&y=2)**\n\n0. Zero\n32768. Large\n\n- first\n\tcontinued\n\t- [child](https://example.com/child)"
        let data = try PicoDocsEngine.write(markdown: source, to: .pptx)
        let slide = try xml(data, "ppt/slides/slide1.xml")
        let rels = try xml(data, "ppt/slides/_rels/slide1.xml.rels")
        #expect(slide.components(separatedBy: "<a:hlinkClick ").count - 1 == 3)
        #expect(slide.contains(#"<a:rPr b="1"><a:hlinkClick"#))
        #expect(rels.contains(#"Target="https://example.com/a?x=1&amp;y=2" TargetMode="External""#))
        #expect(rels.contains("/title")); #expect(rels.contains("/child"))
        #expect(!slide.contains(#"startAt="0""#)); #expect(!slide.contains(#"startAt="32768""#))
        #expect(slide.contains(">0. </a:t>")); #expect(slide.contains(">32768. </a:t>"))
        #expect(slide.contains(">first continued</a:t>"))
        #expect(slide.contains(#"<a:pPr lvl="1"><a:buChar"#))
        let docx = try PicoDocsEngine.write(markdown: "- first\n\tcontinued", to: .docx)
        let document = try xml(docx, "word/document.xml")
        #expect(document.components(separatedBy: "<w:p>").count - 1 == 1)
        #expect(document.contains("continued"))
    }

    @Test func unsupportedMediaExtensionUsesKnownMIME() throws {
        let image = DocumentSection(kind: .image, markdown: "", sourcePath: "avatar.dat", metadata: ["base64": "AQID", "mimeType": "image/png"])
        let data = try PicoDocsEngine.write(ConverterResult(sections: [.init(markdown: "![Avatar](avatar.dat)"), image]), to: .docx)
        let archive = try #require(Archive(data: data, accessMode: .read))
        #expect(archive["word/media/avatar.png"] != nil)
        #expect(archive["word/media/avatar.dat"] == nil)
        #expect(try xml(data, "[Content_Types].xml").contains(#"Extension="png" ContentType="image/png""#))
    }

    @Test func structuredEmphasisFlankingAndLiteralPaths() {
        #expect(MarkdownInlineParser.parse("**before `code` after**") == [.strong([.text("before "), .code("code"), .text(" after")])])
        #expect(MarkdownInlineParser.parse("*see [link](https://example.com)*") == [.emphasis([.text("see "), .link(label: [.text("link")], destination: "https://example.com")])])
        #expect(MarkdownInlineParser.parse("2 * 3 * 4").plainText == "2 * 3 * 4")
        #expect(MarkdownInlineParser.parse(#"![x](C:\images\pic.png)"#) == [.image(alt: "x", source: #"C:\images\pic.png"#)])
    }

    @Test func listStartsAndNestingSurviveOfficeRoundTrips() async throws {
        let source = "3. Parent\n   1. Child\n      - Grandchild\n4. Next"
        var result = ConverterResult(sections: [.init(markdown: source)])
        for _ in 0..<2 {
            let docx = try PicoDocsEngine.write(result, to: .docx)
            let document = try xml(docx, "word/document.xml")
            #expect(document.contains(#"w:ilvl w:val="1""#))
            #expect(document.contains(#"w:ilvl w:val="2""#))
            #expect(try xml(docx, "word/numbering.xml").contains(#"w:startOverride w:val="3""#))
            result = try await PicoDocsEngine.convert(data: docx, filename: "nested.docx")
            #expect(result.markdown().contains("3. Parent\n   1. Child\n      - Grandchild\n4. Next"))
        }
        let pptx = try PicoDocsEngine.write(result, to: .pptx)
        let slide = try xml(pptx, "ppt/slides/slide1.xml")
        #expect(slide.contains(#"<a:pPr lvl="1"><a:buAutoNum type="arabicPeriod" startAt="1""#))
        #expect(slide.contains(#"startAt="3""#))
    }

    @Test func imagePathsCSVMetadataCellLimitsAndSlideGaps() throws {
        for (path, title, reference) in [(#"C:\images\pic.png"#, "pic.png", #"C:\images\pic.png"#), ("", "logo.png", "logo.png")] {
            let image = DocumentSection(title: title, kind: .image, markdown: "", sourcePath: path, metadata: ["base64": "AQID", "mimeType": "image/png"])
            let result = ConverterResult(sections: [.init(markdown: "![Image](\(reference))"), image])
            let data = try PicoDocsEngine.write(result, to: .docx)
            #expect(try xml(data, "word/document.xml").contains("<w:drawing>"))
            let archive = try #require(Archive(data: data, accessMode: .read))
            for entry in archive where entry.path.hasPrefix("word/media/") {
                #expect(!entry.path.contains("\\"))
                #expect(!entry.path.contains(":"))
            }
        }
        let csvOnly = ConverterResult(sections: [.init(kind: .sheet, markdown: "", metadata: ["csv": "A,B\n1,2"])])
        #expect(try xml(PicoDocsEngine.write(csvOnly, to: .xlsx), "xl/worksheets/sheet1.xml").contains(">A</t>"))
        #expect(throws: ExporterError.self) { try PicoDocsEngine.write(markdown: String(repeating: "x", count: 32_768), to: .xlsx) }
        let deck = ConverterResult(sections: [.init(kind: .slide, markdown: "Third", slideNumber: 3), .init(kind: .slide, markdown: "First", slideNumber: 1)])
        let pptx = try PicoDocsEngine.write(deck, to: .pptx)
        #expect(try xml(pptx, "ppt/slides/slide1.xml").contains("First"))
        #expect(try xml(pptx, "ppt/slides/slide2.xml").contains("<a:p/>"))
        #expect(try xml(pptx, "ppt/slides/slide3.xml").contains("Third"))
    }

    @Test func slideBreaksSpaceCodeAndTableNumbering() async throws {
        let pptx = try PicoDocsEngine.write(markdown: "first\nsecond\n\nfirst\\\nsecond", to: .pptx)
        let slide = try xml(pptx, "ppt/slides/slide1.xml")
        #expect(slide.contains("first second</a:t>"))
        #expect(slide.contains("first</a:t></a:r><a:br/><a:r><a:t>second"))
        var result = ConverterResult(sections: [.init(markdown: "` `")])
        for _ in 0..<3 {
            result = try await PicoDocsEngine.convert(data: PicoDocsEngine.write(result, to: .docx), filename: "space.docx")
            #expect(MarkdownInlineParser.parse(result.markdown()) == [.code(" ")])
        }
        let ns = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main""#
        let numbering = "<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:numFmt w:val=\"decimal\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num></w:numbering>"
        func paragraph(_ text: String) -> String { "<w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>" }
        let document = "<w:document \(ns)><w:body>" + paragraph("Before") + "<w:tbl><w:tr><w:tc>" + paragraph("Inside") + "</w:tc></w:tr></w:tbl>" + paragraph("After") + "</w:body></w:document>"
        let data = PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(document.utf8)), (name: "word/numbering.xml", data: Array(numbering.utf8))])
        let numbered = try await PicoDocsEngine.convert(data: data, filename: "table.docx").markdown()
        #expect(numbered.contains("2. Inside"))
        #expect(numbered.contains("3. After"))
    }

    @Test func completeCodeDelimitersAndMalformedDestinations() async throws {
        #expect(MarkdownInlineParser.parse("Use ``a`b`` now") == [.text("Use "), .code("a`b"), .text(" now")])
        #expect(MarkdownInlineParser.parse("`` `x` ``") == [.code("`x`")])
        let fenced = "````\n```\ncontent\n```\n````"
        #expect(MarkdownBlockParser.parse(fenced) == [.code("```\ncontent\n```")])
        #expect(MarkdownBlockParser.parse("~~~\n```\n~~~") == [.code("```")])
        let incomplete = String(repeating: "[](", count: 20_000)
        #expect(MarkdownInlineParser.parse(incomplete).plainText == incomplete)
        let markdown = "Use ``a`b`` now\n\n" + fenced
        let docx = try PicoDocsEngine.write(markdown: markdown, to: .docx)
        let recovered = try await PicoDocsEngine.convert(data: docx, filename: "code.docx")
        #expect(recovered.markdown().contains("``a`b``"))
        #expect(recovered.markdown().contains(fenced))
    }

    @Test func quotesListsSlideMarkersAndTitleImages() async throws {
        let source = "> Quoted\n\n1. Plan\n2. Ship\n\n- Bullet"
        let data = try PicoDocsEngine.write(markdown: source, to: .docx)
        let recovered = try await PicoDocsEngine.convert(data: data, filename: "roundtrip.docx")
        #expect(recovered.markdown().contains("> Quoted"))
        #expect(recovered.markdown().contains("1. Plan"))
        #expect(recovered.markdown().contains("2. Ship"))
        #expect(recovered.markdown().contains("- Bullet"))
        let second = try PicoDocsEngine.write(recovered, to: .docx)
        let reread = try await PicoDocsEngine.convert(data: second, filename: "second.docx")
        #expect(reread.markdown().contains("2. Ship"))
        let slide = try xml(PicoDocsEngine.write(markdown: source, to: .pptx), "ppt/slides/slide1.xml")
        #expect(slide.contains(#"<a:buAutoNum type="arabicPeriod" startAt="1"/>"#))
        #expect(slide.contains(#"<a:buAutoNum type="arabicPeriod" startAt="2"/>"#))
        #expect(slide.contains("<a:buChar"))
        let image = ConverterResult(sections: [.init(title: "icons/logo.png", kind: .image, markdown: "", metadata: ["base64": Data([1,2,3]).base64EncodedString(), "mimeType": "image/png"])])
        #expect(try xml(PicoDocsEngine.write(image, to: .docx), "word/document.xml").contains("<w:drawing>"))
    }

    @Test func sheetWhitespaceAndAttributedBreaks() throws {
        let sheets = ConverterResult(sections: ["A B", "A\nB", "A\tB", "A\rB"].map { .init(title: $0, kind: .sheet, markdown: "x") })
        let workbook = try xml(PicoDocsEngine.write(sheets, to: .xlsx), "xl/workbook.xml")
        #expect(workbook.components(separatedBy: #"name="A B""#).count == 2)
        #expect(workbook.contains(#"name="A B (2)""#))
        #if canImport(AppKit) || canImport(UIKit)
        let result = ConverterResult(sections: [.init(markdown: "first\nsecond\n\nfirst\\\nsecond\n\nfirst  \nsecond")])
        let text = AttributedStringDocumentBuilder.attributedString(from: result).string
        #expect(text.contains("first second"))
        #expect(text.components(separatedBy: "first\nsecond").count == 3)
        #expect(!text.contains("\\"))
        #endif
    }

    private func xml(_ data: Data, _ path: String) throws -> String {
        let archive = try #require(Archive(data: data, accessMode: .read))
        let entry = try #require(archive[path])
        var bytes = Data()
        _ = try archive.extract(entry) { bytes.append($0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    @Test func inlineLiteralEscapesFootnotesAndUnmatchedOpeners() {
        #expect(MarkdownInlineParser.parse(#"\*literal\*"#) == [.text("*literal*")])
        #expect(MarkdownInlineParser.parse(#"*a\*b*"#) == [.emphasis([.text("a*b")])])
        #expect(MarkdownInlineParser.parse(#"\[not a link](url)"#).plainText == "[not a link](url)")
        #expect(MarkdownInlineParser.parse("Claim[^1]\n[^1]: Source").plainText == "Claim[^1]\n[^1]: Source")
        let unfinished = String(repeating: "[^", count: 20_000)
        #expect(MarkdownInlineParser.parse(unfinished).plainText == unfinished)
    }

    @Test func docxStylesCodeAndHyperlinks() async throws {
        let markdown = "# Heading\n\n> Quote\n\nUse `x` here.\n\n```\n  let x = 1\nprint(x)\n```\n\n[Link](<https://example.com/a b?q=x y&v=1>)"
        let data = try PicoDocsEngine.write(markdown: markdown, to: .docx)
        let styles = try xml(data, "word/styles.xml")
        #expect(styles.contains(#"w:styleId="Heading1""#))
        #expect(styles.contains(#"w:styleId="Quote""#))
        #expect(styles.contains(#"w:styleId="PicoCodeBlock""#))
        let rels = try xml(data, "word/_rels/document.xml.rels")
        #expect(rels.contains("/styles"))
        #expect(rels.contains("https://example.com/a%20b?q=x%20y&amp;v=1"))
        let recovered = try await PicoDocsEngine.convert(data: data, filename: "out.docx")
        #expect(recovered.markdown().contains("Use `x` here."))
        #expect(recovered.markdown().contains("```\n  let x = 1\nprint(x)\n```"))
    }

    @Test func mediaIdentitySurvivesSecondExportAndReservedExtensions() async throws {
        for name in ["chart#1.png", "chart.xml", "chart.rels"] {
            let image = DocumentSection(kind: .image, markdown: "", sourcePath: name, metadata: ["mimeType": "image/png", "base64": Data([1, 2, 3]).base64EncodedString()])
            let first = try PicoDocsEngine.write(ConverterResult(sections: [image]), to: .docx)
            let recovered = try await PicoDocsEngine.convert(data: first, filename: "one.docx")
            let second = try PicoDocsEngine.write(recovered, to: .docx)
            #expect(try xml(second, "word/document.xml").contains("<w:drawing>"))
            let types = try xml(first, "[Content_Types].xml")
            #expect(types.components(separatedBy: #"Extension="xml""#).count == 2)
            #expect(types.components(separatedBy: #"Extension="rels""#).count == 2)
        }
    }

    @Test func emptyWorksheetsAndSpreadsheetLimits() throws {
        let sheets = ConverterResult(sections: [DocumentSection(title: "Empty", kind: .sheet, markdown: ""), DocumentSection(title: "Data", kind: .sheet, markdown: "Value")])
        let data = try PicoDocsEngine.write(sheets, to: .xlsx)
        let workbook = try xml(data, "xl/workbook.xml")
        #expect(workbook.contains(#"name="Empty""#))
        #expect(workbook.contains(#"name="Data""#))
        let oversized = ConverterResult(sections: [DocumentSection(markdown: "data", metadata: ["csv": Array(repeating: "x", count: 16_385).joined(separator: ",")])])
        #expect(throws: ExporterError.self) { try PicoDocsEngine.write(oversized, to: .xlsx) }
        #expect(throws: ExporterError.self) { try XLSXExporter.validateDimensions(rows: 1_048_577, columns: 1) }
        try XLSXExporter.validateDimensions(rows: 61, columns: 16_384)
    }

    @Test func metadataAndCanonicalTableBreaks() throws {
        let result = ConverterResult(title: "Review title", author: "Review author", sections: [DocumentSection(markdown: "| first<br>second |\n| --- |")])
        for format in [ExportableFileType.docx, .xlsx, .pptx] {
            let data = try PicoDocsEngine.write(result, to: format)
            let core = try xml(data, "docProps/core.xml")
            #expect(core.contains("<dc:title>Review title</dc:title>"))
            #expect(core.contains("<dc:creator>Review author</dc:creator>"))
            #expect(try xml(data, "_rels/.rels").contains("metadata/core-properties"))
        }
        let pptx = try PicoDocsEngine.write(result, to: .pptx)
        #expect(try xml(pptx, "ppt/slides/slide1.xml").contains("first</a:t></a:r><a:br/><a:r><a:t>second"))
        #if canImport(AppKit) || canImport(UIKit)
        let rtf = try PicoDocsEngine.write(result, to: .rtf)
        let text = String(decoding: rtf, as: UTF8.self)
        #expect(text.contains("Review title"))
        #expect(text.contains("Review author"))
        #expect(!text.contains("<br>"))
        #endif
    }
}
