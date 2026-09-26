//
//  NumbersConverterTests.swift
//  PicoDocsTests
//
//  Apple Numbers import, against the real `sample.numbers` workbook (ten sheets,
//  one table each) plus detection/routing.
//

import Foundation
import Testing
import UniformTypeIdentifiers
@testable import PicoDocs

@Suite("Numbers converter")
struct NumbersConverterTests {

    @Test("Converts each sheet, in tab order, to a titled Markdown table section")
    func realWorkbook() async throws {
        let result = try await PicoDocsEngine.convert(data: Fixture.data("sample", "numbers"), filename: "sample.numbers")
        #expect(result.title == "sample.numbers")
        #expect(result.sections.allSatisfy { $0.kind == .sheet })
        let names = [
            "README", "Lookups", "Data_Rows", "Formula_Summary", "Agent_QA",
            "Layout_EdgeCases", "Locale_Unicode", "Formula_Errors", "Dashboard", "Sources",
        ]
        #expect(result.sections.map(\.sheetName) == names)
        #expect(result.sections.map(\.title) == names)
        for section in result.sections {
            #expect(section.markdown.hasPrefix("## \(section.sheetName ?? "")\n\n| "))
        }

        let rows = try #require(result.sections.first { $0.sheetName == "Data_Rows" }).markdown
        #expect(rows.contains("| Task ID | Project | Owner | Status | Priority |"))
        #expect(rows.contains("| T-0001 | Pico AI Server | Ronald | Done | Critical | 2026-01-15 |"))
        #expect(rows.contains("| 000006 | Data QA |"))        // leading zeros survive
        #expect(rows.contains("| T-0005 | UX Polish | 李雷 |"))
        let sources = try #require(result.sections.last).markdown
        #expect(sources.contains("| SRC-001 | https://example.com/pico/server |"))
    }

    @Test("A .numbers file routes to Numbers by extension, UTType, or MIME")
    func detection() throws {
        let data = try Fixture.data("sample", "numbers")
        let byName = ContentTypeDetector.classify(
            data, info: PicoDocsEngine.makeStreamInfo(filename: "budget.numbers", mimeType: nil, url: nil, charset: nil)
        )
        #expect(byName.detectedFormat == .numbers)
        #expect(byName.confidence > 0.9)   // the IWA layout confirms the hint

        let byMIME = ContentTypeDetector.classify(
            data, info: PicoDocsEngine.makeStreamInfo(filename: "download", mimeType: "application/vnd.apple.numbers", url: nil, charset: nil)
        )
        #expect(byMIME.detectedFormat == .numbers)

        #expect(UTType.numbers.isSupported)
        #expect(UTType.numbersSingleFile.isSupported)
    }

    @Test("A .numbers that isn't an iWork package fails instead of converting as text")
    func notAnIWorkPackage() async {
        let zip = PagesConverterTests.makeZip([(name: "hello.txt", data: Array("hi".utf8))])
        await #expect(throws: PicoDocsError.documentTypeNotSupported) {
            try await PicoDocsEngine.convert(data: zip, filename: "fake.numbers")
        }
        await #expect(throws: (any Error).self) {
            try await PicoDocsEngine.convert(data: Data("not a zip".utf8), filename: "broken.numbers")
        }
    }
}
