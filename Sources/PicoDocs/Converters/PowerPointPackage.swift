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
            _ = try archive.extract(entry) { chunk in
                try Task.checkCancellation()
                guard chunk.count <= self.entryLimit - bytes.count, chunk.count <= self.remaining,
                      !chunk.isEmpty || entry.uncompressedSize == 0 else { throw PicoDocsError.fileCorrupted }
                self.remaining -= chunk.count
                bytes.append(chunk)
            }
            return bytes
        } catch { failure = error; return nil }
    }
}

/// Validate XML and normalize known namespace aliases before the existing DOM walk.
/// SAX parsing rejects malformed parts and bounds nesting before SwiftSoup sees them.
final class PowerPointXML: NSObject, XMLParserDelegate {
    private var scopes: [[String: String]] = [[:]]
    private var names: [String] = []
    private var unknownPrefixes: [String: String] = [:]
    private var output = ""
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

    static func normalize(_ data: Data) -> String? {
        let parser = XMLParser(data: data)
        let delegate = PowerPointXML()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), !Task.isCancelled else { return nil }
        return delegate.output
    }

    private func name(_ raw: String, scope: [String: String], attribute: Bool = false) -> String {
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        let prefix = parts.count == 2 ? parts[0] : ""
        let local = parts.last!
        guard !attribute || !prefix.isEmpty, let uri = scope[prefix] else { return raw }
        if let canonical = Self.prefixes[uri] { return canonical.isEmpty ? local : canonical + ":" + local }
        // URI identity survives normalization, even for ignorable extensions.
        let synthetic = unknownPrefixes[uri] ?? "extension\(unknownPrefixes.count)"
        unknownPrefixes[uri] = synthetic
        return synthetic + ":" + local
    }

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
        output += "<" + tag
        for (key, value) in attributes where key != "xmlns" && !key.hasPrefix("xmlns:") {
            var value = value
            if key == "Requires" {
                value = value.split(separator: " ").map { Self.prefixes[scope[String($0)] ?? ""] ?? "unsupported" }.joined(separator: " ")
            }
            output += " \(name(key, scope: scope, attribute: true))=\"\(Self.escape(value))\""
        }
        output += ">"
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if let name = names.popLast() { output += "</" + name + ">" }
        if scopes.count > 1 { scopes.removeLast() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if Task.isCancelled { parser.abortParsing(); return }
        output += Self.escape(string)
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { output += Self.escape(String(decoding: CDATABlock, as: UTF8.self)) }
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
