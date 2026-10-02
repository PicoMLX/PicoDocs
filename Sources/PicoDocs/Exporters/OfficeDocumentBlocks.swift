import Foundation

/// Office writers share a lossless projection of structured worksheet cells.
/// Markdown remains the fallback for sections without a raw CSV carrier.
enum OfficeDocumentBlocks {
    /// These writers do not serialize result.cover; do not silently discard it
    /// when it is the only payload. Custom exporters remain free to support it.
    static func validateInput(_ result: ConverterResult, includesNativeNotes: Bool = false, maximumBytes: Int = 64 * 1024 * 1024) throws {
        try Task.checkCancellation()
        if !(result.cover?.isEmpty ?? true), PicoDocsEngine.isEmptyForExport(result, includingCover: false) {
            throw PicoDocsError.emptyDocument
        }
        var remaining = max(0, maximumBytes)
        func charge(_ bytes: Int) throws {
            guard bytes <= remaining else { throw ExporterError.serializationFailed("Office projection exceeds the supported 64 MiB budget") }
            remaining -= bytes
        }
        for value in [result.title, result.author].compactMap({ $0 }) {
            guard value.utf8.count <= remaining / 7 else {
                throw ExporterError.serializationFailed("Office metadata exceeds the supported byte budget")
            }
            try charge(value.utf8.count * 7)
        }
        for section in result.sections {
            try Task.checkCancellation()
            // Parser section entries and joined separators exist even without text.
            try charge(256)
            if section.kind == .image {
                // Synthesis duplicates identities into alt text, destinations and
                // generated sections before any Markdown parser sees them.
                for value in [section.title, section.sourcePath].compactMap({ $0 }) {
                    guard value.utf8.count <= remaining / 14 else { throw ExporterError.serializationFailed("Office image references exceed the supported byte budget") }
                    try charge(value.utf8.count * 14)
                }
                for (key, value) in section.metadata where key != "base64" {
                    guard key.utf8.count <= remaining / 7 else { throw ExporterError.serializationFailed("Office image metadata exceeds the supported byte budget") }
                    try charge(key.utf8.count * 7)
                    guard value.utf8.count <= remaining / 7 else { throw ExporterError.serializationFailed("Office image metadata exceeds the supported byte budget") }
                    try charge(value.utf8.count * 7)
                }
                continue
            }
            if section.kind == .slide, let notes = section.metadata["notes"] {
                // PPTX retains an XML-safe notes copy and two comparison suffix
                // copies before removing canonical Notes content.
                let fixed = 2 * "### Notes\n\n".utf8.count + 2
                try charge(fixed)
                guard notes.utf8.count <= remaining / 3 else { throw ExporterError.serializationFailed("Office slide notes exceed the supported byte budget") }
                try charge(notes.utf8.count * 3)
                if includesNativeNotes {
                    // Notes metadata can exist without the visible Notes suffix.
                    // Admit its native run/paragraph projection independently.
                    try charge(1024)
                    for (index, scalar) in notes.unicodeScalars.enumerated() {
                        if index.isMultiple(of: 4096) { try Task.checkCancellation() }
                        let value = scalar.value
                        let bytes = value <= 0x7F ? 1 : value <= 0x7FF ? 2 : value <= 0xFFFF ? 3 : 4
                        try charge(bytes * 7)
                        if "*_[]`<>()".unicodeScalars.contains(scalar) { try charge(64) }
                        if scalar == "\n" || scalar == "\r" { try charge(256) }
                    }
                }
            }
            let projectedTitle = section.kind == .sheet ? (section.sheetName ?? section.metadata["sheetName"] ?? section.title) : section.title
            for title in Set([section.title, projectedTitle].compactMap({ $0 })) {
                guard title.utf8.count <= remaining / 7 else { throw ExporterError.serializationFailed("Office section metadata exceeds the supported byte budget") }
                try charge(title.utf8.count * 7)
            }
            if let csv = section.metadata["csv"], !csv.isEmpty {
                // Bound a single field before the streaming parser decodes it.
                guard csv.utf8.count <= remaining / 7 else { throw ExporterError.serializationFailed("Office CSV projection exceeds the supported byte budget") }
                var rows = 0, columns = 0, cells = 0
                try CSVConverter.forEachField(csv) { field, endsRow in
                    if cells.isMultiple(of: 64) { try Task.checkCancellation() }
                    columns += 1; cells += 1
                    guard columns <= 16_384, cells <= 1_000_000, rows < 1_048_576 else {
                        throw ExporterError.serializationFailed("Office CSV projection exceeds supported dimensions")
                    }
                    try charge(field.utf8.count * 7 + 256)
                    if endsRow { try charge(32); rows += 1; columns = 0 }
                }
            } else {
                var hasContent = false, tableLine = false, previousWasCR = false
                for (index, scalar) in section.markdown.unicodeScalars.enumerated() {
                    if index.isMultiple(of: 4096) { try Task.checkCancellation() }
                    // Match the block parser's CRLF normalization for both byte
                    // and physical-line charges, without allocating a new string.
                    if scalar == "\n", previousWasCR { previousWasCR = false; continue }
                    previousWasCR = scalar == "\r"
                    let value = scalar.value
                    let bytes = value <= 0x7F ? 1 : value <= 0x7FF ? 2 : value <= 0xFFFF ? 3 : 4
                    try charge(bytes * 7)
                    // Potential inline delimiters can each produce a node/run,
                    // even when the paragraph occupies only one source line.
                    // Include parentheses: even literal pairs occupy the link index.
                    // Charge conservatively before constructing the inline IR.
                    if "*_[]`<>()".unicodeScalars.contains(scalar) { try charge(64) }
                    if scalar == "\n" || scalar == "\r" {
                        // Empty/whitespace-only lines still become parser line
                        // records and code-block paragraphs or break runs.
                        if !hasContent { try charge(128) }
                        hasContent = false; tableLine = false; continue
                    }
                    if !hasContent, !CharacterSet.whitespaces.contains(scalar) {
                        hasContent = true; tableLine = scalar == "|"
                        try charge(128) // line/block/row storage before Markdown parsing
                    }
                    if tableLine, scalar == "|" { try charge(256) } // cell, grid and paragraph markup plus storage
                }
            }
        }
        try Task.checkCancellation()
    }

