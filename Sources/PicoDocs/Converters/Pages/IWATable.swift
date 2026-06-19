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
//      array (field 7). A cell record begins `05 <value-type>`; the value-type
//      byte selects how to read offset +12: rich text key (0x09), inline text
//      key (0x03), or a date as a double in seconds since 2001-01-01 (0x05).
//    • TST.DataList (type 6005) — the cell-value store, two flavors keyed by
//      `list_type` (field 1): rich text (`8`) maps a key (entry field 1) to a
//      RichTextPayload (entry field 9 → 6218 → 2001 TSWP.StorageArchive); inline
//      text (`1`) stores the string directly in the entry (field 3, Keynote).
//
//  Confirmed against real `.pages` and `.key` fixtures (text + date cells).
//
//  Scope: text, date, number, and formula-result cells; duration cells aren't
//  decoded yet and render empty. For Pages, tables are placed inline at their
//  attachment point (see PagesConverter); for Keynote, with the slide that owns
//  them (see KeynoteConverter).
//

import Foundation

enum IWATable {

    private static let tileType: UInt64 = 6002
    private static let dataListType: UInt64 = 6005
    private static let stringListType: UInt64 = 8       // DataList.list_type for strings
    private static let richTextPayloadType: UInt64 = 6218
    private static let storageType: UInt64 = 2001
    private static let tableModelTypes: Set<UInt64> = [6001, 6316]   // TST.TableModelArchive
    private static let inlineListType: UInt64 = 1        // DataList.list_type for inline cell text
    // Cell record value-type byte (record offset 1) selects how to read offset
    // +12: rich text key (f1==8 list), inline text key (f1==1 list), a date
    // (double, seconds since 2001-01-01), or a number / formula result (IEEE-754
    // decimal128). Duration cells aren't decoded yet.
    private static let richTextCell: UInt8 = 0x09
    private static let inlineTextCell: UInt8 = 0x03
    private static let dateCell: UInt8 = 0x05
    private static let numberCell: UInt8 = 0x02
    private static let formulaCell: UInt8 = 0x0a

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

    /// Reconstructed tables grouped by the slide that owns them: a table's tile
    /// must be reachable from that slide object, without descending into the
    /// master/template subgraphs in `blocked` (a real slide references its
    /// template directly, so otherwise its placeholder tables — which live in
    /// shared streams, not master-named components — would be pulled in). A tile is
    /// attributed to the first slide, in the given order, that reaches it. Lets
    /// Keynote place each table with its slide instead of appending all at the end.
    static func tablesBySlide(slideIDs: [UInt64], in streams: [[UInt8]],
                              excludingSubgraphs blocked: Set<UInt64>) -> [UInt64: [String]] {
        let objects = buildObjects(streams)
        let tableMarkdown = reconstructTables(objects)
        guard !tableMarkdown.isEmpty else { return [:] }
        let tiles = Set(tableMarkdown.keys)

        var result: [UInt64: [String]] = [:]
        var claimed = Set<UInt64>()
        for slideID in slideIDs {
            var markdowns: [String] = []
            for tile in reachableTiles(from: slideID, objects: objects, tiles: tiles, blocked: blocked)
            where claimed.insert(tile).inserted {
                if let markdown = tableMarkdown[tile] { markdowns.append(markdown) }
            }
            if !markdowns.isEmpty { result[slideID] = markdowns }
        }
        return result
    }

    /// Bounded breadth-first walk from a root object collecting every
    /// reconstructed table's tile reachable from it (a slide → its drawables →
    /// TableInfo → model → tile), in discovery order. References in `blocked`
    /// (master/template objects) are not traversed, so a slide can't reach its
    /// template's tables. Depth-bounded so the walk stays within a slide's own
    /// content subgraph rather than fanning out through shared objects.
    private static func reachableTiles(from root: UInt64, objects: [UInt64: IWAArchive.Object],
                                       tiles: Set<UInt64>, blocked: Set<UInt64>) -> [UInt64] {
        var frontier = [root]
        var visited: Set<UInt64> = [root]
        var found: [UInt64] = []
        for _ in 0 ..< 12 {
            var next: [UInt64] = []
            for id in frontier {
                guard let object = objects[id] else { continue }
                for reference in object.references where !blocked.contains(reference) {
                    if tiles.contains(reference), !found.contains(reference) { found.append(reference) }
                    if visited.insert(reference).inserted { next.append(reference) }
                }
            }
            if next.isEmpty { break }
            frontier = next
        }
        return found
    }

