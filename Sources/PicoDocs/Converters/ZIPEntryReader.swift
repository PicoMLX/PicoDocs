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
    static func read(_ archive: Archive, path: String, maxBytes: Int = Int.max, onBytes: ((Int) throws -> Void)? = nil) throws -> Data? {
        try Task.checkCancellation()
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let entry = archive[cleanPath] else { return nil }
        return try read(archive, entry: entry, maxBytes: maxBytes, onBytes: onBytes)
    }

    /// Callers already walking an archive retain the physical entry rather than
    /// performing another linear central-directory lookup for each component.
    static func read(_ archive: Archive, entry: Entry, maxBytes: Int = Int.max, onBytes: ((Int) throws -> Void)? = nil) throws -> Data? {
        try Task.checkCancellation()
        let archiveSize = UInt64(archive.data?.count ?? Int.max)
        guard entry.compressedSize <= archiveSize,
              entry.isCompressed || entry.uncompressedSize <= archiveSize else { return nil }
        guard maxBytes >= 0, entry.uncompressedSize <= UInt64(maxBytes) else { return nil }
        let declaredSize = entry.uncompressedSize
        var data = Data(capacity: Int(min(declaredSize, maxReservation)))
        do {
            _ = try archive.extract(entry) { chunk in
                if chunk.isEmpty, declaredSize > 0 { throw TruncatedEntry() }
                try Task.checkCancellation()
                try onBytes?(chunk.count)
                guard chunk.count <= maxBytes - data.count else { throw TruncatedEntry() }
                data.append(chunk)
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            return nil
        }
        return data
    }
}

// MARK: - Opening archives

extension ZIPEntryReader {

    /// Opens `data` as a read-only archive, or nil when it isn't a ZIP whose
    /// records ZIPFoundation can walk without trapping.
    ///
    /// ZIPFoundation's in-memory archive seeks to the central-directory and
    /// local-header offsets the archive declares, and a read positioned past the
    /// end of the bytes computes a negative length and traps (`MemoryFile`
    /// `readData`) instead of failing. Its iterator also adds an entry's 64-bit
    /// size to its offset unchecked. Truncated and fuzzed packages reach both, so
    /// every archive is opened through this pre-flight, which repeats
    /// ZIPFoundation's record walk with bounds checks.
    static func archive(_ data: Data) -> Archive? {
        guard isSafelyTraversable(data) else { return nil }
        return Archive(data: data, accessMode: .read)
    }

    /// Mirrors how ZIPFoundation (0.9.19) locates the end-of-central-directory
    /// record and iterates entries. Returns false when that walk would seek past
    /// the end of `data` or overflow; a record ZIPFoundation would merely fail to
    /// decode ends its iteration there, so the walk stops there too.
    static func isSafelyTraversable(_ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            let count = UInt64(bytes.count)
            func value(at offset: UInt64, width: UInt64) -> UInt64? {
                guard offset <= count, count - offset >= width else { return nil }
                var result: UInt64 = 0
                for index in (0..<Int(width)).reversed() {
                    result = result << 8 | UInt64(bytes[Int(offset) + index])
                }
                return result
            }
            func u16(_ offset: UInt64) -> UInt64? { value(at: offset, width: 2) }
            func u32(_ offset: UInt64) -> UInt64? { value(at: offset, width: 4) }
            func u64(_ offset: UInt64) -> UInt64? { value(at: offset, width: 8) }

            // The last end-of-central-directory signature, scanning backwards.
            guard count >= 22 else { return false }
            var position = count - 22
            while u32(position) != 0x0605_4B50 {
                guard position > 0 else { return false }
                position -= 1
            }
            let end = position
            guard let commentLength = u16(end + 20), end + 22 + commentLength <= count,
                  var entryCount = u16(end + 10), var directory = u32(end + 16) else { return false }
            // A ZIP64 locator and record immediately precede the record.
            if end > 20, end - 20 > 56 {
                let locator = end - 20, record = locator - 56
                if u32(locator) == 0x0706_4B50, u32(record) == 0x0606_4B50,
                   let version = u16(record + 14), version >= 45,
                   let entries = u64(record + 32), let start = u64(record + 48) {
                    entryCount = entries
                    directory = start
                }
            }

            var index: UInt64 = 0
            while index < entryCount {
                guard directory <= count else { return false }
                guard u32(directory) == 0x0201_4B50, count - directory >= 46,
                      let flags = u16(directory + 8),
                      let method = u16(directory + 10), var compressed = u32(directory + 20),
                      var uncompressed = u32(directory + 24), let nameLength = u16(directory + 28),
                      let extraLength = u16(directory + 30), let commentLength = u16(directory + 32),
                      let disk = u16(directory + 34), var offset = u32(directory + 42) else { return true }
                let recordEnd = directory + 46 + nameLength + extraLength + commentLength
                guard recordEnd <= count else { return true }

                // ZIP64 extended information: present only with the exact size of
                // the fields whose 32-bit (16-bit for the disk) values are saturated.
                var fieldWidths: [UInt64] = []
                if uncompressed == 0xFFFF_FFFF { fieldWidths.append(8) }
                if compressed == 0xFFFF_FFFF { fieldWidths.append(8) }
                if offset == 0xFFFF_FFFF { fieldWidths.append(8) }
                if disk == 0xFFFF { fieldWidths.append(4) }
                var zip64: (uncompressed: UInt64, compressed: UInt64, offset: UInt64)?
                var field = directory + 46 + nameLength
                let extraEnd = field + extraLength
                while extraLength >= 4, field < extraEnd - 4,
                      let header = u16(field), let size = u16(field + 2) {
                    let next = field + 4 + size
                    guard next <= extraEnd else { break }
                    if header == 0x0001 {
                        if size == fieldWidths.reduce(0, +) {
                            var cursor = field + 4
                            func next64(_ saturated: Bool) -> UInt64 {
                                guard saturated, let value = u64(cursor) else { return 0 }
                                cursor += 8
                                return value
                            }
                            let u = next64(uncompressed == 0xFFFF_FFFF)
                            let c = next64(compressed == 0xFFFF_FFFF)
                            let o = next64(offset == 0xFFFF_FFFF)
                            zip64 = (u, c, o)
                        }
                        break
                    }
                    field = next
                }
                // An entry with the field is ZIP64 whatever its version; its zero
                // values fall back to the 32-bit fields.
                if let zip64 {
                    if zip64.uncompressed > 0 { uncompressed = zip64.uncompressed }
                    if zip64.compressed > 0 { compressed = zip64.compressed }
                    if zip64.offset > 0 { offset = zip64.offset }
                }

                guard offset <= count else { return false }
                guard u32(offset) == 0x0403_4B50, let localName = u16(offset + 26),
                      let localExtra = u16(offset + 28) else { return true }
                let dataStart = offset + 30 + localName + localExtra
                guard dataStart <= count else { return true }
                if flags & 0x8 != 0 {
                    // The data descriptor follows the entry's declared bytes.
                    let (descriptor, overflow) = dataStart.addingReportingOverflow(method != 0 ? compressed : uncompressed)
                    guard !overflow, descriptor <= count else { return false }
                }
                directory = recordEnd
                index += 1
            }
            return true
        }
    }
}
