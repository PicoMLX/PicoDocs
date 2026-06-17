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

    @Test("Removes zero-width and invisible formatting characters")
    func removesInvisibles() {
        #expect(UnicodeSanitizer.sanitize("a\u{200B}b") == "ab")            // ZWSP
        #expect(UnicodeSanitizer.sanitize("a\u{200C}b") == "ab")            // ZWNJ
        #expect(UnicodeSanitizer.sanitize("a\u{200D}b") == "ab")            // ZWJ
        #expect(UnicodeSanitizer.sanitize("a\u{2060}b") == "ab")            // word joiner
        #expect(UnicodeSanitizer.sanitize("\u{FEFF}text") == "text")        // BOM / ZWNBSP
        #expect(UnicodeSanitizer.sanitize("soft\u{00AD}hyphen") == "softhyphen")
    }

    @Test("Removes bidirectional formatting controls")
    func removesBidi() {
        #expect(UnicodeSanitizer.sanitize("a\u{202E}b\u{202C}c") == "abc")
        #expect(UnicodeSanitizer.sanitize("a\u{2066}b\u{2069}c") == "abc")
    }

    @Test("Folds Unicode space variants to a plain space")
    func foldsSpaces() {
        #expect(UnicodeSanitizer.sanitize("a\u{00A0}b") == "a b")   // no-break space
        #expect(UnicodeSanitizer.sanitize("a\u{2009}b") == "a b")   // thin space
        #expect(UnicodeSanitizer.sanitize("a\u{3000}b") == "a b")   // ideographic space
    }

    @Test("Folds line/paragraph separators and CR/CRLF/NEL to newline")
    func foldsLineBreaks() {
        #expect(UnicodeSanitizer.sanitize("a\u{2028}b") == "a\nb")  // line separator
        #expect(UnicodeSanitizer.sanitize("a\u{2029}b") == "a\nb")  // paragraph separator
        #expect(UnicodeSanitizer.sanitize("a\u{0085}b") == "a\nb")  // NEL
        #expect(UnicodeSanitizer.sanitize("a\r\nb") == "a\nb")      // CRLF
        #expect(UnicodeSanitizer.sanitize("a\rb") == "a\nb")        // lone CR
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

    @Test("convert sanitizes extracted text by default")
    func engineSanitizesByDefault() async throws {
        let data = Data("Hello\u{200B}\u{00A0}World".utf8)
        let result = try await PicoDocsEngine.convert(data: data, filename: "note.txt")
        #expect(result.markdown() == "Hello World")
    }

    @Test("convert leaves text untouched when sanitizeUnicode is false")
    func engineRespectsOptOut() async throws {
        let data = Data("Hello\u{200B}\u{00A0}World".utf8)
        let result = try await PicoDocsEngine.convert(
            data: data, filename: "note.txt", sanitizeUnicode: false
        )
        let scalars = result.markdown().unicodeScalars
        #expect(scalars.contains("\u{200B}"))
        #expect(scalars.contains("\u{00A0}"))
    }
}
