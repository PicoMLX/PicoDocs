//
//  IWorkExportSpike.swift
//  PicoDocs
//
//  Research spike notes — there is intentionally NO Pages/Keynote writer.
//  `ExportableFileType.pages` / `.keynote` report `isImplemented == false`, are not
//  registered in `DocumentExporterRegistry.default`, and `PicoDocsEngine.write(...)`
//  throws `PicoDocsError.unableToExportToRequestedFormat` for them.
//
//  Why writing iWork third-party is impractical (vs. the feasible OOXML writers):
//
//  - An iWork file is a ZIP whose document model lives in `Index/*.iwa` archives.
//    Each `.iwa` is Snappy-framed protobuf (see the read side:
//    `Converters/Pages/Snappy.swift`, `IWAArchive.swift`, `ProtobufReader.swift`).
//    The read path only *decodes* these and only extracts plain text — even reading
//    headings/tables/styles is deferred there.
//
//  - Writing requires emitting a valid TSP object graph (component archives, object
//    identifiers, the message-info table, and document/slide objects) that Pages/
//    Keynote's strict importer accepts. Apple publishes no schema; the proto
//    definitions are reverse-engineered and version-fragile, and the project has no
//    `SwiftProtobuf` dependency.
//
//  Recommended path for "export to Pages/Keynote": export OOXML (`.docx` / `.pptx`)
//  and let Pages/Keynote import it — they open OOXML cleanly. Revisit a native iWork
//  writer only if a spike demonstrates a reliable, version-stable encoder.
//

import Foundation

enum IWorkExportSpike {
    /// The formats this spike covers; deliberately unimplemented (see file header).
    static let deferredFormats: [ExportableFileType] = [.pages, .keynote]
}
