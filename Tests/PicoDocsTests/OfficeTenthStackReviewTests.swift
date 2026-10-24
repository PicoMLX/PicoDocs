import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

struct OfficeTenthStackReviewTests {
    @Test func XLSXCoreMetadataSurvivesTwoRoundTrips() async throws {
        var result = ConverterResult(title: "Quarterly Report", author: "An Author", sections: [.init(title: "Data", kind: .sheet, markdown: "| A | B |\n| --- | --- |\n| One | Two |", sheetName: "Data")])
        for _ in 0..<2 {
            let bytes = try PicoDocsEngine.write(result, to: .xlsx)
            result = try await PicoDocsEngine.convert(data: bytes, filename: "fallback.xlsx")
            #expect(result.title == "Quarterly Report")
            #expect(result.author == "An Author")
            #expect(result.sections.first?.sheetName == "Data")
        }
    }
    @Test func XLSXMetadataUsesRelocatedRootRelationshipAndKeepsFallback() async throws {
        let source = ConverterResult(title: "Report", author: "Writer", sections: [.init(title: "Data", kind: .sheet, markdown: "| A |\n| --- |\n| One |", sheetName: "Data")])
        let exported = try PicoDocsEngine.write(source, to: .xlsx)
        let archive = try #require(Archive(data: exported, accessMode: .read))
        var entries: [(name: String, data: [UInt8])] = []
        for entry in archive {
            var bytes = Data()
            _ = try archive.extract(entry) { bytes.append($0) }
            var path = entry.path
            if path == "docProps/core.xml" { path = "metadata/props.xml" }
            if path == "_rels/.rels" {
                bytes = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "docProps/core.xml", with: "metadata/props.xml").utf8)
            }
            entries.append((path, Array(bytes)))
        }
        let imported = try await SpreadsheetConverter().convert(PagesConverterTests.makeZip(entries), info: StreamInfo(filename: "fallback.xlsx", detectedFormat: .xlsx))
        #expect(imported.title == "Report")
        #expect(imported.author == "Writer")
        let missing = entries.map { entry in
            entry.name == "metadata/props.xml" ? (name: entry.name, data: Array("<cp:coreProperties xmlns:cp='http://schemas.openxmlformats.org/package/2006/metadata/core-properties'/>".utf8)) : entry
        }
        let fallback = try await SpreadsheetConverter().convert(PagesConverterTests.makeZip(missing), info: StreamInfo(filename: "fallback.xlsx", detectedFormat: .xlsx))
        #expect(fallback.title == "Data")
        #expect(fallback.author == nil)
    }
}
