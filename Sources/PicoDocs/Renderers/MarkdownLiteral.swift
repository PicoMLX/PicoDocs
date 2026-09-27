import Foundation

/// Protect literal source text from being reinterpreted as nested Markdown blocks.
enum MarkdownLiteral {
    /// Verbatim converters predate canonical Markdown escaping. Protect their
    /// literal backslashes before the renderer decodes generated escapes.
    static func escapeBackslashes(_ text: String, paragraphEndLines: Set<Int> = []) -> String {
        var inFence = false
        var fenceList: (base: Int, content: Int)?
        var inNote = false
        var lists: [(base: Int, content: Int)] = []
        var followsBlank = false
        var prose = ""
        var output = ""
        func flushProse() {
            output += MarkdownTableCell.mapCodeSpans(prose, code: { $0 }, plain: {
                escapeProseBackslashes($0)
            })
            prose = ""
        }
        let lines = text.components(separatedBy: "\n")
        var followedByNoteContinuation = Array(repeating: false, count: lines.count)
        var nextIsIndented = false
        for index in lines.indices.reversed() {
            followedByNoteContinuation[index] = nextIsIndented
            if !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                nextIsIndented = lines[index].hasPrefix("    ") || lines[index].hasPrefix("\t")
            }
        }
        for (index, line) in lines.enumerated() {
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if inFence, let container = fenceList, !blank,
               !DocumentRenderer.literalListContains(line, base: container.base, content: container.content) {
                inFence = false; fenceList = nil
            }
            // Footnote extraction joins continued paragraphs into one inline value.
            if !inFence, inNote, line.hasPrefix("    ") || line.hasPrefix("\t") || (blank && followedByNoteContinuation[index]) {
                prose += line
                if index < lines.count - 1 { prose += "\n" }
                continue
            }
            if !inFence, !blank {
                if inNote, !line.hasPrefix("    "), !line.hasPrefix("\t") {
                    flushProse(); inNote = false
                }
                if DocumentRenderer.literalFootnoteDefinition(line) { inNote = true }
                var exitedList = false
                while let last = lists.last, !DocumentRenderer.literalListContains(line, base: last.base, content: last.content, afterBlank: followsBlank) {
                    lists.removeLast(); exitedList = true
                }
                if exitedList { flushProse() }
                if let item = DocumentRenderer.literalListIndent(lines, index: index) { lists.append(item) }
            }
            followsBlank = blank
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flushProse()
                inFence.toggle()
                fenceList = inFence ? lists.last : nil
                output += line
                if index < lines.count - 1 { output += "\n" }
            } else if inFence {
                output += line
                if index < lines.count - 1 { output += "\n" }
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // Inline spans stop at paragraph boundaries; fences retain state.
                flushProse()
                output += line
                if index < lines.count - 1 { output += "\n" }
            } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                flushProse()
                var cell = "", escaped = false
                func flushCell() {
                    output += MarkdownTableCell.mapCodeSpans(cell, code: { MarkdownTableCell.codePipes($0, encoding: true) }, plain: { escapeProseBackslashes($0) })
                    cell = ""
                }
                for character in line {
                    if character == "|", !escaped { flushCell(); output.append(character) }
                    else { cell.append(character) }
                    escaped = character == "\\" && !escaped
                }
                flushCell()
                if index < lines.count - 1 { output += "\n" }
            } else {
                let boundary = DocumentRenderer.literalBlockBoundary(line)
                if boundary.starts || DocumentRenderer.literalListIndent(lines, index: index) != nil { flushProse() }
                prose += line
                if index < lines.count - 1 { prose += "\n" }
                if boundary.ends || paragraphEndLines.contains(index) { flushProse() }
            }
        }
        flushProse()
        return output
    }

    private static func escapeProseBackslashes(_ text: String) -> String {
        var output = "", slashes = 0
        for character in text {
            if character == "\\" { slashes += 1; continue }
            let keepsEscape = slashes % 2 == 1 && #"`*_{}[]<>()#+-.!|"#.contains(character)
            output += String(repeating: "\\", count: slashes * 2 + (keepsEscape ? 1 : 0))
            output.append(character); slashes = 0
        }
        return output + String(repeating: "\\", count: slashes * 2)
    }

    /// Count added backslashes while retaining source
    /// UTF-16 indices, so styled runs can share whole-document code context.
    static func backslashEscapeCounts(_ text: String, paragraphSeparators: Set<UInt16> = [], softSeparators: Set<UInt16> = []) -> [Int] {
        let source = Array(text.utf16)
        // Replacing each separator with one LF preserves UTF-16 source offsets.
        let separators = paragraphSeparators.union(softSeparators)
        var paragraphEndLines: Set<Int> = [], line = 0
        for unit in source where unit == 0x0A || separators.contains(unit) {
            if paragraphSeparators.contains(unit) { paragraphEndLines.insert(line) }
            line += 1
        }
        let context = String(decoding: source.map { separators.contains($0) ? 0x0A : $0 }, as: UTF16.self)
        let escaped = Array(escapeBackslashes(context, paragraphEndLines: paragraphEndLines).utf16)
        var counts = Array(repeating: 0, count: source.count)
        var i = 0, j = 0
        while i < source.count {
            if source[i] == 0x5C {
                let start = i, escapedStart = j
                while i < source.count, source[i] == 0x5C { i += 1 }
                while j < escaped.count, escaped[j] == 0x5C { j += 1 }
                let added = j - escapedStart - (i - start)
                if added > 0 {
                    // Keep each source slash paired with its own escape copy, so
                    // generated style/link delimiters cannot split the pair.
                    for index in start..<i { counts[index] = 1 }
                    counts[i - 1] += added - (i - start)
                }
            } else { i += 1; j += 1 }
        }
        return counts
    }

    /// Keep the punctuation escape next to its source character when style or
    /// link delimiters will be inserted between it and the preceding slash.
    static func escapeProjection(_ text: String, boundaries: Set<Int>, paragraphSeparators: Set<UInt16> = [], softSeparators: Set<UInt16> = []) -> (after: [Int], before: Set<Int>) {
        var after = backslashEscapeCounts(text, paragraphSeparators: paragraphSeparators, softSeparators: softSeparators)
        let source = Array(text.utf16)
        var before: Set<Int> = []
        for offset in boundaries where offset > 0 && offset < source.count {
            if source[offset - 1] == 0x5C, after[offset - 1] >= 2 {
                after[offset - 1] -= 1
                before.insert(offset)
            }
        }
        return (after, before)
    }

    /// Escape the same joined stream that ConverterResult renders, retaining
    /// section provenance and already-generated table/image Markdown.
    static func escapeSectionBackslashes(_ sections: [DocumentSection]) -> [DocumentSection] {
        var result = sections
        let counts = backslashEscapeCounts(sections.filter { $0.kind != .image }.map(\.markdown).joined(separator: "\n\n"))
        var offset = 0
        for index in result.indices where result[index].kind != .image {
            let source = Array(result[index].markdown.utf16)
            if result[index].kind != .table {
                var units: [UInt16] = []
                for (local, unit) in source.enumerated() {
                    units.append(unit)
                    units += Array(repeating: 0x5C, count: counts[offset + local])
                }
                result[index].markdown = String(decoding: units, as: UTF16.self)
            }
            offset += source.count + 2
        }
        return result
    }

    static func escapeBlockStart(_ line: String) -> String {
        let content = line.drop { $0 == " " || $0 == "\t" }
        let lead = String(line[..<content.startIndex])
        if content.hasPrefix("[^"), let close = content.firstIndex(of: "]"), content[content.index(after: close)...].hasPrefix(":") { return lead + "\\" + content }
        if content.hasPrefix("```") {
            return lead + content.replacingOccurrences(of: "`", with: "\\`")
        }
        if let first = content.first, "#>|".contains(first) { return lead + "\\" + content }
        let compact = content.filter { !$0.isWhitespace }
        if compact.count >= 3, let first = compact.first, "-*_".contains(first), compact.allSatisfy({ $0 == first }) {
            return lead + content.map { $0 == first ? "\\" + String($0) : String($0) }.joined()
        }
        func endsMarker(_ rest: Substring) -> Bool { rest.isEmpty || rest.first == " " || rest.first == "\t" }
        if let first = content.first, "-*+".contains(first), endsMarker(content.dropFirst()) {
            return lead + "\\" + String(content)
        }
        let digits = content.prefix { $0.isASCII && $0.isNumber }
        let rest = content.dropFirst(digits.count)
        if (1...9).contains(digits.count), let delimiter = rest.first, delimiter == "." || delimiter == ")",
           endsMarker(rest.dropFirst()) {
            return lead + String(digits) + "\\" + String(rest)
        }
        return line
    }
}
