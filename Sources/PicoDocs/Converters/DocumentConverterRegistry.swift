//
//  DocumentConverterRegistry.swift
//  PicoDocs
//
//  An immutable, Sendable registry of converters. Conversion is pure (data in,
//  result out) with no shared mutable state, so this is a value type rather than
//  an actor. Replaces the old `Parser.parser(for:url:)` if/else factory.
//

import Foundation

public struct DocumentConverterRegistry: Sendable {

    private struct Entry: Sendable {
        let priority: Double
        let converter: any DocumentConverter
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

    /// Returns a new registry with `converter` added. Value-returning so it can
    /// be chained on a `let` (third parties extend the engine this way).
    public func registering(_ converter: any DocumentConverter, priority: Double = Priority.specific) -> DocumentConverterRegistry {
        // Keep `entries` sorted by ascending priority at registration time so
        // `convert` doesn't re-sort on every call. Insert after equal-priority
        // entries to preserve registration order among ties (stable ordering).
        var updated = entries
        let index = updated.firstIndex { $0.priority > priority } ?? updated.endIndex
        updated.insert(Entry(priority: priority, converter: converter), at: index)
        return DocumentConverterRegistry(entries: updated)
    }

    /// The default registry with all built-in converters registered.
    public static let `default`: DocumentConverterRegistry = makeDefault()

    static func makeDefault() -> DocumentConverterRegistry {
        DocumentConverterRegistry()
            .registering(HTMLConverter(), priority: Priority.specific)
            .registering(PlainTextConverter(), priority: Priority.generic)
    }

    /// Convert `data` using the first accepting converter (ascending priority).
    ///
    /// Failure semantics: a converter that `accepts` but then throws anything
    /// other than `ConverterError.notAccepted` fails the whole conversion — the
    /// error propagates. We deliberately do **not** fall through to a more
    /// generic converter on a real failure, so e.g. a corrupt `.docx` surfaces
    /// as an error instead of being silently mis-handled as plain text.
    public func convert(_ data: Data, info: StreamInfo) async throws -> ConverterResult {
        // `entries` is kept sorted by ascending priority at registration time.
        for entry in entries {
            try Task.checkCancellation()
            guard entry.converter.accepts(info) else { continue }
            do {
                return try await entry.converter.convert(data, info: info)
            } catch let error as ConverterError {
                if case .notAccepted = error { continue }
                throw error
            }
        }
        throw PicoDocsError.documentTypeNotSupported
    }
}
