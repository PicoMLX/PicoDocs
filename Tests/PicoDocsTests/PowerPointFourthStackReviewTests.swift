import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

struct PowerPointFourthStackReviewTests {
    @Test func UTF16TextCannotImpersonateASCIIDeclarations() throws {
        let text = String(String.UnicodeScalarView([0x3C00, 0x2100, 0x4400, 0x4F00, 0x4300, 0x5400, 0x5900, 0x5000, 0x4500].map { UnicodeScalar($0)! }))
        let xml = "<?xml version='1.0' encoding='UTF-16'?><a:t xmlns:a='http://schemas.openxmlformats.org/drawingml/2006/main'>" + text + "</a:t>"
        for (encoding, bom) in [(String.Encoding.utf16BigEndian, [UInt8(0xFE), 0xFF]), (.utf16LittleEndian, [0xFF, 0xFE])] {
            let data = Data(bom) + (try #require(xml.data(using: encoding)))
            #expect(PowerPointXML.normalize(data)?.contains(text) == true)
        }
    }

    @Test func angleDestinationsDoNotCaptureFollowingCellBreaks() {
        for url in ["https://example/a(b", "https://example/a)b", "https://example/a((b"] {
            let source = "[x](<" + url + ">)<br>next"
            #expect(MarkdownTableCell.decodeBreaks(source) == "[x](<" + url + ">)\nnext")
        }
    }

    @Test func percentTripletCaseIdentifiesTheSamePart() async throws {
        typealias B = PowerPointConverterTests
        let seed = B.deck(slides: [.init(file: "caf%C3%A9.xml", shapes: B.titleShape("Cafe"))])
        let data = try PowerPointThirdStackReviewTests.replacing(seed, part: "ppt/_rels/presentation.xml.rels") { $0.replacingOccurrences(of: "caf%C3%A9.xml", with: "caf%c3%a9.xml") }
        let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
        #expect(result.markdown().contains("Cafe"))
    }

    @Test func escapeProtectionChecksItsIntermediateAllocation() throws {
        let input = #"\*\&\!"# + "\u{E006}🙂"
        let protected = try DocumentRenderer.boundedProtectEscapes(input)
        #expect(protected.utf8.count == 28)
        #expect(try DocumentRenderer.boundedProtectEscapes(input, maximumBytes: 28) == protected)
        #expect(throws: PicoDocsError.fileCorrupted) { _ = try DocumentRenderer.boundedProtectEscapes(input, maximumBytes: 27) }
        // The final visible text fits the allowance, but its escape sentinels do not.
        let punctuation = String(repeating: #"\*"#, count: 12_000_000)
        for suffix in ["", "\n\n[^note]: definition"] {
            let result = ConverterResult(sections: [DocumentSection(markdown: punctuation + suffix)])
            #expect(throws: PicoDocsError.fileCorrupted) { () throws -> Void in _ = try DocumentRenderer.render(result, to: .html) }
        }
    }

    @Test func attributeLimitRunsBeforeFoundationParsingInEachEncoding() throws {
        let attributes = (0..<256).map { "a\($0)='v'" }.joined(separator: " ")
        let accepted = "<root " + attributes + "/>"
        let rejected = "<root " + attributes + " extra='v'/>"
        for encoding in [String.Encoding.utf8, .utf16] {
            let exact = try #require(accepted.data(using: encoding))
            let extra = try #require(rejected.data(using: encoding))
            #expect(PowerPointXML.lexicalPreflight(exact))
            #expect(PowerPointXML.normalize(exact) != nil)
            #expect(!PowerPointXML.lexicalPreflight(extra))
            #expect(PowerPointXML.normalize(extra) == nil)
            let declaration = try #require("<!DOCTYPE root><root/>".data(using: encoding))
            #expect(!PowerPointXML.lexicalPreflight(declaration))
            let literal = try #require("<!-- <!DOCTYPE root> --><root><![CDATA[<!DOCTYPE literal>]]></root>".data(using: encoding))
            #expect(PowerPointXML.lexicalPreflight(literal))
            #expect(PowerPointXML.normalize(literal)?.contains("&lt;!DOCTYPE literal&gt;") == true)
        }
        // Foundation on macOS rejects UTF-32; its lexical preflight still reads
        // complete code units and bounds attributes before handing it off.
        #expect(PowerPointXML.lexicalPreflight(try #require(accepted.data(using: .utf32))))
        #expect(!PowerPointXML.lexicalPreflight(try #require(rejected.data(using: .utf32))))
    }

    @Test func namespaceWorkSharesUnchangedScopesAndBoundsRealCopies() {
        let root = "<root xmlns:p='urn:one' xmlns:q='urn:q'>"
        let redundant = Data((root + String(repeating: "<child xmlns:p='urn:one'/>", count: 1000) + "</root>").utf8)
        let minimal = PowerPointXML.Budget(namespaceWork: 1)
        #expect(PowerPointXML.normalize(redundant, budget: minimal) != nil)
        #expect(minimal.namespaceWork == 0)
        let changed = Data((root + "<child xmlns:p='urn:two'/><child xmlns:p='urn:two'/></root>").utf8)
        #expect(PowerPointXML.normalize(changed, budget: .init(namespaceWork: 7)) != nil)
        #expect(PowerPointXML.normalize(changed, budget: .init(namespaceWork: 6)) == nil)
        let shared = PowerPointXML.Budget(namespaceWork: 13)
        #expect(PowerPointXML.normalize(changed, budget: shared) != nil)
        #expect(PowerPointXML.normalize(changed, budget: shared) == nil)
    }

    @Test func equivalentPartNamesShareLookupOverridesAndRejectDuplicates() throws {
        let type = "image/png"
        let manifest = "<Types><Override PartName='/media/caf%C3%A9.png' ContentType='" + type + "'/></Types>"
        let zip = PagesConverterTests.makeZip([("[Content_Types].xml", Array(manifest.utf8)), ("media/caf%c3%a9.png", [1, 2, 3])])
        let package = PowerPointPackage(archive: try Archive(data: zip, accessMode: .read))
        #expect(package.read("media/caf%C3%A9.png") == Data([1, 2, 3]))
        #expect(PowerPointConverter.contentType("media/caf%c3%a9.png", archive: package) == type)
        try package.check()
        let ambiguous = PagesConverterTests.makeZip([("media/caf%C3%A9.png", [1]), ("media/caf%c3%a9.png", [2])])
        let duplicates = PowerPointPackage(archive: try Archive(data: ambiguous, accessMode: .read))
        #expect(throws: PicoDocsError.fileCorrupted) { try duplicates.check() }
        #expect(PowerPointPackage.canonicalPartPath("Case/%2f/%GG") == "Case/%2F/%GG")
    }

}
