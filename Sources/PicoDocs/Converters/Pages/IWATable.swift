//
//  IWATable.swift
//  PicoDocs
//
//  Reconstructs Apple iWork (Pages/Numbers/Keynote) tables from decompressed IWA
//  object streams into GitHub-flavored Markdown grid tables.
//
//  A table is assembled from three object kinds, joined through the document
//  object graph (`MessageInfo.object_references`):
//
//    • TST.TableModelArchive (type 6001 / 6316) — the table itself; its
//      references point at exactly one Tile and the DataLists backing its
//      columns (one per aspect: strings, formats, styles, …).
//    • TST.Tile (type 6002) — the cell grid: `repeated TileRowInfo` (field 5),
//      each row carrying a packed cell buffer (field 6) and a uint16 offset
//      array (field 7). A string cell record begins with the bytes `05 09` and
//      stores its string key as a little-endian uint32 at byte offset 12.
//    • TST.DataList (type 6005) with `list_type == 8` (field 1) — the string
//      store: `repeated entry` (field 3) mapping a key (field 1) to a
//      RichTextPayload reference (field 9 → type 6218 → type 2001
//      TSWP.StorageArchive, whose `repeated string text` is the cell text).
//
//  Confirmed against a real `.pages` fixture (two text tables, 5×4 and 4×6,
//  including empty cells and Unicode/URL content).
//
//  Scope (v1): text cells only — numeric/date/formula cells render as empty
//  cells. Tables are emitted as standalone sections appended after the body
//  rather than positioned inline at their attachment point (see README).
//

import Foundation

enum IWATable {

    private static let tileType: UInt64 = 6002
    private static let dataListType: UInt64 = 6005
    private static let stringListType: UInt64 = 8       // DataList.list_type for strings
    private static let richTextPayloadType: UInt64 = 6218
    private static let storageType: UInt64 = 2001
    private static let tableModelTypes: Set<UInt64> = [6001, 6316]   // TST.TableModelArchive

    /// One ordered piece of a converted body — a run of text or a reconstructed
    /// table, in reading order. Text is raw; the caller normalizes it.
    enum Block: Equatable {
        case text(String)
        case table(String)
    }

    /// Every text table across the given decompressed IWA streams, rendered as
    /// Markdown and ordered by tile identifier (a stable proxy for document
    /// order). This is the appended-table fallback; `inlineBlocks` instead places
    /// tables at their attachment points. Best-effort: a document with no tables
    /// yields `[]`.
    static func markdownTables(from streams: [[UInt8]]) -> [String] {
        let byTile = reconstructTables(buildObjects(streams))
        return byTile.keys.sorted().compactMap { byTile[$0] }
    }

    /// Splits the document body into ordered text/table blocks, placing each
    /// reconstructed table inline at its ￼ (U+FFFC) attachment position. Returns
    /// nil — so the caller can fall back to appended tables — unless every
    /// reconstructed table is cleanly placed (e.g. it bails on a count mismatch
    /// between ￼ markers and attachment runs), so a table is never dropped.
    static func inlineBlocks(documentStream: [UInt8], in streams: [[UInt8]]) -> [Block]? {
        let objects = buildObjects(streams)
        let tableMarkdown = reconstructTables(objects)
        guard !tableMarkdown.isEmpty else { return nil }
        let tiles = Set(tableMarkdown.keys)

        var blocks: [Block] = []
        var placed = Set<UInt64>()
        // Body storages in document (stream) order; each carries its own text
        // (field 3) and drawable attachment runs (field 9).
        for storage in IWAArchive.objects(in: documentStream) where storage.type == storageType {
            guard let text = bodyStorageText(storage) else { continue }    // kind 0 only
            let runs = attachmentRuns(in: storage)
            let markers = text.indices.filter { text[$0] == "\u{FFFC}" }
            guard markers.count == runs.count else { return nil }          // can't map 1:1

            var buffer = ""
            var segmentStart = text.startIndex
            for (marker, run) in zip(markers, runs) {
                buffer += String(text[segmentStart..<marker])
                segmentStart = text.index(after: marker)                   // always drop the ￼
                guard let tile = reachableTile(from: run.objectID, objects: objects, tiles: tiles),
                      let markdown = tableMarkdown[tile] else { continue }  // non-table (image): merge text
                if !buffer.isEmpty { blocks.append(.text(buffer)); buffer = "" }
                blocks.append(.table(markdown))
                placed.insert(tile)
            }
            buffer += String(text[segmentStart...])
            if !buffer.isEmpty { blocks.append(.text(buffer)) }
        }
        // Commit to inline layout only if every reconstructed table found a home.
        return placed == tiles ? blocks : nil
    }

