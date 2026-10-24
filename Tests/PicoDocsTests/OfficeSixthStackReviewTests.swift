import Foundation
import Testing
@testable import PicoDocs

struct OfficeSixthStackReviewTests {
    @Test func KeynoteUsesItsConventionalFileExtension() {
        #expect(ExportableFileType.keynote.fileExtension == "key")
        #expect(ExportableFileType.pptx.fileExtension == "pptx")
    }
    @Test func presenterNotesRetainNativeSlideJumps() async throws {
        let note = "[details](#details)"
        let result = ConverterResult(sections: [
            .init(title: "Intro", kind: .slide, markdown: "## Intro\n\nBody\n\n### Notes\n\n" + note, slideNumber: 1, metadata: ["notes": note]),
            .init(title: "Details", kind: .slide, markdown: "## Details\n\nMore", slideNumber: 2)
        ])
        let data = try PicoDocsEngine.write(result, to: .pptx)
        let relations = try OfficeStackReviewTests.xml(data, "ppt/notesSlides/_rels/notesSlide1.xml.rels")
        #expect(relations.contains("relationships/hyperlink\" Target=\"../slides/slide2.xml"))
        #expect(!relations.contains("TargetMode=\"External\""))
        let imported = try await PicoDocsEngine.convert(data: data, filename: "notes.pptx")
        #expect(imported.sections[0].metadata["notes"]?.contains("[details](#details)") == true)
        let repeated = try await PicoDocsEngine.convert(data: PicoDocsEngine.write(imported, to: .pptx), filename: "again.pptx")
        #expect(repeated.sections[0].metadata["notes"]?.contains("[details](#details)") == true)
    }
    @Test func writerRejectsTargetsBeyondTheReaderEnvelope() throws {
        let long = "https://example.com/" + String(repeating: "a", count: 32 * 1024)
        #expect(throws: ExporterError.self) { _ = try PicoDocsEngine.write(markdown: "# Slide\n\n[link](" + long + ")", to: .pptx) }
    }
    @Test func targetLengthAdmitsTheExactReaderLimit() throws {
        var relations = PPTXExporter.SlideRelationships()
        let target = "https://example.com/" + String(repeating: "a", count: 32 * 1024 - "https://example.com/".utf8.count)
        #expect(try relations.add(target: target, jump: false) == "hyperlink1")
        #expect(try relations.add(target: target, jump: false) == "hyperlink1")
        #expect(throws: ExporterError.self) { try relations.add(target: target + "a", jump: false) }
    }
    @Test func actualXMLNodesAndAttributesShareTheReaderAllowance() throws {
        let xml = "<root a='1'><child b='2'/></root>"
        let exact = PPTXExporter.PackageBudget(xmlBudget: .init(nodes: 4, attributes: 4))
        try exact.admitXML("ppt/slideMasters/m.xml", xml)
        try exact.admitXML("ppt/slides/s.xml", xml)
        #expect(throws: ExporterError.self) { try exact.admitXML("ppt/notesSlides/n.xml", "<root/>") }
        let attributes = PPTXExporter.PackageBudget(xmlBudget: .init(nodes: 20, attributes: 3))
        try attributes.admitXML("ppt/theme/t.xml", xml)
        #expect(throws: ExporterError.self) { try attributes.admitXML("ppt/slides/s.xml", xml) }
        // Independent package parses must not debit the cached slide graph.
        let separate = PPTXExporter.PackageBudget(xmlBudget: .init(nodes: 2, attributes: 2))
        try separate.admitXML("ppt/_rels/presentation.xml.rels", xml)
        try separate.admitXML("ppt/presentation.xml", xml)
        try separate.admitXML("ppt/slides/s.xml", xml)
    }
    @Test func repeatedGeneratedSlideXMLCannotExceedTheReaderNodeLimit() throws {
        let budget = PPTXExporter.PackageBudget()
        let xml = "<p:sld xmlns:p='http://schemas.openxmlformats.org/presentationml/2006/main'>" + String(repeating: "<p:cSld/>", count: 45) + "</p:sld>"
        for number in 0..<5_434 { try budget.admitXML("ppt/slides/slide\(number).xml", xml) }
        // 5,434 * 46 = 249,964; the next part exceeds 250,000.
        #expect(throws: ExporterError.self) { try budget.admitXML("ppt/slides/next.xml", xml) }
    }

}
