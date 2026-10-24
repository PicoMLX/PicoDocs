//
//  TextEditMatcher.swift
//  PicoDocs
//
//  The format-independent half of the edit contract: find exact, literal
//  occurrences of a needle in a snapshot string and enforce the non-empty /
//  uniqueness / replaceAll rules. Kept separate from the DOCX splicer so it can
//  be unit-tested on plain strings and reused by any future editor (or the lossy
//  Markdown round-trip fallback).
//

import Foundation

enum TextEditMatcher {

    /// All non-overlapping, literal occurrences of `needle` in `haystack`, left to
    /// right. Literal (not normalized/diacritic-insensitive) so matching is exact.
    static func occurrences(of needle: String, in haystack: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let found = haystack.range(of: needle, options: .literal, range: searchStart..<haystack.endIndex) {
            ranges.append(found)
            // Non-overlapping: continue after this match (guard against a zero-width
            // step, though a non-empty needle always advances).
            searchStart = found.upperBound > found.lowerBound ? found.upperBound : haystack.index(after: found.lowerBound)
        }
        return ranges
    }

    /// The snapshot ranges a single `TextEdit` resolves to, applying the contract:
    /// empty `find` → `editEmptyFind`; no match → `editTextNotFound`; multiple
    /// matches without `replaceAll` → `editTextAmbiguous`.
    static func resolve(_ edit: TextEdit, in haystack: String) throws -> [Range<String.Index>] {
        guard !edit.find.isEmpty else { throw PicoDocsError.editEmptyFind }
        let found = occurrences(of: edit.find, in: haystack)
        guard !found.isEmpty else { throw PicoDocsError.editTextNotFound(find: edit.find) }
        guard edit.replaceAll || found.count == 1 else {
            throw PicoDocsError.editTextAmbiguous(find: edit.find, occurrences: found.count)
        }
        return edit.replaceAll ? found : [found[0]]
    }
}
