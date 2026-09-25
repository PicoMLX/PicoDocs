//
//  ZIPEntryReaderTests.swift
//  PicoDocsTests
//
//  Hostile central-directory sizes must fail a conversion cleanly — not trap on
//  the `Int` cast, allocate the claimed size, or spin reading past the archive.
//

import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

@Suite("ZIP entry reads")
struct ZIPEntryReaderTests {

    @Test("An overstated ZIP64 entry size fails DOCX conversion instead of crashing")
    func docxHostileSize() async throws {
        for declared in [UInt64(Int64.max), UInt64.max] {
            let zip = Self.zip(name: "word/document.xml", content: Array("<w:document/>".utf8), declaredSize: declared)
            await #expect(throws: (any Error).self) {
                try await PicoDocsEngine.convert(data: zip, filename: "hostile.docx")
            }
        }
    }

    @Test("An overstated ZIP64 entry size fails EPUB conversion instead of crashing")
    func epubHostileSize() async throws {
        let zip = Self.zip(name: "META-INF/container.xml", content: Array("<container/>".utf8), declaredSize: UInt64(Int64.max))
        await #expect(throws: (any Error).self) {
            try await PicoDocsEngine.convert(data: zip, filename: "hostile.epub")
        }
    }

    @Test("ZIPEntryReader reads honest entries and rejects overstated ones")
    func readerDirect() throws {
        let content = Array("hello".utf8)
        let honest = PagesConverterTests.makeZip([(name: "a.txt", data: content)])
        let honestArchive = try #require(Archive(data: honest, accessMode: .read))
        #expect(ZIPEntryReader.read(honestArchive, path: "/a.txt") == Data(content))
        #expect(ZIPEntryReader.read(honestArchive, path: "missing.txt") == nil)

        let hostile = Self.zip(name: "a.txt", content: content, declaredSize: UInt64(Int64.max))
        let hostileArchive = try #require(Archive(data: hostile, accessMode: .read))
        #expect(ZIPEntryReader.read(hostileArchive, path: "a.txt") == nil)
    }

    // MARK: - Builder

    /// A one-entry, stored (uncompressed) ZIP holding `content`, whose local and
    /// central headers put 0xFFFFFFFF in the 32-bit uncompressed-size field and
    /// claim `declaredSize` in a ZIP64 extended-information extra field.
    static func zip(name: String, content: [UInt8], declaredSize: UInt64) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }

        let nameBytes = Array(name.utf8)
        let extra = le16(0x0001) + le16(8) + le64(declaredSize)
        let crc = PagesConverterTests.crc32(content)

        var local: [UInt8] = le32(0x04034b50) + le16(45) + le16(0) + le16(0) + le16(0) + le16(0)
        local += le32(crc) + le32(UInt32(content.count)) + le32(0xFFFFFFFF)
        local += le16(nameBytes.count) + le16(extra.count) + nameBytes + extra + content

        var central: [UInt8] = le32(0x02014b50) + le16(45) + le16(45) + le16(0) + le16(0) + le16(0) + le16(0)
        central += le32(crc) + le32(UInt32(content.count)) + le32(0xFFFFFFFF)
        central += le16(nameBytes.count) + le16(extra.count) + le16(0) + le16(0) + le16(0) + le32(0) + le32(0)
        central += nameBytes + extra

        var eocd: [UInt8] = le32(0x06054b50) + le16(0) + le16(0) + le16(1) + le16(1)
        eocd += le32(UInt32(central.count)) + le32(UInt32(local.count)) + le16(0)
        return Data(local + central + eocd)
    }
}
