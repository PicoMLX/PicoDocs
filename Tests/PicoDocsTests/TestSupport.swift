//
//  TestSupport.swift
//  PicoDocsTests
//
//  Shared helpers for loading the binary fixtures bundled with the test target.
//  The OOXML/EPUB fixtures are minimal-but-valid archives (see the PR notes for
//  how they're generated); the PDF is a real sample document.
//

import Foundation

enum Fixture {

    enum FixtureError: Error, CustomStringConvertible {
        case missing(String)
        var description: String {
            switch self {
            case .missing(let name): return "Missing test fixture: \(name)"
            }
        }
    }

    /// Locates a bundled fixture, tolerating both the `Resources/`-subdirectory
    /// layout (`.copy("Resources")`) and a flattened layout.
    static func url(_ name: String, _ ext: String) throws -> URL {
        if let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources") {
            return url
        }
        if let url = Bundle.module.url(forResource: name, withExtension: ext) {
            return url
        }
        throw FixtureError.missing("\(name).\(ext)")
    }

    static func data(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: url(name, ext))
    }

    /// A third-party test-suite file under `Resources/Corpus/` (sources and
    /// licenses in the README there), by its path relative to that folder.
    static func corpusURL(_ path: String) throws -> URL {
        let file = path as NSString
        let name = file.lastPathComponent as NSString
        let directory = ["Resources/Corpus", file.deletingLastPathComponent].filter { !$0.isEmpty }.joined(separator: "/")
        if let url = Bundle.module.url(forResource: name.deletingPathExtension, withExtension: name.pathExtension, subdirectory: directory) {
            return url
        }
        throw FixtureError.missing(path)
    }

    static func corpusData(_ path: String) throws -> Data {
        try Data(contentsOf: corpusURL(path))
    }
}
