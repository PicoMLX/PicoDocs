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

    @Test("IWAArchive captures the identifier regardless of ArchiveInfo field order")
    func iwaIdentifierOrderIndependent() {
        // Protobuf fields may be serialized in any order: an ArchiveInfo that
        // emits message_infos (field 2) BEFORE identifier (field 1) must still
        // attach the right id (it would be 0 if we trusted field order).
        let payload = Array("body".utf8)
        var storage: [UInt8] = []                         // TSWP.StorageArchive { text }
        storage += Self.tag(field: 3, wire: 2) + Self.varint(UInt64(payload.count)) + payload
        var messageInfo: [UInt8] = []                     // MessageInfo { type=2001; length }
        messageInfo += Self.tag(field: 1, wire: 0) + Self.varint(2001)
        messageInfo += Self.tag(field: 3, wire: 0) + Self.varint(UInt64(storage.count))
        var archiveInfo: [UInt8] = []                     // field 2 before field 1
        archiveInfo += Self.tag(field: 2, wire: 2) + Self.varint(UInt64(messageInfo.count)) + messageInfo
        archiveInfo += Self.tag(field: 1, wire: 0) + Self.varint(4242)
        var stream: [UInt8] = []
        stream += Self.varint(UInt64(archiveInfo.count)) + archiveInfo + storage

        #expect(IWAArchive.objects(in: stream).first?.identifier == 4242)
        #expect(IWAArchive.text(in: stream) == "body")
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

    @Test("PagesConverter extracts body text from a real Pages fixture, excluding header/footer")
    func realPagesFixture() async throws {
        let data = try Fixture.data("sample", "pages")
        let result = try await PicoDocsEngine.convert(data: data, filename: "sample.pages")
        let markdown = result.markdown()

        // Body storage (kind == 0) is extracted: heading, body paragraphs (incl.
        // inline code, full Unicode coverage), and the end-of-document marker.
        #expect(markdown.contains("Representative Import Fixture for Apple Pages"))
        #expect(markdown.contains("let importer = PagesImporter()"))
        #expect(markdown.contains("café, naïve"))
        #expect(markdown.contains("🚀"))
        #expect(markdown.contains("日本語"))
        #expect(markdown.contains("END_OF_PAGES_IMPORT_FIXTURE"))

        // Header/footer storages (kind == 1) are excluded from the body.
        #expect(!markdown.contains("generated source DOCX"))
        #expect(!markdown.contains("Fixture coverage: headings"))
        #expect(!markdown.contains("End of fixture"))

        // Control-character artifacts (e.g. the U+0004 section-break sentinel) are
        // stripped from the output.
        #expect(!markdown.unicodeScalars.contains("\u{0004}"))
    }

    @Test("PagesConverter reconstructs tables from a real Pages fixture")
    func realPagesTables() async throws {
        let data = try Fixture.data("sample", "pages")
        let result = try await PicoDocsEngine.convert(data: data, filename: "sample.pages")
        let tables = result.sections.filter { $0.kind == .table }

        // Three content tables (5×4, 4×6, and the dates/formula table); empty
        // placeholder tables are skipped.
        #expect(tables.count == 3)

        // Table 1: exact header row, plus a body row exercising empty cells.
        #expect(tables.contains { $0.markdown.contains("| Feature | Expected import | Sample value | Notes |") })
        #expect(tables.contains { $0.markdown.contains("| Empty cell |  |  | Importer should not crash |") })

        // Table 2: exact header row across all six columns.
        #expect(tables.contains {
            $0.markdown.contains("| Column A | Column B | Column C | Column D | Column E | Column F |")
        })

        // Table 3: inline-text header (the "Date" column), decoded date cells, and
        // decimal128 number/formula cells — the Total row sums each column
        // (12+8=20, 4.2+275.92=280.12), which validates the numeric decode.
        #expect(tables.contains { $0.markdown.contains("| Column A | Date | Column B | Column C | Column D |") })
        #expect(tables.contains { $0.markdown.contains("| Item 1 | 2026-06-18 | 12 | 0.35 | 4.2 |") })
        #expect(tables.contains { $0.markdown.contains("| Items 2 | 2026-06-15 | 8 | 34.49 | 275.92 |") })
        #expect(tables.contains { $0.markdown.contains("| Total |  | 20 |  | 280.12 |") })

        // GitHub-flavored separator row for the four-column table.
        #expect(tables.contains { $0.markdown.contains("| --- | --- | --- | --- |") })
    }

    @Test("PagesConverter places tables inline at their attachment points, in reading order")
    func realPagesTablesInline() async throws {
        let data = try Fixture.data("sample", "pages")
        let result = try await PicoDocsEngine.convert(data: data, filename: "sample.pages")
        let kinds = result.sections.map(\.kind)

        // Tables are interleaved with the body, not all appended at the end: a
        // body section follows the first table section.
        let firstTable = kinds.firstIndex(of: .table)
        #expect(firstTable != nil)
        if let firstTable {
            #expect(kinds[(firstTable + 1)...].contains(.body))
        }

        // Reading order in the rendered Markdown: intro text → Table 1 → Table 2
        // → end marker. (In the appended fallback the end marker would precede the
        // tables, so this also asserts the inline path is taken.)
        let markdown = result.markdown()
        let intro = markdown.range(of: "Representative Import Fixture for Apple Pages")
        let table1 = markdown.range(of: "| Feature | Expected import | Sample value | Notes |")
        let table2 = markdown.range(of: "| Column A | Column B | Column C | Column D | Column E | Column F |")
        let endMarker = markdown.range(of: "END_OF_PAGES_IMPORT_FIXTURE")
        #expect(intro != nil && table1 != nil && table2 != nil && endMarker != nil)
        if let intro, let table1, let table2, let endMarker {
            #expect(intro.lowerBound < table1.lowerBound)
            #expect(table1.lowerBound < table2.lowerBound)
            #expect(table2.lowerBound < endMarker.lowerBound)
        }
    }

    @Test("PagesConverter renders paragraph styles as Markdown headings")
    func realPagesHeadings() async throws {
        let data = try Fixture.data("sample", "pages")
        let result = try await PicoDocsEngine.convert(data: data, filename: "sample.pages")
        let markdown = result.markdown()

        // The Title paragraph style maps to `#`, the section "Heading" style to `##`
        // (a heading run is attributed to its paragraph even though the auto-number
        // sits in a neighbouring run, so "2. Lists" is a heading, not "2").
        #expect(markdown.contains("# Representative Import Fixture for Apple Pages"))
        #expect(markdown.contains("## 1. Body text and inline formatting"))
        #expect(markdown.contains("## 2. Lists"))
        // Section 5 is preceded by a U+0004 section-break sentinel (a Body-styled
        // run); the heading must still win the style vote once it's excluded.
        #expect(markdown.contains("## 5. Landscape section and wider table"))
        #expect(markdown.contains("## 6. Dates and formula"))

        // Body paragraphs are not headings.
        #expect(!markdown.contains("## This document is intentionally ordinary"))
        #expect(!markdown.contains("## Plain paragraph before list"))
    }

    @Test("PagesConverter renders character styles and hyperlinks as inline Markdown")
    func realPagesInlineStyling() async throws {
        let data = try Fixture.data("sample", "pages")
        let result = try await PicoDocsEngine.convert(data: data, filename: "sample.pages")
        let markdown = result.markdown()

        // Bold/italic character runs become Markdown emphasis (underline is dropped,
        // matching the other converters); markers hug the styled text.
        #expect(markdown.contains("**Purpose.**"))
        #expect(markdown.contains("**bold**"))
        #expect(markdown.contains("*italic*"))
        #expect(markdown.contains("underlined, and code-like"))   // underline left as plain text

        // Hyperlink smart fields become inline links.
        #expect(markdown.contains("[Apple Developer Documentation](https://developer.apple.com/documentation)"))

        // Headings carry no inline emphasis even though the title's runs are bold.
        #expect(!markdown.contains("**Representative Import Fixture"))

        // No stranded markup: control sentinels are skipped before emphasis/links
        // are applied, so nothing wraps a character normalize later deletes.
        #expect(!markdown.contains("****"))
        #expect(!markdown.contains("[]("))
    }

    @Test("PagesConverter renders bullet and numbered lists as Markdown")
    func realPagesLists() async throws {
        let data = try Fixture.data("sample", "pages")
        let result = try await PicoDocsEngine.convert(data: data, filename: "sample.pages")
        let markdown = result.markdown()

        // Bullet-list paragraphs (the "List Bullet" style) render with a `-` marker.
        #expect(markdown.contains("- First unordered item with a longer line that wraps naturally."))
        #expect(markdown.contains("- Second unordered item"))

        // Numbered-list paragraphs render with a running counter that starts at 1.
        #expect(markdown.contains("1. First ordered item"))
        #expect(markdown.contains("2. Second ordered item"))
        #expect(markdown.contains("3. Third ordered item"))

        // Consecutive items of one list are tight — no blank line between them.
        #expect(markdown.contains("1. First ordered item\n2. Second ordered item\n3. Third ordered item"))
    }

    @Test("PagesConverter honors explicit list restarts and start numbers")
    func listRestarts() async throws {
        // Four paragraphs in one ordered list style; paragraph data (field 6) marks
        // where a list (re)starts. Same style throughout, so only the restart value
        // can split the count.
        func render(_ restarts: [(offset: Int, restart: UInt64)]) async throws -> String {
            let pages = Self.makeListPagesFile(text: "a\nb\nc\nd", style: .ordered, restarts: restarts)
            return try await PicoDocsEngine.convert(data: pages, filename: "lists.pages").markdown()
        }
        // A second adjacent list restarted at 1 is its own list, not "3. c".
        let restarted = try await render([(0, 1), (2, 0), (4, 1), (6, 0)])
        #expect(restarted == "1. a\n2. b\n\n1. c\n2. d")
        // "Start at 5" keeps the author's numbering.
        let startAt = try await render([(0, 1), (2, 0), (4, 5), (6, 0)])
        #expect(startAt == "1. a\n2. b\n\n5. c\n6. d")
        // No paragraph data (older/other encoders): one running count.
        let plain = try await render([])
        #expect(plain == "1. a\n2. b\n3. c\n4. d")
    }

    @Test("PagesConverter keeps multi-line list items as one item")
    func multiLineListItems() async throws {
        // A soft line break (U+2028) inside an item — plus the author's own
        // indentation after it — must become the item's indented continuation, not
        // a separate paragraph.
        let bullets = Self.makeListPagesFile(text: "First line\u{2028}  second line\nNext item", style: .bullet, restarts: [])
        let bulletMarkdown = try await PicoDocsEngine.convert(data: bullets, filename: "lists.pages").markdown()
        #expect(bulletMarkdown == "- First line\n  second line\n- Next item")

        let ordered = Self.makeListPagesFile(text: "Alpha\u{2028}beta\u{2028}\u{2028}gamma\nDelta", style: .ordered, restarts: [])
        let orderedMarkdown = try await PicoDocsEngine.convert(data: ordered, filename: "lists.pages").markdown()
        #expect(orderedMarkdown == "1. Alpha\n   beta\n   gamma\n2. Delta")

        // The repo's own Markdown parser reads it back as two items, not item + paragraph.
        let result = try await PicoDocsEngine.convert(data: bullets, filename: "lists.pages")
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.components(separatedBy: "<li>").count == 3)
        #expect(!html.contains("<p>second line"))
    }

    @Test("PagesConverter keeps empty list items and their numbering")
    func emptyListItems() async throws {
        func render(_ text: String, _ style: ListKind) async throws -> ConverterResult {
            let pages = Self.makeListPagesFile(text: text, style: style, restarts: [])
            return try await PicoDocsEngine.convert(data: pages, filename: "lists.pages")
        }
        // An interior empty item keeps its marker, so the next item stays "3.".
        let ordered = try await render("a\n\nc", .ordered)
        #expect(ordered.markdown() == "1. a\n2.\n3. c")
        #expect(try await render("a\n\nc", .bullet).markdown() == "- a\n-\n- c")
        // Trailing empty items leave no dangling marker.
        #expect(try await render("a\nb\n\n", .ordered).markdown() == "1. a\n2. b")

        // The renderers read the empty item as part of the same list.
        let html = try DocumentRenderer.render(ordered, to: .html)
        #expect(html.contains("<ol>\n<li>a</li>\n<li></li>\n<li>c</li>\n</ol>"))
        #expect(try DocumentRenderer.render(ordered, to: .plaintext) == "1. a\n2.\n3. c")
    }

    @Test("PagesConverter escapes marker-like text inside list items")
    func listItemMarkerText() async throws {
        // A soft-break line (or item) that starts like a list marker is content,
        // not a nested list.
        let bullets = Self.makeListPagesFile(text: "Intro\u{2028}- not a sub-item\n- literal dash", style: .bullet, restarts: [])
        let bulletResult = try await PicoDocsEngine.convert(data: bullets, filename: "lists.pages")
        #expect(bulletResult.markdown() == "- Intro\n  \\- not a sub-item\n- \\- literal dash")

        let ordered = Self.makeListPagesFile(text: "Alpha\u{2028}2. inner\nBeta", style: .ordered, restarts: [])
        let orderedResult = try await PicoDocsEngine.convert(data: ordered, filename: "lists.pages")
        #expect(orderedResult.markdown() == "1. Alpha\n   2\\. inner\n2. Beta")

        // The renderers keep each item whole and drop the escape.
        let html = try DocumentRenderer.render(bulletResult, to: .html)
        #expect(html.components(separatedBy: "<li>").count == 3)
        #expect(try DocumentRenderer.render(bulletResult, to: .plaintext) == "- Intro - not a sub-item\n- - literal dash")
        #expect(try DocumentRenderer.render(orderedResult, to: .plaintext) == "1. Alpha 2. inner\n2. Beta")
    }

    @Test("PagesConverter clamps oversized list restarts instead of overflowing")
    func oversizedListRestart() async throws {
        let pages = Self.makeListPagesFile(text: "a\nb", style: .ordered,
                                           restarts: [(0, UInt64(Int.max)), (2, 0)])
        let markdown = try await PicoDocsEngine.convert(data: pages, filename: "lists.pages").markdown()
        #expect(markdown == "999999999. a\n1000000000. b")
    }

    @Test("PagesConverter keeps list numbering across an inline table")
    func listNumberingAcrossInlineTable() async throws {
        // The table sits at the end of item 2; item 3 continues the same list.
        let pages = Self.makeListPagesFile(text: "a\nb \u{FFFC}\nc", style: .ordered, restarts: [], tableCell: "X")
        let markdown = try await PicoDocsEngine.convert(data: pages, filename: "lists.pages").markdown()
        #expect(markdown == "1. a\n2. b\n\n| X |\n| --- |\n\n3. c")
    }

    @Test("Explicit list start numbers survive plaintext and HTML rendering")
    func listStartRendering() async throws {
        let pages = Self.makeListPagesFile(text: "a\nb\nc\nd", style: .ordered,
                                           restarts: [(0, 1), (2, 0), (4, 5), (6, 0)])
        let result = try await PicoDocsEngine.convert(data: pages, filename: "lists.pages")
        #expect(try DocumentRenderer.render(result, to: .plaintext) == "1. a\n2. b\n\n5. c\n6. d")
        let html = try DocumentRenderer.render(result, to: .html)
        #expect(html.contains("<ol>\n<li>a</li>"))
        #expect(html.contains("<ol start=\"5\">\n<li>c</li>\n<li>d</li>\n</ol>"))
    }

    @Test("Detector routes a .pages package to the Pages format")
    func detectionRoutesToPages() {
        let pages = Self.makePagesFile(paragraphs: ["Hi"])
        let info = PicoDocsEngine.makeStreamInfo(filename: "note.pages", mimeType: nil, url: nil, charset: nil)
        let resolved = ContentTypeDetector.classify(pages, info: info)
        #expect(resolved.detectedFormat == .pages)
    }

    @Test("Detector routes a Pages MIME type without a .pages extension")
    func detectionRoutesByMIME() {
        let pages = Self.makePagesFile(paragraphs: ["Hi"])
        let info = PicoDocsEngine.makeStreamInfo(
            filename: "download", mimeType: "application/vnd.apple.pages", url: nil, charset: nil
        )
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

    /// A decompressed IWA stream holding several objects, each written as
    /// `varint(ArchiveInfo length) · ArchiveInfo · payload`, with its
    /// cross-object references in MessageInfo field 5.
    static func makeIWAStream(objects: [(id: UInt64, type: UInt64, payload: [UInt8], references: [UInt64])]) -> [UInt8] {
        var stream: [UInt8] = []
        for object in objects {
            var messageInfo = varintField(1, object.type) + varintField(3, UInt64(object.payload.count))
            for reference in object.references { messageInfo += varintField(5, reference) }
            let archiveInfo = varintField(1, object.id) + lengthField(2, messageInfo)
            stream += varint(UInt64(archiveInfo.count)) + archiveInfo + object.payload
        }
        return stream
    }

    enum ListKind { case bullet, ordered }

    /// A `.pages` file whose body storage (`\n`-separated paragraphs in `text`) is
    /// entirely in one list style of `style`'s kind (ListStyle field 11 level 0:
    /// 2 = bullet, 3 = number), with paragraph-data runs (storage field 6) carrying
    /// each `(UTF-16 offset, restart)`.
    ///
    /// With `tableCell`, the first U+FFFC in `text` becomes an inline table
    /// attachment: a one-cell table (inline-string cell `tableCell`) reached from the
    /// attachment object through a table model → tile, as in real Pages files.
    static func makeListPagesFile(text: String, style: ListKind,
                                  restarts: [(offset: Int, restart: UInt64)],
                                  tableCell: String? = nil) -> Data {
        let listStyleID: UInt64 = 10
        let listStyle = varintField(11, style == .bullet ? 2 : 3)
        var storage = varintField(1, 0) + lengthField(3, Array(text.utf8))
        storage += lengthField(7, lengthField(1, varintField(1, 0) + lengthField(2, varintField(1, listStyleID))))
        if !restarts.isEmpty {
            var table: [UInt8] = []
            for run in restarts {
                table += lengthField(1, varintField(1, UInt64(run.offset)) + varintField(2, 0) + varintField(3, run.restart))
            }
            storage += lengthField(6, table)
        }
        var objects: [(id: UInt64, type: UInt64, payload: [UInt8], references: [UInt64])] = [
            (listStyleID, 2023, listStyle, []),
        ]
        if let tableCell, let marker = Array(text.utf16).firstIndex(of: 0xFFFC) {
            let (modelID, tileID, listID): (UInt64, UInt64, UInt64) = (20, 21, 22)
            // Attachment run (storage field 9): {1: charIndex, 2: Reference{1: id}}.
            storage += lengthField(9, lengthField(1, varintField(1, UInt64(marker)) + lengthField(2, varintField(1, modelID))))
            // Tile row: cell storage buffer (field 6) + 16-bit cell offsets (field 7).
            // Cell: version 5, type 3 (inline string), key 1 at byte 12.
            let cell: [UInt8] = [0x05, 0x03] + Array(repeating: 0, count: 10) + [1, 0, 0, 0]
            let tile = lengthField(5, lengthField(6, cell) + lengthField(7, [0x00, 0x00]))
            // Inline-string data list: list_type 1, entry {1: key, 3: text}.
            let strings = varintField(1, 1) + lengthField(3, varintField(1, 1) + lengthField(3, Array(tableCell.utf8)))
            objects += [(modelID, 6001, [], [tileID, listID]), (tileID, 6002, tile, []), (listID, 6005, strings, [])]
        }
        let stream = makeIWAStream(objects: [(1, 2001, storage, [])] + objects)
        return makeZip([(name: "Index/Document.iwa", data: snappyFrame(stream))])
    }

    static func varintField(_ field: Int, _ value: UInt64) -> [UInt8] { tag(field: field, wire: 0) + varint(value) }

    static func lengthField(_ field: Int, _ bytes: [UInt8]) -> [UInt8] {
        tag(field: field, wire: 2) + varint(UInt64(bytes.count)) + bytes
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
