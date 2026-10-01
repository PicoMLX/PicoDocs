import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import ZIPFoundation

/// One conversion's extraction budget, charged for actual inflated bytes.
final class PowerPointPackage {
    let archive: Archive
    private var entries: [String: Entry] = [:]
    private var remaining: Int
    private let entryLimit: Int
    private(set) var failure: Error?
    private var remainingRelationships: Int
    private var remainingRelationshipBytes: Int
    var contentTypes: [String: String]?
    var relationshipMaps: [String: [String: PowerPointConverter.Relationship]] = [:]

    var relationshipTypeIndexes: [String: [String: [PowerPointConverter.Relationship]]] = [:]
    var relationshipIndexBuildCount = 0

    init(archive: Archive, entryLimit: Int = 64 * 1024 * 1024, totalLimit: Int = 256 * 1024 * 1024, maximumEntries: Int = 16_384, maximumNameBytes: Int = 8 * 1024 * 1024, maximumRelationships: Int = 65_536, maximumRelationshipBytes: Int = 16 * 1024 * 1024) {
        self.archive = archive
        self.entryLimit = entryLimit
        self.remaining = totalLimit
        self.remainingRelationships = max(0, maximumRelationships)
        self.remainingRelationshipBytes = max(0, maximumRelationshipBytes)
        var names: Set<String> = []
        var count = 0, nameBytes = 0
        for entry in archive {
            if Task.isCancelled { fail(CancellationError()); break }
            let bytes = entry.path.utf8.count
            guard count < maximumEntries, bytes <= maximumNameBytes - nameBytes else {
                fail(PicoDocsError.fileCorrupted); break
            }
            count += 1; nameBytes += bytes
            guard entry.type == .file || entry.type == .directory else { fail(PicoDocsError.fileCorrupted); break }
            if entry.type == .directory, !entry.path.hasSuffix("/") { fail(PicoDocsError.fileCorrupted); break }
            let identity = Self.canonicalPartPath(entry.path)
            if !names.insert(identity).inserted { fail(PicoDocsError.fileCorrupted); break }
            entries[identity] = entry
        }
    }

    static func canonicalPartPath(_ path: String) -> String {
        let bytes = Array(path.utf8)
        var output = bytes, i = 0
        func hex(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) }
        while i + 2 < bytes.count {
            if bytes[i] == 37, hex(bytes[i + 1]), hex(bytes[i + 2]) {
                for j in (i + 1)...(i + 2) where (97...102).contains(output[j]) { output[j] -= 32 }
                i += 3
            } else { i += 1 }
        }
        return String(decoding: output, as: UTF8.self)
    }

    func entry(_ path: String) -> Entry? {
        let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return entries[Self.canonicalPartPath(clean)]
    }

    /// Bound all retained relationship dictionaries, including empty-map keys.
    func reserveRelationshipMap(_ part: String) -> Bool {
        let bytes = part.utf8.count + 64
        guard bytes <= remainingRelationshipBytes else { fail(PicoDocsError.fileCorrupted); return false }
        remainingRelationshipBytes -= bytes
        return true
    }

    func reserveRelationship(id: String, type: String, target: String) -> Bool {
        let bytes = id.utf8.count + type.utf8.count + target.utf8.count + 96
        guard remainingRelationships > 0, bytes <= remainingRelationshipBytes else {
            fail(PicoDocsError.fileCorrupted); return false
        }
        remainingRelationships -= 1; remainingRelationshipBytes -= bytes
        return true
    }

    func fail(_ error: Error) { if failure == nil { failure = error } }

    func check() throws {
        try Task.checkCancellation()
        if let failure { throw failure }
    }

    func read(_ path: String, maximumBytes: Int = Int.max) -> Data? {
        do {
            try check()
            let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
            guard let entry = entry(clean) else { return nil }
            let size = UInt64(archive.data?.count ?? 0)
            let allowed = max(0, min(entryLimit, maximumBytes))
            guard entry.uncompressedSize <= UInt64(allowed), entry.uncompressedSize <= UInt64(remaining),
                  entry.compressedSize <= size, entry.isCompressed || entry.uncompressedSize <= size else {
                throw PicoDocsError.fileCorrupted
            }
            var bytes = Data()
            bytes.reserveCapacity(Int(min(entry.uncompressedSize, 1024 * 1024)))
            let checksum = try archive.extract(entry) { chunk in
                try Task.checkCancellation()
                guard chunk.count <= allowed - bytes.count, chunk.count <= self.remaining,
                      !chunk.isEmpty || entry.uncompressedSize == 0 else { throw PicoDocsError.fileCorrupted }
                self.remaining -= chunk.count
                bytes.append(chunk)
            }
            guard checksum == entry.checksum, UInt64(bytes.count) == entry.uncompressedSize else { throw PicoDocsError.fileCorrupted }
            return bytes
        } catch let error as CancellationError { failure = error; return nil }
        catch { fail(PicoDocsError.fileCorrupted); return nil }
    }
}