    static func parse(_ result: ConverterResult, includeSlideTitles: Bool = true) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var pending: [String] = []
        func flush() {
            blocks += MarkdownBlockParser.parse(pending.joined(separator: "\n\n"))
            pending.removeAll(keepingCapacity: true)
        }
        for original in result.sections where original.kind != .image {
            var section = original
            if section.metadata["preservedWhitespace"] == "1" {
                section.markdown = decodedPreservedWhitespace(section.markdown)
            }
            if let csv = section.metadata["csv"] ?? (section.kind == .sheet && section.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : nil),
               !csv.isEmpty || ([.sheet, .table].contains(section.kind) && section.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                flush()
                if section.kind == .sheet, let title = section.sheetName ?? section.metadata["sheetName"] ?? section.title, !title.isEmpty {
                    let escaped = title.map { #"\`*_{}[]<>"#.contains($0) ? "\\" + String($0) : String($0) }.joined()
                    blocks.append(.heading(2, escaped))
                }
                let rows = CSVConverter.parseCSV(csv).map { row in
                    row.map { cell in
                        MarkdownBlockParser.normalizedLineEndings(cell).map {
                            #"\`*_{}[]<>"#.contains($0) ? "\\" + String($0) : String($0)
                        }.joined().replacingOccurrences(of: "\n", with: "<br>")
                    }
                }
                if !rows.isEmpty { blocks.append(.table(rows)) }
                else if csv.isEmpty {
                    // Legacy carriers serialized a single empty cell as empty CSV.
                    for block in MarkdownBlockParser.parse(section.markdown) {
                        if case .table = block { blocks.append(block) }
                    }
                }
            } else if includeSlideTitles, section.kind == .slide, let title = section.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flush()
                let parsed = MarkdownBlockParser.parse(section.markdown)
                let normalized = MarkdownBlockParser.normalizedLineEndings(title).replacingOccurrences(of: "\n", with: " ")
                let alreadyPresent = parsed.first.map { block in
                    if case .heading(_, let text) = block { return MarkdownInlineParser.parse(text).plainText == normalized }
                    return false
                } ?? false
                if !alreadyPresent {
                    let escaped = normalized.map { #"\`*_{}[]<>"#.contains($0) ? "\\" + String($0) : String($0) }.joined()
                    blocks.append(.heading(2, escaped))
                }
                blocks += parsed
            } else { pending.append(section.markdown) }
        }
        flush()
        return blocks
    }
    /// Numeric whitespace belongs only to producers carrying the ownership flag. Literal
    /// ampersands already carry an odd backslash prefix and stay literal.
    static func decodedPreservedWhitespace(_ text: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"&#([0-9]{1,7});"#)
        let source = text as NSString
        var output = "", offset = 0
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, _ in
            guard let match, let value = UInt32(source.substring(with: match.range(at: 1))),
                  let scalar = UnicodeScalar(value), CharacterSet.whitespaces.contains(scalar) else { return }
            var before = match.range.location, slashes = 0
            while before > 0, source.character(at: before - 1) == 92 { before -= 1; slashes += 1 }
            guard slashes.isMultiple(of: 2) else { return }
            output += source.substring(with: NSRange(location: offset, length: match.range.location - offset)) + String(scalar)
            offset = NSMaxRange(match.range)
        }
        return output + source.substring(from: offset)
    }

}
