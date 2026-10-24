import Foundation
import Testing
import SwiftSoup
import ZIPFoundation
@testable import PicoDocs

struct OfficeFifteenthStackReviewTests {
    @Test func ownedWhitespaceIsDecodedOnlyForMarkedXLSXMarkdown() throws {
        for marked in [false, true] {
            let metadata = marked ? ["preservedWhitespace": "1"] : [:]
            let section = DocumentSection(kind: .slide, markdown: "A&#32;B\n\n```\nX&#9;Y\n```", metadata: metadata)
            let data = try XLSXExporter().write(ConverterResult(sections: [section]), format: .xlsx)
            let xml = try OfficeStackReviewTests.xml(data, "xl/worksheets/sheet1.xml")
            #expect(xml.contains(marked ? "A B" : "A&amp;#32;B"))
            #expect(xml.contains(marked ? "X\tY" : "X&amp;#9;Y"))
        }
    }
    @Test func namedEmptySheetsKeepCSVNamesWithoutRawMetadata() throws {
        let result = ConverterResult(sections: [
            .init(kind: .sheet, markdown: "", sheetName: "Empty, One"),
            .init(kind: .sheet, markdown: " \t\n", sheetName: "Empty Two")
        ])
        #expect(try DocumentRenderer.render(result, to: .csv) == "\"Empty, One\"\nEmpty Two")
    }
    @Test func missingPayloadCarrierStillOwnsItsHTMLIdentity() throws {
        let result = ConverterResult(sections: [
            .init(markdown: "![missing](shared.png) ![real](real.png)"),
            .init(kind: .image, markdown: "", sourcePath: "shared.png", metadata: ["markdownReference": "real.png", "base64": "AQID", "mimeType": "image/png"]),
            .init(kind: .image, markdown: "", sourcePath: "missing.png", metadata: ["markdownReference": "shared.png"])
        ])
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("src=\"shared.png\""))
        #expect(html.components(separatedBy: "src=\"data:image/png;base64,AQID\"").count - 1 == 1)
    }
    @Test func malformedPreferredSVGDoesNotSuppressRasterFallback() throws {
        let shape = #"<root xmlns:asvg="http://schemas.microsoft.com/office/drawing/2016/SVG/main"><a:blip r:embed="raster"><a:ext uri="{96DAC541-7B7A-43D3-8B79-37D633B846F1}"><asvg:svgBlip r:embed="svg"/></a:ext></a:blip></root>"#
        let root = try SwiftSoup.parse(shape, "", SwiftSoup.Parser.xmlParser())
        let relationships = ["svg": "media/vector.svg", "raster": "media/fallback.png"]
        for payload in ["not SVG", "<png/>", #"<svg xmlns="http://www.w3.org/2000/svg"><g>"#] {
            let archive = try Archive(data: PagesConverterTests.makeZip([("word/media/vector.svg", Array(payload.utf8)), ("word/media/fallback.png", [1, 2, 3])]), accessMode: .read)
            let usable = try WordConverter.usableSVGRelationships(in: root, relationships: relationships, archive: archive, budget: WordConverter.MediaBudget())
            #expect(usable["svg"] == nil)
            #expect(usable["raster"] == relationships["raster"])
            #expect(WordConverter.imageMarkdown(in: root, relationships: usable).contains("word/media/fallback.png"))
            let carriers = try WordConverter.extractImages(from: root, relationships: usable, archive: archive)
            #expect(carriers.count == 1)
            #expect(carriers.first?.metadata["base64"] == "AQID")
        }
    }

    @Test func SVGProbeAcceptsNamespaceAliasesAndDebitsFailedXMLWork() throws {
        let shape = #"<root xmlns:asvg="http://schemas.microsoft.com/office/drawing/2016/SVG/main"><a:blip r:embed="raster"><a:ext uri="{96DAC541-7B7A-43D3-8B79-37D633B846F1}"><asvg:svgBlip r:embed="svg"/></a:ext></a:blip></root>"#
        let root = try SwiftSoup.parse(shape, "", SwiftSoup.Parser.xmlParser())
        let alias = #"<s:svg xmlns:s="http://www.w3.org/2000/svg"><s:rect width="1" height="1"/></s:svg>"#
        let malformed = #"<svg xmlns="http://www.w3.org/2000/svg"><g>"#
        let archive = try Archive(data: PagesConverterTests.makeZip([("word/media/valid.svg", Array(alias.utf8)), ("word/media/bad.svg", Array(malformed.utf8))]), accessMode: .read)
        let valid = ["svg": "media/valid.svg", "raster": "media/fallback.png"]
        #expect(try WordConverter.usableSVGRelationships(in: root, relationships: valid, archive: archive, budget: WordConverter.MediaBudget())["svg"] != nil)
        let shared = WordConverter.MediaBudget()
        shared.svgXMLBudget.nodes = 2
        let bad = ["svg": "media/bad.svg", "raster": "media/fallback.png"]
        #expect(try WordConverter.usableSVGRelationships(in: root, relationships: bad, archive: archive, budget: shared)["svg"] == nil)
        #expect(shared.svgXMLBudget.nodes == 0)
        #expect(try WordConverter.usableSVGRelationships(in: root, relationships: valid, archive: archive, budget: shared)["svg"] == nil)
    }
    #if canImport(AppKit) || canImport(UIKit)
    @Test func attributedRTFExportHonorsPreCancelledTasks() async throws {
        let result = ConverterResult(sections: [.init(markdown: "Content")])
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try AttributedStringRTFExporter().write(result, format: .rtf)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
    #endif
}
