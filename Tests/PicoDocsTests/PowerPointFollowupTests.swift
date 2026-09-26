import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

struct PowerPointFollowupTests {
    @Test func HTMLTableTextKeepsLiteralInlinePunctuation() async throws {
        let source = "<table><tr><td>Value</td></tr><tr><td>*stars* `code` [label](target) <strong>Bold</strong></td></tr></table>"
        let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: "literal.html")
        for format in [ExportFileType.plaintext, .csv] {
            #expect(try DocumentRenderer.render(result, to: format).contains("*stars* `code` [label](target) Bold"))
        }
    }

    @Test func mixedOrderedMarkersAdvanceAndLooseListsKeepBoundaries() throws {
        let result = ConverterResult(sections: [.init(markdown: "1. First\n1. Second\n2. Third\n10. Gap\n\n11. Separate")])
        #expect(try DocumentRenderer.render(result, to: .plaintext) == "1. First\n2. Second\n3. Third\n10. Gap\n\n11. Separate")
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.components(separatedBy: "<ol").count - 1 == 2)
        #expect(!html.contains(#"value="2""#))
    }

    @Test func numberingSchemeChangesClearStartTracking() async throws {
        typealias B = PowerPointConverterTests
        let specs = [("arabicPeriod", " startAt=\"5\""), ("alphaLcPeriod", ""), ("alphaLcPeriod", " startAt=\"5\"")]
        let paragraphs = specs.enumerated().map { index, pair in
            "<a:p><a:pPr><a:buAutoNum type=\"\(pair.0)\"\(pair.1)/></a:pPr><a:r><a:t>Item \(index)</a:t></a:r></a:p>"
        }
        let result = try await PicoDocsEngine.convert(data: B.deck(slides: [.init(file:"s.xml",shapes:B.shape(placeholder:nil,paragraphs:paragraphs))]), filename:"schemes.pptx")
        #expect(result.markdown().contains("- e. Item 2"))
    }

    @Test func XMLRejectsDTDsAcrossEncodingsAndRetainsLiteralMentions() {
        for source in ["<!DOCTYPE x [<!ENTITY a 'text'>]><x>&a;</x>", "<!DOCTYPE x SYSTEM 'https://invalid.example/x'><x/>", "<!DOCTYPE x><x/>"] {
            for encoding in [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian] {
                #expect(PowerPointXML.normalize(source.data(using: encoding)!) == nil)
            }
        }
        #expect(PowerPointXML.normalize(Data("<!-- <!DOCTYPE ignored> --><x><![CDATA[<!DOCTYPE literal>]]></x>".utf8)) == "<x>&lt;!DOCTYPE literal&gt;</x>")
    }

    @Test func cachedLayoutAndMasterTreesAndDuplicateRelationshipsAreValidated() throws {
        typealias B = PowerPointConverterTests
        for root in ["sldLayout", "sldMaster", "notesMaster"] {
            let data = PagesConverterTests.makeZip([(name:"part.xml",data:Array("<p:\(root) \(B.namespaces)/>".utf8))])
            let package = PowerPointPackage(archive: try #require(Archive(data:data,accessMode:.read)))
            var cache = PowerPointConverter.PartCache(archive:package)
            #expect(cache.document("part.xml",root:"p:" + root.lowercased()) == nil)
            #expect(throws:PicoDocsError.fileCorrupted) { try package.check() }
        }
        let rels = B.relationshipsXML([("same","http://schemas.openxmlformats.org/officeDocument/2006/relationships/image","a.png"),("same","http://schemas.openxmlformats.org/officeDocument/2006/relationships/image","b.png")])
        let package = PowerPointPackage(archive:try #require(Archive(data:PagesConverterTests.makeZip([(name:"ppt/slides/_rels/s.xml.rels",data:Array(rels.utf8))]),accessMode:.read)))
        #expect(PowerPointConverter.relationships(package,forPart:"ppt/slides/s.xml").isEmpty)
        #expect(throws:PicoDocsError.fileCorrupted) { try package.check() }
    }

    @Test func pictureRelationshipsAndAlternateBranchesAreValidated() async throws {
        typealias B = PowerPointConverterTests
        let fill = "<mc:AlternateContent><mc:Choice Requires=\"p14\"><a:blip r:embed=\"wrong\"/></mc:Choice><mc:Fallback><a:blip r:embed=\"image\"/></mc:Fallback></mc:AlternateContent>"
        let picture = "<p:pic><p:nvPicPr><p:cNvPr descr=\"Photo\"/></p:nvPicPr><p:blipFill>" + fill + "</p:blipFill></p:pic>"
        let type = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
        for imageType in ["image", "slide"] {
            let data = B.deck(slides:[.init(file:"s.xml",shapes:B.titleShape("Slide") + picture,relationships:[("image",type + imageType,"../media/good.png")])],extraParts:[("ppt/media/good.png",[1,2,3])])
            if imageType == "image" {
                let result = try await PicoDocsEngine.convert(data:data,filename:"fallback.pptx")
                #expect(result.sections.contains { $0.kind == .image && $0.metadata["base64"] == "AQID" })
            } else {
                await #expect(throws:PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data:data,filename:"bad-type.pptx") }
            }
        }
    }

    @Test func normalizedXMLHasAnOutputBudget() {
        let quotes = "<root>" + String(repeating: "\"", count: 100) + "</root>"
        #expect(PowerPointXML.normalize(Data(quotes.utf8), maximumOutputBytes: 113) == quotes)
        for source in ["<root><![CDATA[" + String(repeating: "<", count: 50) + "]]></root>", "<root value='" + String(repeating: "\"", count: 50) + "'/>"] {
            #expect(PowerPointXML.normalize(Data(source.utf8), maximumOutputBytes: 128) == nil)
        }
    }

    @Test func tableLiteralBreakMarkersRemainVisible() async throws {
        for (name, source) in [("table.csv", "Value\nfirst<br>second"), ("table.html", "<table><tr><td>Value</td></tr><tr><td>first&lt;br&gt;second</td></tr></table>")] {
            let result = try await PicoDocsEngine.convert(data: Data(source.utf8), filename: name)
            #expect(try DocumentRenderer.render(result, to: .plaintext).contains("first<br>second"))
            #expect(try DocumentRenderer.render(result, to: .html).contains("first&lt;br&gt;second"))
            #expect(try DocumentRenderer.render(result, to: .csv).contains("first<br>second"))
        }
    }

    @Test func unorderedRunsKeepTheirBlankBoundary() throws {
        let result = ConverterResult(sections: [.init(markdown: "- First\n- Second\n\n- Separate\n  - Child")])
        #expect(try DocumentRenderer.render(result, to: .plaintext) == "- First\n- Second\n\n- Separate\n  - Child")
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.components(separatedBy: "<ul>").count - 1 == 3)
    }

    @Test func misplacedSlideIDsAndNotesTreesAreRejected() async throws {
        typealias B = PowerPointConverterTests
        let notes = "<p:notes \(B.namespaces)><p:extLst><p:cSld><p:spTree>" + B.shape(placeholder: #"<p:ph type="body"/>"#, paragraphs: ["<a:p><a:r><a:t>Wrong</a:t></a:r></a:p>"]) + "</p:spTree></p:cSld></p:extLst></p:notes>"
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Slide"), relationships: [("notes", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide", "../notesSlides/n.xml")])], extraParts: [("ppt/notesSlides/n.xml", Array(notes.utf8))])
        await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: data, filename: "bad-notes.pptx") }
        let ordinary = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Slide"))])
        let archive = try #require(Archive(data: ordinary, accessMode: .read))
        var entries: [(name: String, data: [UInt8])] = []
        for entry in archive {
            var bytes = Data(); _ = try archive.extract(entry) { bytes.append($0) }
            if entry.path == "ppt/presentation.xml" {
                let text = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "<p:sldIdLst>", with: "<p:extLst><p:sldIdLst>").replacingOccurrences(of: "</p:sldIdLst>", with: "</p:sldIdLst></p:extLst>")
                bytes = Data(text.utf8)
            }
            entries.append((entry.path, Array(bytes)))
        }
        await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip(entries), filename: "bad-order.pptx") }
    }

    @Test func repeatedMarkersContinueWithinOneMarkdownList() throws {
        let result = ConverterResult(sections: [.init(markdown: "1. First\n1. Second\n1. Third\n10. Gap\n10. Next")])
        #expect(try DocumentRenderer.render(result, to: .plaintext) == "1. First\n2. Second\n3. Third\n10. Gap\n11. Next")
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(!html.contains(#"value="1""#)); #expect(html.contains(#"value="10""#))
        let restarted = ConverterResult(sections: [.init(markdown: "1. First\n1. Second\n\n1. Restart")])
        #expect(try DocumentRenderer.render(restarted, to: .plaintext) == "1. First\n2. Second\n\n1. Restart")
    }

    @Test func missingOrMisplacedShapeTreesAreCorrupt() async throws {
        typealias B = PowerPointConverterTests
        let data = B.deck(slides: [.init(file: "one.xml", shapes: B.titleShape("Good")), .init(file: "two.xml", shapes: "")])
        let archive = try #require(Archive(data: data, accessMode: .read))
        for content in ["", "<p:extLst><p:cSld><p:spTree/></p:cSld></p:extLst>"] {
            var entries: [(name: String,data: [UInt8])] = []
            for entry in archive {
                var bytes = Data(); _ = try archive.extract(entry) { bytes.append($0) }
                entries.append((entry.path, entry.path == "ppt/slides/two.xml" ? Array("<p:sld \(B.namespaces)>\(content)</p:sld>".utf8) : Array(bytes)))
            }
            await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip(entries), filename: "bad-tree.pptx") }
        }
        let valid = try await PicoDocsEngine.convert(data: data, filename: "empty-slide.pptx")
        #expect(valid.sections.count == 1)
    }

    @Test func cellsAndOtherPlaceholdersInheritTheirOwnListStyles() async throws {
        typealias B = PowerPointConverterTests
        let table = #"<p:graphicFrame><a:graphic><a:graphicData><a:tbl><a:tr><a:tc><a:txBody><a:lstStyle><a:lvl1pPr><a:buAutoNum type="arabicPeriod" startAt="4"/><a:defRPr b="1" i="1"/></a:lvl1pPr></a:lstStyle><a:p><a:r><a:t>Cell</a:t></a:r></a:p></a:txBody></a:tc><a:tc><a:txBody><a:p><a:r><a:t>Plain</a:t></a:r></a:p></a:txBody></a:tc></a:tr></a:tbl></a:graphicData></a:graphic></p:graphicFrame>"#
        let shape = B.shape(placeholder: #"<p:ph type="chart"/>"#, paragraphs: ["<a:p><a:r><a:t>Caption</a:t></a:r></a:p>"])
        let layout = "<p:sldLayout \(B.namespaces)><p:cSld><p:spTree/></p:cSld></p:sldLayout>"
        let master = "<p:sldMaster \(B.namespaces)><p:cSld><p:spTree/></p:cSld><p:txStyles><p:otherStyle><a:lvl1pPr><a:buAutoNum type=\"arabicPeriod\" startAt=\"7\"/></a:lvl1pPr></p:otherStyle></p:txStyles></p:sldMaster>"
        let rels = B.relationshipsXML([("master","http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster","../slideMasters/m.xml")])
        let data = B.deck(slides: [.init(file: "s.xml", shapes: table + shape, relationships: [("layout","http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout","../slideLayouts/l.xml")])], extraParts: [("ppt/slideLayouts/l.xml",Array(layout.utf8)),("ppt/slideLayouts/_rels/l.xml.rels",Array(rels.utf8)),("ppt/slideMasters/m.xml",Array(master.utf8))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "styles.pptx")
        #expect(result.markdown().contains("| 4. ***Cell*** | Plain |"))
        #expect(result.markdown().contains("7. Caption"))
    }

    @Test func changedExplicitStartsRestartWhileOmittedStartsContinue() async throws {
        typealias B = PowerPointConverterTests
        let starts: [Int?] = [1,1,10,nil,10,3,3]
        let paragraphs = starts.enumerated().map { index, start in
            let attribute = start.map { " startAt=\"\($0)\"" } ?? ""
            return "<a:p><a:pPr><a:buAutoNum type=\"arabicPeriod\"\(attribute)/></a:pPr><a:r><a:t>Item \(index)</a:t></a:r></a:p>"
        }
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.shape(placeholder: nil, paragraphs: paragraphs))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "starts.pptx")
        #expect(result.markdown() == "1. Item 0\n2. Item 1\n10. Item 2\n11. Item 3\n12. Item 4\n3. Item 5\n4. Item 6")
    }

    @Test func relationshipPartsRequireTheirOwnRoot() throws {
        for source in ["<root/>", #"<root><Relationships><Relationship Id="x" Target="foo" Type="bar"/></Relationships></root>"#] {
            let data = PagesConverterTests.makeZip([(name: "ppt/slides/_rels/s.xml.rels", data: Array(source.utf8))])
            let package = PowerPointPackage(archive: try #require(Archive(data: data, accessMode: .read)))
            #expect(PowerPointConverter.relationships(package, forPart: "ppt/slides/s.xml").isEmpty)
            #expect(throws: PicoDocsError.fileCorrupted) { try package.check() }
        }
    }

    @Test func exactSlideRootAndPresentationDefaults() async throws {
        typealias B = PowerPointConverterTests
        let shape = B.shape(placeholder: nil, paragraphs: ["<a:p><a:r><a:t>Defaulted</a:t></a:r></a:p>"])
        let data = B.deck(slides: [.init(file: "s.xml", shapes: shape)])
        let archive = try #require(Archive(data: data, accessMode: .read))
        func changed(_ path: String, _ transform: (String) -> String) throws -> Data {
            var entries: [(name: String, data: [UInt8])] = []
            for entry in archive {
                var bytes = Data(); _ = try archive.extract(entry) { bytes.append($0) }
                entries.append((entry.path, entry.path == path ? Array(transform(String(decoding: bytes, as: UTF8.self)).utf8) : Array(bytes)))
            }
            return PagesConverterTests.makeZip(entries)
        }
        let corrupt = try changed("ppt/slides/s.xml") { $0.replacingOccurrences(of: "<p:sld ", with: "<root><p:sld ").replacingOccurrences(of: "</p:sld>", with: "</p:sld></root>") }
        await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: corrupt, filename: "bad.pptx") }
        let defaults = try changed("ppt/presentation.xml") { $0.replacingOccurrences(of: "</p:presentation>", with: #"<p:defaultTextStyle><a:lvl1pPr><a:buAutoNum type="arabicPeriod" startAt="4"/><a:defRPr b="1" i="1"/></a:lvl1pPr></p:defaultTextStyle></p:presentation>"#) }
        let result = try await PicoDocsEngine.convert(data: defaults, filename: "defaults.pptx")
        #expect(result.markdown() == "4. ***Defaulted***")
    }

    @Test func notesStyleSuppliesBulletsAndRunDefaults() throws {
        typealias B = PowerPointConverterTests
        let notes = "<p:notes \(B.namespaces)><p:cSld><p:spTree>" + B.shape(placeholder: #"<p:ph type="body"/>"#, paragraphs: ["<a:p><a:r><a:t>Note</a:t></a:r></a:p>"]) + "</p:spTree></p:cSld></p:notes>"
        let master = "<p:notesMaster \(B.namespaces)><p:cSld><p:spTree/></p:cSld>" + #"<p:notesStyle><a:lvl1pPr><a:buAutoNum type="arabicPeriod" startAt="3"/><a:defRPr b="1" i="1"/></a:lvl1pPr></p:notesStyle></p:notesMaster>"#
        let rels = B.relationshipsXML([("master", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesMaster", "../notesMasters/m.xml")])
        let entries = [(name: "ppt/notesSlides/n.xml", data: Array(notes.utf8)), (name: "ppt/notesSlides/_rels/n.xml.rels", data: Array(rels.utf8)), (name: "ppt/notesMasters/m.xml", data: Array(master.utf8))]
        let package = PowerPointPackage(archive: try #require(Archive(data: PagesConverterTests.makeZip(entries), accessMode: .read)))
        var cache = PowerPointConverter.PartCache(archive: package)
        let relations = ["notes": PowerPointConverter.Relationship(type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide", target: "../notesSlides/n.xml", external: false)]
        #expect(PowerPointConverter.notes(forSlide: "ppt/slides/s.xml", relationships: relations, archive: package, parts: &cache) == "3. ***Note***")
    }

    @Test func optionalListIndentDoesNotCreateChildren() throws {
        for source in ["- one\n - two", "10. one\n 11. two", "  - one\n- two"] {
            let result = ConverterResult(sections: [.init(markdown: source)])
            let html = try DocumentRenderer.render(result, to: .html)
            #expect(html.components(separatedBy: "<li").count - 1 == 2)
            #expect(html.components(separatedBy: source.hasPrefix("10.") ? "<ol" : "<ul").count - 1 == 1)
        }
        let nested = ConverterResult(sections: [.init(markdown: "10. Parent\n    - child\n 11. Sibling")])
        #expect(try DocumentRenderer.render(nested, to: .plaintext) == "10. Parent\n    - child\n11. Sibling")
    }

    @Test func referencedDocumentsMustHaveExpectedRootTypes() async throws {
        typealias B = PowerPointConverterTests
        for type in ["notesSlide", "slideLayout"] {
            for wrongXML in ["<root/>", "<root \(B.namespaces)><p:notes/></root>"] {
                let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Title"), relationships: [("part", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/" + type, "wrong.xml")])], extraParts: [("ppt/slides/wrong.xml", Array(wrongXML.utf8))])
                await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: data, filename: "wrong-root.pptx") }
            }
        }
    }

    @Test func iWorkAndWordTablesPreserveLiteralSourceSyntax() async throws {
        typealias B = PagesConverterTests
        func field(_ n: Int, _ value: UInt64) -> [UInt8] { B.tag(field: n, wire: 0) + B.varint(value) }
        func bytes(_ n: Int, _ value: [UInt8]) -> [UInt8] { B.tag(field: n, wire: 2) + B.varint(UInt64(value.count)) + value }
        let literal = #"<br> *stars* `code` [label](target) \path |"#
        let cell: [UInt8] = [5, 3] + Array(repeating: 0, count: 10) + [1,0,0,0]
        let tile = bytes(5, bytes(6, cell) + bytes(7, [0,0]))
        let strings = field(1, 1) + bytes(3, field(1, 1) + bytes(3, Array(literal.utf8)))
        let objects: [(UInt64, UInt64, [UInt8], [UInt64])] = [(20,6001,[],[21,22]), (21,6002,tile,[]), (22,6005,strings,[])]
        var stream: [UInt8] = []
        for (id,type,payload,references) in objects {
            var info = field(1,type) + field(3,UInt64(payload.count))
            for reference in references { info += field(5,reference) }
            let header = field(1,id) + bytes(2,info)
            stream += B.varint(UInt64(header.count)) + header + payload
        }
        let table = try #require(IWATable.markdownTables(from: [stream]).first)
        let iwork = ConverterResult(sections: [.init(kind: .table, markdown: table)])
        let document = #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:tbl><w:tr><w:tc><w:p><w:r><w:rPr><w:b/></w:rPr><w:t>&lt;br&gt; *stars* `code` [label](target) \path |</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>"#
        let word = try await PicoDocsEngine.convert(data: B.makeZip([(name: "word/document.xml", data: Array(document.utf8))]), filename: "literal.docx")
        for result in [iwork,word] {
            for format in [ExportFileType.plaintext,.csv] { #expect(try DocumentRenderer.render(result, to: format).contains(literal)) }
            let html = try DocumentRenderer.render(result, to: .html)
            #expect(html.contains("&lt;br&gt; *stars* `code` [label](target) \\path |"))
            #expect(!html.contains("<br>"))
        }
    }

    @Test func notesMasterUsesConversionWideDocumentCache() throws {
        typealias B = PowerPointConverterTests
        let notes = "<p:notes \(B.namespaces)><p:cSld><p:spTree>" + B.shape(placeholder: #"<p:ph type="body"/>"#, paragraphs: ["<a:p><a:r><a:t>Note</a:t></a:r></a:p>"]) + "</p:spTree></p:cSld></p:notes>"
        let master = "<p:notesMaster \(B.namespaces)><p:cSld><p:spTree/></p:cSld></p:notesMaster>"
        let rels = B.relationshipsXML([("master", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesMaster", "../notesMasters/m.xml")])
        let entries = [(name: "ppt/notesSlides/n.xml", data: Array(notes.utf8)), (name: "ppt/notesSlides/_rels/n.xml.rels", data: Array(rels.utf8)), (name: "ppt/notesMasters/m.xml", data: Array(master.utf8))]
        let package = PowerPointPackage(archive: try #require(Archive(data: PagesConverterTests.makeZip(entries), accessMode: .read)), totalLimit: entries.reduce(0) { $0 + $1.data.count })
        var cache = PowerPointConverter.PartCache(archive: package)
        let relations = ["notes": PowerPointConverter.Relationship(type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide", target: "../notesSlides/n.xml", external: false)]
        for _ in 0..<5 { #expect(PowerPointConverter.notes(forSlide: "ppt/slides/s.xml", relationships: relations, archive: package, parts: &cache) == "Note") }
        try package.check()
    }

    @Test func malformedXMLNeverNormalizesIntoValidContent() async throws {
        for source in ["<p:sld><p:cSld/></p:sld>", "<root><child></root>", "<root xmlns:p=\"x\"><p:item></root>"] {
            #expect(PowerPointXML.normalize(Data(source.utf8)) == nil)
        }
        typealias B = PowerPointConverterTests
        let malformed = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Title") + "<unknown:shape/>")])
        await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: malformed, filename: "bad.pptx") }
    }

    @Test func pictureAltAndSpreadsheetCellsKeepLiteralInlineSyntax() async throws {
        typealias B = PowerPointConverterTests
        let picture = #"<p:pic><p:nvPicPr><p:cNvPr descr="*draft* `code` [copy]"/></p:nvPicPr><p:blipFill><a:blip r:embed="image"/></p:blipFill></p:pic>"#
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Title") + picture, relationships: [("image", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", "../media/p.png")])], extraParts: [("ppt/media/p.png", [1,2,3])])
        let result = try await PicoDocsEngine.convert(data: data, filename: "image.pptx")
        #expect(try DocumentRenderer.render(result, to: .html).contains(#"alt="*draft* `code` [copy]""#))
        for format in [ExportFileType.plaintext, .csv] { #expect(try DocumentRenderer.render(result, to: format).contains("*draft* `code` [copy]")) }
        let worksheet = #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>*stars* `code` [label](target) \path | &lt;br&gt;</t></is></c></row></sheetData></worksheet>"#
        let workbook = try await PicoDocsEngine.convert(data: ConverterTests.xlsx(sheetXML: worksheet), filename: "literal.xlsx")
        for format in [ExportFileType.plaintext, .csv] {
            #expect(try DocumentRenderer.render(workbook, to: format).contains(#"*stars* `code` [label](target) \path | <br>"#))
        }
        #expect(try DocumentRenderer.render(workbook, to: .html).contains(#"*stars* `code` [label](target) \path | &lt;br&gt;"#))
    }

    @Test func sharedRelationshipCacheUsesDistinctPartBudget() throws {
        typealias B = PowerPointConverterTests
        let xml = B.relationshipsXML([("master", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster", "../slideMasters/m.xml")])
        let data = PagesConverterTests.makeZip([(name: "ppt/slideLayouts/_rels/shared.xml.rels", data: Array(xml.utf8))])
        let package = PowerPointPackage(archive: try #require(Archive(data: data, accessMode: .read)), totalLimit: xml.utf8.count)
        for _ in 0..<5 { #expect(PowerPointConverter.relationships(package, forPart: "ppt/slideLayouts/shared.xml")["master"]?.target == "../slideMasters/m.xml") }
        try package.check()
    }

    @Test func missingPictureRelationshipsAndNotesShapeLinks() async throws {
        typealias B = PowerPointConverterTests
        let picture = #"<p:pic><p:nvPicPr><p:cNvPr descr="Missing"/></p:nvPicPr><p:blipFill><a:blip r:embed="missing"/></p:blipFill></p:pic>"#
        let missing = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Title") + picture)])
        await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: missing, filename: "missing.pptx") }
        let shape = B.shape(placeholder: #"<p:ph type="body"/>"#, paragraphs: [#"<a:p><a:r><a:t>Linked note</a:t></a:r></a:p>"#])
            .replacingOccurrences(of: #"<p:cNvPr id="2" name="Shape"/>"#, with: #"<p:cNvPr id="2" name="Shape"><a:hlinkClick r:id="link"/></p:cNvPr>"#)
        let notes = "<p:notes \(B.namespaces)><p:cSld><p:spTree>" + shape + "</p:spTree></p:cSld></p:notes>"
        let rels = B.relationshipsXML([("link", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", "https://example.com/notes\" TargetMode=\"External")])
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Title"), relationships: [("notes", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide", "../notesSlides/n.xml")])], extraParts: [("ppt/notesSlides/n.xml", Array(notes.utf8)), ("ppt/notesSlides/_rels/n.xml.rels", Array(rels.utf8))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "notes.pptx")
        #expect(result.markdown().contains("[Linked note](https://example.com/notes)"))
    }

    @Test func tableLiteralPunctuationUnicodeWhitespaceAndBackticks() async throws {
        typealias B = PowerPointConverterTests
        let table = #"<p:graphicFrame><a:graphic><a:graphicData><a:tbl><a:tr><a:tc><a:txBody><a:p><a:r><a:t>*stars* `code` \path | &lt;br&gt;</a:t></a:r></a:p></a:txBody></a:tc></a:tr></a:tbl></a:graphicData></a:graphic></p:graphicFrame>"#
        let shape = B.shape(placeholder: nil, paragraphs: ["<a:p><a:r><a:t>Hello</a:t></a:r><a:r><a:rPr b=\"1\"/><a:t>\u{00A0}world\u{2003}\u{00A0}</a:t></a:r><a:r><a:t>end</a:t></a:r></a:p>"])
        let result = try await PicoDocsEngine.convert(data: B.deck(slides: [.init(file: "s.xml", shapes: shape + table)]), filename: "literal.pptx")
        #expect(result.markdown().contains("Hello\u{00A0}**world**\u{2003}\u{00A0}end"))
        for format in [ExportFileType.html, .plaintext, .csv] {
            let rendered = try DocumentRenderer.render(result, to: format)
            #expect(rendered.contains("*stars* `code` \\path | " + (format == .html ? "&lt;br&gt;" : "<br>")))
            #expect(!rendered.contains("<em>stars</em>")); #expect(!rendered.contains("<code>code</code>"))
        }
        let mixed = ConverterResult(sections: [.init(markdown: #"\`literal\` and `\*code` and \`[^n]\`"# + "\n\n[^n]: Note")])
        let html = try DocumentRenderer.render(mixed, to: .html)
        #expect(html.contains("`literal`")); #expect(html.contains(#"<code>\*code</code>"#))
        #expect(html.contains("footnote-ref")); #expect(html.contains("Note"))
    }

    @Test func defaultParagraphStyleAndExplicitLinkOverride() async throws {
        typealias B = PowerPointConverterTests
        let shape = B.shape(placeholder: nil, paragraphs: [
            #"<a:p><a:r><a:rPr><a:hlinkClick r:id="jump"/></a:rPr><a:t>Internal override</a:t></a:r></a:p>"#])
            .replacingOccurrences(of: "<a:bodyPr/>", with: #"<a:bodyPr/><a:lstStyle><a:defPPr><a:buChar char="•"/><a:defRPr b="1" i="1"/></a:defPPr></a:lstStyle>"#)
            .replacingOccurrences(of: #"<p:cNvPr id="2" name="Shape"/>"#, with: #"<p:cNvPr id="2" name="Shape"><a:hlinkClick r:id="outer"/></p:cNvPr>"#)
        let title = B.shape(placeholder: #"<p:ph type="title"/>"#, paragraphs: [#"<a:p><a:r><a:t>Plan</a:t></a:r><a:br/><a:r><a:t>Draft</a:t></a:r></a:p>"#])
        let data = B.deck(slides: [.init(file: "s.xml", shapes: title + shape, relationships: [
            ("outer", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", "https://example.com\" TargetMode=\"External"),
            ("jump", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide", "s.xml")])])
        let result = try await PicoDocsEngine.convert(data: data, filename: "defaults.pptx")
        #expect(result.sections.first?.title == "Plan Draft")
        #expect(result.markdown().contains("- ***Internal override***"))
        #expect(!result.markdown().contains("https://example.com"))
    }

    @Test func invalidRelationshipsNotesMastersAndCRC() async throws {
        typealias B = PowerPointConverterTests
        let malformed = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Title"))], extraParts: [("ppt/slides/_rels/s.xml.rels", Array("<bad".utf8))])
        await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: malformed, filename: "bad.pptx") }
        let notes = "<p:notes \(B.namespaces)><p:cSld><p:spTree>" + B.shape(placeholder: #"<p:ph type="body"/>"#, paragraphs: ["<a:p><a:r><a:t>Note</a:t></a:r></a:p>"]) + "</p:spTree></p:cSld></p:notes>"
        let notesRels = B.relationshipsXML([("master", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesMaster", "../notesMasters/missing.xml")])
        let missing = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Title"), relationships: [("notes", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide", "../notesSlides/n.xml")])], extraParts: [("ppt/notesSlides/n.xml", Array(notes.utf8)), ("ppt/notesSlides/_rels/n.xml.rels", Array(notesRels.utf8))])
        await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: missing, filename: "missing.pptx") }
        var corrupt = PagesConverterTests.makeZip([(name: "part", data: Array("UNIQUEPAYLOAD".utf8))])
        let range = try #require(corrupt.range(of: Data("UNIQUEPAYLOAD".utf8)))
        corrupt[range.lowerBound] = 0
        let package = PowerPointPackage(archive: try #require(Archive(data: corrupt, accessMode: .read)))
        #expect(package.read("part") == nil)
        #expect(throws: PicoDocsError.fileCorrupted) { try package.check() }
    }

    @Test func literalEscapeTokensAndTableBreakText() async throws {
        let literal = "\u{E006}0\u{E007}"
        let result = ConverterResult(sections: [.init(markdown: literal + " \\* `" + literal + "`")])
        for format in [ExportFileType.html, .plaintext] {
            let text = try DocumentRenderer.render(result, to: format)
            #expect(text.components(separatedBy: literal).count == 3)
        }
        let xml = #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:tbl><w:tr><w:tc><w:p><w:r><w:t>\&lt;br&gt;</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>"#
        let word = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(xml.utf8))]), filename: "literal.docx")
        #expect(try DocumentRenderer.render(word, to: .plaintext).contains(#"\<br>"#))
        #expect(try DocumentRenderer.render(word, to: .html).contains(#"\&lt;br&gt;"#))
        #expect(try DocumentRenderer.render(word, to: .csv).contains(#"\<br>"#))
    }

    @Test func declaredLayoutsAndInheritedRunDefaults() async throws {
        typealias B = PowerPointConverterTests
        let relation = ("layout", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout", "../slideLayouts/layout.xml")
        let shape = B.shape(placeholder: #"<p:ph type="body" idx="1"/>"#, paragraphs: [
            #"<a:p><a:r><a:t>Inherited</a:t></a:r></a:p>"#,
            #"<a:p><a:r><a:rPr b="0"/><a:t>Italic only</a:t></a:r></a:p>"#])
        let missing = B.deck(slides: [.init(file: "s.xml", shapes: shape, relationships: [relation])])
        await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: missing, filename: "bad.pptx") }
        let layoutShape = B.shape(placeholder: #"<p:ph type="body" idx="1"/>"#, paragraphs: [])
            .replacingOccurrences(of: "<a:bodyPr/>", with: #"<a:bodyPr/><a:lstStyle><a:lvl1pPr><a:buNone/><a:defRPr b="1"/></a:lvl1pPr></a:lstStyle>"#)
        let layout = "<p:sldLayout \(B.namespaces)><p:cSld><p:spTree>\(layoutShape)</p:spTree></p:cSld></p:sldLayout>"
        let master = "<p:sldMaster \(B.namespaces)><p:cSld><p:spTree/></p:cSld><p:txStyles><p:bodyStyle><a:lvl1pPr><a:defRPr i=\"1\"/></a:lvl1pPr></p:bodyStyle></p:txStyles></p:sldMaster>"
        let rels = B.relationshipsXML([("master", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster", "../slideMasters/master.xml")])
        let data = B.deck(slides: [.init(file: "s.xml", shapes: shape, relationships: [relation])], extraParts: [
            ("ppt/slideLayouts/layout.xml", Array(layout.utf8)), ("ppt/slideLayouts/_rels/layout.xml.rels", Array(rels.utf8)), ("ppt/slideMasters/master.xml", Array(master.utf8))])
        let markdown = try await PicoDocsEngine.convert(data: data, filename: "styled.pptx").markdown()
        #expect(markdown.contains("***Inherited***"))
        #expect(markdown.contains("*Italic only*"))
        #expect(!markdown.contains("**Italic only**"))
    }

    @Test func localizedNumbersHardBreaksAndPlainTitles() async throws {
        typealias B = PowerPointConverterTests
        let title = B.shape(placeholder: #"<p:ph type="title"/>"#, paragraphs: [#"<a:p><a:r><a:rPr b="1"/><a:t>Plan [Draft]</a:t></a:r></a:p>"#])
        let paragraphs = [#"<a:p><a:pPr><a:buChar char="•"/></a:pPr><a:r><a:t>First</a:t></a:r><a:br/><a:r><a:t>Second</a:t></a:r></a:p>"#]
            + ["circleNumWdBlackPlain", "thaiNumPeriod", "hindiAlphaPeriod", "ea1ChsPeriod"].map {
                "<a:p><a:pPr><a:buAutoNum type=\"\($0)\"/></a:pPr><a:r><a:t>Item</a:t></a:r></a:p>"
            }
        let result = try await PicoDocsEngine.convert(data: B.deck(slides: [.init(file: "s.xml", shapes: title + B.shape(placeholder: nil, paragraphs: paragraphs))]), filename: "local.pptx")
        #expect(result.sections.first?.title == "Plan [Draft]")
        #expect(result.markdown().contains("First  \n  Second"))
        #expect(try DocumentRenderer.render(result, to: .html).contains("First<br>Second"))
        #expect(try DocumentRenderer.render(result, to: .plaintext).contains("First\n  Second"))
        #expect(result.markdown().contains("❶ Item"))
        #expect(result.markdown().contains("๑. Item"))
        #expect(result.markdown().contains("अ. Item"))
        #expect(result.markdown().contains("ea1ChsPeriod"))
    }

    @Test func manifestIsCachedAndEscapedImageReferencesEmbed() throws {
        let manifest = #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="png" ContentType="image/png"/></Types>"#
        let data = PagesConverterTests.makeZip([(name: "[Content_Types].xml", data: Array(manifest.utf8))])
        let package = PowerPointPackage(archive: try #require(Archive(data: data, accessMode: .read)), totalLimit: manifest.utf8.count)
        for name in ["a.png", "b.png", "c.png"] { #expect(PowerPointConverter.contentType(name, archive: package) == "image/png") }
        try package.check()
        let result = ConverterResult(sections: [.init(markdown: "![Image](chart&notes.png)"), .init(kind: .image, markdown: "", sourcePath: "chart&notes.png", metadata: ["base64": "AQID", "mimeType": "image/png"])])
        #expect(try DocumentRenderer.render(result, to: .html).contains("data:image/png;base64,AQID"))
    }

    @Test func manifestMIMEAndAssembledMarkers() async throws {
        typealias B = PowerPointConverterTests
        let paragraphs = [["-", " item"], ["1", ". item"], ["  ", "# heading"], ["-", "--"]].map { runs in
            "<a:p>" + runs.map { "<a:r><a:t>\($0)</a:t></a:r>" }.joined() + "</a:p>"
        }
        let picture = #"<p:pic><p:nvPicPr><p:cNvPr descr="Image"/></p:nvPicPr><p:blipFill><a:blip r:embed="image"/></p:blipFill></p:pic>"#
        let manifest = #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="png" ContentType="image/png&quot; onerror=&quot;alert(1)"/></Types>"#
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.shape(placeholder: nil, paragraphs: paragraphs) + picture,
            relationships: [("image", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", "../media/p.png")])],
            extraParts: [("ppt/media/p.png", [1,2,3]), ("[Content_Types].xml", Array(manifest.utf8))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "deck.pptx")
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("data:image/png;base64,"))
        #expect(!html.contains("onerror="))
        for tag in ["<ul>", "<ol>", "<h1>", "<hr>"] { #expect(!html.contains(tag)) }
        #expect(html.contains("1. item"))
    }

    @Test func missingNotesAndAutomaticSchemes() async throws {
        typealias B = PowerPointConverterTests
        let broken = B.deck(slides: [.init(file: "s.xml", shapes: "", relationships: [
            ("notes", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide", "../notesSlides/missing.xml")])])
        await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: broken, filename: "broken.pptx") }
        let paragraphs = [("alphaLcParenR", 1), ("alphaUcPeriod", 2), ("romanUcPeriod", 4)].map { scheme, start in
            "<a:p><a:pPr><a:buAutoNum type=\"\(scheme)\" startAt=\"\(start)\"/></a:pPr><a:r><a:t>Item</a:t></a:r></a:p>"
        }
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.shape(placeholder: nil, paragraphs: paragraphs))])
        let result = try await PicoDocsEngine.convert(data: data, filename: "schemes.pptx")
        for format in [ExportFileType.markdown, .plaintext, .html] {
            let text = try DocumentRenderer.render(result, to: format)
            for label in ["a) Item", "B. Item", "IV. Item"] { #expect(text.contains(label)) }
        }
        #expect(PowerPointConverter.automaticNumber(27, scheme: "alphaLcParenBoth") == "(aa)")
    }

    @Test func literalWordTableBreakMarker() async throws {
        let xml = #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:tbl><w:tr><w:tc><w:p><w:r><w:t>&lt;br&gt;</w:t><w:br/><w:t>Next</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>"#
        let result = try await PicoDocsEngine.convert(data: PagesConverterTests.makeZip([(name: "word/document.xml", data: Array(xml.utf8))]), filename: "table.docx")
        for format in [ExportFileType.html, .plaintext, .csv] {
            let text = try DocumentRenderer.render(result, to: format)
            #expect(text.contains(format == .html ? "&lt;br&gt;" : "<br>"))
            #expect(text.contains("Next"))
        }
    }

    @Test func literalEscapesCodeFootnotesAndScaling() throws {
        for format in [ExportFileType.html, .plaintext] {
            let code = try DocumentRenderer.render(ConverterResult(sections: [DocumentSection(markdown: #"`\*`"#)]), to: format)
            #expect(code.contains(#"\*"#))
            let note = try DocumentRenderer.render(ConverterResult(sections: [DocumentSection(markdown: "\\[^n]\n\n[^n]: Hidden definition")]), to: format)
            #expect(note.contains("[^n]"))
            #expect(!note.contains("Hidden definition"))
            let escaped = String(repeating: #"\*"#, count: 10_000)
            let rendered = try DocumentRenderer.render(ConverterResult(sections: [DocumentSection(markdown: escaped)]), to: format)
            #expect(rendered.contains(String(repeating: "*", count: 10_000)))
            let table = try DocumentRenderer.render(ConverterResult(sections: [DocumentSection(markdown: #"| \<br> | first<br>second |"# + "\n| --- | --- |")]), to: format)
            #expect(table.contains(format == .html ? "&lt;br&gt;" : "<br>"))
            #expect(table.contains(format == .html ? "first<br>second" : "first\nsecond"))
        }
    }

    @Test func strictAndUnknownNamespaceNormalization() throws {
        let strict = #"<s:sld xmlns:s="http://purl.oclc.org/ooxml/presentationml/main" xmlns:t="http://purl.oclc.org/ooxml/drawingml/main" xmlns:x="urn:one" xmlns:y="urn:two" x:attr="one" y:attr="two"><t:p/></s:sld>"#
        let normalized = try #require(PowerPointXML.normalize(Data(strict.utf8)))
        #expect(normalized.contains("<p:sld"))
        #expect(normalized.contains("<a:p>"))
        #expect(normalized.contains("extension0:attr="))
        #expect(normalized.contains("extension1:attr="))
    }

    @Test func literalRulesShapeLinksAndPictures() async throws {
        typealias B = PowerPointConverterTests
        let rule = B.shape(placeholder: nil, paragraphs: ["<a:p><a:r><a:t>---</a:t></a:r></a:p>"])
        let linked = B.shape(placeholder: nil, paragraphs: ["<a:p><a:r><a:t>Shape link</a:t></a:r></a:p>"])
            .replacingOccurrences(of: #"<p:cNvPr id="2" name="Shape"/>"#, with: #"<p:cNvPr id="2" name="Shape"><a:hlinkClick r:id="link"/></p:cNvPr>"#)
        let picture = #"<p:pic><p:nvPicPr><p:cNvPr descr="Trailing\"/></p:nvPicPr><p:blipFill><a:blip r:embed="image"/></p:blipFill></p:pic>"#
        let relationships = [("link", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", "https://example.com\" TargetMode=\"External"), ("image", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", "../media/p.png")]
        let data = B.deck(slides: [.init(file: "s.xml", shapes: rule + linked + picture, relationships: relationships)], extraParts: [("ppt/media/p.png", [1, 2, 3])])
        let result = try await PicoDocsEngine.convert(data: data, filename: "deck.pptx")
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(!html.contains("<hr>"))
        #expect(html.contains("---"))
        #expect(html.contains(#"href="https://example.com""#))
        #expect(html.contains("<img"))
        let missing = B.deck(slides: [.init(file: "s.xml", shapes: picture, relationships: relationships)])
        await #expect(throws: PicoDocsError.fileCorrupted) { try await PicoDocsEngine.convert(data: missing, filename: "bad.pptx") }
    }

    @Test func nestedStartsSurviveRenderedExports() throws {
        let result = ConverterResult(sections: [DocumentSection(markdown: "5. Parent\n   - Child\n6. Next")])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains(#"<ol start="5">"#))
        #expect(html.contains("Parent\n<ul>"))
        #expect(try DocumentRenderer.render(result, to: .plaintext) == "5. Parent\n   - Child\n6. Next")
    }
}
