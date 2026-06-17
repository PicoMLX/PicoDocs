//
//  UnicodeSanitizerTests.swift
//  PicoDocsTests
//
//  Unit coverage for `UnicodeSanitizer` plus its integration into the engine
//  (`PicoDocsEngine.convert` applies it by default, honoring `sanitizeUnicode`).
//

import Foundation
import Testing
@testable import PicoDocs

@Suite("Unicode sanitization")
struct UnicodeSanitizerTests {

    @Test("Removes truly-invisible formatting characters")
    func removesInvisibles() {
        #expect(UnicodeSanitizer.sanitize("a\u{200B}b") == "ab")            // ZWSP
        #expect(UnicodeSanitizer.sanitize("a\u{2060}b") == "ab")            // word joiner
        #expect(UnicodeSanitizer.sanitize("a\u{2062}b") == "ab")            // invisible times
        #expect(UnicodeSanitizer.sanitize("a\u{2064}b") == "ab")            // invisible plus
        #expect(UnicodeSanitizer.sanitize("\u{FEFF}text") == "text")        // BOM / ZWNBSP
        #expect(UnicodeSanitizer.sanitize("soft\u{00AD}hyphen") == "softhyphen")
    }

    @Test("Keeps ZWJ / ZWNJ joiners (they shape text and compose emoji)")
    func keepsJoiners() {
        #expect(UnicodeSanitizer.sanitize("a\u{200C}b") == "a\u{200C}b")    // ZWNJ kept
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"          // 👨‍👩‍👧 (ZWJ)
        #expect(UnicodeSanitizer.sanitize(family) == family)               // ZWJ kept
    }

    @Test("Removes bidirectional formatting controls")
    func removesBidi() {
        #expect(UnicodeSanitizer.sanitize("a\u{202E}b\u{202C}c") == "abc")
        #expect(UnicodeSanitizer.sanitize("a\u{2066}b\u{2069}c") == "abc")
        #expect(UnicodeSanitizer.sanitize("a\u{061C}b") == "ab")   // Arabic letter mark
    }

    @Test("Folds Unicode space variants to a plain space")
    func foldsSpaces() {
        #expect(UnicodeSanitizer.sanitize("a\u{00A0}b") == "a b")   // no-break space
        #expect(UnicodeSanitizer.sanitize("a\u{2009}b") == "a b")   // thin space
        #expect(UnicodeSanitizer.sanitize("a\u{3000}b") == "a b")   // ideographic space
    }

    @Test("Normalizes CR/CRLF to newline; folds other separators to space")
    func foldsLineBreaks() {
        #expect(UnicodeSanitizer.sanitize("a\r\nb") == "a\nb")      // CRLF → LF
        #expect(UnicodeSanitizer.sanitize("a\rb") == "a\nb")        // lone CR → LF
        #expect(UnicodeSanitizer.sanitize("a\u{2028}b") == "a b")   // line separator → space
        #expect(UnicodeSanitizer.sanitize("a\u{2029}b") == "a b")   // paragraph separator → space
        #expect(UnicodeSanitizer.sanitize("a\u{0085}b") == "a b")   // NEL → space
        #expect(UnicodeSanitizer.sanitize("a\u{000C}b") == "a b")   // form feed → space
        #expect(UnicodeSanitizer.sanitize("a\u{000B}b") == "a b")   // vertical tab → space
    }

    @Test("Drops control characters but keeps tab and newline")
    func dropsControls() {
        #expect(UnicodeSanitizer.sanitize("a\u{0007}b") == "ab")    // bell
        #expect(UnicodeSanitizer.sanitize("a\u{0000}b") == "ab")    // NUL
        #expect(UnicodeSanitizer.sanitize("a\u{FFFD}b") == "ab")    // replacement char
        #expect(UnicodeSanitizer.sanitize("a\tb\nc") == "a\tb\nc")  // tab + newline kept
    }

    @Test("Applies canonical (NFC) composition")
    func canonicalComposition() {
        let decomposed = "e\u{0301}"   // e + combining acute accent
        let sanitized = UnicodeSanitizer.sanitize(decomposed)
        #expect(sanitized == "é")
        #expect(sanitized.unicodeScalars.count == 1)
    }

    @Test("Preserves legitimate visible typography")
    func preservesTypography() {
        // “Hello” — café…  (smart quotes, em dash, precomposed accent, ellipsis)
        let text = "\u{201C}Hello\u{201D} \u{2014} caf\u{00E9}\u{2026}"
        #expect(UnicodeSanitizer.sanitize(text) == text)
    }

    @Test("Is idempotent")
    func idempotent() {
        let messy = "\u{FEFF}a\u{200B}b\u{00A0}c\u{2028}d\r\ne\u{0301}"
        let once = UnicodeSanitizer.sanitize(messy)
        #expect(UnicodeSanitizer.sanitize(once) == once)
    }

    @Test("Empty string is unchanged")
    func emptyString() {
        #expect(UnicodeSanitizer.sanitize("") == "")
    }

    // MARK: - Engine integration

    @Test("convert leaves text raw by default (sanitization is opt-in)")
    func engineDefaultsToRaw() async throws {
        let data = Data("Hello\u{200B}\u{00A0}World".utf8)
        let result = try await PicoDocsEngine.convert(data: data, filename: "note.txt")
        let scalars = result.markdown().unicodeScalars
        #expect(scalars.contains("\u{200B}"))
        #expect(scalars.contains("\u{00A0}"))
    }

    @Test("convert sanitizes when sanitizeUnicode is enabled")
    func engineSanitizesWhenEnabled() async throws {
        let data = Data("Hello\u{200B}\u{00A0}World".utf8)
        let result = try await PicoDocsEngine.convert(
            data: data, filename: "note.txt", sanitizeUnicode: true
        )
        #expect(result.markdown() == "Hello World")
    }

    @Test("convert throws when enabled sanitization removes all content")
    func engineThrowsWhenSanitizedEmpty() async throws {
        let data = Data("\u{FEFF}\u{200B}\u{2060}".utf8)   // only removable characters
        await #expect(throws: PicoDocsError.self) {
            _ = try await PicoDocsEngine.convert(
                data: data, filename: "blank.txt", sanitizeUnicode: true
            )
        }
    }

    @Test("CSV export sanitizes metadata-backed cell content when enabled")
    func csvExportSanitized() async throws {
        let csv = Data("a\u{200B}b,c\u{00A0}d\n1,2".utf8)
        let out = try await PicoDocsEngine.export(
            data: csv, filename: "t.csv", to: .csv, sanitizeUnicode: true
        )
        #expect(!out.unicodeScalars.contains("\u{200B}"))   // ZWSP removed
        #expect(!out.unicodeScalars.contains("\u{00A0}"))   // NBSP folded to space
    }
}
