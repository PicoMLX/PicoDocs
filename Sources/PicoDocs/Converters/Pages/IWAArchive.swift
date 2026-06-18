//
//  IWAArchive.swift
//  PicoDocs
//
//  Walks a decompressed IWA object stream into (identifier, type, payload)
//  objects, and pulls plain text out of TSWP text storages.
//
//  Stream layout (after Snappy), repeated for each object:
//      varint(ArchiveInfo length) · ArchiveInfo · payload bytes
//  where
//      ArchiveInfo { uint64 identifier = 1; repeated MessageInfo message_infos = 2 }
//      MessageInfo { uint32 type = 1; uint32 length = 3 }   (other fields ignored)
//  The payload(s) follow the ArchiveInfo, one per MessageInfo, each `length`
//  bytes long. In practice iWork emits a single message per archive.
//
//  Format references: obriensp/iWorkFileFormat, the SheetJS IWA notes, and
//  Cocoanetics/SwiftText (MIT).
//

import Foundation

enum IWAArchive {

    /// The TSWP text storage message type (`TSWP.StorageArchive`): field 1 is the
    /// storage `kind` (0 = body; non-zero = header/footer/footnote/…) and field 3
    /// is `repeated string text`, the paragraph text runs. Shared across
    /// Pages/Numbers/Keynote.
    ///
    /// Confirmed against a real Pages file: 2001 is the text storage and the body
    /// is `kind == 0`. The alternate id 2005 sometimes cited for text storage did
    /// not appear there, so it's intentionally not matched (a wrong id would
    /// surface non-text payloads as garbage).
    static let textStorageType: UInt64 = 2001

    struct Object {
        let identifier: UInt64
        let type: UInt64
        let payload: [UInt8]
        /// Cross-object references (`MessageInfo.object_references`), in order —
        /// used to follow the document object graph (e.g. Keynote's slide tree).
        let references: [UInt64]
    }

    /// Parses every object in a decompressed IWA stream. Best-effort: on a
    /// truncated/garbled envelope it returns the objects parsed so far rather than
    /// throwing, so partially-recoverable files still yield text. Strict
    /// envelope-truncation detection (failing on any malformation) is deferred to
    /// the real-file-validation follow-up, to avoid mis-rejecting valid documents
    /// whose envelope quirks aren't yet covered by tests.
    static func objects(in stream: [UInt8]) -> [Object] {
        var objects: [Object] = []
        var cursor = StreamCursor(stream)
        while let archiveLen = cursor.readVarint() {
            guard archiveLen > 0, archiveLen <= UInt64(Int.max),
                  let archiveBytes = cursor.take(Int(archiveLen)) else { break }
            let infos = messageInfos(in: archiveBytes)
            guard !infos.isEmpty else { break }
            // Payloads follow the ArchiveInfo, concatenated in MessageInfo order.
            // Stop at the first failure (truncated/garbled stream, or a length past
            // `Int.max`) and return what parsed cleanly — never re-read past a
            // partially-consumed object, which would mis-parse or loop.
            for info in infos {
                guard info.length <= UInt64(Int.max),
                      let payload = cursor.take(Int(info.length)) else { return objects }
                objects.append(Object(identifier: info.identifier, type: info.type,
                                      payload: payload, references: info.references))
            }
        }
        return objects
    }

    /// Concatenated plain *body* text from the stream's TSWP text storages, in
    /// object order. Only body storages (`kind == 0`) are included — header,
    /// footer, footnote, and text-box storages (non-zero `kind`) are skipped so
    /// their text isn't passed off as the document body. Each storage's `repeated
    /// string text` runs are joined; a blank line separates distinct body storages.
    static func text(in stream: [UInt8]) -> String {
        text(from: objects(in: stream))
    }

    /// Body text from already-parsed objects — lets a caller that already has the
    /// objects (e.g. Keynote, which also needs the slide id) avoid re-parsing.
    static func text(from objects: [Object]) -> String {
        var storages: [String] = []
        for object in objects where object.type == textStorageType {
            guard let body = bodyText(in: object.payload), !body.isEmpty else { continue }
            storages.append(body)
        }
        return storages.joined(separator: "\n\n")
    }

    // MARK: - Helpers

    private struct InfoEntry {
        let identifier: UInt64
        let type: UInt64
        let length: UInt64
        let references: [UInt64]
    }

