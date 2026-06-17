//
//  PagesConverterTests.swift
//  PicoDocsTests
//
//  Exercises the in-module iWork Pages reader end to end without needing a real
//  Pages.app file: the Snappy and protobuf-wire building blocks are tested with
//  hand-built byte vectors, and a synthetic `.pages` package (a hand-rolled,
//  stored ZIP containing one Snappy-framed `Index/Document.iwa`) drives the full
//  PagesConverter path.
//

import Foundation
import Testing
@testable import PicoDocs

struct PagesConverterTests {

    // MARK: - Snappy

    @Test("Snappy decompresses a literal-only block")
    func snappyLiteral() throws {
        // preamble length 5, literal tag ((5-1) << 2 = 0x10), then "Hello".
        let block: [UInt8] = [0x05, 0x10] + Array("Hello".utf8)
        #expect(try Snappy.decompressBlock(block) == Array("Hello".utf8))
    }

    @Test("Snappy expands an overlapping copy back-reference")
    func snappyOverlappingCopy() throws {
        // "ababab": literal "ab", then a 1-byte-offset copy (offset 2, length 4).
        let block: [UInt8] = [
            0x06,                                   // preamble: uncompressed length 6
            0x04, UInt8(ascii: "a"), UInt8(ascii: "b"),  // literal "ab"
            0x01, 0x02,                              // copy: length 4, offset 2
        ]
        #expect(try Snappy.decompressBlock(block) == Array("ababab".utf8))
    }

    @Test("Snappy round-trips an iWork frame")
    func snappyFrameRoundTrips() throws {
        let payload = Array("The quick brown fox".utf8)
        let framed = Self.snappyFrame(payload)
        #expect(try Snappy.decompressIWA(framed) == payload)
    }

    // MARK: - IWA stream

    @Test("IWAArchive joins text runs from a TSWP storage")
    func iwaTextExtraction() {
        let stream = Self.makeIWAStream(runs: ["Hello, ", "Pages!"])
        #expect(IWAArchive.text(in: stream) == "Hello, Pages!")
    }

    @Test("IWAArchive ignores non-text object types")
    func iwaIgnoresOtherTypes() {
        // A type-2001 storage plus a decoy object of another type carrying a
        // field-3 string that must NOT be extracted.
        let stream = Self.makeIWAStream(runs: ["real"]) + Self.makeIWAStream(runs: ["noise"], type: 6000)
        #expect(IWAArchive.text(in: stream) == "real")
    }

    // MARK: - End to end

    @Test("PagesConverter extracts body text from a synthetic .pages package")
    func pagesEndToEnd() async throws {
        let pages = Self.makePagesFile(paragraphs: ["First paragraph.", "Second paragraph."])
        let result = try await PicoDocsEngine.convert(data: pages, filename: "sample.pages")
        let markdown = result.markdown()
        #expect(markdown.contains("First paragraph."))
        #expect(markdown.contains("Second paragraph."))
    }

    @Test("Detector routes a .pages package to the Pages format")
    func detectionRoutesToPages() {
        let pages = Self.makePagesFile(paragraphs: ["Hi"])
        let info = PicoDocsEngine.makeStreamInfo(filename: "note.pages", mimeType: nil, url: nil, charset: nil)
        let resolved = ContentTypeDetector.classify(pages, info: info)
        #expect(resolved.detectedFormat == .pages)
    }

