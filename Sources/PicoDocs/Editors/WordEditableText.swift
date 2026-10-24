//
//  WordEditableText.swift
//  PicoDocs
//
//  Extracts the editable-text *snapshot* of a DOCX `word/document.xml` and the
//  mapping from each visible character back to the exact raw byte span it came
//  from. This is the piece that makes surgical, source-preserving edits possible:
//
//   • The snapshot is the single string the caller shows the model AND the
//     matcher searches, so a verbatim quote always matches (it is NOT the
//     rendered Markdown/plaintext, which injects list markers, table pipes, …).
//   • Each editable run carries an entity-aware token map (`&amp;` ≠ `&`), so a
//     decoded offset in the snapshot resolves to the correct raw index in
//     `document.xml` — the DOM alone does not supply those byte spans.
//
//  A single hand scanner (no DOM round-trip) does both at once: it walks the raw
//  XML in document order, classifies each `<w:t>` run (editable vs. shown-but-
//  fixed vs. hidden), and records raw ranges directly. Text that is visible but
//  can't be safely spliced in place — inside a hyperlink, field, content control,
//  or tracked change — is included in the snapshot (so reading order is natural
//  and no match silently spans it) but marked non-editable; hidden text
//  (`w:vanish`) is excluded entirely.
//

import Foundation

struct DocxEditableText {

    /// The visible text: what the caller shows the model and what the matcher
    /// searches. Includes non-editable spans (hyperlinks/fields) for context.
    let snapshot: String

    /// The raw `word/document.xml` this maps into.
    let documentXML: String

    /// Ordered, contiguous segments partitioning `snapshot`.
    let segments: [Segment]

    struct Segment {
        /// Range within `snapshot`.
        let range: Range<String.Index>
        /// Non-nil only for editable runs; nil for fixed visible text and
        /// structural separators (paragraph breaks, tabs, line breaks).
        let run: EditableRun?
        var isEditable: Bool { run != nil }
    }

    /// One editable `<w:t>` run and its mapping into `documentXML`.
    struct EditableRun {
        let paragraph: Int
        /// Raw inner-text range of the `<w:t>` element in `documentXML`.
        let innerRange: Range<String.Index>
        /// Raw range of the `<w:t …>` opening tag (for `xml:space` insertion).
        let openTagRange: Range<String.Index>
        let hasXmlSpacePreserve: Bool
        /// Whether the raw markup between the previous editable run and this one
        /// is splice-safe (same paragraph, only run/run-property markup between —
        /// no drawing, field, break, tab, or alternate-content). A match may only
        /// span two editable runs when the later one reports `true`.
        let safeJoinWithPrevious: Bool
        /// Entity-aware tokens covering `innerRange`, in order.
        let tokens: [Token]

        /// The raw `String.Index` in `documentXML` for a given decoded UTF-16
        /// offset within this run's visible text.
        func rawIndex(atDecodedUTF16Offset offset: Int, in xml: String) -> String.Index {
            var consumed = 0
            for token in tokens {
                let length = token.decoded.utf16.count
                if offset <= consumed + length {
                    let within = offset - consumed
                    if within <= 0 { return token.rawRange.lowerBound }
                    if within >= length { return token.rawRange.upperBound }
                    // Only literal tokens can be split mid-token; an entity is one
                    // atomic character, so `within` is always 0 or `length` there.
                    if token.isLiteral {
                        return xml.utf16.index(token.rawRange.lowerBound, offsetBy: within)
                    }
                    return token.rawRange.upperBound
                }
                consumed += length
            }
            return tokens.last?.rawRange.upperBound ?? innerRange.upperBound
        }
    }

    /// A literal run of characters (decoded == raw, 1:1) or a single XML entity.
    struct Token {
        let decoded: String
        let rawRange: Range<String.Index>
        let isLiteral: Bool
    }

    // MARK: - Classification tables

    /// Elements that make the text they wrap non-editable in this version.
    private static let nonEditableWrappers: Set<String> = [
        "w:hyperlink", "w:sdt", "w:fldsimple", "w:ins", "w:del",
    ]

    /// Tags that, if present between two editable runs, make joining them unsafe.
    private static let unsafeBetweenRuns: [String] = [
        "<w:drawing", "<w:pict", "<w:object", "<w:sym", "<w:fldchar",
        "<w:instrtext", "<w:br", "<w:cr", "<w:tab", "<w:ptab",
        "<w:nobreakhyphen", "<w:softhyphen", "<mc:",
    ]

    // MARK: - Extraction

