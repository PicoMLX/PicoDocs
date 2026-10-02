import Foundation

/// Stable, unique heading fragments shared by Office import/export.
enum MarkdownHeadingAnchors {
    static func slugs(_ titles: [String]) -> [String] {
        var used: Set<String> = []
        var nextSuffix: [String: Int] = [:]
        return titles.map { title in
            let base = String(title.lowercased().unicodeScalars.filter {
                !CharacterSet.punctuationCharacters.union(.symbols).contains($0) || $0 == "-" || $0 == "_"
            }).replacingOccurrences(of: "\\s", with: "-", options: .regularExpression)
            var slug = base, suffix = nextSuffix[base, default: 1]
            while used.contains(slug) { slug = "\(base)-\(suffix)"; suffix += 1 }
            nextSuffix[base] = suffix
            used.insert(slug)
            return slug
        }
    }
}
