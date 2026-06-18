//
//  DocumentExporterRegistry.swift
//  PicoDocs
//
//  An immutable, Sendable registry of exporters — the write-side mirror of
//  `DocumentConverterRegistry`. Serialization is pure (result in, bytes out) with
//  no shared mutable state, so this is a value type rather than an actor.
//

import Foundation

public struct DocumentExporterRegistry: Sendable {

    private struct Entry: Sendable {
        let priority: Double
        let exporter: any DocumentExporter
    }

    /// Kept sorted by ascending priority (see `registering`).
    private let entries: [Entry]

    /// Standard priorities. Lower is tried first (more specific wins).
    public enum Priority {
        public static let specific: Double = 0
        public static let generic: Double = 10
    }

    public init() {
        self.entries = []
    }

    private init(entries: [Entry]) {
        self.entries = entries
    }

    /// Returns a new registry with `exporter` added. Value-returning so it can be
    /// chained on a `let` (third parties extend the engine this way).
    public func registering(_ exporter: any DocumentExporter, priority: Double = Priority.specific) -> DocumentExporterRegistry {
        // Keep `entries` sorted by ascending priority at registration time so
        // `write` doesn't re-sort on every call. Insert after equal-priority
        // entries to preserve registration order among ties (stable ordering).
        var updated = entries
        let index = updated.firstIndex { $0.priority > priority } ?? updated.endIndex
        updated.insert(Entry(priority: priority, exporter: exporter), at: index)
        return DocumentExporterRegistry(entries: updated)
    }

    /// The default registry with all built-in exporters registered.
    public static let `default`: DocumentExporterRegistry = makeDefault()

    static func makeDefault() -> DocumentExporterRegistry {
        var registry = DocumentExporterRegistry()
            .registering(WordprocessingMLExporter(), priority: Priority.specific)
            .registering(XLSXExporter(), priority: Priority.specific)
            .registering(PPTXExporter(), priority: Priority.specific)
        #if canImport(AppKit) || canImport(UIKit)
        // RTF is written via NSAttributedString (Apple-only). On other platforms
        // `.rtf` simply has no exporter and `write` throws.
        registry = registry.registering(AttributedStringRTFExporter(), priority: Priority.specific)
        #endif
        // NOTE: `AttributedStringDOCXExporter` is intentionally NOT registered by
        // default. The hand-rolled `WordprocessingMLExporter` is the primary, all-
        // platform DOCX writer (and the round-trip oracle); the Apple path is kept
        // available for opt-in `.registering(...)` and round-trip testing so we
        // don't ship two DOCX semantics. See its file header.
        return registry
    }

    /// Serialize `result` to `format` using the first accepting exporter
    /// (ascending priority).
    ///
    /// Fallthrough semantics mirror `DocumentConverterRegistry`: an exporter that
    /// throws `.notAccepted` or `.platformUnavailable` defers to the next
    /// candidate; `.serializationFailed` (an accepting exporter that genuinely
    /// failed) propagates rather than degrading to a lower-fidelity writer.
    public func write(_ result: ConverterResult, format: ExportableFileType) throws -> Data {
        for entry in entries {
            guard entry.exporter.accepts(format) else { continue }
            do {
                return try entry.exporter.write(result, format: format)
            } catch let error as ExporterError {
                switch error {
                case .notAccepted, .platformUnavailable: continue
                case .serializationFailed: throw error
                }
            }
        }
        throw PicoDocsError.unableToExportToRequestedFormat
    }
}
