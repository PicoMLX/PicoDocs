import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

struct PowerPointSixthStackReviewTests {
    typealias B = PowerPointConverterTests
    typealias R = PowerPointThirdStackReviewTests
    typealias N = PowerPointFifthStackReviewTests

    @Test func permittedAttributeCountsStillBoundTheirBytesBeforeParsing() {
        let large = Data(("<root a='" + String(repeating: "x", count: 64 * 1024) + "'/>").utf8)
        let accepted = PowerPointXML.lexicalPreflight(large)
        #expect(accepted == false)
        let exact = "<root a='" + String(repeating: "x", count: 64 * 1024 - 1) + "'/>"
        #expect(PowerPointXML.lexicalPreflight(Data(exact.utf8)))
        let wide = "<root a='" + String(repeating: "x", count: 32 * 1024 - 1) + "'/>"
        #expect(PowerPointXML.lexicalPreflight(wide.data(using: .utf16)!))
        let oversized = wide.replacingOccurrences(of: "'/>", with: "x'/>")
        let wideAccepted = PowerPointXML.lexicalPreflight(oversized.data(using: .utf16)!)
        #expect(wideAccepted == false)
        let siblings = Data("<root><child a='xxx'/><child a='xxx'/></root>".utf8)
        #expect(PowerPointXML.lexicalPreflight(siblings, maximumAttributeBytes: 8))
        let cumulativeAccepted = PowerPointXML.lexicalPreflight(siblings, maximumAttributeBytes: 7)
        #expect(cumulativeAccepted == false)
    }

    @Test func compatibilityCopiesUseTheSharedWorkBudget() {
        let root = "<root xmlns:mc='http://schemas.openxmlformats.org/markup-compatibility/2006' xmlns:one='urn:one' xmlns:two='urn:two' mc:Ignorable='one'>"
        let changed = Data((root + "<child mc:Ignorable='two'/><child mc:Ignorable='two'/></root>").utf8)
        #expect(PowerPointXML.normalize(changed, budget: .init(namespaceWork: 6)) != nil)
        #expect(PowerPointXML.normalize(changed, budget: .init(namespaceWork: 5)) == nil)
        let redundant = Data((root + String(repeating: "<child mc:Ignorable='one'/>", count: 1000) + "</root>").utf8)
        #expect(PowerPointXML.normalize(redundant, budget: .init(namespaceWork: 2)) != nil)
        let processedRoot = root.replacingOccurrences(of: "mc:Ignorable='one'", with: "mc:ProcessContent='one:first'")
        let processed = Data((processedRoot + "<child mc:ProcessContent='two:second'/><child mc:ProcessContent='two:second'/></root>").utf8)
        #expect(PowerPointXML.normalize(processed, budget: .init(namespaceWork: 6)) != nil)
        #expect(PowerPointXML.normalize(processed, budget: .init(namespaceWork: 5)) == nil)
        let shared = PowerPointXML.Budget(namespaceWork: 11)
        #expect(PowerPointXML.normalize(changed, budget: shared) != nil)
        #expect(shared.namespaceWork == 5)
        #expect(PowerPointXML.normalize(changed, budget: shared) == nil)
    }

    @Test func HTMLTextEscapingPreflightsEveryEntityAndUnicodeScalar() throws {
        let text = "&<>\"'\u{1F642}"
        #expect(try DocumentRenderer.htmlEscapedByteCount(text, maximumBytes: 28) == 28)
        #expect(try DocumentRenderer.boundedEscapeHTML(text, maximumBytes: 28) == "&amp;&lt;&gt;&quot;&#39;\u{1F642}")
        #expect(throws: PicoDocsError.fileCorrupted) { _ = try DocumentRenderer.boundedEscapeHTML(text, maximumBytes: 27) }
        for scalar in ["'", "\""] {
            let text = String(repeating: scalar, count: 14_000_000)
            let result = ConverterResult(sections: [DocumentSection(markdown: text)])
            #expect(throws: PicoDocsError.fileCorrupted) { () throws -> Void in _ = try DocumentRenderer.render(result, to: .html) }
            let fenced = ConverterResult(sections: [DocumentSection(markdown: "```\n" + text + "\n```")])
            #expect(throws: PicoDocsError.fileCorrupted) { () throws -> Void in _ = try DocumentRenderer.render(fenced, to: .html) }
        }
    }

