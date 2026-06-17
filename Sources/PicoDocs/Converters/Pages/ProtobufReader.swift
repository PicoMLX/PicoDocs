//
//  ProtobufReader.swift
//  PicoDocs
//
//  A tiny protobuf *wire-format* reader — just enough to walk iWork's IWA
//  messages without the proprietary `.proto` schemas. We never model full message
//  types: the IWA envelope (`ArchiveInfo` / `MessageInfo`) and the text storage
//  (`TSWP.StorageArchive`) are read by field number alone.
//
//  Wire types handled: varint (0), 64-bit (1), length-delimited (2), 32-bit (5).
//  Groups (3/4, deprecated) end iteration. The reader is best-effort: malformed
//  input stops iteration (returns nil) rather than throwing, so one odd field
//  can't abort a whole document.
//

import Foundation

struct ProtobufReader {

    enum Value: Equatable {
        case varint(UInt64)
        case length([UInt8])      // strings, sub-messages, packed repeated
        case fixed64(UInt64)
        case fixed32(UInt32)
    }

    struct Field {
        let number: Int
        let value: Value
    }

    private let bytes: [UInt8]
    private var pos: Int
    private let end: Int

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.pos = 0
        self.end = bytes.count
    }

    /// Returns the next field, or nil at end of message / on malformed input.
    mutating func next() -> Field? {
        guard pos < end, let tag = readVarint() else { return nil }
        let number = Int(tag >> 3)
        let wireType = Int(tag & 0x07)
        guard number > 0 else { return nil }
        switch wireType {
        case 0:
            guard let v = readVarint() else { return nil }
            return Field(number: number, value: .varint(v))
        case 1:
            guard let v = readFixed(8) else { return nil }
            return Field(number: number, value: .fixed64(v))
        case 2:
            guard let len = readVarint() else { return nil }
            let length = Int(len)
            guard length >= 0, pos + length <= end else { return nil }
            let sub = Array(bytes[pos ..< pos + length])
            pos += length
            return Field(number: number, value: .length(sub))
        case 5:
            guard let v = readFixed(4) else { return nil }
            return Field(number: number, value: .fixed32(UInt32(truncatingIfNeeded: v)))
        default:
            // Groups / unknown wire types: stop.
            return nil
        }
    }

    private mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while pos < end {
            let byte = bytes[pos]
            pos += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    private mutating func readFixed(_ count: Int) -> UInt64? {
        guard pos + count <= end else { return nil }
        var value: UInt64 = 0
        for k in 0 ..< count {
            value |= UInt64(bytes[pos + k]) << (8 * k)
        }
        pos += count
        return value
    }
}
