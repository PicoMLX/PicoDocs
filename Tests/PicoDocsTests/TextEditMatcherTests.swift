//
//  TextEditMatcherTests.swift
//  PicoDocsTests
//
//  The format-independent edit contract, checked on plain strings: exact and
//  unambiguous matching, replaceAll, batch semantics, and UTF-16 offsets that
//  never split a grapheme cluster.
//

import Foundation
import Testing
@testable import PicoDocs

@Suite("TextEditMatcher (exact-match edit contract)")
struct TextEditMatcherTests {

    @Test("A unique match resolves to its UTF-16 range")
    func uniqueMatch() throws {
        let ranges = try TextEditMatcher.resolve([TextEdit(find: "world", replace: "there")], in: "hello world")
        #expect(ranges == [[6..<11]])
    }

    @Test("Offsets are UTF-16 code units, so astral characters count twice")
    func utf16Offsets() throws {
        let ranges = try TextEditMatcher.resolve([TextEdit(find: "ok", replace: "fine")], in: "👍 ok")
        #expect(ranges == [[3..<5]])
    }

    @Test("An empty find is rejected")
    func emptyFind() {
        #expect(throws: PicoDocsError.editEmptyFind) {
            try TextEditMatcher.resolve([TextEdit(find: "", replace: "x")], in: "text")
        }
    }

    @Test("Text that isn't in the snapshot is rejected")
    func notFound() {
        #expect(throws: PicoDocsError.editTextNotFound(find: "absent")) {
            try TextEditMatcher.resolve([TextEdit(find: "absent", replace: "x")], in: "present")
        }
    }

    @Test("Repeated text without replaceAll is rejected with its count")
    func ambiguous() {
        #expect(throws: PicoDocsError.editTextAmbiguous(find: "the", occurrences: 2)) {
            try TextEditMatcher.resolve([TextEdit(find: "the", replace: "a")], in: "the cat and the hat")
        }
        let message = PicoDocsError.editTextAmbiguous(find: "the", occurrences: 2).errorDescription
        #expect(message?.contains("2") == true)
    }

    @Test("replaceAll resolves every occurrence, left to right without overlap")
    func replaceAll() throws {
        let ranges = try TextEditMatcher.resolve([TextEdit(find: "the", replace: "a", replaceAll: true)], in: "the cat and the hat")
        #expect(ranges == [[0..<3, 12..<15]])
        #expect(try TextEditMatcher.occurrences(of: "aa", in: "aaa") == [0..<2])
        #expect(try TextEditMatcher.occurrences(of: "aa", in: "aaaa") == [0..<2, 2..<4])
    }

    @Test("Edits whose ranges overlap are rejected")
    func overlappingEdits() {
        #expect(throws: PicoDocsError.editsOverlap) {
            try TextEditMatcher.resolve([
                TextEdit(find: "hello wo", replace: "x"),
                TextEdit(find: "world", replace: "y"),
            ], in: "hello world")
        }
        #expect(throws: PicoDocsError.editsOverlap) {
            try TextEditMatcher.resolve([
                TextEdit(find: "world", replace: "x"),
                TextEdit(find: "world", replace: "y"),
            ], in: "hello world")
        }
    }

    @Test("Adjacent edits don't overlap")
    func adjacentEdits() throws {
        let ranges = try TextEditMatcher.resolve([
            TextEdit(find: "world", replace: "x"),
            TextEdit(find: "hello ", replace: "y"),
        ], in: "hello world")
        #expect(ranges == [[6..<11], [0..<6]])
    }

    @Test("Every edit matches the original snapshot, not an earlier edit's output")
    func batchUsesOriginalSnapshot() {
        #expect(throws: PicoDocsError.editTextNotFound(find: "dog")) {
            try TextEditMatcher.resolve([
                TextEdit(find: "cat", replace: "dog"),
                TextEdit(find: "dog", replace: "bird"),
            ], in: "the cat")
        }
    }

    @Test("The first failing edit's error wins, even when later edits are fine")
    func firstFailureWins() {
        #expect(throws: PicoDocsError.editTextNotFound(find: "missing")) {
            try TextEditMatcher.resolve([
                TextEdit(find: "missing", replace: "x"),
                TextEdit(find: "", replace: "y"),
            ], in: "text")
        }
    }

    @Test("A match never splits a grapheme cluster")
    func graphemeAlignment() throws {
        let decomposed = "cafe\u{301} au lait"
        #expect(throws: PicoDocsError.editTextNotFound(find: "cafe")) {
            try TextEditMatcher.resolve([TextEdit(find: "cafe", replace: "tea")], in: decomposed)
        }
        #expect(throws: PicoDocsError.editTextNotFound(find: "\u{301}")) {
            try TextEditMatcher.resolve([TextEdit(find: "\u{301}", replace: "")], in: decomposed)
        }
        #expect(try TextEditMatcher.resolve([TextEdit(find: "cafe\u{301}", replace: "tea")], in: decomposed) == [[0..<5]])
        // A misaligned candidate is skipped, not counted, so a later aligned one
        // is still unique.
        #expect(try TextEditMatcher.occurrences(of: "e", in: "e\u{301} e") == [3..<4])
    }

    @Test("Matching is literal: canonically equivalent spellings don't match")
    func literalMatching() {
        #expect(throws: PicoDocsError.editTextNotFound(find: "caf\u{E9}")) {
            try TextEditMatcher.resolve([TextEdit(find: "caf\u{E9}", replace: "tea")], in: "cafe\u{301}")
        }
    }

    @Test("Every boundary kind has its own message")
    func boundaryMessages() {
        let messages = PicoDocsError.EditBoundary.allCases.compactMap {
            PicoDocsError.editCrossesBoundary(kind: $0).errorDescription
        }
        #expect(messages.count == PicoDocsError.EditBoundary.allCases.count)
        #expect(Set(messages).count == messages.count)
    }
}