    /// Parse `document.xml` into the snapshot + segment map. Throws `.fileCorrupted`
    /// if the XML is too malformed to scan safely (so a bad input is rejected, never
    /// silently mis-edited).
    static func extract(documentXML xml: String) throws -> DocxEditableText {
        var pieces: [(text: String, run: EditableRun?)] = []

        var stack: [String] = []
        var runVanishStack: [Bool] = []
        var paragraphIndex = -1
        var wrapperDepth = 0
        var fieldDepth = 0
        var inRunRPr = false

        var didEmitAny = false
        var lastParagraph = Int.min
        var prevEditable: (innerEnd: String.Index, paragraph: Int)?

        // Pending <w:t> open state (w:t has no child elements, so the next tag is
        // its </w:t>).
        var pendingWT: (openTag: Range<String.Index>, innerStart: String.Index, space: Bool)?

        /// Emit a visible piece, inserting a paragraph separator on a paragraph
        /// change. Fixed pieces (run == nil) break the editable-run adjacency chain.
        func emit(_ text: String, run: EditableRun?, paragraph: Int) {
            if didEmitAny && paragraph != lastParagraph {
                pieces.append(("\n", nil))
            }
            pieces.append((text, run))
            didEmitAny = true
            lastParagraph = paragraph
            if run == nil { prevEditable = nil }
        }

        var i = xml.startIndex
        let end = xml.endIndex
        var guardCounter = 0
        while i < end {
            guardCounter += 1
            if guardCounter > 50_000_000 { throw PicoDocsError.fileCorrupted }

            if xml[i] != "<" {
                i = xml[i...].firstIndex(of: "<") ?? end
                continue
            }

            let rest = xml[i...]
            if rest.hasPrefix("<!--") { i = Self.advance(xml, from: i, past: "-->"); continue }
            if rest.hasPrefix("<![CDATA[") { i = Self.advance(xml, from: i, past: "]]>"); continue }
            if rest.hasPrefix("<?") { i = Self.advance(xml, from: i, past: "?>"); continue }
            if rest.hasPrefix("<!") {
                guard let gt = xml[i...].firstIndex(of: ">") else { throw PicoDocsError.fileCorrupted }
                i = xml.index(after: gt); continue
            }

            guard let gt = Self.tagEnd(xml, from: i) else { throw PicoDocsError.fileCorrupted }
            let afterTag = xml.index(after: gt)
            let interior = xml[xml.index(after: i)..<gt]       // between < and >
            let isEnd = interior.first == "/"
            let isSelfClose = interior.last == "/"
            let nameSlice = isEnd ? interior.dropFirst() : interior
            let name = Self.elementName(nameSlice)

            if isEnd {
                switch name {
                case "w:r":
                    if !runVanishStack.isEmpty { runVanishStack.removeLast() }
                case "w:rpr":
                    inRunRPr = false
                case "w:t":
                    if let wt = pendingWT {
                        let innerRange = wt.innerStart..<i
                        let vanished = runVanishStack.last ?? false
                        if !vanished {
                            let (decoded, tokens) = Self.tokenize(innerRange, in: xml)
                            if !decoded.isEmpty {
                                if wrapperDepth == 0 && fieldDepth == 0 {
                                    let safeJoin: Bool
                                    if let prev = prevEditable, prev.paragraph == paragraphIndex {
                                        let between = xml[prev.innerEnd..<wt.openTag.lowerBound].lowercased()
                                        safeJoin = !Self.unsafeBetweenRuns.contains { between.contains($0) }
                                    } else {
                                        safeJoin = false
                                    }
                                    let run = EditableRun(
                                        paragraph: paragraphIndex,
                                        innerRange: innerRange,
                                        openTagRange: wt.openTag,
                                        hasXmlSpacePreserve: wt.space,
                                        safeJoinWithPrevious: safeJoin,
                                        tokens: tokens
                                    )
                                    emit(decoded, run: run, paragraph: paragraphIndex)
                                    prevEditable = (innerEnd: innerRange.upperBound, paragraph: paragraphIndex)
                                } else {
                                    emit(decoded, run: nil, paragraph: paragraphIndex)
                                }
                            }
                        }
                        pendingWT = nil
                    }
                default:
                    if Self.nonEditableWrappers.contains(name), wrapperDepth > 0 { wrapperDepth -= 1 }
                }
                if !stack.isEmpty { stack.removeLast() }
                i = afterTag
                continue
            }

            // Start tag (possibly self-closing).
            switch name {
            case "w:p":
                paragraphIndex += 1
            case "w:fldchar":
                switch Self.attribute("w:fldCharType", in: interior) {
                case "begin": fieldDepth += 1
                case "end": fieldDepth = max(0, fieldDepth - 1)
                default: break
                }
            case "w:tab", "w:ptab":
                // Only a run-level tab is a literal tab; `<w:tab>` inside `<w:tabs>`
                // (paragraph properties) defines a tab stop and carries no text.
                if stack.last == "w:r", !(runVanishStack.last ?? false) {
                    emit("\t", run: nil, paragraph: paragraphIndex)
                }
            case "w:br", "w:cr":
                if stack.last == "w:r", !(runVanishStack.last ?? false) {
                    emit("\n", run: nil, paragraph: paragraphIndex)
                }
            case "w:vanish":
                if inRunRPr, !runVanishStack.isEmpty {
                    runVanishStack[runVanishStack.count - 1] = Self.isToggleOn(interior)
                }
            case "w:t":
                if !isSelfClose {
                    pendingWT = (openTag: i..<afterTag, innerStart: afterTag, space: Self.hasXmlSpacePreserve(interior))
                }
            default:
                break
            }

            if !isSelfClose {
                // Counters that depend on nesting are maintained on open/close.
                switch name {
                case "w:r":
                    runVanishStack.append(false)
                case "w:rpr":
                    inRunRPr = (stack.last == "w:r")
                default:
                    if Self.nonEditableWrappers.contains(name) { wrapperDepth += 1 }
                }
                stack.append(name)
            }

            i = afterTag
        }

        // Assemble the snapshot and resolve segment ranges in one pass.
        var snapshot = ""
        for piece in pieces { snapshot += piece.text }
        var segments: [Segment] = []
        var cursor = snapshot.startIndex
        for piece in pieces {
            let next = snapshot.index(cursor, offsetBy: piece.text.count)
            segments.append(Segment(range: cursor..<next, run: piece.run))
            cursor = next
        }

        return DocxEditableText(snapshot: snapshot, documentXML: xml, segments: segments)
    }

