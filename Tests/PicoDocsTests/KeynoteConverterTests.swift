//
//  KeynoteConverterTests.swift
//  PicoDocsTests
//
//  Exercises the Keynote converter with synthetic `.key` packages built from the
//  shared IWA byte-builders in `PagesConverterTests` (Snappy + protobuf + a
//  hand-rolled stored ZIP) — no Keynote.app needed. A real `.key` fixture is a
//  planned follow-up to confirm slide-text kinds/ordering against actual files,
//  mirroring the Pages real-file pass.
//

import Foundation
import Testing
@testable import PicoDocs

struct KeynoteConverterTests {

    /// A synthetic `.key`: loose `Index/Slide<N>.iwa`, each a Snappy-framed IWA
    /// holding one body (kind-absent → 0) TSWP storage with `text`.
    static func makeKeynoteFile(slides: [String]) -> Data {
        var entries: [(name: String, data: [UInt8])] = []
        for (index, text) in slides.enumerated() {
            let iwa = PagesConverterTests.snappyFrame(PagesConverterTests.makeIWAStream(runs: [text]))
            entries.append((name: "Index/Slide\(index + 1).iwa", data: iwa))
        }
        return PagesConverterTests.makeZip(entries)
    }

    @Test("KeynoteConverter emits one section per slide, in slide-number order")
    func keynoteSlides() async throws {
        let key = Self.makeKeynoteFile(slides: ["First slide title", "Second slide body", "Third slide"])
        let result = try await PicoDocsEngine.convert(data: key, filename: "deck.key")
        #expect(result.sections.count == 3)
        #expect(result.sections.allSatisfy { $0.kind == .slide })
        #expect(result.sections.map(\.slideNumber) == [1, 2, 3])
        #expect(result.sections[0].markdown.contains("First slide title"))
        #expect(result.sections[2].markdown.contains("Third slide"))
        #expect(result.markdown().contains("Second slide body"))
    }

    @Test("MasterSlide components are excluded from slides")
    func keynoteExcludesMasters() async throws {
        // One real slide plus a master template; only the slide should surface.
        let slide = PagesConverterTests.snappyFrame(PagesConverterTests.makeIWAStream(runs: ["Real slide content"]))
        let master = PagesConverterTests.snappyFrame(PagesConverterTests.makeIWAStream(runs: ["Master placeholder"]))
        let key = PagesConverterTests.makeZip([
            (name: "Index/Slide1.iwa", data: slide),
            (name: "Index/MasterSlide-1.iwa", data: master),
        ])
        let result = try await PicoDocsEngine.convert(data: key, filename: "deck.key")
        #expect(result.sections.count == 1)
        #expect(result.markdown().contains("Real slide content"))
        #expect(!result.markdown().contains("Master placeholder"))
    }

    @Test("Detector routes a .key package to the Keynote format")
    func detectionRoutesToKeynote() {
        let key = Self.makeKeynoteFile(slides: ["Hi"])
        let info = PicoDocsEngine.makeStreamInfo(filename: "talk.key", mimeType: nil, url: nil, charset: nil)
        let resolved = ContentTypeDetector.classify(key, info: info)
        #expect(resolved.detectedFormat == .keynote)
    }

    @Test("Detector routes a Keynote MIME type without a .key extension")
    func detectionRoutesByMIME() {
        let key = Self.makeKeynoteFile(slides: ["Hi"])
        let info = PicoDocsEngine.makeStreamInfo(
            filename: "download", mimeType: "application/vnd.apple.keynote", url: nil, charset: nil
        )
        let resolved = ContentTypeDetector.classify(key, info: info)
        #expect(resolved.detectedFormat == .keynote)
    }

    @Test("A non-ZIP .key file (e.g. a PEM key) is not routed to Keynote")
    func plaintextKeyNotKeynote() {
        let pem = Data("-----BEGIN PRIVATE KEY-----\nMIIBVwIBADANBgkq\n-----END PRIVATE KEY-----\n".utf8)
        let info = PicoDocsEngine.makeStreamInfo(filename: "server.key", mimeType: nil, url: nil, charset: nil)
        let resolved = ContentTypeDetector.classify(pem, info: info)
        #expect(resolved.detectedFormat != .keynote)
        #expect(resolved.detectedFormat == .plainText)
    }

