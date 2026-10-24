import Foundation

/// Zipping a package-format document as a folder (Mail attachments, web
/// uploads) nests the whole package under one top-level directory —
/// `Talk.key/Index.zip`, `Budget.numbers/Index/…`. Observing every entry path
/// finds that directory, the package root, or nil when the entries don't share
/// exactly one. macOS's `__MACOSX/` resource-fork entries sit beside the folder
/// and don't count as a second directory.
struct IWAPackageFolder {
    private(set) var root: String?
    private var shared = true

    mutating func observe(_ path: String) {
        guard shared, !path.hasPrefix("__MACOSX/") else { return }
        guard let slash = path.firstIndex(of: "/"), slash != path.startIndex else { shared = false; root = nil; return }
        let folder = String(path[...slash])
        if root == nil { root = folder } else if root != folder { shared = false; root = nil }
    }
}
