import Foundation
import Testing
@testable import PicoDocs

struct NumbersDocumentSelectionReviewTests {
    typealias B = PagesConverterTests

    @Test(arguments: [false, true])
    func auxiliarySuffixDoesNotReplaceOrInvalidateAuthoritativeDocument(_ malformed: Bool) async throws {
        let document = B.lengthField(1, B.varintField(1, 10)) + B.lengthField(1, B.varintField(1, 11))
        let objects: [(id: UInt64, type: UInt64, payload: [UInt8], references: [UInt64])] = [
            (1, 1, document, [10, 11]),
            (11, 2, B.lengthField(1, Array("Second".utf8)), []),
            (10, 2, B.lengthField(1, Array("First".utf8)), [])
        ]
        let auxiliary = malformed ? [UInt8(255)] : B.snappyFrame(B.makeIWAStream(objects: [(90, 2001, B.lengthField(3, Array("Backup".utf8)), [])]))
        let data = B.makeZip([
            ("Index/Document.iwa", B.snappyFrame(B.makeIWAStream(objects: objects))),
            ("Index/BackupDocument.iwa", auxiliary)
        ])
        let result = try await NumbersConverter().convert(data, info: StreamInfo(detectedFormat: .numbers))
        #expect(result.sections.map(\.sheetName) == ["First", "Second"])
    }

    @Test func earlyTableOutputExhaustionPropagatesToSharedObjectBudget() throws {
        let stream = NumbersReviewTests.repeatedCellStream(rows: [1], value: "Cell")
        let objects = IWAObjectBudget()
        let output = IWAOutputBudget(bytes: 0)
        #expect(throws: PicoDocsError.fileCorrupted) {
            _ = try IWATable.PreparedDocument(documentStream: stream, streams: [stream], objectBudget: objects, outputBudget: output)
        }
        #expect(output.exceeded)
        #expect(throws: PicoDocsError.fileCorrupted) { try objects.check() }
    }
}
