import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

struct NumbersExtractionReviewTests {
    @Test func emptyIWAEntriesStillHaveAnAdmissionLimit() throws {
        let entries = (0..<3).map { index in
            (name: "Index/" + String(index) + ".iwa", data: [UInt8]())
        }
        let archive = try Archive(data: PagesConverterTests.makeZip(entries), accessMode: .read)
        #expect(try PagesConverter.iwaComponents(in: archive, maximumArchiveEntries: 3, maximumComponents: 3).count == 3)
        #expect(throws: PicoDocsError.fileCorrupted) { _ = try PagesConverter.iwaComponents(in: archive, maximumArchiveEntries: 2) }
        #expect(throws: PicoDocsError.fileCorrupted) { _ = try PagesConverter.iwaComponents(in: archive, maximumComponents: 2) }
        let requiredBytes = entries.reduce(0) { $0 + 256 + $1.name.utf8.count }
        #expect(try PagesConverter.iwaComponents(in: archive, maximumMetadataBytes: requiredBytes).count == 3)
        #expect(throws: PicoDocsError.fileCorrupted) { _ = try PagesConverter.iwaComponents(in: archive, maximumMetadataBytes: requiredBytes - 1) }
    }

    @Test func nestedEntryAdmissionIncludesOuterContainerAndIgnoredEntries() throws {
        typealias B = PagesConverterTests
        let inner = B.makeZip([(name: "Document.iwa", data: [UInt8]()), (name: "Aux.iwa", data: [UInt8]())])
        let data = B.makeZip([(name: "Index.zip", data: Array(inner)), (name: "ignored", data: [UInt8]())])
        let archive = try Archive(data: data, accessMode: .read)
        #expect(try PagesConverter.iwaComponents(in: archive, maximumArchiveEntries: 4, maximumComponents: 2).count == 2)
        #expect(throws: PicoDocsError.fileCorrupted) { _ = try PagesConverter.iwaComponents(in: archive, maximumArchiveEntries: 3) }
        #expect(throws: PicoDocsError.fileCorrupted) { _ = try PagesConverter.iwaComponents(in: archive, maximumComponents: 1) }
        var exact = IWAComponentBudget(entries: 1, components: 1, bytes: 260)
        try exact.scan("name"); try exact.retainComponent("name")
        #expect(throws: PicoDocsError.fileCorrupted) { try exact.scan("") }
        var over = IWAComponentBudget(entries: 1, bytes: 259)
        #expect(throws: PicoDocsError.fileCorrupted) { try over.scan("name") }
    }
    @Test func literalTildesDoNotBecomeStrikethrough() async throws {
        let result = try await NumbersConverter().convert(NumbersReviewTests.workbook(name: "~~Draft~~", cellValue: "~~deleted~~"), info: StreamInfo(detectedFormat: .numbers))
        #expect(result.markdown().contains("\\~\\~Draft\\~\\~"))
        #expect(result.markdown().contains("\\~\\~deleted\\~\\~"))
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("~~deleted~~"), Comment(rawValue: html))
    }
}
