import Foundation

/// Numbers admits reconstruction work as well as final output. A small IWA
/// string can be referenced by many cells, and sparse rows expand when padded.
/// The best-effort shared readers record exhaustion here; their throwing caller
/// checks cancellation first, then reports exhaustion as corruption.
final class IWAOutputBudget {
    private(set) var remainingBytes: Int
    private var remainingCells: Int
    private var remainingProjectedCells: Int
    private(set) var exceeded = false

    init(bytes: Int = 64 * 1024 * 1024, cells: Int = 1_000_000) {
        remainingBytes = max(0, bytes)
        remainingCells = max(0, cells)
        remainingProjectedCells = max(0, cells)
    }

    var active: Bool { !Task.isCancelled && !exceeded }

    @discardableResult
    func reserve(_ count: Int, copies: Int = 1) -> Bool {
        guard active else { return false }
        guard count >= 0, copies > 0, count <= remainingBytes / copies else {
            exceeded = true
            return false
        }
        remainingBytes -= count * copies
        return true
    }

    func reserveCell() -> Bool {
        guard active else { return false }
        guard remainingCells > 0 else { exceeded = true; return false }
        remainingCells -= 1
        return reserve(64)
    }

    func reserveGrid(rows: Int, columns: Int) -> Bool {
        guard active else { return false }
        guard rows > 0, columns > 0, rows <= remainingProjectedCells / columns else {
            exceeded = true
            return false
        }
        let count = rows * columns
        remainingProjectedCells -= count
        return reserve(count, copies: 32)
    }

    func check() throws {
        try Task.checkCancellation()
        if exceeded { throw PicoDocsError.fileCorrupted }
    }
}