    @Test func apostropheMIMETokensHaveAnExactHTMLProjection() throws {
        let html = "<img src=\"i.png\">"
        let mime = "image/x'''\u{1F642}"
        let expected = "<img src=\"data:image/x&#39;&#39;&#39;\u{1F642};base64,AAAA\">"
        #expect(try DocumentRenderer.boundedImageReplacement(html, reference: "i.png", mime: mime, base64: "AAAA", maximumBytes: expected.utf8.count) == expected)
        #expect(throws: PicoDocsError.fileCorrupted) { _ = try DocumentRenderer.boundedImageReplacement(html, reference: "i.png", mime: mime, base64: "AAAA", maximumBytes: expected.utf8.count - 1) }
    }

    @Test func notesContentPlaceholderSpellingsKeepVisibleText() async throws {
        for placeholder in ["", "<p:ph/>", "<p:ph type='obj'/>", "<p:ph type='body'/>", "<p:ph type='title'/>"] {
            let data = N.deck(masterShapes: "", localShapes: N.text("Note content", placeholder: placeholder))
            let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
            #expect(result.sections.first?.metadata["notes"] == "Note content")
        }
        for type in ["dt", "ftr", "sldNum", "hdr", "sldImg"] {
            let data = N.deck(masterShapes: "", localShapes: N.text("Furniture", placeholder: "<p:ph type='" + type + "'/>") + N.text("Visible"))
            let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
            #expect(result.sections.first?.metadata["notes"] == "Visible")
        }
    }

    @Test func freeformTextUsesApplicableMasterStylesAndLocalOverrides() async throws {
        let text = N.text("Freeform")
        let style = "<a:lvl1pPr><a:buAutoNum type='arabicPeriod' startAt='3'/><a:defRPr b='1' i='1'/></a:lvl1pPr>"
        let layout = "<p:sldLayout " + B.namespaces + "><p:cSld><p:spTree/></p:cSld></p:sldLayout>"
        let master = "<p:sldMaster " + B.namespaces + "><p:cSld><p:spTree/></p:cSld><p:txStyles><p:otherStyle>" + style + "</p:otherStyle></p:txStyles></p:sldMaster>"
        let slide = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Slide") + text, relationships: [("layout", R.rel + "slideLayout", "../slideLayouts/l.xml")])], extraParts: [("ppt/slideLayouts/l.xml", Array(layout.utf8)), ("ppt/slideLayouts/_rels/l.xml.rels", Array(B.relationshipsXML([("master", R.rel + "slideMaster", "../slideMasters/m.xml")]).utf8)), ("ppt/slideMasters/m.xml", Array(master.utf8))])
        let result = try await PowerPointConverter().convert(slide, info: StreamInfo(detectedFormat: .pptx))
        #expect(result.markdown().contains("3. ***Freeform***"))
        let noteSeed = N.deck(masterShapes: N.text("Inherited freeform"), localShapes: text)
        let note = try R.replacing(noteSeed, part: "ppt/notesMasters/m.xml") { $0.replacingOccurrences(of: "</p:notesMaster>", with: "<p:notesStyle>" + style + "</p:notesStyle></p:notesMaster>") }
        let noteResult = try await PowerPointConverter().convert(note, info: StreamInfo(detectedFormat: .pptx))
        let notes = try #require(noteResult.sections.first?.metadata["notes"])
        #expect(notes.contains("3. ***Inherited freeform***"))
        #expect(notes.contains("3. ***Freeform***"))
        let overridden = try R.replacing(slide, part: "ppt/slides/s.xml") { $0.replacingOccurrences(of: "<a:p><a:r><a:t>Freeform", with: "<a:p><a:pPr><a:buNone/><a:defRPr b='0' i='0'/></a:pPr><a:r><a:t>Freeform") }
        let overriddenResult = try await PowerPointConverter().convert(overridden, info: StreamInfo(detectedFormat: .pptx))
        #expect(overriddenResult.markdown() == "## Slide\n\nFreeform")
        let textBox = try R.replacing(slide, part: "ppt/slides/s.xml") { $0.replacingOccurrences(of: "<p:cNvSpPr/>", with: "<p:cNvSpPr txBox='1'/>") }
        let textBoxMaster = try R.replacing(textBox, part: "ppt/slideMasters/m.xml") { $0.replacingOccurrences(of: "p:otherStyle", with: "p:bodyStyle") }
        let textBoxResult = try await PowerPointConverter().convert(textBoxMaster, info: StreamInfo(detectedFormat: .pptx))
        #expect(textBoxResult.markdown().contains("3. ***Freeform***"))
    }
}
