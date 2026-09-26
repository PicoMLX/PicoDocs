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
                $0.replacingOccurrences(of: "\\", with: "\\\\")
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
            } else {
                prose += line
                if index < lines.count - 1 { prose += "\n" }
            }
        }
        flushProse()
        return output
    }

    /// Identify source backslashes that need an escape while retaining source
    /// UTF-16 indices, so styled runs can share whole-document code context.
    static func backslashEscapeMask(_ text: String) -> [Bool] {
        let source = Array(text.utf16), escaped = Array(escapeBackslashes(text).utf16)
        var mask = Array(repeating: false, count: source.count)
        var i = 0, j = 0
        while i < source.count {
            if source[i] == 0x5C {
                let start = i, escapedStart = j
                while i < source.count, source[i] == 0x5C { i += 1 }
                while j < escaped.count, escaped[j] == 0x5C { j += 1 }
                if j - escapedStart == 2 * (i - start) {
                    for index in start..<i { mask[index] = true }
                }
            } else { i += 1; j += 1 }
        }
        return mask
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
