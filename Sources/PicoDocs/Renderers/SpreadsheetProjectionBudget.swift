import Foundation

/// Shared reader/writer budget for decoded cells and both text projections.
struct SpreadsheetProjectionBudget {
    private var remaining: Int
    private var remainingSheets: Int

    init(maximumBytes: Int = 64 * 1024 * 1024, maximumSheets: Int = 4096) {
        remaining = maximumBytes
        remainingSheets = maximumSheets
    }

    mutating func reserveGrid(rows: Int, columns: Int, name: String?) throws {
        // Bound per-sheet package parts, relationships, and section allocations,
        // including worksheets with no cells to charge against the byte budget.
        guard remainingSheets > 0 else { throw PicoDocsError.parsingError }
        remainingSheets -= 1
        // Even an empty worksheet retains a section, names and package metadata.
        let overhead = (name?.utf8.count ?? 0) + 16
        guard overhead <= remaining else { throw PicoDocsError.parsingError }
        remaining -= overhead
        guard columns > 0 else { return }
        guard rows > 0, rows <= 1_048_576, columns <= 16_384,
              rows <= 1_000_000 / columns else { throw PicoDocsError.parsingError }
        let bytes = rows * columns * 10 + columns * 8
        guard bytes <= remaining else { throw PicoDocsError.parsingError }
        remaining -= bytes
    }

    /// Account for retained row/cell arrays and XML wrappers in the writer.
    mutating func reserveWriterStorage(rows: Int, columns: Int) throws {
        guard rows >= 0, columns >= 0, rows <= 1_048_576, columns <= 16_384,
              columns == 0 || rows <= 1_000_000 / columns else { throw PicoDocsError.parsingError }
        let bytes = rows * 32 + rows * columns * 64
        guard bytes <= remaining else { throw PicoDocsError.parsingError }
        remaining -= bytes
    }

    mutating func reserveValue(_ value: String) throws {
        let bytes = value.utf8.count
        guard bytes <= remaining / 5 else { throw PicoDocsError.parsingError }
        let encodedBytes = SpreadsheetMLText.xmlEncodedByteCount(value)
        guard encodedBytes <= remaining else { throw PicoDocsError.parsingError }
        remaining -= max(bytes * 5, encodedBytes)
    }
}
