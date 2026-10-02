import Foundation

/// The parser needs only a short name prefix to recognize common monospace
/// families. Font identities and retained prefixes have their own admission.
final class RTFFontTable {
    private var names: [Int: String] = [:]
    private var monospace: Set<Int> = []
    private var remainingBytes: Int
    private let maximumFonts: Int
    private(set) var exceeded = false
    init(maximumFonts: Int = 4_096, maximumBytes: Int = 1024 * 1024) {
        self.maximumFonts = max(0, maximumFonts); remainingBytes = max(0, maximumBytes)
    }
    @discardableResult func admit(_ font: Int) -> Bool {
        guard !exceeded else { return false }
        if names[font] != nil { return true }
        guard names.count < maximumFonts, remainingBytes >= 128 else { exceeded = true; return false }
        remainingBytes -= 128; names[font] = ""
        return true
    }
    func append(_ text: String, font: Int) {
        guard admit(font), var name = names[font] else { return }
        var bytes = name.utf8.count
        for scalar in text.unicodeScalars {
            let width = String(scalar).utf8.count
            if width > 256 - bytes { break }
            guard width <= remainingBytes else { exceeded = true; return }
            remainingBytes -= width; bytes += width; name.unicodeScalars.append(scalar)
        }
        names[font] = name
    }
    func finish(_ font: Int) {
        guard !exceeded, let prefix = names[font] else { return }
        let name = prefix.lowercased()
        if ["menlo", "monaco", "courier", "consolas", "sfmono", "sfnsmono", "monospaced"].contains(where: name.contains) { monospace.insert(font) }
    }
    func markMonospace(_ font: Int) { if admit(font) { monospace.insert(font) } }
    func isMonospace(_ font: Int) -> Bool { monospace.contains(font) }
    func check() throws { if exceeded { throw PicoDocsError.fileCorrupted } }
}
