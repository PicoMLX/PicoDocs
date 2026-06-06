//
//  DocumentConverter.swift
//  PicoDocs
//
//  The unit of the MarkItDown-style engine: a small, Sendable converter for one
//  family of formats. Detection has already run by the time `convert` is called,
//  so `accepts` only inspects `StreamInfo.detectedFormat` — it never re-sniffs
//  the bytes.
//

import Foundation

/// Errors a converter can throw to communicate intent to the registry.
public enum ConverterError: Error, Sendable {
    /// The converter declined this input; the registry should try the next
    /// candidate rather than treat it as a hard failure.
    case notAccepted
    /// The input could not be decoded with the available/declared encoding.
    case decodingFailed
    /// A required part/resource was missing from the input.
    case missingResource(String)
}

public protocol DocumentConverter: Sendable {

    /// Cheap check against already-resolved `StreamInfo` (typically just
    /// `info.detectedFormat`). Must not perform heavy work or decode `data`.
    func accepts(_ info: StreamInfo) -> Bool

    /// Convert the input into the canonical structured form.
    ///
    /// Throw `ConverterError.notAccepted` to defer to the next converter; throw
    /// any other error to signal a real failure (e.g. a corrupt document), which
    /// the registry will surface rather than silently degrade.
    func convert(_ data: Data, info: StreamInfo) async throws -> ConverterResult
}