    // MARK: - Object graph

    private static func buildObjects(_ streams: [[UInt8]]) -> [UInt64: IWAArchive.Object] {
        var objects: [UInt64: IWAArchive.Object] = [:]
        for stream in streams {
            for object in IWAArchive.objects(in: stream) { objects[object.identifier] = object }
        }
        return objects
    }

    /// Maps each content table's tile id to its rendered Markdown. A table model
    /// (6001/6316) references exactly one tile and the datalist holding its
    /// strings; restricting to those types avoids mistaking an unrelated object
    /// that references both for a table.
    private static func reconstructTables(_ objects: [UInt64: IWAArchive.Object]) -> [UInt64: String] {
        let tileIDs = Set(objects.values.filter { $0.type == tileType }.map(\.identifier))
        guard !tileIDs.isEmpty else { return [:] }

        var stringLists: [UInt64: [UInt32: String]] = [:]
        for object in objects.values where object.type == dataListType {
            if let map = stringList(object, objects: objects), !map.isEmpty {
                stringLists[object.identifier] = map
            }
        }
        guard !stringLists.isEmpty else { return [:] }

        var byTile: [UInt64: String] = [:]
        for object in objects.values where tableModelTypes.contains(object.type) {
            guard let tile = object.references.first(where: { tileIDs.contains($0) }),
                  let strings = object.references.first(where: { stringLists[$0] != nil }),
                  byTile[tile] == nil,
                  let tileObject = objects[tile], let stringMap = stringLists[strings] else { continue }
            if let markdown = render(grid: cellKeyGrid(tileObject), strings: stringMap) {
                byTile[tile] = markdown
            }
        }
        return byTile
    }

    // MARK: - Inline attachments

    /// A body storage's drawable attachment runs (field 9, a wrapper of repeated
    /// runs), sorted by character index. Each run pairs a ￼ with the attached
    /// object's id; for a table that object (TSWP attachment, type 2003) leads on
    /// to the TableInfo → model → tile.
    private static func attachmentRuns(in storage: IWAArchive.Object) -> [(charIndex: Int, objectID: UInt64)] {
        var runs: [(charIndex: Int, objectID: UInt64)] = []
        var reader = ProtobufReader(storage.payload)
        while let field = reader.next() {
            guard field.number == 9, case .length(let wrapper) = field.value else { continue }
            var wrapperReader = ProtobufReader(wrapper)
            while let entry = wrapperReader.next() {
                guard entry.number == 1, case .length(let runBytes) = entry.value else { continue }
                var charIndex: Int?
                var objectID: UInt64?
                var runReader = ProtobufReader(runBytes)
                while let runField = runReader.next() {
                    switch (runField.number, runField.value) {
                    case (1, .varint(let index)): charIndex = Int(index)
                    case (2, .length(let reference)): objectID = referencedID(in: reference)
                    default: continue
                    }
                }
                if let charIndex, let objectID { runs.append((charIndex, objectID)) }
            }
        }
        return runs.sorted { $0.charIndex < $1.charIndex }
    }

    /// Bounded breadth-first walk from an attachment object to a referenced tile
    /// (2003 → TableInfo 6000 → model 6001/6316 → tile 6002), returning the first
    /// tile that has a reconstructed table — or nil (e.g. for an image).
    private static func reachableTile(from start: UInt64, objects: [UInt64: IWAArchive.Object],
                                      tiles: Set<UInt64>) -> UInt64? {
        var frontier = [start]
        var visited: Set<UInt64> = [start]
        for _ in 0..<5 {
            var next: [UInt64] = []
            for id in frontier {
                guard let object = objects[id] else { continue }
                for reference in object.references {
                    if tiles.contains(reference) { return reference }
                    if visited.insert(reference).inserted { next.append(reference) }
                }
            }
            if next.isEmpty { break }
            frontier = next
        }
        return nil
    }

