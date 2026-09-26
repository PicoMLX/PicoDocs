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
    private var isLibreOffice = false
    private var lastInstance: [String: String] = [:]
    private var resumeAlias: (original: String, replacement: String)?
    private var levelOverrides: [String: [Int: Level]] = [:]

    /// Whether `numbering.xml` was found; without it, list paragraphs fall back
    /// to plain bullets.
    private(set) var isResolvable = false

    init(archive: Archive) {
        if let app = Self.xml(archive, path: "docProps/app.xml") {
            isLibreOffice = ((try? app.getElementsByTag("Application").text()) ?? "").hasPrefix("LibreOffice")
        }
        if let numbering = Self.xml(archive, path: "word/numbering.xml") {
            isResolvable = true
            parseNumbering(numbering)
        }
        if let styles = Self.xml(archive, path: "word/styles.xml") {
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
        guard let numID, numID != "0" else { return nil }   // numId 0: numbering removed
        let ilvl = min(max(level ?? 0, 0), 8)

        guard isResolvable, let number = numbers[numID] else {
            return numPr == nil ? nil : "- "   // unknown definition: keep the old bullet
        }
        let abstract = number.abstract
        let definition = effectiveLevel(numID: numID, level: ilvl)
        if let alias = resumeAlias, alias.original == numID {
            counters[numID] = counters[alias.replacement]
            markerWidths[numID] = markerWidths[alias.replacement]
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

        let marker: String
        switch definition?.format ?? "bullet" {
        case "none":
            return nil
        case "bullet":
            marker = "- "
        default:
            let start = number.overrides[ilvl] ?? definition?.start ?? 1
            let previous = counters[numID]?[ilvl]
            let count = previous.map { min($0, Int.max - 1) + 1 } ?? start
            counters[numID, default: [:]][ilvl] = count
            marker = "\(count). "
        }
        let indent = (0..<ilvl).reduce(0) { $0 + (markerWidths[numID]?[$1] ?? 2) }
        markerWidths[numID, default: [:]][ilvl] = marker.count
        return String(repeating: " ", count: indent) + marker
    }

    private func effectiveLevel(numID: String, level: Int, visited: Set<String> = []) -> Level? {
        guard !visited.contains(numID), visited.count < 16, let number = numbers[numID] else { return nil }
        if let direct = levelOverrides[numID]?[level] ?? abstractLevels[number.abstract]?[level] { return direct }
        guard let style = numberingStyleLinks[number.abstract],
              let linkedID = styleNumbering(style)?.numID,
              let linked = effectiveLevel(numID: linkedID, level: level, visited: visited.union([numID])) else { return nil }
        return Level(format: linked.format, start: numbers[linkedID]?.overrides[level] ?? linked.start, restart: linked.restart)
    }

    // MARK: - Parsing

    private func parseNumbering(_ document: Document) {
        for abstract in (try? document.getElementsByTag("w:abstractNum").array()) ?? [] {
            guard let id = try? abstract.attr("w:abstractNumId"), !id.isEmpty else { continue }
            numberingStyleLinks[id] = Self.child(of: abstract, named: "w:numstylelink").flatMap { try? $0.attr("w:val") }
            var levels: [Int: Level] = [:]
            for level in abstract.children().array() where level.tagName().lowercased() == "w:lvl" {
                guard let ilvl = Int((try? level.attr("w:ilvl")) ?? ""), (0...8).contains(ilvl) else { continue }
                let format = Self.child(of: level, named: "w:numfmt").flatMap { try? $0.attr("w:val") } ?? "decimal"
                let start = Self.child(of: level, named: "w:start").flatMap { try? $0.attr("w:val") }.flatMap { Int($0) } ?? 1
                let restart = Self.child(of: level, named: "w:lvlrestart").flatMap { try? $0.attr("w:val") }.flatMap { Int($0) }
                levels[ilvl] = Level(format: format, start: max(0, start), restart: restart.flatMap { (0...ilvl).contains($0) ? $0 : nil })
            }
            abstractLevels[id] = levels
        }
        for number in (try? document.getElementsByTag("w:num").array()) ?? [] {
            guard let id = try? number.attr("w:numId"), !id.isEmpty,
                  let abstract = Self.child(of: number, named: "w:abstractnumid").flatMap({ try? $0.attr("w:val") }) else { continue }
            var overrides: [Int: Int] = [:]
            for override in number.children().array() where override.tagName().lowercased() == "w:lvloverride" {
                guard let ilvl = Int((try? override.attr("w:ilvl")) ?? ""), (0...8).contains(ilvl) else { continue }
                if let start = Self.child(of: override, named: "w:startoverride")
                    .flatMap({ try? $0.attr("w:val") }).flatMap({ Int($0) }) {
                    overrides[ilvl] = max(0, start)
                }
                if let level = Self.child(of: override, named: "w:lvl") {
                    let base = abstractLevels[abstract]?[ilvl]
                    let format = Self.child(of: level, named: "w:numfmt").flatMap { try? $0.attr("w:val") } ?? base?.format ?? "decimal"
                    let start = Self.child(of: level, named: "w:start").flatMap { try? $0.attr("w:val") }.flatMap { Int($0) } ?? base?.start ?? 1
                    let restart = Self.child(of: level, named: "w:lvlrestart").flatMap { try? $0.attr("w:val") }.flatMap { Int($0) } ?? base?.restart
                    levelOverrides[id, default: [:]][ilvl] = Level(format: format, start: max(0, start), restart: restart.flatMap { (0...ilvl).contains($0) ? $0 : nil })
                }
            }
            numbers[id] = (abstract, overrides)
        }
    }

    private func parseStyles(_ document: Document) {
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
        return numID == nil && level == nil ? nil : (numID, level)
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
