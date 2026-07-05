//
//  IWATable.swift
//  PicoDocs
//
//  Reconstructs Apple iWork (Pages/Numbers/Keynote) tables from decompressed IWA
//  object streams into GitHub-flavored Markdown grid tables, and (via
//  `inlineBlocks`) renders the Pages body as paragraphs with Markdown headings,
//  bullet/numbered lists, inline bold/italic emphasis, and hyperlinks,
//  interleaving each table at its attachment point.
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
    private static let hyperlinkFieldType: UInt64 = 2032   // TSWP.HyperlinkFieldArchive (smart field)
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

    /// Splits the document body into ordered text/table blocks: body text is
    /// rendered paragraph-by-paragraph with Markdown headings (from each paragraph's
    /// ParagraphStyle) and inline emphasis/links (character styles and hyperlink
    /// smart fields), and each reconstructed table is placed inline at its ￼
    /// (U+FFFC) attachment position. Returns nil — so the caller can fall back to
    /// appended tables — only when the ￼ markers can't be matched 1:1 to attachment
    /// runs, so a table is never dropped. Offsets are UTF-16 code units, the index
    /// space iWork's run/attachment character indices use.
    static func inlineBlocks(documentStream: [UInt8], in streams: [[UInt8]]) -> [Block]? {
        let objects = buildObjects(streams)
        let tableMarkdown = reconstructTables(objects)
        let tiles = Set(tableMarkdown.keys)

        var blocks: [Block] = []
        var placed = Set<UInt64>()
        // Body storages in document (stream) order; each carries its own text and
        // run tables (paragraph/character styles, smart fields) and attachments.
        for storage in IWAArchive.objects(in: documentStream) where storage.type == storageType {
            guard let body = bodyStorage(storage, objects: objects) else { continue }   // kind 0 only
            let attachments = attachmentRuns(in: storage)
            let markers = body.units.indices.filter { body.units[$0] == 0xFFFC }
            guard markers.count == attachments.count else { return nil }    // can't map 1:1

            // Split the body only at table attachments; non-table markers (inline
            // images) stay in the text and are dropped during paragraph rendering,
            // so an image mid-paragraph doesn't break the paragraph into two blocks.
            var segmentStart = 0
            for (marker, attachment) in zip(markers, attachments) {
                guard let tile = reachableTile(from: attachment.objectID, objects: objects, tiles: tiles),
                      let markdown = tableMarkdown[tile] else { continue }  // image: leave ￼ in the text
                let segment = renderParagraphs(body, segmentStart ..< marker, objects: objects)
                if !segment.isEmpty { blocks.append(.text(segment)) }
                blocks.append(.table(markdown))
                placed.insert(tile)
                segmentStart = marker + 1                                   // drop the table ￼
            }
            let tail = renderParagraphs(body, segmentStart ..< body.units.count, objects: objects)
            if !tail.isEmpty { blocks.append(.text(tail)) }
        }
        // Commit to inline layout only if every reconstructed table found a home.
        return placed == tiles ? blocks : nil
    }

    /// The document body rendered as heading-aware Markdown *without* inline tables.
    /// Used by PagesConverter's fallback (when `inlineBlocks` bails on table
    /// placement) so styles still produce Markdown while the tables are appended
    /// separately; attachment marks are dropped. Empty when there is no body text,
    /// so the caller can degrade to plain extraction.
    static func bodyMarkdown(documentStream: [UInt8], in streams: [[UInt8]]) -> String {
        let objects = buildObjects(streams)
        var parts: [String] = []
        for storage in IWAArchive.objects(in: documentStream) where storage.type == storageType {
            guard let body = bodyStorage(storage, objects: objects) else { continue }
            let rendered = renderParagraphs(body, 0 ..< body.units.count, objects: objects)
            if !rendered.isEmpty { parts.append(rendered) }
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Body storage

    /// One body storage prepared for rendering: its UTF-16 units plus the run tables
    /// it carries — paragraph styles (field 5 → headings), character styles (field 8
    /// → emphasis), smart fields (field 11 → hyperlinks) and list styles (field 7 →
    /// bullets/numbers) — with character-style traits, link URLs and list markers
    /// pre-resolved so rendering needs no further object lookups.
    private struct BodyStorage {
        let units: [UInt16]
        let paragraphStyles: [(offset: Int, id: UInt64?)]
        let characterStyles: [(offset: Int, id: UInt64?)]
        let smartFields: [(offset: Int, id: UInt64?)]
        let listStyles: [(offset: Int, id: UInt64?)]
        let traits: [UInt64: (bold: Bool, italic: Bool)]
        let links: [UInt64: String]
        let listMarkers: [UInt64: ListMarker]
    }

    /// Builds a `BodyStorage` for a kind-0 text storage, or nil for a header/footer
    /// (non-body) storage.
    private static func bodyStorage(_ storage: IWAArchive.Object,
                                    objects: [UInt64: IWAArchive.Object]) -> BodyStorage? {
        guard let text = bodyStorageText(storage) else { return nil }       // kind 0 only
        let characterStyles = indexedReferences(in: storage, field: 8)
        let smartFields = indexedReferences(in: storage, field: 11)
        let listStyles = indexedReferences(in: storage, field: 7)
        var traits: [UInt64: (bold: Bool, italic: Bool)] = [:]
        for id in Set(characterStyles.compactMap(\.id)) { traits[id] = characterTraits(of: id, in: objects) }
        var links: [UInt64: String] = [:]
        for id in Set(smartFields.compactMap(\.id)) where objects[id]?.type == hyperlinkFieldType {
            if let url = hyperlinkURL(of: id, in: objects) { links[id] = url }
        }
        var listMarkers: [UInt64: ListMarker] = [:]
        for id in Set(listStyles.compactMap(\.id)) {
            if let marker = listMarker(of: id, in: objects) { listMarkers[id] = marker }
        }
        return BodyStorage(units: Array(text.utf16),
                           paragraphStyles: indexedReferences(in: storage, field: 5),
                           characterStyles: characterStyles, smartFields: smartFields,
                           listStyles: listStyles, traits: traits, links: links, listMarkers: listMarkers)
    }

    // MARK: - Paragraph rendering

    /// The Markdown list marker a ListStyle produces at the base indent level.
    private enum ListMarker { case bullet, ordered }

    /// A rendered paragraph: a heading (never takes a list marker and breaks an
    /// ordered run) or a body paragraph (may become a list item).
    private enum RenderedParagraph { case heading(String), body(String) }

    /// Renders a UTF-16 range as Markdown: split into paragraphs at true paragraph
    /// separators (not soft line breaks) and render each — a heading prefixed with
    /// `#`s, a list item prefixed with `-`/`N.`, otherwise a plain body paragraph
    /// (all with inline emphasis/links). Consecutive items of the same list render
    /// tight (one newline); everything else is separated by a blank line. Interior
    /// whitespace and soft breaks are left for `PagesConverter.normalize` to fold.
    private static func renderParagraphs(_ body: BodyStorage, _ range: Range<Int>,
                                         objects: [UInt64: IWAArchive.Object]) -> String {
        var parts: [(text: String, list: UInt64?)] = []   // list = list-style id, nil for non-items
        var orderedList: UInt64?                           // style of the ordered run currently counting
        var counter = 0
        var start = range.lowerBound
        var index = range.lowerBound
        while index <= range.upperBound {
            if index == range.upperBound || isParagraphSeparator(body.units[index]) {
                switch renderParagraph(body, start ..< index, objects: objects) {
                case .heading(let text)?:
                    orderedList = nil
                    parts.append((text, nil))
                case .body(let text)?:
                    let listStyle = referenceID(at: start, in: body.listStyles)
                    switch listStyle.flatMap({ body.listMarkers[$0] }) {
                    case .bullet?:
                        orderedList = nil
                        parts.append(("- " + text, listStyle))
                    case .ordered?:
                        if listStyle != orderedList { counter = 0; orderedList = listStyle }
                        counter += 1
                        parts.append(("\(counter). " + text, listStyle))
                    case nil:
                        orderedList = nil
                        parts.append((text, nil))
                    }
                case nil:
                    break
                }
                start = index + 1
            }
            index += 1
        }
        var output = ""
        for (i, part) in parts.enumerated() {
            if i > 0 {
                let tight = part.list != nil && part.list == parts[i - 1].list
                output += tight ? "\n" : "\n\n"
            }
            output += part.text
        }
        return output
    }

    /// Only true paragraph terminators split paragraphs; soft line breaks (U+2028,
    /// U+000B, U+000C) stay inside the paragraph and become newlines via `normalize`.
    private static func isParagraphSeparator(_ unit: UInt16) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2029
    }

    /// One paragraph rendered to Markdown, or nil when it holds no text. A heading is
    /// flattened to a single, space-separated line and not emphasized (it's already a
    /// heading) but keeps its hyperlinks; a body paragraph keeps its interior spacing
    /// and gains inline emphasis and hyperlinks. The list marker (if any) is applied
    /// by `renderParagraphs`, which holds the ordered-list counter.
    private static func renderParagraph(_ body: BodyStorage, _ range: Range<Int>,
                                        objects: [UInt64: IWAArchive.Object]) -> RenderedParagraph? {
        let style = majorityStyle(body.units, body.paragraphStyles, range, total: body.units.count)
        if let level = headingLevel(styleName(style, objects: objects)) {
            let label = renderInline(body, range, emphasis: false)   // links kept, emphasis suppressed
            guard !label.isEmpty else { return nil }
            let line = label.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            return .heading(String(repeating: "#", count: level) + " " + line)
        }
        let rendered = renderInline(body, range)
        return rendered.isEmpty ? nil : .body(rendered)
    }

    // MARK: - Inline emphasis & links

    /// Renders a paragraph's text with inline hyperlinks and — when `emphasis` is on
    /// — bold/italic. Visible units are grouped first by hyperlink (so a link is a
    /// single `[label](url)`), then by bold/italic within. Soft breaks
    /// (U+000B/U+000C/U+2028) are kept for `PagesConverter.normalize` to fold to
    /// newlines, but the attachment placeholder and the controls `normalize` deletes
    /// are skipped so markup never wraps a character that later vanishes (e.g. a bold
    /// section-break sentinel leaving a stray `****`). Headings pass `emphasis: false`
    /// (already emphasized) but keep their links.
    private static func renderInline(_ body: BodyStorage, _ range: Range<Int>,
                                     emphasis: Bool = true) -> String {
        var items: [(unit: UInt16, bold: Bool, italic: Bool, url: String?)] = []
        for index in range {
            let unit = body.units[index]
            if unit == 0xFFFC || isStrippedControl(unit) { continue }
            var trait: (bold: Bool, italic: Bool)?
            if emphasis { trait = referenceID(at: index, in: body.characterStyles).flatMap { body.traits[$0] } }
            let url = referenceID(at: index, in: body.smartFields).flatMap { body.links[$0] }
            items.append((unit, trait?.bold ?? false, trait?.italic ?? false, url))
        }
        var output = ""
        var i = 0
        while i < items.count {
            let url = items[i].url
            var j = i
            while j < items.count, items[j].url == url { j += 1 }
            let inner = renderEmphasis(items[i ..< j])
            if let url, !inner.isEmpty {
                output += "[\(escapeLinkLabel(inner))](\(escapeLinkDestination(url)))"
            } else {
                output += inner
            }
            i = j
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Renders a run of attributed units (constant hyperlink) by grouping consecutive
    /// units with the same bold/italic and wrapping each group with emphasis markers.
    private static func renderEmphasis(_ items: ArraySlice<(unit: UInt16, bold: Bool, italic: Bool, url: String?)>) -> String {
        var output = ""
        var i = items.startIndex
        while i < items.endIndex {
            let bold = items[i].bold
            let italic = items[i].italic
            var j = i
            while j < items.endIndex, items[j].bold == bold, items[j].italic == italic { j += 1 }
            let text = String(decoding: items[i ..< j].map(\.unit), as: UTF16.self)
            output += emphasize(text, bold: bold, italic: italic)
            i = j
        }
        return output
    }

    /// Wraps `text` in `**`/`*` for bold/italic, keeping the markers hugging the text
    /// (` **word** ` rather than `** word **`), matching the other converters.
    private static func emphasize(_ text: String, bold: Bool, italic: Bool) -> String {
        guard bold || italic else { return text }
        let isSpace: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        let afterLeading = text.drop(while: isSpace)
        let leading = String(text.prefix(text.count - afterLeading.count))
        let trailingCount = afterLeading.reversed().prefix(while: isSpace).count
        let trailing = String(afterLeading.suffix(trailingCount))
        var core = String(afterLeading.dropLast(trailingCount))
        guard !core.isEmpty else { return text }
        if italic { core = "*\(core)*" }
        if bold { core = "**\(core)**" }
        return leading + core + trailing
    }

    private static func escapeLinkLabel(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }

    /// Spaces or parentheses break a bare inline-link destination; wrap such URLs in
    /// `<>` (a valid CommonMark destination form).
    private static func escapeLinkDestination(_ url: String) -> String {
        (url.contains(" ") || url.contains("(") || url.contains(")")) ? "<\(url)>" : url
    }

    // MARK: - Style & run resolution

    /// The ParagraphStyle id covering the most *visible* units of `range`. Control
    /// and object-replacement units (which `normalize` later strips) don't vote, so
    /// a section-break sentinel sitting before a short heading can't outweigh the
    /// heading's own run; runs without a style id don't vote either. Runs are sorted
    /// and contiguous, so the runs overlapping `range` form a slice found by binary
    /// search.
    private static func majorityStyle(_ units: [UInt16], _ runs: [(offset: Int, id: UInt64?)],
                                      _ range: Range<Int>, total: Int) -> UInt64? {
        guard !runs.isEmpty else { return nil }
        var low = 0
        var high = runs.count - 1
        var first = runs.count
        while low <= high {
            let mid = (low + high) / 2
            let runEnd = mid + 1 < runs.count ? runs[mid + 1].offset : total
            if runEnd > range.lowerBound { first = mid; high = mid - 1 } else { low = mid + 1 }
        }
        var best: UInt64?
        var bestOverlap = 0
        for index in first ..< runs.count {
            let run = runs[index]
            guard run.offset < range.upperBound else { break }
            guard let id = run.id else { continue }
            let runEnd = index + 1 < runs.count ? runs[index + 1].offset : total
            var overlap = 0
            for position in max(range.lowerBound, run.offset) ..< min(range.upperBound, runEnd)
            where !isDroppedUnit(units[position]) { overlap += 1 }
            if overlap > bestOverlap { bestOverlap = overlap; best = id }
        }
        return best
    }

    /// Units that won't survive into visible heading text — C0/C1 controls and soft
    /// breaks (which `PagesConverter.normalize` strips or folds to newlines) and the
    /// object-replacement placeholder — so they don't get a vote in the heading-style
    /// tally. (Body rendering keeps soft breaks and lets `normalize` clean controls.)
    private static func isDroppedUnit(_ unit: UInt16) -> Bool {
        if unit == 0x09 || unit == 0x0A { return false }
        return unit <= 0x1F || (0x7F ... 0x9F).contains(unit) || unit == 0xFFFC
    }

    /// A control unit `PagesConverter.normalize` deletes outright, so inline
    /// rendering skips it rather than wrap it in emphasis/link markup that would be
    /// stranded once the control is gone (e.g. `****`). Tab and the breaks normalize
    /// keeps or folds to a newline — U+0009, U+000A–U+000D, U+2028 — are not stripped.
    private static func isStrippedControl(_ unit: UInt16) -> Bool {
        if unit == 0x09 || (0x0A ... 0x0D).contains(unit) { return false }
        return unit <= 0x1F || (0x7F ... 0x9F).contains(unit)
    }

    /// The reference id of the run covering `index` (the last run starting at or
    /// before it), or nil if none — or the covering run carries no reference. Runs
    /// are sorted by offset.
    private static func referenceID(at index: Int, in runs: [(offset: Int, id: UInt64?)]) -> UInt64? {
        var low = 0
        var high = runs.count - 1
        var result: UInt64?
        while low <= high {
            let mid = (low + high) / 2
            if runs[mid].offset <= index { result = runs[mid].id; low = mid + 1 } else { high = mid - 1 }
        }
        return result
    }

    /// A storage run table (a wrapper of repeated `{1: charOffset, 2: reference}`)
    /// for the given field, sorted by offset. A run keeps a nil id when it carries an
    /// offset but no reference, so a boundary that *ends* a span — e.g. where a
    /// hyperlink stops — is preserved rather than absorbed into the previous run.
    private static func indexedReferences(in storage: IWAArchive.Object,
                                          field: Int) -> [(offset: Int, id: UInt64?)] {
        var runs: [(offset: Int, id: UInt64?)] = []
        var reader = ProtobufReader(storage.payload)
        while let outer = reader.next() {
            guard outer.number == field, case .length(let wrapper) = outer.value else { continue }
            var wrapperReader = ProtobufReader(wrapper)
            while let entry = wrapperReader.next() {
                guard entry.number == 1, case .length(let runBytes) = entry.value else { continue }
                var offset: Int?
                var id: UInt64?
                var runReader = ProtobufReader(runBytes)
                while let runField = runReader.next() {
                    switch (runField.number, runField.value) {
                    case (1, .varint(let value)): offset = Int(exactly: value)
                    case (2, .length(let reference)): id = referencedID(in: reference)
                    default: continue
                    }
                }
                if let offset { runs.append((offset, id)) }
            }
        }
        return runs.sorted { $0.offset < $1.offset }
    }

    /// The bold/italic traits of a CharacterStyle, resolved through its parent chain
    /// (properties archive field 11: bold = field 1, italic = field 2). A trait the
    /// style doesn't set itself is inherited from a named preset (e.g. "Strong" /
    /// "Emphasis"), mirroring how `styleName` resolves names; an explicit value wins
    /// over the parents'. Underline (field 11 of that archive) has no Markdown form
    /// and is dropped, matching the other converters.
    private static func characterTraits(of styleID: UInt64, in objects: [UInt64: IWAArchive.Object],
                                        visited: Set<UInt64> = []) -> (bold: Bool, italic: Bool) {
        guard !visited.contains(styleID), let object = objects[styleID] else { return (false, false) }
        var reader = ProtobufReader(object.payload)
        var properties: [UInt8]?
        while let field = reader.next() {
            if field.number == 11, case .length(let bytes) = field.value { properties = bytes; break }
        }
        var bold: Bool?
        var italic: Bool?
        if let properties {
            var propertyReader = ProtobufReader(properties)
            while let field = propertyReader.next() {
                switch (field.number, field.value) {
                case (1, .varint(let value)): bold = value != 0
                case (2, .varint(let value)): italic = value != 0
                default: continue
                }
            }
        }
        // Fill any trait this style doesn't set itself from the parent chain.
        if bold == nil || italic == nil {
            var seen = visited
            seen.insert(styleID)
            for parent in styleArchive(object).parents {
                let inherited = characterTraits(of: parent, in: objects, visited: seen)
                if bold == nil, inherited.bold { bold = true }
                if italic == nil, inherited.italic { italic = true }
            }
        }
        return (bold ?? false, italic ?? false)
    }

    /// The URL of a HyperlinkField smart field (field 2).
    private static func hyperlinkURL(of fieldID: UInt64,
                                     in objects: [UInt64: IWAArchive.Object]) -> String? {
        guard let object = objects[fieldID] else { return nil }
        var reader = ProtobufReader(object.payload)
        while let field = reader.next() {
            if field.number == 2, case .length(let bytes) = field.value { return String(bytes: bytes, encoding: .utf8) }
        }
        return nil
    }

    /// The list marker a ListStyle (field 7 → TSWP.ListStyleArchive) applies at the
    /// base indent level, from the first entry of its per-level marker-type array
    /// (field 11): 2 = bullet, 3 = ordered/number. Any other value (0 = none, image
    /// bullets, …) yields nil, so the paragraph renders as plain body text. Nesting
    /// levels beyond the first aren't resolved yet, so nested items render flat.
    private static func listMarker(of listStyleID: UInt64,
                                   in objects: [UInt64: IWAArchive.Object]) -> ListMarker? {
        guard let object = objects[listStyleID] else { return nil }
        var reader = ProtobufReader(object.payload)
        while let field = reader.next() {
            if field.number == 11, case .varint(let value) = field.value {
                switch value {
                case 2: return .bullet
                case 3: return .ordered
                default: return nil
                }
            }
        }
        return nil
    }

    /// The display name of a ParagraphStyle, resolved through its parent chain (an
    /// anonymous override inherits its name from a named preset like "Title").
    private static func styleName(_ styleID: UInt64?, objects: [UInt64: IWAArchive.Object],
                                  visited: Set<UInt64> = []) -> String? {
        guard let styleID, !visited.contains(styleID), let object = objects[styleID] else { return nil }
        let (name, parents) = styleArchive(object)
        if let name { return name }
        var seen = visited
        seen.insert(styleID)
        for parent in parents {
            if let resolved = styleName(parent, objects: objects, visited: seen) { return resolved }
        }
        return nil
    }

    /// A style's TSS.StyleArchive (field 1): its name (sub-field 1) and parent
    /// style references (sub-fields 3 and 5).
    private static func styleArchive(_ object: IWAArchive.Object) -> (name: String?, parents: [UInt64]) {
        var archive: [UInt8]?
        var reader = ProtobufReader(object.payload)
        while let field = reader.next() {
            if field.number == 1, case .length(let bytes) = field.value { archive = bytes; break }
        }
        guard let archive else { return (nil, []) }
        var name: String?
        var parents: [UInt64] = []
        var sub = ProtobufReader(archive)
        while let field = sub.next() {
            switch (field.number, field.value) {
            case (1, .length(let bytes)): name = String(bytes: bytes, encoding: .utf8)
            case (3, .length(let reference)), (5, .length(let reference)):
                if let id = referencedID(in: reference) { parents.append(id) }
            default: continue
            }
        }
        return (name, parents)
    }

    /// Markdown heading level for a paragraph-style name: Title → 1, Subtitle → 2,
    /// Heading N → N+1 (so "Title" outranks "Heading 1"), capped at 6. Other styles
    /// (Body, lists, …) aren't headings.
    private static func headingLevel(_ name: String?) -> Int? {
        guard let name else { return nil }
        let lower = name.lowercased()
        if lower.hasPrefix("title") { return 1 }
        if lower.hasPrefix("subtitle") { return 2 }
        if lower.hasPrefix("heading") {
            let number = Int(name.filter(\.isNumber)) ?? 1
            return min(number + 1, 6)
        }
        return nil
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
    /// (16 bytes, little-endian) at offset +12. Decodes the full 113-bit
    /// coefficient (any precision) into a decimal string — plain for everyday
    /// magnitudes, scientific notation for extreme exponents. Returns "" only for
    /// the rare large-coefficient encoding (combination field 0b11) or out-of-bounds.
    private static func decimalString(in buffer: [UInt8], at offset: Int) -> String {
        guard offset >= 0, offset + 16 <= buffer.count else { return "" }
        let high = buffer[offset + 15]
        guard (high >> 5) & 0x3 != 0x3 else { return "" }     // large-coefficient form
        let exponent = ((Int(high & 0x7F) << 7) | Int(buffer[offset + 14] >> 1)) - 6176
        // Coefficient is the low 113 bits: bytes 0-13 (112 bits) + bit 112.
        var coefficient = Array(buffer[offset ..< offset + 14])
        coefficient.append(buffer[offset + 14] & 1)
        return formatDecimal(negative: high & 0x80 != 0, coefficient: coefficient, exponent: exponent)
    }

    /// Formats `coefficient × 10^exponent` (coefficient as a little-endian
    /// magnitude): a plain decimal for everyday magnitudes — trimming trailing
    /// fractional zeros (420×10⁻² → "4.2", 35×10⁻² → "0.35") — or scientific
    /// notation when the magnitude is extreme (e.g. "1E-200"), so no valid value
    /// is dropped. A zero coefficient is always "0".
    private static func formatDecimal(negative: Bool, coefficient: [UInt8], exponent: Int) -> String {
        let digits = decimalDigits(coefficient)
        if digits == "0" { return "0" }
        let sign = negative ? "-" : ""

        // Exponent if written with a single leading digit (d.ddd × 10^adjusted).
        let adjusted = exponent + digits.count - 1
        guard adjusted >= -6, adjusted < 21 else {     // extreme magnitude → scientific
            var mantissa = String(digits.first!)
            var fraction = String(digits.dropFirst())
            while fraction.hasSuffix("0") { fraction.removeLast() }
            if !fraction.isEmpty { mantissa += "." + fraction }
            return sign + mantissa + "E\(adjusted)"
        }

        var result: String
        if exponent >= 0 {
            result = digits + String(repeating: "0", count: exponent)
        } else {
            var padded = digits
            let fractionCount = -exponent
            if padded.count <= fractionCount {
                padded = String(repeating: "0", count: fractionCount - padded.count + 1) + padded
            }
            let split = padded.index(padded.endIndex, offsetBy: -fractionCount)
            let integerPart = String(padded[..<split])
            var fractionPart = String(padded[split...])
            while fractionPart.hasSuffix("0") { fractionPart.removeLast() }
            result = fractionPart.isEmpty ? integerPart : integerPart + "." + fractionPart
        }
        return sign + result
    }

    /// Decimal string of a little-endian magnitude, via repeated division by 10.
    /// Returns "0" when the magnitude is zero.
    private static func decimalDigits(_ littleEndianMagnitude: [UInt8]) -> String {
        var value = littleEndianMagnitude
        var digits = ""
        while value.contains(where: { $0 != 0 }) {
            var remainder = 0
            for i in stride(from: value.count - 1, through: 0, by: -1) {
                let current = (remainder << 8) | Int(value[i])
                value[i] = UInt8(current / 10)
                remainder = current % 10
            }
            digits = String(remainder) + digits
        }
        return digits.isEmpty ? "0" : digits
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
