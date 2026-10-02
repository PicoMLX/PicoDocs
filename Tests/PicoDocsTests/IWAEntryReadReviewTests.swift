import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

struct IWAEntryReadReviewTests {
    @Test(arguments: [false, true])
    func canonicalDuplicateComponentsAreRejected(_ nested: Bool) throws {
        let path = nested ? "Document.iwa" : "Index/Document.iwa"
        let entries = [(path, [UInt8(1)]), (path, [UInt8(2)])]
        let data = nested ? PagesConverterTests.makeZip([("Index.zip", Array(PagesConverterTests.makeZip(entries)))]) : PagesConverterTests.makeZip(entries)
        let archive = try #require(Archive(data: data, accessMode: .read))
        #expect(throws: PicoDocsError.fileCorrupted) { _ = try PagesConverter.iwaComponents(in: archive) }
    }
    @Test(arguments: [false, true])
    func duplicateKeynoteSlidesAreRejected(_ nested: Bool) async throws {
        let path = nested ? "Slide1.iwa" : "Index/Slide1.iwa"
        let first = PagesConverterTests.snappyFrame(PagesConverterTests.makeIWAStream(runs: ["First"]))
        let second = PagesConverterTests.snappyFrame(PagesConverterTests.makeIWAStream(runs: ["Second"]))
        let entries = [(path, first), (path, second)]
        let data = nested ? PagesConverterTests.makeZip([("Index.zip", Array(PagesConverterTests.makeZip(entries)))]) : PagesConverterTests.makeZip(entries)
        await #expect(throws: PicoDocsError.fileCorrupted) {
            _ = try await KeynoteConverter().convert(data, info: StreamInfo(detectedFormat: .keynote))
        }
    }

    @Test func componentReadsUseTheIteratedPhysicalEntry() throws {
        let data = PagesConverterTests.makeZip([("Index/A.iwa", [1]), ("Index/A.iwa", [2])])
        let archive = try #require(Archive(data: data, accessMode: .read))
        #expect(throws: PicoDocsError.fileCorrupted) { _ = try PagesConverter.iwaComponents(in: archive) }
        var values: [Data] = []
        for entry in archive {
            let bytes = try ZIPEntryReader.read(archive, entry: entry, maxBytes: 1)
            values.append(try #require(bytes))
            #expect(try ZIPEntryReader.read(archive, entry: entry, maxBytes: 1)?.count == 1)
            #expect(try ZIPEntryReader.read(archive, entry: entry, maxBytes: 0) == nil)
        }
        #expect(values == [Data([1]), Data([2])])
    }
    @Test func manyTinyComponentsKeepByteAndCountAdmission() throws {
        let entries = (0..<256).map { index in (name: "Index/" + String(index) + ".iwa", data: [UInt8(truncatingIfNeeded: index)]) }
        let archive = try #require(Archive(data: PagesConverterTests.makeZip(entries), accessMode: .read))
        let components = try PagesConverter.iwaComponents(in: archive, maximumEntryBytes: 1, maximumTotalBytes: 256, maximumArchiveEntries: 256, maximumComponents: 256)
        #expect(components.map(\.bytes) == entries.map(\.data))
        #expect(throws: PicoDocsError.fileCorrupted) { _ = try PagesConverter.iwaComponents(in: archive, maximumTotalBytes: 255) }
        #expect(throws: PicoDocsError.fileCorrupted) { _ = try PagesConverter.iwaComponents(in: archive, maximumComponents: 255) }
    }
    @Test func directEntryReadKeepsCancellation() async throws {
        let data = PagesConverterTests.makeZip([("Index/A.iwa", [1])])
        let task = Task { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            let archive = try #require(Archive(data: data, accessMode: .read))
            let entry = try #require(archive.first { _ in true })
            _ = try ZIPEntryReader.read(archive, entry: entry)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
