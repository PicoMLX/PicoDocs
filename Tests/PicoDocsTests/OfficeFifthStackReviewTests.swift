import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

struct OfficeFifthStackReviewTests {
    @Test func emptyCSVMetadataFallsBackToVisibleMarkdown() throws {
        for kind in [SectionKind.body, .table, .sheet] {
            let result = ConverterResult(sections: [.init(kind: kind, markdown: "| A |\n| --- |\n| B |", metadata: ["csv": ""])])
            #expect(try DocumentRenderer.render(result, to: .csv) == "A\nB")
            let docx = try PicoDocsEngine.write(result, to: .docx)
            let xml = try OfficeStackReviewTests.xml(docx, "word/document.xml")
            #expect(xml.contains(">A</w:t>"))
            #expect(xml.contains(">B</w:t>"))
        }
    }
    @Test func nativeRTFNonbreakingEdgesRemainSemantic() async throws {
        let result = try await RTFConverter().convert(Data(#"{\rtf1\ansi\~Hello\~}"#.utf8), info: StreamInfo(detectedFormat: .rtf))
        #expect(result.markdown() == "\u{00A0}Hello\u{00A0}")
    }
    @Test func bodyHeadingsAndTheirJumpsSurviveTwoPPTXCycles() async throws {
        let source = "# Slide\n\n### Details\n\n[jump](#details)"
        let first = try await PicoDocsEngine.convert(data: PicoDocsEngine.write(markdown: source, to: .pptx), filename: "first.pptx")
        #expect(first.markdown().contains("### Details"))
        let second = try await PicoDocsEngine.convert(data: PicoDocsEngine.write(first, to: .pptx), filename: "second.pptx")
        #expect(second.markdown().contains("### Details"))
        #expect(second.markdown().contains("[jump](#details)"))
    }
    @Test func SVGImagesUseTheNativeOfficeExtension() async throws {
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10"><rect width="20" height="10" fill="red"/></svg>"#.utf8)
        let source = ConverterResult(sections: [.init(kind: .image, markdown: "", sourcePath: "vector.svg", metadata: ["base64": svg.base64EncodedString(), "mimeType": "image/svg+xml"])])
        let data = try PicoDocsEngine.write(source, to: .docx)
        let xml = try OfficeStackReviewTests.xml(data, "word/document.xml")
        #expect(xml.contains("asvg:svgBlip"))
        let imported = try await PicoDocsEngine.convert(data: data, filename: "vector.docx")
        let image = try #require(imported.sections.first { $0.kind == .image })
        #expect(image.metadata["mimeType"] == "image/svg+xml")
        #expect(image.metadata["base64"].flatMap { Data(base64Encoded: $0) } == svg)
        let second = try PicoDocsEngine.write(imported, to: .docx)
        #expect(try OfficeStackReviewTests.xml(second, "word/document.xml").contains("asvg:svgBlip"))
    }

    @Test func packagePartsIncludeNotesAndMatchTheEmittedArchive() throws {
        let result = ConverterResult(sections: [
            .init(kind: .slide, markdown: "## One\n\nBody\n\n**Notes:** Note", metadata: ["notes": "Note"]),
            .init(kind: .slide, markdown: "## Two\n\nBody")
        ])
        let data = try PicoDocsEngine.write(result, to: .pptx)
        let archive = try Archive(data: data, accessMode: .read)
        #expect(Array(archive).count == 16) // ten fixed, four slide parts, two notes parts
        try PPTXExporter.PackageBudget(maximumParts: 16).admitStructure(slides: 2, noteSlideIDs: [1])
        #expect(throws: ExporterError.self) { try PPTXExporter.PackageBudget(maximumParts: 15).admitStructure(slides: 2, noteSlideIDs: [1]) }
        try PPTXExporter.PackageBudget().admitStructure(slides: 8187, noteSlideIDs: [])
        #expect(throws: ExporterError.self) { try PPTXExporter.PackageBudget().admitStructure(slides: 8188, noteSlideIDs: []) }
        #expect(throws: ExporterError.self) { try PPTXExporter.PackageBudget(maximumParts: 16).admitStructure(slides: 2, noteSlideIDs: [3]) }
    }
    @Test func relationshipsShareOneCountAcrossSlidesAndNotes() throws {
        // The generated two-slide graph with one notes part owns 12 fixed relationships.
        let budget = PPTXExporter.PackageBudget(maximumRelationships: 14)
        try budget.admitStructure(slides: 2, noteSlideIDs: [1])
        var first = PPTXExporter.SlideRelationships(packageBudget: budget)
        var second = PPTXExporter.SlideRelationships(packageBudget: budget)
        var notes = PPTXExporter.SlideRelationships(packageBudget: budget)
        let id = try first.add(target: "https://example.com/one", jump: false)
        #expect(try first.add(target: "https://example.com/one", jump: false) == id)
        _ = try second.add(target: "https://example.com/two", jump: false)
        #expect(throws: ExporterError.self) { _ = try notes.add(target: "https://example.com/notes", jump: false) }
        #expect(throws: ExporterError.self) { try PPTXExporter.PackageBudget(maximumRelationships: 11).admitStructure(slides: 2, noteSlideIDs: [1]) }
    }
    @Test func relationshipsShareOneByteAllowanceBeforeFragmentConstruction() throws {
        let target = "https://example.com/one"
        let cost = "hyperlink1".utf8.count + "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink".utf8.count + target.utf8.count + 96
        let budget = PPTXExporter.PackageBudget(maximumBytes: cost * 2)
        var first = PPTXExporter.SlideRelationships(packageBudget: budget)
        var second = PPTXExporter.SlideRelationships(packageBudget: budget)
        _ = try first.add(target: target, jump: false)
        _ = try second.add(target: target, jump: false)
        #expect(throws: ExporterError.self) { _ = try second.add(target: target + "/more", jump: false) }
        let short = PPTXExporter.PackageBudget(maximumBytes: cost - 1)
        var denied = PPTXExporter.SlideRelationships(packageBudget: short)
        #expect(throws: ExporterError.self) { _ = try denied.add(target: target, jump: false) }
        #expect(denied.xml.isEmpty)
    }
    @Test func allBodyHeadingLevelsSurvivePPTXRoundTrips() async throws {
        let source = "# Slide\n\n" + (3...6).map { String(repeating: "#", count: $0) + " Level " + String($0) }.joined(separator: "\n\n")
        let imported = try await PicoDocsEngine.convert(data: PicoDocsEngine.write(markdown: source, to: .pptx), filename: "headings.pptx")
        for level in 3...6 { #expect(imported.markdown().contains(String(repeating: "#", count: level) + " Level " + String(level))) }
    }
}
