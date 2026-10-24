import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

struct ArchiveCancellationReviewTests {
    @Test func entryConsumerDoesNotSwallowCancellation() async throws {
        let archive = try #require(Archive(data: PagesConverterTests.makeZip([("entry", Array(repeating: 65, count: 4096))]), accessMode: .read))
        let task = Task<Data?, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ZIPEntryReader.read(archive, path: "entry")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    @Test func cancelledArchiveConversionsRetainTheirErrorType() async throws {
        let archive = PagesConverterTests.makeZip([("Index/Document.iwa", [0]), ("Index/Slide-1.iwa", [0]), ("word/document.xml", [65])])
        let converters: [any DocumentConverter] = [WordConverter(), EPUBConverter(), PagesConverter(), KeynoteConverter()]
        for converter in converters {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await converter.convert(archive, info: StreamInfo())
            }
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        let frames = PagesConverterTests.snappyFrame([1, 2, 3])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try Snappy.decompressIWA(frames + frames)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

}
