import Foundation

/// Admission for envelope structures, copied protobuf fields and graph entries,
/// separate from the decoded byte and reconstructed-output budgets. Callers share
/// it across streams and repeated parsing; best-effort readers record failure,
/// and converters check it before accepting any partial result.
final class IWAObjectBudget {
    private(set) var remainingBytes: Int
    private var remainingObjects: Int
    private(set) var exceeded = false
    init(bytes: Int = 64 * 1024 * 1024, objects: Int = 250_000) {
        remainingBytes = max(0, bytes); remainingObjects = max(0, objects)
    }
    var active: Bool { !Task.isCancelled && !exceeded }
    func reserve(_ count: Int, copies: Int = 1) -> Bool {
        guard active else { return false }
        guard count >= 0, copies > 0, count <= remainingBytes / copies else { exceeded = true; return false }
        remainingBytes -= count * copies
        return true
    }
    func reserveInfo() -> Bool {
        guard active else { return false }
        guard remainingObjects > 0 else { exceeded = true; return false }
        remainingObjects -= 1
        return reserve(256)
    }
    func check() throws {
        try Task.checkCancellation()
        if exceeded { throw PicoDocsError.fileCorrupted }
    }
}
