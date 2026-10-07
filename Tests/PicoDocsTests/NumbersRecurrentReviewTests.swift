import Foundation
import Testing
import SwiftSoup
@testable import PicoDocs

struct NumbersRecurrentReviewTests {
    typealias B = PagesConverterTests

    @Test(arguments: [false, true])
    func nestedDocumentBasenameCannotReplaceWorkbook(_ nested: Bool) async throws {
        let document = B.lengthField(1, B.varintField(1, 10))
        let objects: [(id: UInt64, type: UInt64, payload: [UInt8], references: [UInt64])] = [
            (1, 1, document, [10]), (10, 2, B.lengthField(1, Array("Real".utf8)), [])
        ]
        let prefix = nested ? "" : "Index/"
        let entries: [(name: String, data: [UInt8])] = [
            (prefix + "Document.iwa", B.snappyFrame(B.makeIWAStream(objects: objects))),
            (prefix + "Backup/Document.iwa", B.snappyFrame(B.makeIWAStream(objects: [(90, 2001, B.lengthField(3, Array("Backup".utf8)), [])])))
        ]
        let data = nested ? B.makeZip([("Index.zip", Array(B.makeZip(entries)))]) : B.makeZip(entries)
        let result = try await NumbersConverter().convert(data, info: StreamInfo(detectedFormat: .numbers))
        #expect(result.sections.map(\.sheetName) == ["Real"])
    }

    @Test(arguments: ["  padded  ", "\tTabbed\t", " \tMixed\t "])
    func boundaryWhitespaceSurvivesNamedAndUnclaimedCells(_ value: String) async throws {
        let result = try await NumbersConverter().convert(NumbersReviewTests.workbook(orphan: true, cellValue: value), info: StreamInfo(detectedFormat: .numbers))
        let plain = try DocumentRenderer.render(result, to: .plaintext)
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(plain.components(separatedBy: value).count - 1 == 2)
        let htmlText = try SwiftSoup.parse(html).text(trimAndNormaliseWhitespace: false)
        #expect(htmlText.components(separatedBy: value).count - 1 == 2)
    }

    @Test func noDocumentFallbackGraphIsPreparedAndReused() async throws {
        let value = String(repeating: "x", count: 1024 * 1024)
        let stream = B.makeIWAStream(objects: [(1, 2001, B.lengthField(3, Array(value.utf8)), [])])
        let single = IWAObjectBudget(bytes: 1536 * 1024)
        let prepared = try IWATable.PreparedDocument(documentStream: nil, streams: [stream], objectBudget: single)
        #expect(IWAArchive.text(from: prepared.streamObjects[0]) == value)
        try single.check()
        _ = IWATable.markdownTables(from: [stream], objectBudget: single, prepared: prepared)
        try single.check()
        let data = B.makeZip([("Index/Body.iwa", B.snappyFrame(stream))])
        let result = try await PagesConverter(objectBudgetBytes: 1536 * 1024).convert(data, info: StreamInfo(detectedFormat: .pages))
        #expect(result.markdown() == value)
    }

    @Test func boundaryWhitespaceGrowthIsAdmittedBeforeConstruction() throws {
        let exact = IWAOutputBudget(bytes: 16)
        #expect(IWATable.cleanCell(" a ", preservingBoundaryWhitespace: true, budget: exact) == "&#32;a&#32;")
        #expect(exact.remainingBytes == 0)
        try exact.check()
        let over = IWAOutputBudget(bytes: 15)
        #expect(IWATable.cleanCell(" a ", preservingBoundaryWhitespace: true, budget: over).isEmpty)
        #expect(throws: PicoDocsError.self) { try over.check() }
    }
}
