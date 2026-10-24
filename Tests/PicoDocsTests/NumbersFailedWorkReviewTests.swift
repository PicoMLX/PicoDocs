import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

struct NumbersFailedWorkReviewTests {
    @Test func failedInflationStillConsumesTheComponentAllowance() throws {
        let content = Data(repeating: 65, count: 8192)
        let zip = try Archive(accessMode: .create)
        try zip.addEntry(with: "Index/Aux.iwa", type: .file, uncompressedSize: Int64(content.count), compressionMethod: .deflate) { position, count in
            content.subdata(in: Int(position)..<(Int(position) + count))
        }
        var bytes = Array(try #require(zip.data))
        let signature: [UInt8] = [0x50, 0x4b, 0x01, 0x02]
        let central = try #require(bytes.indices.first { $0 + 4 <= bytes.count && Array(bytes[$0..<($0 + 4)]) == signature })
        bytes.replaceSubrange((central + 24)..<(central + 28), with: [16, 0, 0, 0])
        let archive = try Archive(data: Data(bytes), accessMode: .read)
        var received = 0
        #expect(try ZIPEntryReader.read(archive, path: "Index/Aux.iwa", maxBytes: 16, onBytes: { received += $0 }) == nil)
        #expect(received == content.count)
        #expect(throws: PicoDocsError.fileCorrupted) {
            _ = try PagesConverter.iwaComponents(in: archive, maximumEntryBytes: 16, maximumTotalBytes: 128)
        }
    }
    @Test func failedFramesConsumeDecodedBytesBeforeBeingSkipped() async throws {
        typealias B = PagesConverterTests
        let valid = NumbersReviewTests.workbook(name: "Sheet", cellValue: "Value")
        let archive = try Archive(data: valid, accessMode: .read)
        let document = try #require(try ZIPEntryReader.read(archive, path: "Index/Document.iwa"))
        let documentSize = try Snappy.decompressIWA(Array(document)).count
        let failed = B.snappyFrame(Array(repeating: UInt8(65), count: 128)) + [0]
        var charged = 0
        #expect(throws: Snappy.SnappyError.malformed) {
            _ = try Snappy.decompressIWA(failed, onOutput: { charged += $0 })
        }
        #expect(charged == 128)
        let data = B.makeZip([(name: "Index/Document.iwa", data: Array(document)), (name: "Index/A.iwa", data: failed), (name: "Index/B.iwa", data: failed)])
        let exact = NumbersConverter(outputBudgetBytes: 1024 * 1024, decodedBudgetBytes: documentSize + 256)
        #expect(try await exact.convert(data, info: StreamInfo(detectedFormat: .numbers)).sections.count > 0)
        let under = NumbersConverter(outputBudgetBytes: 1024 * 1024, decodedBudgetBytes: documentSize + 255)
        await #expect(throws: PicoDocsError.fileCorrupted) { _ = try await under.convert(data, info: StreamInfo(detectedFormat: .numbers)) }
    }
}
