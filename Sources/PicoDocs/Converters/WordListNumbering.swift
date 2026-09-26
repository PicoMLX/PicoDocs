//
//  WordListNumbering.swift
//  PicoDocs
//
//  Resolves DOCX list membership and Markdown markers from `word/numbering.xml`
//  (and list styles in `word/styles.xml`), so numbered lists render as `1.`,
//  bulleted ones as `-`, nested levels are indented, and paragraphs whose
//  numbering is switched off (`w:numId="0"`) aren't list items at all.
//
//  Counters belong to concrete numbering instances. LibreOffice restart aliases
//  are handled only for its explicit startOverride/return-to-original pattern.

import Foundation
import ZIPFoundation
import SwiftSoup

final class WordListNumbering {

    private struct Level {
        let format: String   // w:numFmt, e.g. "decimal", "bullet", "none"
        let start: Int       // w:start
        let restart: Int?    // one-based triggering ancestor; zero means never
        var text: String? = nil
    }

    /// abstractNumId → ilvl → level definition.
    private var numberingStyleLinks: [String: String] = [:]
    private var abstractLevels: [String: [Int: Level]] = [:]
    /// numId → (abstractNumId, ilvl → startOverride).
    private var numbers: [String: (abstract: String, overrides: [Int: Int])] = [:]
    /// styleId → numbering its paragraph properties declare, and its parent style.
    private var styles: [String: (numID: String?, level: Int?, basedOn: String?)] = [:]

    private var counters: [String: [Int: Int]] = [:]
    private var markerWidths: [String: [Int: Int]] = [:]
    private var defaultStyle: String?
    private var documentDefaults: (numID: String?, level: Int?)?
    private var restartAfterBreak: Set<String> = []
    private var isLibreOffice = false
    private var lastInstance: [String: String] = [:]
    private var resumeAlias: (original: String, replacement: String)?
    private struct PartialLevel { let format: String?; let start: Int?; let restart: Int?; var text: String? = nil }
    private var levelOverrides: [String: [Int: PartialLevel]] = [:]

    /// Whether `numbering.xml` was found; without it, list paragraphs fall back
    /// to plain bullets.
    private(set) var isResolvable = false

    init(archive: Archive) {
        if let app = Self.xml(archive, path: "docProps/app.xml") {
            isLibreOffice = ((try? app.getElementsByTag("Application").text()) ?? "").hasPrefix("LibreOffice")
        }
        let numberingPath = WordConverter.relationshipTarget(archive, typeSuffix: "/numbering")
            .map { WordConverter.resolvePartPath($0, relativeTo: "word") } ?? "word/numbering.xml"
        let stylesPath = WordConverter.relationshipTarget(archive, typeSuffix: "/styles")
            .map { WordConverter.resolvePartPath($0, relativeTo: "word") } ?? "word/styles.xml"
        if let numbering = Self.xml(archive, path: numberingPath) {
            isResolvable = true
            parseNumbering(numbering)
        }
        if let styles = Self.xml(archive, path: stylesPath) {
            parseStyles(styles)
        }
    }