    /// A storage's body text (concatenated `repeated string text`, field 3) when
    /// it's a body storage (`kind` 0 or absent); nil for header/footer/etc.
    private static func bodyStorageText(_ storage: IWAArchive.Object) -> String? {
        var kind: UInt64 = 0
        var runs: [String] = []
        var reader = ProtobufReader(storage.payload)
        while let field = reader.next() {
            switch (field.number, field.value) {
            case (1, .varint(let value)): kind = value
            case (3, .length(let bytes)):
                if let run = String(bytes: bytes, encoding: .utf8) { runs.append(run) }
            default: continue
            }
        }
        return kind == 0 ? runs.joined() : nil
    }

    // MARK: - DataList (string store)

    /// For a `list_type == 8` DataList, resolves entry key -> text by following
    /// each entry's RichTextPayload reference (6218) to its TSWP.StorageArchive
    /// (2001). Returns nil for non-string lists. Field order independent.
    private static func stringList(_ object: IWAArchive.Object,
                                   objects: [UInt64: IWAArchive.Object]) -> [UInt32: String]? {
        var listType: UInt64?
        var entries: [(key: UInt32, payload: UInt64)] = []
        var reader = ProtobufReader(object.payload)
        while let field = reader.next() {
            switch (field.number, field.value) {
            case (1, .varint(let type)):
                listType = type
            case (3, .length(let entryBytes)):
                if let entry = dataListEntry(entryBytes) { entries.append(entry) }
            default:
                continue
            }
        }
        guard let listType, listType == stringListType else { return nil }

        var map: [UInt32: String] = [:]
        for entry in entries {
            guard let richText = objects[entry.payload], richText.type == richTextPayloadType,
                  let storageID = referencedID(in: richText.payload),
                  let storage = objects[storageID], storage.type == storageType else { continue }
            map[entry.key] = storageText(storage.payload)
        }
        return map
    }

    /// One DataList entry: key (field 1) + RichTextPayload id (field 9 → field 1).
    private static func dataListEntry(_ bytes: [UInt8]) -> (key: UInt32, payload: UInt64)? {
        var key: UInt32?
        var payload: UInt64?
        var reader = ProtobufReader(bytes)
        while let field = reader.next() {
            switch (field.number, field.value) {
            case (1, .varint(let k)):
                key = UInt32(truncatingIfNeeded: k)
            case (9, .length(let sub)):
                payload = referencedID(in: sub)
            default:
                continue
            }
        }
        guard let key, let payload else { return nil }
        return (key, payload)
    }

    /// Reads a referenced object id out of field 1 — either a bare varint id or a
    /// TSP.Reference sub-message whose field 1 is the id. Used for both the
    /// DataList entry → RichTextPayload and RichTextPayload → Storage hops.
    private static func referencedID(in bytes: [UInt8]) -> UInt64? {
        var reader = ProtobufReader(bytes)
        while let field = reader.next() {
            guard field.number == 1 else { continue }
            switch field.value {
            case .varint(let id):
                return id
            case .length(let sub):
                if let id = referencedID(in: sub) { return id }
            default:
                continue
            }
        }
        return nil
    }

    /// TSWP.StorageArchive text: the concatenated `repeated string text` (field 3).
    private static func storageText(_ payload: [UInt8]) -> String {
        var runs: [String] = []
        var reader = ProtobufReader(payload)
        while let field = reader.next() {
            if field.number == 3, case .length(let bytes) = field.value,
               let run = String(bytes: bytes, encoding: .utf8) {
                runs.append(run)
            }
        }
        return runs.joined()
    }

    // MARK: - Tile (cell grid)

    /// Decodes a Tile into a grid of per-cell string keys (nil = empty or
    /// non-text cell). Trailing empty columns are trimmed per row.
    private static func cellKeyGrid(_ tile: IWAArchive.Object) -> [[UInt32?]] {
        var rows: [[UInt32?]] = []
        var reader = ProtobufReader(tile.payload)
        while let field = reader.next() {
            if field.number == 5, case .length(let rowBytes) = field.value {
                rows.append(cellKeys(inRow: rowBytes))
            }
        }
        return rows
    }

