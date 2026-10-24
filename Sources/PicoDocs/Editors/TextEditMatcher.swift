//
//  TextEditMatcher.swift
//  PicoDocs
//
//  The format-independent half of the edit contract: resolve a batch of
//  `TextEdit`s against one editable-text snapshot. It enforces the rules every
//  editor shares — non-empty `find`, exact and unambiguous matches unless
//  `replaceAll`, and no two edits targeting overlapping text — and leaves
//  mapping the matches back into a file to the format's editor.
//
//  Offsets are UTF-16 code units throughout, the unit editors use to map
//  snapshot positions back to raw bytes. Matching is literal (no Unicode
//  normalization), but a match must start and end on grapheme-cluster
//  boundaries, so quoting "e" never matches half of a decomposed "é" and a
//  replacement can't strand a combining mark.
//

import Foundation

enum TextEditMatcher {

    /// Resolves every edit against the same `snapshot` (edits never see each
    /// other's replacements) and returns, per edit and in order, the UTF-16 ranges
    /// it replaces.
    ///
    /// Throws the first failing edit's error — `editEmptyFind`, `editTextNotFound`
    /// or `editTextAmbiguous` — and `editsOverlap` when two edits' ranges overlap.
    /// Nothing is partially resolved: callers apply all ranges or none.
    static func resolve(_ edits: [TextEdit], in snapshot: String) throws -> [[Range<Int>]] {
        var resolved: [[Range<Int>]] = []
        resolved.reserveCapacity(edits.count)
        for edit in edits {
            guard !edit.find.isEmpty else { throw PicoDocsError.editEmptyFind }
            let found = try occurrences(of: edit.find, in: snapshot)
            guard !found.isEmpty else { throw PicoDocsError.editTextNotFound(find: edit.find) }
            guard edit.replaceAll || found.count == 1 else {
                throw PicoDocsError.editTextAmbiguous(find: edit.find, occurrences: found.count)
            }
            resolved.append(found)
        }
        let ordered = resolved.joined().sorted { $0.lowerBound < $1.lowerBound }
        for (previous, next) in zip(ordered, ordered.dropFirst()) where next.lowerBound < previous.upperBound {
            throw PicoDocsError.editsOverlap
        }
        return resolved
    }

    /// Every literal, grapheme-aligned occurrence of `needle` in `haystack`,
    /// counted left to right without overlap ("aa" occurs once in "aaa").
    static func occurrences(of needle: String, in haystack: String) throws -> [Range<Int>] {
        guard !needle.isEmpty else { return [] }
        let source = haystack as NSString
        let length = source.length
        var ranges: [Range<Int>] = []
        var start = 0
        while start < length {
            try Task.checkCancellation()
            let found = source.range(of: needle, options: .literal, range: NSRange(location: start, length: length - start))
            guard found.location != NSNotFound, found.length > 0 else { break }
            let range = found.location..<(found.location + found.length)
            if isCharacterBoundary(range.lowerBound, in: haystack), isCharacterBoundary(range.upperBound, in: haystack) {
                ranges.append(range)
                start = range.upperBound
            } else {
                start = range.lowerBound + 1
            }
        }
        return ranges
    }

    /// Whether a UTF-16 offset falls between two grapheme clusters of `text`.
    private static func isCharacterBoundary(_ utf16Offset: Int, in text: String) -> Bool {
        String.Index(utf16Offset: utf16Offset, in: text).samePosition(in: text) != nil
    }
}
