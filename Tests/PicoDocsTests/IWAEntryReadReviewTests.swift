import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

struct IWAEntryReadReviewTests {
    @Test func componentReadsUseTheIteratedPhysicalEntry() throws {
        let data = PagesConverterTests.makeZip([("Index/A.iwa", [1]), ("Index/A.iwa", [2])])
        let archive = try #require(Archive(data: data, accessMode: .read))
        let components = try PagesConverter.iwaComponents(in: archive)
        #expect(components.map(\.bytes) == [[1], [2]])
        for entry in archive {
            #expect(try ZIPEntryReader.read(archive, entry: entry, maxBytes: 1)?.count == 1)
            #expect(try ZIPEntryReader.read(archive, entry: entry, maxBytes: 0) == nil)
        }
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