/// Validate XML and normalize known namespace aliases before the existing DOM walk.
/// SAX parsing rejects malformed parts and bounds nesting before SwiftSoup sees them.
final class PowerPointXML: NSObject, XMLParserDelegate {
    /// Conversion-wide allowance for shared and transient slide/notes DOM construction.
    final class Budget {
        var nodes: Int, attributes: Int, bytes: Int, attributeBytes: Int, namespaceWork: Int
        init(nodes: Int = 250_000, attributes: Int = 500_000, bytes: Int = 64 * 1024 * 1024, attributeBytes: Int = 8 * 1024 * 1024, namespaceWork: Int = 1_000_000) {
            self.nodes = max(0, nodes); self.attributes = max(0, attributes); self.bytes = max(0, bytes)
            self.attributeBytes = max(0, attributeBytes); self.namespaceWork = max(0, namespaceWork)
        }
    }

    private var scopes: [[String: String]] = [[:]]
    private var scopeBytes: [Int] = [0]
    private var names: [String] = []
    private var emitted: [Bool] = []
    private var compatibility: [(ignored: Set<String>, processed: Set<String>)] = [([], [])]
    private var unknownPrefixes: [String: String] = [:]
    private var unknownNamespaceBytes = 0
    private var output = ""
    private var hasError = false
    private var outputBytes = 0
    private var nodes = 0
    private var attributesCount = 0
    private var attributeBytes = 0
    private var maximumAttributeBytes = 8 * 1024 * 1024
    private var maximumAttributesPerElement = 256
    private var namespaceWork = 0
    private var maximumNamespaceWork = 1_000_000
    private var maximumNodes = 250_000
    private var maximumAttributes = 500_000
    private var maximumOutputBytes = 64 * 1024 * 1024
    private static let prefixes = [
        "http://schemas.openxmlformats.org/presentationml/2006/main": "p",
        "http://schemas.openxmlformats.org/drawingml/2006/main": "a",
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships": "r",
        "http://schemas.openxmlformats.org/markup-compatibility/2006": "mc",
        "http://purl.org/dc/elements/1.1/": "dc",
        "http://purl.org/dc/terms/": "dcterms",
        "http://purl.org/dc/dcmitype/": "dcmitype",
        "http://www.w3.org/2001/XMLSchema-instance": "xsi",
        "http://schemas.openxmlformats.org/package/2006/metadata/core-properties": "cp",
        "http://purl.oclc.org/ooxml/package/metadata/core-properties": "cp",
        "http://purl.oclc.org/ooxml/presentationml/main": "p",
        "http://purl.oclc.org/ooxml/drawingml/main": "a",
        "http://purl.oclc.org/ooxml/officeDocument/relationships": "r",
        "http://schemas.openxmlformats.org/package/2006/relationships": "",
        "http://schemas.openxmlformats.org/package/2006/content-types": ""
    ]