    @Test("A .key file carrying a synthesized Keynote MIME is still not routed to Keynote")
    func synthesizedKeynoteMIMEOnKeyExtensionNotKeynote() {
        // Mirrors PicoDocument+Fetch synthesizing the MIME from the .key UTType:
        // a PEM server.key arrives with `application/vnd.apple.keynote` but must
        // still be treated as text, not a (failing) Keynote.
        let pem = Data("-----BEGIN PRIVATE KEY-----\nMIIBVwIBADANBgkq\n-----END PRIVATE KEY-----\n".utf8)
        let info = PicoDocsEngine.makeStreamInfo(
            filename: "server.key", mimeType: "application/vnd.apple.keynote", url: nil, charset: nil
        )
        let resolved = ContentTypeDetector.classify(pem, info: info)
        #expect(resolved.detectedFormat != .keynote)
    }

    @Test("An explicit Keynote MIME with no .key extension routes to Keynote")
    func explicitKeynoteMIMEWithoutExtensionRoutesToKeynote() {
        // A truncated/extensionless web download with a real server Content-Type:
        // not a ZIP, no `.key` extension, so the MIME can't have been synthesized.
        let truncated = Data("PK-ish but truncated, not a real archive".utf8)
        let info = PicoDocsEngine.makeStreamInfo(
            filename: "download", mimeType: "application/vnd.apple.keynote", url: nil, charset: nil
        )
        let resolved = ContentTypeDetector.classify(truncated, info: info)
        #expect(resolved.detectedFormat == .keynote)
    }

    @Test("A corrupt slide stream fails rather than silently dropping the slide")
    func corruptSlideFails() async {
        // A valid ZIP entry whose bytes aren't a valid Snappy/IWA stream.
        let key = PagesConverterTests.makeZip([(name: "Index/Slide1.iwa", data: [0xFF, 0x00, 0x00, 0x00, 0x01])])
        let info = PicoDocsEngine.makeStreamInfo(filename: "deck.key", mimeType: nil, url: nil, charset: nil)
        await #expect(throws: Error.self) {
            _ = try await KeynoteConverter().convert(key, info: info)
        }
    }

    @Test("KeynoteConverter extracts deck-ordered slide text from a real .key, excluding presenter notes")
    func realKeynoteFixture() async throws {
        let data = try Fixture.data("sample", "key")
        let result = try await PicoDocsEngine.convert(data: data, filename: "sample.key")

        let slides = result.sections.filter { $0.kind == .slide }
        #expect(slides.count == 5)
        #expect(slides.map(\.slideNumber) == [1, 2, 3, 4, 5])

        // Deck order comes from Document.iwa's slide tree, NOT the filenames:
        // Slide.iwa ("The problem") is slide 2, not last. (Filename order would
        // put it last and swap slides 2/3.) The two table slides follow.
        #expect(slides[0].markdown.contains("The Spoon"))
        #expect(slides[0].markdown.contains("Ronald Mannak"))
        #expect(slides[1].markdown.contains("The problem"))
        #expect(slides[1].markdown.contains("Every mug has a spoon-shaped absence"))
        #expect(slides[2].markdown.contains("The data"))
        #expect(slides[3].markdown.contains("Table 1"))
        #expect(slides[4].markdown.contains("Table 2"))

        // Presenter notes are kind 4 → excluded by the kind==0 filter; they must
        // not leak into slide text.
        let markdown = result.markdown()
        #expect(!markdown.contains("Good morning. Thank you all"))
        #expect(!markdown.contains("barista pea"))

        // Object-replacement image placeholders are stripped.
        #expect(!markdown.unicodeScalars.contains("\u{FFFC}"))

        // Tables are reconstructed and placed with their slide — text via the
        // inline-text store, dates from the cell record, and decimal128
        // number/formula cells (the last row sums each column: 3+4+5=12,
        // 4.66+36.14+2.76=43.56).
        let tables = result.sections.filter { $0.kind == .table }
        #expect(tables.count == 2)
        #expect(tables.contains { $0.markdown.contains("| R1C1 | R1C2 | R1C3 | R1C4 |") })
        #expect(tables.contains { $0.markdown.contains("| Item 1 | 2026-06-18 | 3 | 4.66 |") })
        #expect(tables.contains { $0.markdown.contains("| Item 4 |  | 12 | 43.56 |") })

        // Each table is placed with the slide that owns it (slides 4 and 5),
        // carrying that slide's number — and interleaved, not appended at the end
        // (a slide section follows the first table section).
        #expect(tables.map(\.slideNumber) == [4, 5])
        let kinds = result.sections.map(\.kind)
        if let firstTable = kinds.firstIndex(of: .table) {
            #expect(kinds[(firstTable + 1)...].contains(.slide))
        }
    }
}
