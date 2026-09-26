import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import ZIPFoundation

/// One conversion's extraction budget, charged for actual inflated bytes.
final class PowerPointPackage {
    let archive: Archive
    private var remaining: Int
    private let entryLimit: Int
    private(set) var failure: Error?
    var contentTypes: [String: String]?
    var relationshipMaps: [String: [String: PowerPointConverter.Relationship]] = [:]

    init(archive: Archive, entryLimit: Int = 64 * 1024 * 1024, totalLimit: Int = 256 * 1024 * 1024) {
        self.archive = archive
        self.entryLimit = entryLimit
        self.remaining = totalLimit
    }

    func fail(_ error: Error) { if failure == nil { failure = error } }

    func check() throws {
        try Task.checkCancellation()
        if let failure { throw failure }
    }

    func read(_ path: String) -> Data? {
        do {
            try check()
            let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
            guard let entry = archive[clean] else { return nil }
            let size = UInt64(archive.data?.count ?? 0)
            guard entry.uncompressedSize <= UInt64(entryLimit), entry.uncompressedSize <= UInt64(remaining),
                  entry.compressedSize <= size, entry.isCompressed || entry.uncompressedSize <= size else {
                throw PicoDocsError.fileCorrupted
            }
            var bytes = Data()
            bytes.reserveCapacity(Int(min(entry.uncompressedSize, 1024 * 1024)))
            let checksum = try archive.extract(entry) { chunk in
                try Task.checkCancellation()
                guard chunk.count <= self.entryLimit - bytes.count, chunk.count <= self.remaining,
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
    private var scopes: [[String: String]] = [[:]]
    private var names: [String] = []
    private var unknownPrefixes: [String: String] = [:]
    private var output = ""
    private var hasError = false
    private var outputBytes = 0
    private var maximumOutputBytes = 64 * 1024 * 1024
    private static let prefixes = [
        "http://schemas.openxmlformats.org/presentationml/2006/main": "p",
        "http://schemas.openxmlformats.org/drawingml/2006/main": "a",
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships": "r",
        "http://schemas.openxmlformats.org/markup-compatibility/2006": "mc",
        "http://purl.org/dc/elements/1.1/": "dc",
        "http://purl.oclc.org/ooxml/presentationml/main": "p",
        "http://purl.oclc.org/ooxml/drawingml/main": "a",
        "http://purl.oclc.org/ooxml/officeDocument/relationships": "r",
        "http://schemas.openxmlformats.org/package/2006/relationships": "",
        "http://schemas.openxmlformats.org/package/2006/content-types": ""
    ]

    static func normalize(_ data: Data, maximumOutputBytes: Int = 64 * 1024 * 1024) -> String? {
        guard !containsDoctype(data) else { return nil }
        let parser = XMLParser(data: data)
        let delegate = PowerPointXML()
        delegate.maximumOutputBytes = maximumOutputBytes
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), !delegate.hasError, !Task.isCancelled else { return nil }
        return delegate.output
    }

    /// Inspect the XML prolog without expanding entities. Ignoring NUL padding
    /// recognizes ASCII declaration tokens in UTF-8, UTF-16 and UTF-32 inputs.
    /// Comments, processing instructions and CDATA cannot introduce a DTD.
    private static func containsDoctype(_ data: Data) -> Bool {
        var tail: [UInt8] = []
        let declaration = Array("<!DOCTYPE".utf8), comment = Array("<!--".utf8)
        let cdata = Array("<![CDATA[".utf8), processing = Array("<?".utf8)
        var ending: [UInt8]?
        for byte in data where byte != 0 {
            tail.append(byte)
            if tail.count > 9 { tail.removeFirst() }
            if let terminator = ending {
                if tail.suffix(terminator.count).elementsEqual(terminator) { ending = nil; tail.removeAll(keepingCapacity: true) }
            } else if tail.suffix(comment.count).elementsEqual(comment) { ending = Array("-->".utf8) }
            else if tail.suffix(cdata.count).elementsEqual(cdata) { ending = Array("]]>".utf8) }
            else if tail.suffix(processing.count).elementsEqual(processing) { ending = Array("?>".utf8) }
            else if tail.elementsEqual(declaration) { return true }
        }
        return false
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
        let synthetic = unknownPrefixes[uri] ?? "extension\(unknownPrefixes.count)"
        unknownPrefixes[uri] = synthetic
        return synthetic + ":" + local
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { hasError = true }
    func parser(_ parser: XMLParser, validationErrorOccurred validationError: Error) { hasError = true }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        guard names.count < 128, !Task.isCancelled else { parser.abortParsing(); return }
        var scope = scopes.last!
        for (key, value) in attributes {
            if key == "xmlns" { scope[""] = value }
            else if key.hasPrefix("xmlns:") { scope[String(key.dropFirst(6))] = value }
        }
        scopes.append(scope)
        let tag = name(elementName, scope: scope)
        names.append(tag)
        append("<" + tag, parser: parser)
        for (key, value) in attributes where key != "xmlns" && !key.hasPrefix("xmlns:") {
            var value = value
            if key == "Requires" {
                value = value.split(separator: " ").map { Self.prefixes[scope[String($0)] ?? ""] ?? "unsupported" }.joined(separator: " ")
            }
            append(" \(name(key, scope: scope, attribute: true))=\"", parser: parser)
            appendEscaped(value, attribute: true, parser: parser)
            append("\"", parser: parser)
        }
        append(">", parser: parser)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if let name = names.popLast() { append("</" + name + ">", parser: parser) }
        if scopes.count > 1 { scopes.removeLast() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        appendEscaped(string, parser: parser)
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        appendEscaped(String(decoding: CDATABlock, as: UTF8.self), parser: parser)
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