    // MARK: - Entity tokenization

    /// Decodes the entity-encoded inner text of a `<w:t>` into visible text plus
    /// tokens mapping each decoded span back to its raw range.
    static func tokenize(_ range: Range<String.Index>, in xml: String) -> (String, [Token]) {
        var decoded = ""
        var tokens: [Token] = []
        var i = range.lowerBound
        var literalStart = i
        func flushLiteral(upTo bound: String.Index) {
            guard literalStart < bound else { return }
            let text = String(xml[literalStart..<bound])
            decoded += text
            tokens.append(Token(decoded: text, rawRange: literalStart..<bound, isLiteral: true))
        }
        while i < range.upperBound {
            if xml[i] == "&", let semi = xml[i...].firstIndex(of: ";"), semi < range.upperBound {
                let entity = xml[xml.index(after: i)..<semi]
                if let scalar = Self.decodeEntity(entity) {
                    flushLiteral(upTo: i)
                    let entityRange = i..<xml.index(after: semi)
                    decoded += scalar
                    tokens.append(Token(decoded: scalar, rawRange: entityRange, isLiteral: false))
                    i = xml.index(after: semi)
                    literalStart = i
                    continue
                }
            }
            i = xml.index(after: i)
        }
        flushLiteral(upTo: range.upperBound)
        return (decoded, tokens)
    }

    private static func decodeEntity(_ body: Substring) -> String? {
        switch body {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        default: break
        }
        guard body.first == "#" else { return nil }
        let digits = body.dropFirst()
        let value: UInt32?
        if let first = digits.first, first == "x" || first == "X" {
            value = UInt32(digits.dropFirst(), radix: 16)
        } else {
            value = UInt32(digits, radix: 10)
        }
        guard let value, let scalar = Unicode.Scalar(value) else { return nil }
        return String(scalar)
    }

    // MARK: - Tag helpers

    /// The index of the `>` that closes the tag starting at `start` (`<`),
    /// respecting quoted attribute values that may themselves contain `>`.
    private static func tagEnd(_ xml: String, from start: String.Index) -> String.Index? {
        var i = xml.index(after: start)
        var quote: Character?
        while i < xml.endIndex {
            let c = xml[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == ">" {
                return i
            }
            i = xml.index(after: i)
        }
        return nil
    }

    /// The lowercased element name from a tag's interior (after any leading `/`).
    private static func elementName(_ slice: Substring) -> String {
        var name = ""
        for c in slice {
            if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "/" || c == ">" { break }
            name.append(c)
        }
        return name.lowercased()
    }

    private static func hasXmlSpacePreserve(_ tag: Substring) -> Bool {
        tag.contains("xml:space=\"preserve\"") || tag.contains("xml:space='preserve'")
    }

    /// The value of `name="…"` / `name='…'` within a tag's interior, if present.
    private static func attribute(_ name: String, in tag: Substring) -> String? {
        guard let keyRange = tag.range(of: name + "=") else { return nil }
        var i = keyRange.upperBound
        guard i < tag.endIndex else { return nil }
        let quote = tag[i]
        guard quote == "\"" || quote == "'" else { return nil }
        i = tag.index(after: i)
        guard let close = tag[i...].firstIndex(of: quote) else { return nil }
        return String(tag[i..<close])
    }

    /// Whether a toggle property element (e.g. `w:vanish`) is on: on when `w:val`
    /// is absent, off when `w:val` is false/0/off/none.
    private static func isToggleOn(_ tag: Substring) -> Bool {
        guard let val = attribute("w:val", in: tag) else { return true }
        return !["false", "0", "off", "none"].contains(val.lowercased())
    }

    private static func advance(_ xml: String, from start: String.Index, past marker: String) -> String.Index {
        if let r = xml.range(of: marker, range: start..<xml.endIndex) { return r.upperBound }
        return xml.endIndex
    }
}