    /// Splits the document body into ordered text/table blocks, placing each
    /// reconstructed table inline at its ￼ (U+FFFC) attachment position. Returns
    /// nil — so the caller can fall back to appended tables — unless every
    /// reconstructed table is cleanly placed (e.g. it bails on a count mismatch
    /// between ￼ markers and attachment runs), so a table is never dropped.
    static func inlineBlocks(documentStream: [UInt8], in streams: [[UInt8]]) -> [Block]? {
        let objects = buildObjects(streams)
        let tableMarkdown = reconstructTables(objects)
        // No early return on an empty table set: a table-less document still
        // resolves to text-only blocks below, so the caller can use them directly
        // instead of re-parsing the whole object graph in the appended fallback.
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
    /// (6001/6316) references its tile plus the datalists backing the cells: a
    /// rich-text list (`f1==8`, via RichTextPayload → Storage) and/or an
    /// inline-text list (`f1==1`, text stored directly in the entry). Cells choose
    /// between them by value type; dates live in the cell record itself.
    private static func reconstructTables(_ objects: [UInt64: IWAArchive.Object]) -> [UInt64: String] {
        let tileIDs = Set(objects.values.filter { $0.type == tileType }.map(\.identifier))
        guard !tileIDs.isEmpty else { return [:] }

        var richMaps: [UInt64: [UInt32: String]] = [:]
        var inlineMaps: [UInt64: [UInt32: String]] = [:]
        for object in objects.values where object.type == dataListType {
            // Dispatch on list_type (field 1) so each datalist's entries are fully
            // parsed at most once — rich and inline text are mutually exclusive.
            var listType: UInt64?
            var reader = ProtobufReader(object.payload)
            while let field = reader.next() {
                if field.number == 1, case .varint(let type) = field.value { listType = type; break }
            }
            if listType == stringListType {
                if let map = richTextMap(object, objects: objects) { richMaps[object.identifier] = map }
            } else if listType == inlineListType {
                if let map = inlineTextMap(object) { inlineMaps[object.identifier] = map }
            }
        }

        var byTile: [UInt64: String] = [:]
        for object in objects.values where tableModelTypes.contains(object.type) {
            guard let tile = object.references.first(where: { tileIDs.contains($0) }), byTile[tile] == nil,
                  let tileObject = objects[tile] else { continue }
            let rich = object.references.compactMap { richMaps[$0] }.first ?? [:]
            let inline = object.references.compactMap { inlineMaps[$0] }.first ?? [:]
            if let markdown = render(grid: cellGrid(tileObject, rich: rich, inline: inline)) {
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
                    case (1, .varint(let index)): charIndex = Int(exactly: index)   // nil (skip run) on overflow
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
        var runs: [String] = []
        var reader = ProtobufReader(storage.payload)
        while let field = reader.next() {
            switch (field.number, field.value) {
            case (1, .varint(let kind)):
                guard kind == 0 else { return nil }   // header/footer/etc.: skip without decoding the rest
            case (3, .length(let bytes)):
                if let run = String(bytes: bytes, encoding: .utf8) { runs.append(run) }
            default:
                continue
            }
        }
        return runs.joined()
    }

    // MARK: - DataList (string store)

    /// Resolves a rich-text DataList (`list_type == 8`): entry key → text by
    /// following the RichTextPayload reference (field 9 → type 6218) to its
    /// TSWP.StorageArchive (2001). Returns nil for other list types or no text.
    /// Field-order independent.
    private static func richTextMap(_ object: IWAArchive.Object,
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
        guard listType == stringListType else { return nil }

        var map: [UInt32: String] = [:]
        for entry in entries {
            guard let richText = objects[entry.payload], richText.type == richTextPayloadType,
                  let storageID = referencedID(in: richText.payload),
                  let storage = objects[storageID], storage.type == storageType else { continue }
            map[entry.key] = storageText(storage.payload)
        }
        return map.isEmpty ? nil : map
    }

    /// Resolves an inline-text DataList (`list_type == 1`): entry key → text stored
    /// directly in the entry (field 3). Keynote tables (and some Pages cells) use
    /// this instead of the rich-text list. Returns nil for other types or no text.
    private static func inlineTextMap(_ object: IWAArchive.Object) -> [UInt32: String]? {
        var listType: UInt64?
        var map: [UInt32: String] = [:]
        var reader = ProtobufReader(object.payload)
        while let field = reader.next() {
            switch (field.number, field.value) {
            case (1, .varint(let type)):
                listType = type
            case (3, .length(let entryBytes)):
                var key: UInt32?
                var text: String?
                var entryReader = ProtobufReader(entryBytes)
                while let entryField = entryReader.next() {
                    switch (entryField.number, entryField.value) {
                    case (1, .varint(let k)): key = UInt32(truncatingIfNeeded: k)
                    case (3, .length(let bytes)): text = String(bytes: bytes, encoding: .utf8)
                    default: continue
                    }
                }
                if let key, let text { map[key] = text }
            default:
                continue
            }
        }
        guard listType == inlineListType else { return nil }
        return map.isEmpty ? nil : map
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

    /// Decodes a Tile into a grid of rendered cell strings (nil = absent cell).
    /// Trailing absent columns are trimmed per row.
    private static func cellGrid(_ tile: IWAArchive.Object,
                                 rich: [UInt32: String], inline: [UInt32: String]) -> [[String?]] {
        var rows: [[String?]] = []
        var reader = ProtobufReader(tile.payload)
        while let field = reader.next() {
            if field.number == 5, case .length(let rowBytes) = field.value {
                rows.append(cellTexts(inRow: rowBytes, rich: rich, inline: inline))
            }
        }
        return rows
    }

    /// One TileRowInfo: uint16 offsets (field 7) into the cell buffer (field 6);
    /// 0xFFFF marks an absent cell.
    private static func cellTexts(inRow rowBytes: [UInt8],
                                  rich: [UInt32: String], inline: [UInt32: String]) -> [String?] {
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
        var cells: [String?] = []
        var i = 0
        while i + 1 < offsets.count {
            let offset = Int(offsets[i]) | (Int(offsets[i + 1]) << 8)
            i += 2
            cells.append(offset == 0xFFFF ? nil : cellText(in: buffer, at: offset, rich: rich, inline: inline))
        }
        while let last = cells.last, last == nil { cells.removeLast() }   // trim trailing absent cells
        return cells
    }

    /// The rendered text of a cell record (`05 <type> …`): rich or inline text via
    /// the string maps (key is a little-endian uint32 at +12), or a date (double,
    /// seconds since 2001-01-01, at +12), or a number / formula result (decimal128
    /// at +12). Duration cells aren't decoded yet. Returns "" (a present-but-empty
    /// cell) on any unhandled type or out-of-bounds read.
    private static func cellText(in buffer: [UInt8], at offset: Int,
                                 rich: [UInt32: String], inline: [UInt32: String]) -> String {
        guard offset >= 0, offset + 2 <= buffer.count, buffer[offset] == 0x05 else { return "" }
        switch buffer[offset + 1] {
        case richTextCell:
            guard let key = readUInt32(buffer, at: offset + 12) else { return "" }
            return cleanCell(rich[key] ?? "")
        case inlineTextCell:
            guard let key = readUInt32(buffer, at: offset + 12) else { return "" }
            return cleanCell(inline[key] ?? "")
        case dateCell:
            guard let seconds = readDouble(buffer, at: offset + 12) else { return "" }
            return isoDate(seconds)
        case numberCell, formulaCell:
            return decimalString(in: buffer, at: offset + 12)
        default:
            return ""
        }
    }

    /// A number or formula-result cell stores its value as an IEEE-754 decimal128
    /// (16 bytes, little-endian) at offset +12. Decodes the common case
    /// (coefficient up to 64 bits) into a plain decimal string; returns "" for the
    /// large-coefficient form, an out-of-range exponent, or out-of-bounds.
    private static func decimalString(in buffer: [UInt8], at offset: Int) -> String {
        guard offset >= 0, offset + 16 <= buffer.count else { return "" }
        let high = buffer[offset + 15]
        guard (high >> 5) & 0x3 != 0x3 else { return "" }     // large-coefficient form
        let exponent = ((Int(high & 0x7F) << 7) | Int(buffer[offset + 14] >> 1)) - 6176
        guard exponent >= -128, exponent <= 128 else { return "" }
        // Coefficient is the low 113 bits; supported when it fits in 64 bits.
        guard buffer[offset + 14] & 1 == 0 else { return "" }
        for k in 8 ..< 14 where buffer[offset + k] != 0 { return "" }
        var coefficient: UInt64 = 0
        for k in 0 ..< 8 { coefficient |= UInt64(buffer[offset + k]) << (8 * k) }
        return formatDecimal(negative: high & 0x80 != 0, coefficient: coefficient, exponent: exponent)
    }

    /// Formats `coefficient × 10^exponent` as a plain decimal string, trimming
    /// trailing fractional zeros (e.g. 420×10⁻² → "4.2", 35×10⁻² → "0.35").
    private static func formatDecimal(negative: Bool, coefficient: UInt64, exponent: Int) -> String {
        var result: String
        if exponent >= 0 {
            result = String(coefficient) + String(repeating: "0", count: exponent)
        } else {
            var digits = String(coefficient)
            let fractionCount = -exponent
            if digits.count <= fractionCount {
                digits = String(repeating: "0", count: fractionCount - digits.count + 1) + digits
            }
            let split = digits.index(digits.endIndex, offsetBy: -fractionCount)
            let integerPart = String(digits[..<split])
            var fractionPart = String(digits[split...])
            while fractionPart.hasSuffix("0") { fractionPart.removeLast() }
            result = fractionPart.isEmpty ? integerPart : integerPart + "." + fractionPart
        }
        if result.isEmpty { result = "0" }
        return (negative && result != "0") ? "-" + result : result
    }

    private static func readUInt32(_ buffer: [UInt8], at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= buffer.count else { return nil }
        return UInt32(buffer[offset]) | (UInt32(buffer[offset + 1]) << 8)
            | (UInt32(buffer[offset + 2]) << 16) | (UInt32(buffer[offset + 3]) << 24)
    }

    private static func readDouble(_ buffer: [UInt8], at offset: Int) -> Double? {
        guard offset >= 0, offset + 8 <= buffer.count else { return nil }
        var bits: UInt64 = 0
        for k in 0 ..< 8 { bits |= UInt64(buffer[offset + k]) << (8 * k) }
        return Double(bitPattern: bits)
    }

    /// Formats seconds-since-2001 (iWork's reference date) as `yyyy-MM-dd`.
    /// Computed arithmetically — no `DateFormatter`, which is allocation-free and
    /// avoids a shared static formatter (not `Sendable` under Swift 6). Implausible
    /// magnitudes return "".
    private static func isoDate(_ secondsSinceReference: Double) -> String {
        guard secondsSinceReference.isFinite, abs(secondsSinceReference) < 4e11 else { return "" }
        // Days since 1970-01-01 (2001-01-01 is 11_323 days after 1970-01-01).
        let days = Int((secondsSinceReference / 86_400).rounded(.down)) + 11_323
        // Howard Hinnant's civil-from-days algorithm.
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        func pad(_ value: Int, _ width: Int) -> String {
            var string = String(value)
            while string.count < width { string = "0" + string }
            return string
        }
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))"
    }

    // MARK: - Markdown rendering

    /// Renders a grid of cell strings as a GitHub-flavored Markdown table (first
    /// row is the header). Returns nil if there are no columns or no non-empty
    /// cell, so empty/placeholder tables are skipped.
    private static func render(grid: [[String?]]) -> String? {
        let rows: [[String]] = grid.map { row in row.map { $0 ?? "" } }
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
