import Foundation

/// Empty streams still retain names/array slots and consume traversal work.
/// One allowance covers the outer archive and a nested Index.zip together.
struct IWAComponentBudget {
    private var entries: Int
    private var components: Int
    private var bytes: Int
    private var paths: Set<String> = []
    init(entries: Int = 16_384, components: Int = 16_384, bytes: Int = 8 * 1024 * 1024) {
        self.entries = max(0, entries); self.components = max(0, components); self.bytes = max(0, bytes)
    }
    mutating func scan(_ path: String) throws {
        try Task.checkCancellation()
        let nameBytes = path.utf8.count
        guard entries > 0, bytes >= 256, nameBytes <= bytes - 256 else { throw PicoDocsError.fileCorrupted }
        entries -= 1; bytes -= 256 + nameBytes
    }
    mutating func retainComponent(_ path: String) throws {
        try Task.checkCancellation()
        guard components > 0 else { throw PicoDocsError.fileCorrupted }
        components -= 1
        // scan already admits each path and structural storage before this set.
        // An exact duplicate cannot have a unique component/graph identity.
        guard paths.insert(path).inserted else { throw PicoDocsError.fileCorrupted }
    }
}