    /// One TileRowInfo: uint16 offsets (field 7) into the cell buffer (field 6);
    /// 0xFFFF marks an absent cell.
    private static func cellKeys(inRow rowBytes: [UInt8]) -> [UInt32?] {
        var buffer: [UInt8] = []
        var offsets: [UInt8] = []
        var reader = ProtobufReader(rowBytes)
        while let field = reader.next() {
            switch (field.number, field.value) {
            case (6, .length(let bytes)): buffer = bytes
            case (7, .length(let bytes)): offsets = bytes
            default: continue
            }
        }
        var keys: [UInt32?] = []
        var i = 0
        while i + 1 < offsets.count {
            let offset = Int(offsets[i]) | (Int(offsets[i + 1]) << 8)
            i += 2
            keys.append(offset == 0xFFFF ? nil : stringKey(inCell: buffer, at: offset))
        }
        while let last = keys.last, last == nil { keys.removeLast() }   // trim trailing empties
        return keys
    }

    /// The string key stored in a cell record, or nil if it isn't a string cell
    /// (`05 09` marker) or would read out of bounds. The key is a little-endian
    /// uint32 at byte offset 12.
    private static func stringKey(inCell buffer: [UInt8], at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 16 <= buffer.count,
              buffer[offset] == 0x05, buffer[offset + 1] == 0x09 else { return nil }
        let k = offset + 12
        return UInt32(buffer[k]) | (UInt32(buffer[k + 1]) << 8)
            | (UInt32(buffer[k + 2]) << 16) | (UInt32(buffer[k + 3]) << 24)
    }

    // MARK: - Markdown rendering

    /// Renders a key grid + string map as a GitHub-flavored Markdown table (first
    /// row is the header). Returns nil if there are no columns or no resolvable
    /// text, so empty/placeholder tables are skipped.
    private static func render(grid: [[UInt32?]], strings: [UInt32: String]) -> String? {
        let rows: [[String]] = grid.map { row in
            row.map { key in
                guard let key, let text = strings[key] else { return "" }
                return cleanCell(text)
            }
        }
        let columnCount = rows.map(\.count).max() ?? 0
        guard columnCount > 0,
              rows.contains(where: { $0.contains { !$0.isEmpty } }) else { return nil }

        func line(_ row: [String]) -> String {
            let padded = row + Array(repeating: "", count: max(0, columnCount - row.count))
            return "| " + padded.joined(separator: " | ") + " |"
        }
        var lines = [line(rows[0])]
        lines.append("| " + Array(repeating: "---", count: columnCount).joined(separator: " | ") + " |")
        for row in rows.dropFirst() { lines.append(line(row)) }
        return lines.joined(separator: "\n")
    }

    /// Cleans a cell's raw storage text for a Markdown table cell, mirroring
    /// `PagesConverter.normalize`:
    ///  • folds every line/paragraph separator (CR-LF, CR, LF, and the Unicode
    ///    separators iWork uses) to a single space so a multi-line cell stays on
    ///    one row — CR-LF first, so it collapses to one space, not two;
    ///  • drops the U+FFFC object-replacement sentinel (image / embedded-object
    ///    placeholders) and C0/C1 control characters that aren't real text, so a
    ///    placeholder-only cell becomes empty (and an all-placeholder table is
    ///    skipped) rather than rendering as visible garbage;
    ///  • escapes backslash and pipe so the text can't break the table; and
    ///  • trims surrounding whitespace.
    private static func cleanCell(_ text: String) -> String {
        var folded = text
        for separator in ["\r\n", "\r", "\n", "\u{2028}", "\u{2029}", "\u{000B}", "\u{000C}"] {
            folded = folded.replacingOccurrences(of: separator, with: " ")
        }
        var scalars = folded.unicodeScalars
        scalars.removeAll { scalar in
            let value = scalar.value
            guard value != 0x09 else { return false }        // keep tab
            return value <= 0x1F                              // C0 controls
                || (0x7F...0x9F).contains(value)             // DEL + C1 controls
                || value == 0xFFFC                           // object-replacement placeholder
        }
        let escaped = String(scalars)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
        return escaped.trimmingCharacters(in: .whitespaces)
    }
}