    @Test("PagesConverter reports unsupported for a non-iWork zip")
    func nonIWorkZipUnsupported() async {
        // A .pages-named zip with no IWA streams should fail cleanly, not crash.
        let zip = Self.makeZip([(name: "random.txt", data: Array("hi".utf8))])
        await #expect(throws: Error.self) {
            _ = try await PagesConverter().convert(
                zip, info: PicoDocsEngine.makeStreamInfo(
                    filename: "x.pages", mimeType: nil, url: nil, charset: nil
                )
            )
        }
    }

    // MARK: - Fixture builders

    /// A decompressed IWA object stream with a single storage (default type 2001)
    /// whose field-3 runs are `runs`.
    static func makeIWAStream(runs: [String], type: UInt64 = 2001) -> [UInt8] {
        var payload: [UInt8] = []
        for run in runs {
            payload += tag(field: 3, wire: 2)
            let bytes = Array(run.utf8)
            payload += varint(UInt64(bytes.count))
            payload += bytes
        }
        // MessageInfo { type = 1; length = 3 }
        var messageInfo: [UInt8] = []
        messageInfo += tag(field: 1, wire: 0); messageInfo += varint(type)
        messageInfo += tag(field: 3, wire: 0); messageInfo += varint(UInt64(payload.count))
        // ArchiveInfo { identifier = 1; message_infos = 2 }
        var archiveInfo: [UInt8] = []
        archiveInfo += tag(field: 1, wire: 0); archiveInfo += varint(1)
        archiveInfo += tag(field: 2, wire: 2); archiveInfo += varint(UInt64(messageInfo.count)); archiveInfo += messageInfo
        // Object = varint(archiveInfo length) · archiveInfo · payload
        var stream: [UInt8] = []
        stream += varint(UInt64(archiveInfo.count))
        stream += archiveInfo
        stream += payload
        return stream
    }

    /// Wraps a stream in a single Snappy literal block + one iWork frame header.
    static func snappyFrame(_ stream: [UInt8]) -> [UInt8] {
        var block = varint(UInt64(stream.count))   // preamble: uncompressed length
        block += literalElement(stream)
        var frame: [UInt8] = [0x00]                 // chunk type: compressed
        let len = block.count
        frame += [UInt8(len & 0xFF), UInt8((len >> 8) & 0xFF), UInt8((len >> 16) & 0xFF)]
        frame += block
        return frame
    }

    /// A minimal stored (uncompressed) `.pages` ZIP with one `Index/Document.iwa`.
    static func makePagesFile(paragraphs: [String]) -> Data {
        let text = paragraphs.joined(separator: "\n")
        let iwa = snappyFrame(makeIWAStream(runs: [text]))
        return makeZip([(name: "Index/Document.iwa", data: iwa)])
    }

    // MARK: protobuf wire encoders

    static func tag(field: Int, wire: Int) -> [UInt8] { varint(UInt64(field << 3 | wire)) }

    static func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    /// A Snappy literal element for `bytes` (handles the 60+ extended-length form).
    static func literalElement(_ bytes: [UInt8]) -> [UInt8] {
        guard !bytes.isEmpty else { return [] }
        let lenMinus1 = bytes.count - 1
        var out: [UInt8] = []
        if lenMinus1 < 60 {
            out.append(UInt8(lenMinus1 << 2))
        } else {
            var v = lenMinus1
            var lenBytes: [UInt8] = []
            while v > 0 { lenBytes.append(UInt8(v & 0xFF)); v >>= 8 }
            out.append(UInt8((59 + lenBytes.count) << 2))   // tag: (60 + (count-1)) << 2
            out += lenBytes
        }
        out += bytes
        return out
    }

    // MARK: minimal stored-ZIP writer

    /// Builds a stored (no compression) ZIP from `files`. Deterministic and
    /// version-independent, so fixtures don't depend on a ZIP-write API.
    static func makeZip(_ files: [(name: String, data: [UInt8])]) -> Data {
        var out = Data()
        var central = Data()
        var records: [(name: [UInt8], crc: UInt32, size: Int, offset: Int)] = []

        func put16(_ d: inout Data, _ v: Int) { d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)) }
        func put32(_ d: inout Data, _ v: UInt32) {
            d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF))
            d.append(UInt8((v >> 16) & 0xFF)); d.append(UInt8((v >> 24) & 0xFF))
        }

        for file in files {
            let name = Array(file.name.utf8)
            let crc = crc32(file.data)
            let offset = out.count
            put32(&out, 0x04034b50)                  // local file header signature
            put16(&out, 20); put16(&out, 0); put16(&out, 0)   // version, flags, method (stored)
            put16(&out, 0); put16(&out, 0)            // mod time, date
            put32(&out, crc)
            put32(&out, UInt32(file.data.count)); put32(&out, UInt32(file.data.count))
            put16(&out, name.count); put16(&out, 0)   // name length, extra length
            out.append(contentsOf: name)
            out.append(contentsOf: file.data)
            records.append((name, crc, file.data.count, offset))
        }

        let centralStart = out.count
        for r in records {
            put32(&central, 0x02014b50)               // central directory header signature
            put16(&central, 20); put16(&central, 20)  // version made by, needed
            put16(&central, 0); put16(&central, 0)    // flags, method
            put16(&central, 0); put16(&central, 0)    // mod time, date
            put32(&central, r.crc)
            put32(&central, UInt32(r.size)); put32(&central, UInt32(r.size))
            put16(&central, r.name.count)             // name length
            put16(&central, 0); put16(&central, 0)    // extra, comment length
            put16(&central, 0); put16(&central, 0)    // disk number start, internal attrs
            put32(&central, 0)                        // external attrs
            put32(&central, UInt32(r.offset))         // local header offset
            central.append(contentsOf: r.name)
        }
        out.append(central)

        var eocd = Data()
        put32(&eocd, 0x06054b50)                      // end of central directory signature
        put16(&eocd, 0); put16(&eocd, 0)              // disk numbers
        put16(&eocd, records.count); put16(&eocd, records.count)
        put32(&eocd, UInt32(central.count)); put32(&eocd, UInt32(centralStart))
        put16(&eocd, 0)                               // comment length
        out.append(eocd)
        return out
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : (crc >> 1)
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}
