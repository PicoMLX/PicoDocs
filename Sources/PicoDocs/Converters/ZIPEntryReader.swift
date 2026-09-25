//
//  ZIPEntryReader.swift
//  PicoDocs
//
//  The one place the ZIP-based converters (DOCX, EPUB, Pages, Keynote) read an
//  archive entry into memory. An entry's sizes come from the archive's central
//  directory — untrusted input — so they're treated as hints, never as
//  allocation sizes or loop bounds.
//

import Foundation
import ZIPFoundation

enum ZIPEntryReader {

    /// Upper bound on the up-front buffer reservation. Real entries larger than
    /// this still read fine; the buffer simply grows as chunks arrive.
    static let maxReservation: UInt64 = 16 * 1024 * 1024

    /// Thrown from the extract consumer to stop reading an entry that claims
    /// more bytes than the archive holds.
    private struct TruncatedEntry: Error {}

    /// Reads the entry at `path` (a leading "/" is ignored — ZIP entry names have
    /// none), or nil when it's missing or can't be read intact.
    ///
    /// - Sizes larger than the archive itself are rejected up front. ZIPFoundation
    ///   uses them as extraction loop bounds and converts them to `Int64`
    ///   unchecked (a ZIP64 size above `Int64.max` traps inside `extract`), yet an
    ///   entry's compressed bytes — which, for a stored entry, are its bytes —
    ///   can't exceed the archive holding them.
    /// - The size reservation is clamped (in `UInt64`, before the `Int` cast), so a
    ///   hostile size can neither trap here nor force a multi-gigabyte allocation.
    /// - A stored entry whose declared size still overstates its bytes makes
    ///   ZIPFoundation read past the end of the archive, handing back empty chunks
    ///   for up to `size / chunkSize` iterations; the first empty chunk of a
    ///   non-empty entry ends the read instead.
    static func read(_ archive: Archive, path: String) -> Data? {
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let entry = archive[cleanPath] else { return nil }
        let archiveSize = UInt64(archive.data?.count ?? Int.max)
        guard entry.compressedSize <= archiveSize,
              entry.isCompressed || entry.uncompressedSize <= archiveSize else { return nil }
        let declaredSize = entry.uncompressedSize
        var data = Data(capacity: Int(min(declaredSize, maxReservation)))
        do {
            _ = try archive.extract(entry) { chunk in
                if chunk.isEmpty, declaredSize > 0 { throw TruncatedEntry() }
                data.append(chunk)
            }
        } catch {
            return nil
        }
        return data
    }
}