    /// Reads ArchiveInfo: identifier (field 1) + each MessageInfo (field 2) into
    /// (identifier, type, length, references) entries. Protobuf fields may be
    /// serialized in any order, so the MessageInfo payloads are collected first
    /// and stamped with the identifier only after the whole ArchiveInfo has been
    /// scanned — never assuming field 1 precedes field 2 (an archive that emitted
    /// `message_infos` first would otherwise get identifier 0, breaking the
    /// object-graph lookups, e.g. Keynote's slide-tree ordering).
    private static func messageInfos(in archiveBytes: [UInt8]) -> [InfoEntry] {
        var identifier: UInt64 = 0
        var infos: [(type: UInt64, length: UInt64, references: [UInt64])] = []
        var reader = ProtobufReader(archiveBytes)
        while let field = reader.next() {
            switch (field.number, field.value) {
            case (1, .varint(let id)):
                identifier = id
            case (2, .length(let messageInfoBytes)):
                if let info = parseMessageInfo(messageInfoBytes) { infos.append(info) }
            default:
                continue
            }
        }
        return infos.map {
            InfoEntry(identifier: identifier, type: $0.type, length: $0.length, references: $0.references)
        }
    }

    /// MessageInfo: type (field 1), payload length (field 3), and object_references
    /// (field 5 — packed or repeated uint64).
    private static func parseMessageInfo(_ bytes: [UInt8]) -> (type: UInt64, length: UInt64, references: [UInt64])? {
        var type: UInt64?
        var length: UInt64?
        var references: [UInt64] = []
        var reader = ProtobufReader(bytes)
        while let field = reader.next() {
            switch (field.number, field.value) {
            case (1, .varint(let t)): type = t
            case (3, .varint(let l)): length = l
            case (5, .varint(let r)): references.append(r)                       // unpacked
            case (5, .length(let packed)): references.append(contentsOf: unpackVarints(packed))
            default: continue
            }
        }
        guard let type, let length else { return nil }
        return (type, length, references)
    }

    /// Unpacks a protobuf packed-repeated varint field.
    private static func unpackVarints(_ bytes: [UInt8]) -> [UInt64] {
        var values: [UInt64] = []
        var cursor = StreamCursor(bytes)
        while let value = cursor.readVarint() { values.append(value) }
        return values
    }

    /// TSWP.StorageArchive: the concatenated `repeated string text` (field 3) runs,
    /// but only when this is a *body* storage — `kind` (field 1) is 0, or absent
    /// (protobuf default 0). Header/footer/footnote storages (non-zero kind) return
    /// nil so callers skip them.
    private static func bodyText(in payload: [UInt8]) -> String? {
        var runs: [String] = []
        var reader = ProtobufReader(payload)
        while let field = reader.next() {
            switch (field.number, field.value) {
            case (1, .varint(let kind)):                // StorageArchive.kind
                guard kind == 0 else { return nil }     // non-body (header/footer/…) → skip
            case (3, .length(let bytes)):               // repeated string text
                if let run = String(bytes: bytes, encoding: .utf8) { runs.append(run) }
            default:
                continue
            }
        }
        return runs.joined()                            // kind 0 or absent (default 0) = body
    }
}

/// Raw varint + slice cursor over the decompressed object stream (the IWA
/// envelope is read by hand rather than via `ProtobufReader`, which decodes
/// whole messages).
private struct StreamCursor {
    private let bytes: [UInt8]
    private var pos: Int = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func readVarint() -> UInt64? {
        guard pos < bytes.count else { return nil }
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while pos < bytes.count {
            let byte = bytes[pos]
            pos += 1
            // Reject overflow before shifting: at the 10th byte (shift 63) only the
            // low bit fits a 64-bit value; a longer varint is malformed.
            if shift == 63 {
                if byte & 0x7E != 0 { return nil }
            } else if shift >= 64 {
                return nil
            }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    mutating func take(_ count: Int) -> [UInt8]? {
        // `count <= bytes.count - pos` rather than `pos + count <= count` so a
        // hostile length near Int.max can't overflow the addition.
        guard count >= 0, count <= bytes.count - pos else { return nil }
        let slice = Array(bytes[pos ..< pos + count])
        pos += count
        return slice
    }
}
