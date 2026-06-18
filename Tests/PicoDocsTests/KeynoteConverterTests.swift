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

    @Test("A corrupt slide stream fails rather than silently dropping the slide")
    func corruptSlideFails() async {
        // A valid ZIP entry whose bytes aren't a valid Snappy/IWA stream.
        let key = PagesConverterTests.makeZip([(name: "Index/Slide1.iwa", data: [0xFF, 0x00, 0x00, 0x00, 0x01])])
        let info = PicoDocsEngine.makeStreamInfo(filename: "deck.key", mimeType: nil, url: nil, charset: nil)
        await #expect(throws: Error.self) {
            _ = try await KeynoteConverter().convert(key, info: info)
        }
    }
}
