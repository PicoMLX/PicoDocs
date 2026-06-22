//
//  DocumentExporter.swift
//  PicoDocs
//
//  The write-side counterpart of `DocumentConverter`: a small, Sendable serializer
//  that turns a canonical `ConverterResult` into office-file bytes for one family
//  of formats. The requested `ExportableFileType` has already been chosen by the
//  caller, so `accepts` only inspects the format — it never inspects the result.
//
//  Exporters are synchronous (`throws`, not `async`): serialization is pure CPU
//  with no I/O, unlike converters which may touch PDFKit/Vision/network.
//

import Foundation

/// Errors an exporter can throw to communicate intent to the registry.
public enum ExporterError: Error, Sendable {
    /// The exporter declined this format; the registry should try the next
    /// candidate rather than treat it as a hard failure.
    case notAccepted
    /// The exporter accepts the format in principle, but the platform API it needs
    /// is unavailable here (e.g. `NSAttributedString`'s `.officeOpenXML` on tvOS).
    /// The registry falls through to the next candidate, exactly like `.notAccepted`.
    case platformUnavailable
    /// An accepting exporter genuinely failed to serialize. The registry surfaces
    /// this rather than silently falling through to a lower-fidelity writer.
    case serializationFailed(String)
}

public protocol DocumentExporter: Sendable {

    /// Cheap check against the requested format only. Must not inspect the result
    /// or perform heavy work.
    func accepts(_ format: ExportableFileType) -> Bool

    /// Serialize the canonical structured form into office-file bytes.
    ///
    /// Throw `ExporterError.notAccepted` / `.platformUnavailable` to defer to the
    /// next exporter; throw `.serializationFailed` for a real failure, which the
    /// registry surfaces rather than degrading silently.
    func write(_ result: ConverterResult, format: ExportableFileType) throws -> Data
}
