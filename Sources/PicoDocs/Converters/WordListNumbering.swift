//
//  WordListNumbering.swift
//  PicoDocs
//
//  Resolves DOCX list membership and Markdown markers from `word/numbering.xml`
//  (and list styles in `word/styles.xml`), so numbered lists render as `1.`,
//  bulleted ones as `-`, nested levels are indented, and paragraphs whose
//  numbering is switched off (`w:numId="0"`) aren't list items at all.
//
//  Counting follows Word: a `w:num` instance points at an `w:abstractNum`, and
//  numbering is counted per abstract list and level — separate `w:num`s over one
//  abstract list continue each other — so a `w:lvlOverride/w:startOverride`
//  restarts the count the first time its `w:num` is used, and later paragraphs
//  on the original `w:num` carry on from there. A deeper level restarts after
//  an item at a shallower one.
//

import Foundation
import ZIPFoundation
import SwiftSoup

final class WordListNumbering {

    private struct Level {
        let format: String   // w:numFmt, e.g. "decimal", "bullet", "none"
        let start: Int       // w:start
    }

    /// abstractNumId → ilvl → level definition.
    private var abstractLevels: [String: [Int: Level]] = [:]
    /// numId → (abstractNumId, ilvl → startOverride).
    private var numbers: [String: (abstract: String, overrides: [Int: Int])] = [:]
    /// styleId → numbering its paragraph properties declare, and its parent style.
    private var styles: [String: (numID: String?, level: Int?, basedOn: String?)] = [:]

    private var counters: [String: [Int: Int]] = [:]
    private var markerWidths: [String: [Int: Int]] = [:]
    private var startedNumbers: Set<String> = []

    /// Whether `numbering.xml` was found; without it, list paragraphs fall back
    /// to plain bullets.
    private(set) var isResolvable = false

    init(archive: Archive) {
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
        let definition = abstractLevels[abstract]?[ilvl]

        if startedNumbers.insert(numID).inserted {
            for (overrideLevel, start) in number.overrides {
                counters[abstract, default: [:]][overrideLevel] = start - 1
            }
        }
        // An item restarts every deeper level of its list.
        counters[abstract] = counters[abstract]?.filter { $0.key <= ilvl }
        markerWidths[abstract] = markerWidths[abstract]?.filter { $0.key < ilvl }

        let marker: String
        switch definition?.format ?? "bullet" {
        case "none":
            return nil
        case "bullet":
            marker = "- "
        default:
            let count = (counters[abstract]?[ilvl] ?? (definition?.start ?? 1) - 1) + 1
            counters[abstract, default: [:]][ilvl] = count
            marker = "\(count). "
        }
        let indent = (0..<ilvl).reduce(0) { $0 + (markerWidths[abstract]?[$1] ?? 2) }
        markerWidths[abstract, default: [:]][ilvl] = marker.count
        return String(repeating: " ", count: indent) + marker
    }

    // MARK: - Parsing

    private func parseNumbering(_ document: Document) {
        for abstract in (try? document.getElementsByTag("w:abstractNum").array()) ?? [] {
            guard let id = try? abstract.attr("w:abstractNumId"), !id.isEmpty else { continue }
            var levels: [Int: Level] = [:]
            for level in abstract.children().array() where level.tagName().lowercased() == "w:lvl" {
                guard let ilvl = Int((try? level.attr("w:ilvl")) ?? "") else { continue }
                let format = Self.child(of: level, named: "w:numfmt").flatMap { try? $0.attr("w:val") } ?? "decimal"
                let start = Self.child(of: level, named: "w:start").flatMap { try? $0.attr("w:val") }.flatMap { Int($0) } ?? 1
                levels[ilvl] = Level(format: format, start: start)
            }
            abstractLevels[id] = levels
        }
        for number in (try? document.getElementsByTag("w:num").array()) ?? [] {
            guard let id = try? number.attr("w:numId"), !id.isEmpty,
                  let abstract = Self.child(of: number, named: "w:abstractnumid").flatMap({ try? $0.attr("w:val") }) else { continue }
            var overrides: [Int: Int] = [:]
            for override in number.children().array() where override.tagName().lowercased() == "w:lvloverride" {
                guard let ilvl = Int((try? override.attr("w:ilvl")) ?? ""),
                      let start = Self.child(of: override, named: "w:startoverride")
                        .flatMap({ try? $0.attr("w:val") }).flatMap({ Int($0) }) else { continue }
                overrides[ilvl] = start
            }
            numbers[id] = (abstract, overrides)
        }
    }

    private func parseStyles(_ document: Document) {
        for style in (try? document.getElementsByTag("w:style").array()) ?? [] {
            guard let id = try? style.attr("w:styleId"), !id.isEmpty else { continue }
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
        var current = styleID
        var numID: String?
        var level: Int?
        for _ in 0..<16 {
            guard let id = current, let style = styles[id] else { break }
            numID = numID ?? style.numID
            level = level ?? style.level
            if numID != nil { break }
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
