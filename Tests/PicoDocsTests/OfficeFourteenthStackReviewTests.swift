import Foundation
import Testing
import SwiftSoup
import ZIPFoundation
@testable import PicoDocs

struct OfficeFourteenthStackReviewTests {
    @Test func directDOCXExportHonorsCancellation() async throws {
        let result = ConverterResult(sections: [.init(markdown: "Content")])
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try WordprocessingMLExporter().write(result, format: .docx)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
    @Test func directXLSXRejectsAbsentSectionsButKeepsExplicitEmptySheets() throws {
        #expect(throws: PicoDocsError.emptyDocument) { _ = try XLSXExporter().write(ConverterResult(sections: []), format: .xlsx) }
        let result = ConverterResult(sections: [.init(kind: .sheet, markdown: "", sheetName: "Empty")])
        #expect(try XLSXExporter().write(result, format: .xlsx).count > 0)
    }
    @Test func PPTXCorePropertiesStayWithinTheReaderCeiling() throws {
        let result = ConverterResult(title: String(repeating: "&", count: 210_000), sections: [.init(markdown: "# Slide\n\nContent")])
        #expect(throws: ExporterError.self) { _ = try PPTXExporter().write(result, format: .pptx) }
    }
    @Test func unreadablePreferredSVGUsesItsExistingRasterFallback() async throws {
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10"/>"#.utf8)
        let raster = Data([1, 2, 3])
        let source = ConverterResult(sections: [
            .init(markdown: "![SVG](vector.svg) ![Raster](fallback.png)"),
            .init(kind: .image, markdown: "", sourcePath: "vector.svg", metadata: ["base64": svg.base64EncodedString(), "mimeType": "image/svg+xml"]),
            .init(kind: .image, markdown: "", sourcePath: "fallback.png", metadata: ["base64": raster.base64EncodedString(), "mimeType": "image/png"])
        ])
        let data = try WordprocessingMLExporter().write(source, format: .docx)
        let xml = try OfficeStackReviewTests.xml(data, "word/document.xml")
        let doc = try SwiftSoup.parse(xml, "", SwiftSoup.Parser.xmlParser())
        let blips = try doc.getElementsByTag("a:blip").array()
        let rasterID = try #require(blips.last).attr("r:embed")
        let paired = try PowerPointThirdStackReviewTests.replacing(data, part: "word/document.xml") {
            $0.replacingOccurrences(of: "<a:blip>", with: "<a:blip r:embed=\"" + rasterID + "\">")
        }
        for missingRelationship in [true, false] {
            let broken: Data
            if missingRelationship {
                broken = try PowerPointThirdStackReviewTests.replacing(paired, part: "word/document.xml") {
                    $0.replacingOccurrences(of: "r:embed=\"rId1\"/>", with: "r:embed=\"missingSVG\"/>")
                }
            } else {
                let input = try Archive(data: paired, accessMode: .read)
                let output = try Archive(data: Data(), accessMode: .create)
                for entry in input where !entry.path.hasSuffix(".svg") {
                    var bytes = Data()
                    _ = try input.extract(entry) { bytes.append($0) }
                    try output.addEntry(with: entry.path, type: .file, uncompressedSize: Int64(bytes.count), provider: { position, size in
                        bytes.subdata(in: Int(position)..<min(bytes.count, Int(position) + size))
                    })
                }
                broken = try #require(output.data)
            }
            let imported = try await WordConverter().convert(broken, info: StreamInfo(detectedFormat: .docx))
            #expect(imported.markdown().contains("![SVG](word/media/fallback.png)"))
            #expect(imported.sections.contains { $0.kind == .image && $0.metadata["base64"] == raster.base64EncodedString() })
        }
    }

    @Test func corePropertiesAdmissionCountsSerializedBytesExactly() throws {
        let result = ConverterResult(title: "&<é\u{0000}", author: "A>", sections: [.init(markdown: "Body")])
        let xml = try OOXMLPackageWriter.corePropertiesXML(result, maximumBytes: 4096)
        #expect(xml.contains("<dc:title>&amp;&lt;é</dc:title>"))
        #expect(xml.contains("<dc:creator>A&gt;</dc:creator>"))
        #expect(try OOXMLPackageWriter.corePropertiesXML(result, maximumBytes: xml.utf8.count) == xml)
        #expect(throws: ExporterError.self) { _ = try OOXMLPackageWriter.corePropertiesXML(result, maximumBytes: xml.utf8.count - 1) }
        let empty = try OOXMLPackageWriter.corePropertiesXML(ConverterResult(sections: []), maximumBytes: 4096)
        #expect(try OOXMLPackageWriter.corePropertiesXML(ConverterResult(sections: []), maximumBytes: empty.utf8.count) == empty)
        #expect(throws: ExporterError.self) { _ = try OOXMLPackageWriter.corePropertiesXML(ConverterResult(sections: []), maximumBytes: empty.utf8.count - 1) }
    }

    @Test func SVGProbeBudgetIsSharedAndDecisionsAreCached() throws {
        let shape = #"<root xmlns:asvg="http://schemas.microsoft.com/office/drawing/2016/SVG/main"><a:blip r:embed="raster"><a:ext uri="{96DAC541-7B7A-43D3-8B79-37D633B846F1}"><asvg:svgBlip r:embed="svg"/></a:ext></a:blip></root>"#
        let root = try SwiftSoup.parse(shape, "", SwiftSoup.Parser.xmlParser())
        let archive = try Archive(data: PagesConverterTests.makeZip([("word/media/vector.svg", [1, 2, 3, 4])]), accessMode: .read)
        let relationships = ["svg": "media/vector.svg", "raster": "media/fallback.png"]
        let exact = WordConverter.MediaBudget(maxBytes: 4, maxImages: 1)
        #expect(try WordConverter.usableSVGRelationships(in: root, relationships: relationships, archive: archive, budget: exact)["svg"] != nil)
        #expect(exact.remainingProbeBytes == 0)
        #expect(exact.remainingProbes == 0)
        #expect(try WordConverter.usableSVGRelationships(in: root, relationships: relationships, archive: archive, budget: exact)["svg"] != nil)
        let tooSmall = WordConverter.MediaBudget(maxBytes: 3, maxImages: 1)
        let fallback = try WordConverter.usableSVGRelationships(in: root, relationships: relationships, archive: archive, budget: tooSmall)
        #expect(fallback["svg"] == nil)
        #expect(fallback["raster"] == relationships["raster"])
    }

    @Test func failedSVGCRCProbeStillDebitsActualBytes() throws {
        let shape = #"<root xmlns:asvg="http://schemas.microsoft.com/office/drawing/2016/SVG/main"><a:blip r:embed="raster"><a:ext uri="{96DAC541-7B7A-43D3-8B79-37D633B846F1}"><asvg:svgBlip r:embed="svg"/></a:ext></a:blip></root>"#
        let root = try SwiftSoup.parse(shape, "", SwiftSoup.Parser.xmlParser())
        var zip = PagesConverterTests.makeZip([("word/media/vector.svg", [1, 2, 3, 4])])
        for (signature, offset) in [(Data([0x50, 0x4b, 0x03, 0x04]), 14), (Data([0x50, 0x4b, 0x01, 0x02]), 16)] {
            let range = try #require(zip.range(of: signature))
            zip[range.lowerBound + offset] ^= 1
        }
        let archive = try Archive(data: zip, accessMode: .read)
        let relationships = ["svg": "media/vector.svg", "raster": "media/fallback.png"]
        let budget = WordConverter.MediaBudget(maxBytes: 4, maxImages: 1)
        let fallback = try WordConverter.usableSVGRelationships(in: root, relationships: relationships, archive: archive, budget: budget)
        #expect(fallback["svg"] == nil)
        #expect(fallback["raster"] != nil)
        #expect(budget.remainingProbeBytes == 0)
        #expect(try WordConverter.usableSVGRelationships(in: root, relationships: relationships, archive: archive, budget: budget)["svg"] == nil)
        #expect(budget.remainingProbeBytes == 0)
    }

}