    /// The Markdown prefix (indent + marker) for a paragraph, or nil when it isn't
    /// a list item. `numPr` is the paragraph's own `w:numPr`, if any; `style` its
    /// `w:pStyle`, whose (inherited) numbering applies when the paragraph has none.
    func prefix(numPr: Element?, style: String?) -> String? {
        var numID = numPr.flatMap { Self.child(of: $0, named: "w:numid") }.flatMap { try? $0.attr("w:val") }
        var level = numPr.flatMap { Self.child(of: $0, named: "w:ilvl") }.flatMap { try? $0.attr("w:val") }.flatMap { Int($0) }
        if numID == nil || level == nil, let inherited = styleNumbering(style) {
            numID = numID ?? inherited.numID
            level = level ?? inherited.level
        }
        guard let numID = Self.canonicalID(numID), numID != "0" else { return nil }   // numId 0: numbering removed
        let ilvl = min(max(level ?? 0, 0), 8)

        guard isResolvable, let number = numbers[numID] else {
            return numPr == nil ? nil : "- "   // unknown definition: keep the old bullet
        }
        let abstract = number.abstract
        let definition = effectiveLevel(numID: numID, level: ilvl)
        if let alias = resumeAlias, alias.original == numID {
            counters[numID, default: [:]].merge(counters[alias.replacement] ?? [:]) { _, new in new }
            markerWidths[numID, default: [:]].merge(markerWidths[alias.replacement] ?? [:]) { _, new in new }
        }
        resumeAlias = nil
        if isLibreOffice, counters[numID] == nil, !number.overrides.isEmpty,
           let original = lastInstance[abstract], original != numID {
            resumeAlias = (original, numID)
        }
        lastInstance[abstract] = numID
        // Default: restart after the previous level (or any higher ancestor).
        // Explicit restart=0 preserves counters across all ancestor items.
        for deeper in (ilvl + 1)..<9 {
            let effective = effectiveLevel(numID: numID, level: deeper)
            let trigger = effective?.restart ?? deeper
            if trigger > 0 && ilvl < trigger {
                counters[numID]?[deeper] = nil
            }
        }
        markerWidths[numID] = markerWidths[numID]?.filter { $0.key < ilvl }

        // Invisible and bullet levels still participate in compound numbering.
        let start = number.overrides[ilvl] ?? definition?.start ?? 1
        let previous = counters[numID]?[ilvl]
        let count = previous.map { min($0, Int.max - 1) + 1 } ?? start
        counters[numID, default: [:]][ilvl] = count

        var marker: String
        switch definition?.format ?? "bullet" {
        case "none":
            return nil
        case "bullet":
            marker = "- "
        default:
            let simple = Self.formattedNumber(count, format: definition?.format ?? "decimal") + "."
            var label = definition?.text ?? simple
            for level in 0...8 {
                let effective = effectiveLevel(numID: numID, level: level)
                let value = counters[numID]?[level] ?? numbers[numID]?.overrides[level] ?? effective?.start ?? 1
                label = label.replacingOccurrences(of: "%\(level + 1)", with: Self.formattedNumber(value, format: effective?.format ?? "decimal"))
            }
            if label == "\(count)." { marker = label + " " }
            else {
                let escaped = label.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "*", with: "\\*")
                marker = "- " + escaped + " "
            }
        }
        let indent = (0..<ilvl).reduce(0) { $0 + (markerWidths[numID]?[$1] ?? 2) }
        markerWidths[numID, default: [:]][ilvl] = marker.hasPrefix("- ") ? 2 : marker.count
        return String(repeating: " ", count: indent) + marker
    }

    private func effectiveLevel(numID: String, level: Int, visited: Set<String> = []) -> Level? {
        guard !visited.contains(numID), visited.count < 16, let number = numbers[numID] else { return nil }
        var base = abstractLevels[number.abstract]?[level]
        if base == nil, let style = numberingStyleLinks[number.abstract],
           let linkedID = Self.canonicalID(styleNumbering(style)?.numID),
           let linked = effectiveLevel(numID: linkedID, level: level, visited: visited.union([numID])) {
            base = Level(format: linked.format, start: numbers[linkedID]?.overrides[level] ?? linked.start, restart: linked.restart, text: linked.text)
        }
        guard let override = levelOverrides[numID]?[level] else { return base }
        return Level(format: override.format ?? base?.format ?? "decimal",
                     start: override.start ?? base?.start ?? 1,
                     restart: override.restart ?? base?.restart, text: override.text ?? base?.text)
    }

    // MARK: - Parsing

    private func parseNumbering(_ document: Document) {
        for abstract in (try? document.getElementsByTag("w:abstractNum").array()) ?? [] {
            guard let id = Self.canonicalID(try? abstract.attr("w:abstractNumId")) else { continue }
            if ["1", "true", "on"].contains((try? abstract.attr("w15:restartNumberingAfterBreak")) ?? "") { restartAfterBreak.insert(id) }
            numberingStyleLinks[id] = Self.child(of: abstract, named: "w:numstylelink").flatMap { try? $0.attr("w:val") }
            var levels: [Int: Level] = [:]
            for level in abstract.children().array() where level.tagName().lowercased() == "w:lvl" {
                guard let ilvl = Int((try? level.attr("w:ilvl")) ?? ""), (0...8).contains(ilvl) else { continue }
                let format = Self.child(of: level, named: "w:numfmt").flatMap { try? $0.attr("w:val") } ?? "decimal"
                let start = Self.child(of: level, named: "w:start").flatMap { try? $0.attr("w:val") }.flatMap { Int($0) } ?? 1
                let restart = Self.child(of: level, named: "w:lvlrestart").flatMap { try? $0.attr("w:val") }.flatMap { Int($0) }
                levels[ilvl] = Level(format: format, start: max(0, start), restart: restart.flatMap { (0...ilvl).contains($0) ? $0 : nil }, text: Self.child(of: level, named: "w:lvltext").flatMap { try? $0.attr("w:val") })
            }
            abstractLevels[id] = levels
        }
        for number in (try? document.getElementsByTag("w:num").array()) ?? [] {
            guard let id = Self.canonicalID(try? number.attr("w:numId")),
                  let abstract = Self.child(of: number, named: "w:abstractnumid").flatMap({ try? $0.attr("w:val") }).flatMap(Self.canonicalID) else { continue }
            var overrides: [Int: Int] = [:]
            for override in number.children().array() where override.tagName().lowercased() == "w:lvloverride" {
                guard let ilvl = Int((try? override.attr("w:ilvl")) ?? ""), (0...8).contains(ilvl) else { continue }
                if let start = Self.child(of: override, named: "w:startoverride")
                    .flatMap({ try? $0.attr("w:val") }).flatMap({ Int($0) }) {
                    overrides[ilvl] = max(0, start)
                }
                if let level = Self.child(of: override, named: "w:lvl") {
                    let format = Self.child(of: level, named: "w:numfmt").flatMap { try? $0.attr("w:val") }
                    let start = Self.child(of: level, named: "w:start").flatMap { try? $0.attr("w:val") }.flatMap { Int($0) }
                    let restart = Self.child(of: level, named: "w:lvlrestart").flatMap { try? $0.attr("w:val") }.flatMap { Int($0) }
                    levelOverrides[id, default: [:]][ilvl] = PartialLevel(format: format, start: start.map { max(0, $0) }, restart: restart.flatMap { (0...ilvl).contains($0) ? $0 : nil }, text: Self.child(of: level, named: "w:lvltext").flatMap { try? $0.attr("w:val") })
                }
            }
            numbers[id] = (abstract, overrides)
        }
    }

    private func parseStyles(_ document: Document) {
        if let defaults = try? document.getElementsByTag("w:docDefaults").first(),
           let paragraph = Self.child(of: defaults, named: "w:pprdefault").flatMap({ Self.child(of: $0, named: "w:ppr") }),
           let numPr = Self.child(of: paragraph, named: "w:numpr") {
            documentDefaults = (Self.child(of: numPr, named: "w:numid").flatMap { try? $0.attr("w:val") },
                                Self.child(of: numPr, named: "w:ilvl").flatMap { try? $0.attr("w:val") }.flatMap(Int.init))
        }
        for style in (try? document.getElementsByTag("w:style").array()) ?? [] {
            guard let id = try? style.attr("w:styleId"), !id.isEmpty else { continue }
            if (try? style.attr("w:type")) == "paragraph",
               ["1", "true", "on"].contains((try? style.attr("w:default")) ?? "") { defaultStyle = id }
            let numPr = Self.child(of: style, named: "w:ppr").flatMap { Self.child(of: $0, named: "w:numpr") }
            styles[id] = (
                numID: numPr.flatMap { Self.child(of: $0, named: "w:numid") }.flatMap { try? $0.attr("w:val") },
                level: numPr.flatMap { Self.child(of: $0, named: "w:ilvl") }.flatMap { try? $0.attr("w:val") }.flatMap { Int($0) },
                basedOn: Self.child(of: style, named: "w:basedon").flatMap { try? $0.attr("w:val") }
            )
        }
    }

    /// The numbering a paragraph style declares, walking `w:basedOn` (bounded, so
    /// a cyclic chain can't loop).
    private func styleNumbering(_ styleID: String?) -> (numID: String?, level: Int?)? {
        var current = styleID ?? defaultStyle
        var numID: String?
        var level: Int?
        for _ in 0..<16 {
            guard let id = current, let style = styles[id] else { break }
            numID = numID ?? style.numID
            level = level ?? style.level
            if numID != nil && level != nil { break }
            current = style.basedOn
        }
        numID = numID ?? documentDefaults?.numID
        level = level ?? documentDefaults?.level
        return numID == nil && level == nil ? nil : (numID, level)
    }

    func sectionBreak() {
        for (id, number) in numbers where restartAfterBreak.contains(number.abstract) {
            counters[id] = nil
            markerWidths[id] = nil
        }
        resumeAlias = nil
    }

    private static func formattedNumber(_ value: Int, format: String) -> String {
        guard value > 0 else { return String(value) }
        if format == "lowerLetter" || format == "upperLetter" {
            var n = value, text = ""
            while n > 0 { n -= 1; text = String(UnicodeScalar(65 + n % 26)!) + text; n /= 26 }
            return format == "lowerLetter" ? text.lowercased() : text
        }
        if format == "lowerRoman" || format == "upperRoman", value < 4000 {
            var n = value, text = ""
            for (amount, symbol) in [(1000,"M"),(900,"CM"),(500,"D"),(400,"CD"),(100,"C"),(90,"XC"),(50,"L"),(40,"XL"),(10,"X"),(9,"IX"),(5,"V"),(4,"IV"),(1,"I")] {
                while n >= amount { text += symbol; n -= amount }
            }
            return format == "lowerRoman" ? text.lowercased() : text
        }
        return String(value)
    }

    private static func canonicalID(_ value: String?) -> String? {
        guard let value else { return nil }
        let digits = value.hasPrefix("+") ? value.dropFirst() : value[...]
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let trimmed = digits.drop { $0 == "0" }
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    private static func xml(_ archive: Archive, path: String) -> Document? {
        guard let data = WordConverter.readEntry(archive, path: path),
              let text = WordConverter.decodeText(data) else { return nil }
        return try? SwiftSoup.parse(text, "", SwiftSoup.Parser.xmlParser())
    }

    private static func child(of element: Element, named tag: String) -> Element? {
        element.children().first { $0.tagName().lowercased() == tag }
    }
}
