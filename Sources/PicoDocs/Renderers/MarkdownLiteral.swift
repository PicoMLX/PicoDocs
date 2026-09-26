import Foundation

/// Protect literal source text from being reinterpreted as nested Markdown blocks.
enum MarkdownLiteral {
    /// Verbatim converters predate canonical Markdown escaping. Protect their
    /// literal backslashes before the renderer decodes generated escapes.
    static func escapeBackslashes(_ text: String) -> String {
        var inFence = false
        var prose = ""
        var output = ""
        func flushProse() {
            output += MarkdownTableCell.mapCodeSpans(prose, code: { $0 }, plain: {
                escapeProseBackslashes($0)
            })
            prose = ""
        }
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flushProse()
                inFence.toggle()
                output += line
                if index < lines.count - 1 { output += "\n" }
            } else if inFence {
                output += line
                if index < lines.count - 1 { output += "\n" }
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // Inline code cannot cross a paragraph boundary; fences can.
                flushProse()
                output += line
                if index < lines.count - 1 { output += "\n" }
            } else {
                prose += line
                if index < lines.count - 1 { prose += "\n" }
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

    /// Add only missing escapes to already canonical inline Markdown.
    static func escapeStructural(_ text: String, characters: String) -> String {
        var output = "", slashes = 0
        for character in text {
            if characters.contains(character), slashes.isMultiple(of: 2) { output += "\\" }
            output.append(character)
            slashes = character == "\\" ? slashes + 1 : 0
        }
        return output
    }

    /// Count added backslashes while retaining source
    /// UTF-16 indices, so styled runs can share whole-document code context.
    static func backslashEscapeCounts(_ text: String) -> [Int] {
        let source = Array(text.utf16), escaped = Array(escapeBackslashes(text).utf16)
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

}