    static func normalize(_ data: Data, maximumOutputBytes: Int = 64 * 1024 * 1024, maximumNodes: Int = 250_000, maximumAttributes: Int = 500_000, maximumAttributesPerElement: Int = 256, maximumAttributeBytes: Int = 8 * 1024 * 1024, budget: Budget? = nil) -> String? {
        guard lexicalPreflight(data, maximumAttributesPerElement: maximumAttributesPerElement) else { return nil }
        let parser = XMLParser(data: data)
        let delegate = PowerPointXML()
        delegate.maximumOutputBytes = min(maximumOutputBytes, budget?.bytes ?? maximumOutputBytes)
        delegate.maximumNodes = min(maximumNodes, budget?.nodes ?? maximumNodes)
        delegate.maximumAttributes = min(maximumAttributes, budget?.attributes ?? maximumAttributes)
        delegate.maximumAttributesPerElement = maximumAttributesPerElement
        delegate.maximumAttributeBytes = min(maximumAttributeBytes, budget?.attributeBytes ?? maximumAttributeBytes)
        delegate.maximumNamespaceWork = budget?.namespaceWork ?? 1_000_000
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), !delegate.hasError, !Task.isCancelled else { return nil }
        if let budget {
            budget.nodes -= delegate.nodes
            budget.attributes -= delegate.attributesCount
            budget.attributeBytes -= delegate.attributeBytes
            budget.bytes -= delegate.outputBytes
            budget.namespaceWork -= delegate.namespaceWork
        }
        return delegate.output
    }

    /// Inspect ASCII markup as encoded code units, without allocating attribute
    /// dictionaries or deleting NUL bytes from valid non-ASCII UTF-16 text.
    static func lexicalPreflight(_ data: Data, maximumAttributesPerElement: Int = 256) -> Bool {
        data.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            var width = 1, little = false
            if bytes.count >= 4 {
                let first = Array(bytes.prefix(4))
                if first == [0, 0, 0xFE, 0xFF] || first == [0, 0, 0, 0x3C] { width = 4 }
                else if first == [0xFF, 0xFE, 0, 0] || first == [0x3C, 0, 0, 0] { width = 4; little = true }
            }
            if width == 1, bytes.count >= 2 {
                if (bytes[0] == 0xFE && bytes[1] == 0xFF) || (bytes[0] == 0 && bytes[1] == 0x3C) { width = 2 }
                else if (bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0x3C && bytes[1] == 0) { width = 2; little = true }
            }
            let count = bytes.count / width
            func unit(_ index: Int) -> UInt32 {
                guard index < count else { return 0 }
                var value: UInt32 = 0
                for j in 0..<width {
                    let offset = little ? width - 1 - j : j
                    value = (value << 8) | UInt32(bytes[index * width + offset])
                }
                return value
            }
            func matches(_ token: [UInt8], at index: Int) -> Bool {
                guard token.count <= count - index else { return false }
                for j in token.indices where unit(index + j) != UInt32(token[j]) { return false }
                return true
            }
            func space(_ value: UInt32) -> Bool { value == 32 || value == 9 || value == 10 || value == 13 }
            var i = 0
            func skip(to token: [UInt8]) -> Bool {
                while i < count {
                    if i % 4096 == 0, Task.isCancelled { return false }
                    if matches(token, at: i) { i += token.count; return true }
                    i += 1
                }
                return false
            }
            let comment = Array("<!--".utf8), cdata = Array("<![CDATA[".utf8), processing = Array("<?".utf8)
            while i < count {
                if i % 4096 == 0, Task.isCancelled { return false }
                guard unit(i) == 60 else { i += 1; continue }
                if matches(comment, at: i) { i += 4; guard skip(to: Array("-->".utf8)) else { return false }; continue }
                if matches(cdata, at: i) { i += 9; guard skip(to: Array("]]>".utf8)) else { return false }; continue }
                if matches(processing, at: i) { i += 2; guard skip(to: Array("?>".utf8)) else { return false }; continue }
                // DTDs and entity declarations are unsupported, including external ones.
                if unit(i + 1) == 33 { return false }
                if unit(i + 1) == 47 { i += 2; guard skip(to: [62]) else { return false }; continue }
                i += 1
                // Element name. Leave full XML name validation to XMLParser.
                while i < count, !space(unit(i)), unit(i) != 62, unit(i) != 47 {
                    if i % 4096 == 0, Task.isCancelled { return false }
                    i += 1
                }
                var attributes = 0
                while i < count {
                    while i < count, space(unit(i)) {
                        if i % 4096 == 0, Task.isCancelled { return false }
                        i += 1
                    }
                    if unit(i) == 62 { i += 1; break }
                    if unit(i) == 47, unit(i + 1) == 62 { i += 2; break }
                    guard i < count, attributes < maximumAttributesPerElement else { return false }
                    attributes += 1
                    while i < count, !space(unit(i)), unit(i) != 61 {
                        if i % 4096 == 0, Task.isCancelled { return false }
                        if unit(i) == 62 || unit(i) == 47 { return false }
                        i += 1
                    }
                    while i < count, space(unit(i)) {
                        if i % 4096 == 0, Task.isCancelled { return false }
                        i += 1
                    }
                    guard unit(i) == 61 else { return false }; i += 1
                    while i < count, space(unit(i)) {
                        if i % 4096 == 0, Task.isCancelled { return false }
                        i += 1
                    }
                    let quote = unit(i)
                    guard i < count, quote == 34 || quote == 39 else { return false }; i += 1
                    while i < count, unit(i) != quote {
                        if i % 4096 == 0, Task.isCancelled { return false }
                        i += 1
                    }
                    guard i < count else { return false }; i += 1
                }
            }
            return !Task.isCancelled
        }
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        hasError = true; parser.abortParsing()
    }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        hasError = true; parser.abortParsing()
    }

    private func name(_ raw: String, scope: [String: String], attribute: Bool = false) -> String {
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        let prefix = parts.count == 2 ? parts[0] : ""
        let local = parts.last!
        if parts.count == 2, scope[prefix] == nil, prefix != "xml" { hasError = true }
        guard !attribute || !prefix.isEmpty, let uri = scope[prefix] else { return raw }
        if let canonical = Self.prefixes[uri] { return canonical.isEmpty ? local : canonical + ":" + local }
        // URI identity survives normalization, even for ignorable extensions.
        if unknownPrefixes[uri] == nil {
            guard unknownPrefixes.count < 1024, uri.utf8.count <= 1024 * 1024 - unknownNamespaceBytes else {
                hasError = true; return "invalid:" + local
            }
            unknownNamespaceBytes += uri.utf8.count
            unknownPrefixes[uri] = "extension\(unknownPrefixes.count)"
        }
        let synthetic = unknownPrefixes[uri]!
        return synthetic + ":" + local
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { hasError = true }
    func parser(_ parser: XMLParser, validationErrorOccurred validationError: Error) { hasError = true }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        guard names.count < 128, nodes < maximumNodes,
              attributes.count <= maximumAttributesPerElement,
              attributes.count <= maximumAttributes - attributesCount, !Task.isCancelled else {
            hasError = true; parser.abortParsing(); return
        }
        var elementAttributeBytes = 0
        for (key, value) in attributes {
            let bytes = key.utf8.count + value.utf8.count
            guard bytes <= 64 * 1024 - elementAttributeBytes, bytes <= maximumAttributeBytes - attributeBytes else {
                hasError = true; parser.abortParsing(); return
            }
            elementAttributeBytes += bytes; attributeBytes += bytes
        }
        nodes += 1; attributesCount += attributes.count
        var scope = scopes.last!
        var bytes = scopeBytes.last!
        var chargedScopeCopy = false
        for (key, value) in attributes {
            if Task.isCancelled { hasError = true; parser.abortParsing(); return }
            guard key == "xmlns" || key.hasPrefix("xmlns:") else { continue }
            let prefix = key == "xmlns" ? "" : String(key.dropFirst(6))
            let prior = scope[prefix]
            if prior == value { continue }
            if !chargedScopeCopy {
                let work = scope.count + 1
                guard work <= maximumNamespaceWork - namespaceWork else { hasError = true; parser.abortParsing(); return }
                namespaceWork += work; chargedScopeCopy = true
            }
            bytes -= prior.map { prefix.utf8.count + $0.utf8.count } ?? 0
            bytes += prefix.utf8.count + value.utf8.count
            // Each copied scope is small, even at the maximum XML depth.
            guard bytes <= 64 * 1024, prior != nil || scope.count < 256 else {
                hasError = true; parser.abortParsing(); return
            }
            scope[prefix] = value
        }
        scopes.append(scope); scopeBytes.append(bytes)
        var settings = compatibility.last!
        var canonicalAttributes: Set<String> = []
        for (key, value) in attributes where key != "xmlns" && !key.hasPrefix("xmlns:") {
            let attribute = name(key, scope: scope, attribute: true)
            guard !hasError, canonicalAttributes.insert(attribute).inserted else { hasError = true; parser.abortParsing(); return }
            if ["mc:Ignorable", "mc:ProcessContent", "mc:MustUnderstand", "Requires"].contains(attribute), compatibilityTokens(value, parser: parser) == nil { return }
            if attribute == "mc:Ignorable" {
                for prefix in compatibilityTokens(value, parser: parser) ?? [] {
                    if let uri = scope[String(prefix)] { settings.ignored.insert(uri) }
                    else { hasError = true }
                }
            } else if attribute == "mc:ProcessContent" {
                for qname in compatibilityTokens(value, parser: parser) ?? [] {
                    settings.processed.insert(name(String(qname), scope: scope))
                }
            }
        }
        guard settings.ignored.count <= 256, settings.processed.count <= 256 else {
            hasError = true; parser.abortParsing(); return
        }
        compatibility.append(settings)
        var tag = name(elementName, scope: scope)
        guard !hasError else { parser.abortParsing(); return }
        let prefix = elementName.split(separator: ":", maxSplits: 1).dropLast().first.map(String.init) ?? ""
        if tag.hasPrefix("extension"), !settings.ignored.contains(scope[prefix] ?? "") {
            tag = "required" + tag
        }
        names.append(tag)
        let transparent = tag.hasPrefix("extension") && settings.ignored.contains(scope[prefix] ?? "") && settings.processed.contains(tag)
        emitted.append(!transparent)
        if transparent { return }
        append("<" + tag, parser: parser)
        for (key, value) in attributes where key != "xmlns" && !key.hasPrefix("xmlns:") {
            var value = value
            if key == "Requires" || name(key, scope: scope, attribute: true) == "mc:MustUnderstand" {
                value = (compatibilityTokens(value, parser: parser) ?? []).map { prefix in
                    if prefix == "xml" { return "xml" }
                    return Self.prefixes[scope[String(prefix)] ?? ""] ?? "unsupported"
                }.joined(separator: " ")
            }
            var attribute = name(key, scope: scope, attribute: true)
            let prefix = key.split(separator: ":", maxSplits: 1).dropLast().first.map(String.init) ?? ""
            if attribute.hasPrefix("extension"), !settings.ignored.contains(scope[prefix] ?? "") {
                attribute = "required" + attribute
            }
            append(" \(attribute)=\"", parser: parser)
            appendEscaped(value, attribute: true, parser: parser)
            append("\"", parser: parser)
        }
        append(">", parser: parser)
    }

    /// A single attribute must not create millions of token objects before the
    /// normal node/output limits can run. maxSplits also bounds the temporary array.
    private func compatibilityTokens(_ value: String, parser: XMLParser) -> [Substring]? {
        guard !Task.isCancelled, value.utf8.count <= 16 * 1024 else {
            hasError = true; parser.abortParsing(); return nil
        }
        let tokens = value.split(maxSplits: 256, whereSeparator: \.isWhitespace)
        guard tokens.count <= 256 else { hasError = true; parser.abortParsing(); return nil }
        return tokens
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if let name = names.popLast(), emitted.popLast() == true { append("</" + name + ">", parser: parser) }
        if compatibility.count > 1 { compatibility.removeLast() }
        if scopeBytes.count > 1 { scopeBytes.removeLast() }
        if scopes.count > 1 { scopes.removeLast() }
    }
    private func countTextNode(_ parser: XMLParser) -> Bool {
        guard nodes < maximumNodes else { hasError = true; parser.abortParsing(); return false }
        nodes += 1
        return true
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if countTextNode(parser) { appendEscaped(string, parser: parser) }
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if countTextNode(parser) { appendEscaped(String(decoding: CDATABlock, as: UTF8.self), parser: parser) }
    }
    private func append(_ text: String, parser: XMLParser) {
        guard !hasError else { return }
        let bytes = text.utf8.count
        guard !Task.isCancelled, bytes <= maximumOutputBytes - outputBytes else {
            hasError = true; parser.abortParsing(); return
        }
        output += text; outputBytes += bytes
    }
    private func appendEscaped(_ text: String, attribute: Bool = false, parser: XMLParser) {
        // Escape in bounded chunks: neither character data nor attributes can
        // allocate an expanded copy larger than the DOM input budget.
        var chunk = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": chunk += "&amp;"
            case "<": chunk += "&lt;"
            case ">": chunk += "&gt;"
            case "\"" where attribute: chunk += "&quot;"
            default: chunk.unicodeScalars.append(scalar)
            }
            if chunk.utf8.count >= 4096 {
                append(chunk, parser: parser); chunk = ""
                if hasError { return }
            }
        }
        append(chunk, parser: parser)
    }
}
