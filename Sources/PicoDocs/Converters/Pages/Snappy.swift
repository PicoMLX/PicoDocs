//
//  Snappy.swift
//  PicoDocs
//
//  Minimal Snappy block decompressor plus the iWork `.iwa` chunk framing.
//
//  An iWork Archive (`.iwa`) stores its protobuf object stream as a sequence of
//  Snappy-compressed chunks. The framing is Snappy's "framing format" but
//  trimmed: each chunk is a 4-byte header — a `0x00` type byte (always a
//  compressed chunk for iWork) followed by a 24-bit little-endian length — then
//  that many bytes of a raw Snappy-compressed block. iWork omits the stream
//  identifier and the per-chunk CRC-32C the spec otherwise requires.
//
//  Implemented in-module (no SwiftProtobuf, no external Snappy) to keep PicoDocs
//  dependency-light. Format references: obriensp/iWorkFileFormat, the SheetJS IWA
//  notes, and Cocoanetics/SwiftText (MIT).
//

import Foundation

enum Snappy {

    enum SnappyError: Error {
        case malformed
    }

    /// Decompresses an iWork `.iwa` payload: concatenated `[0x00, len24-LE, block]`
    /// frames, each `block` a raw Snappy-compressed block. Returns the assembled
    /// protobuf object stream.
    static func decompressIWA(_ data: [UInt8]) throws -> [UInt8] {
        var output: [UInt8] = []
        var i = 0
        let n = data.count
        while i < n {
            // 4-byte frame header: type (1) + length (3, little-endian).
            guard i + 4 <= n else { throw SnappyError.malformed }
            let type = data[i]
            let length = Int(data[i + 1]) | (Int(data[i + 2]) << 8) | (Int(data[i + 3]) << 16)
            i += 4
            guard i + length <= n else { throw SnappyError.malformed }
            // Type 0x00 is a compressed block; iWork only ever emits this. Skip
            // any other frame type's bytes defensively rather than failing.
            if type == 0x00 {
                output.append(contentsOf: try decompressBlock(Array(data[i ..< i + length])))
            }
            i += length
        }
        return output
    }

    /// Decompresses a single raw Snappy block (preamble varint = uncompressed
    /// length, then a stream of literal and copy elements).
    static func decompressBlock(_ input: [UInt8]) throws -> [UInt8] {
        var pos = 0
        let expectedLength = try readPreambleLength(input, &pos)
        var output: [UInt8] = []
        // `expectedLength` is an attacker-controlled hint: cap the pre-allocation
        // so a malformed block can't force a huge reserve (OOM). Real output stays
        // bounded by the finite input regardless of the claimed length.
        output.reserveCapacity(min(expectedLength, 16 * 1024 * 1024))

        let n = input.count
        while pos < n {
            let tag = input[pos]
            pos += 1
            switch tag & 0x03 {
            case 0x00:
                // Literal. Upper 6 bits encode (length - 1) directly, or — for the
                // values 60...63 — the number of trailing little-endian length bytes.
                var length = Int(tag >> 2)
                if length >= 60 {
                    let extra = length - 59
                    guard pos + extra <= n else { throw SnappyError.malformed }
                    length = Int(readLittleEndian(input, pos, extra))
                    pos += extra
                }
                length += 1
                guard pos + length <= n else { throw SnappyError.malformed }
                output.append(contentsOf: input[pos ..< pos + length])
                pos += length
            case 0x01:
                // Copy, 1-byte offset: length 4...11, 11-bit offset.
                let length = 4 + Int((tag >> 2) & 0x07)
                guard pos + 1 <= n else { throw SnappyError.malformed }
                let offset = (Int(tag >> 5) << 8) | Int(input[pos])
                pos += 1
                try appendCopy(&output, offset: offset, length: length)
            case 0x02:
                // Copy, 2-byte offset.
                let length = 1 + Int(tag >> 2)
                guard pos + 2 <= n else { throw SnappyError.malformed }
                let offset = Int(input[pos]) | (Int(input[pos + 1]) << 8)
                pos += 2
                try appendCopy(&output, offset: offset, length: length)
            default:
                // Copy, 4-byte offset.
                let length = 1 + Int(tag >> 2)
                guard pos + 4 <= n else { throw SnappyError.malformed }
                let offset = Int(readLittleEndian(input, pos, 4))
                pos += 4
                try appendCopy(&output, offset: offset, length: length)
            }
        }
        // A well-formed Snappy block decodes to exactly its preamble length; a
        // mismatch means the block was truncated/corrupt — reject it rather than
        // emit partial text as a successful decode.
        guard output.count == expectedLength else { throw SnappyError.malformed }
        return output
    }

    /// Reads the block's leading varint (the uncompressed length).
    private static func readPreambleLength(_ input: [UInt8], _ pos: inout Int) throws -> Int {
        // Accumulate in UInt64 so the shift (up to 63) is safe on 32-bit `Int`
        // platforms, then validate the result fits an `Int`.
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while pos < input.count {
            let byte = input[pos]
            pos += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                guard result <= UInt64(Int.max) else { throw SnappyError.malformed }
                return Int(result)
            }
            shift += 7
            if shift >= 64 { break }
        }
        throw SnappyError.malformed
    }

    /// Reads `count` (1...4) little-endian bytes as an unsigned integer.
    private static func readLittleEndian(_ input: [UInt8], _ start: Int, _ count: Int) -> UInt32 {
        var value: UInt32 = 0
        for k in 0 ..< count {
            value |= UInt32(input[start + k]) << (8 * k)
        }
        return value
    }

    /// Appends a back-reference copy byte-by-byte, so overlapping runs (offset <
    /// length) expand correctly — the Snappy way to encode repeats.
    private static func appendCopy(_ output: inout [UInt8], offset: Int, length: Int) throws {
        guard offset > 0, offset <= output.count else { throw SnappyError.malformed }
        var src = output.count - offset
        for _ in 0 ..< length {
            output.append(output[src])
            src += 1
        }
    }
}
