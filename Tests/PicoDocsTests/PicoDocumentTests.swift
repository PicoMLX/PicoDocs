//
//  PicoDocumentTests.swift
//  PicoDocsTests
//
//  The observable document model: identity, ownership, and re-fetching.
//

import Foundation
import Testing
@testable import PicoDocs

@Suite("PicoDocument")
@MainActor
struct PicoDocumentTests {

    /// A fresh temporary directory holding `files` (name → contents).
    private func makeDirectory(_ files: [String: String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicoDocumentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, contents) in files {
            try Data(contents.utf8).write(to: directory.appendingPathComponent(name))
        }
        return directory
    }

    @Test("Documents equal by URL hash equally")
    func hashMatchesEquality() {
        let url = URL(fileURLWithPath: "/tmp/report.txt")
        let a = PicoDocument(url: url)
        let b = PicoDocument(url: url)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(Set([a, b]).count == 1)
    }

    @Test("A child doesn't keep its parent alive")
    func parentIsWeak() {
        weak var weakParent: PicoDocument?
        var child: PicoDocument?
        do {
            let parent = PicoDocument(url: URL(fileURLWithPath: "/tmp/folder", isDirectory: true))
            child = PicoDocument(url: URL(fileURLWithPath: "/tmp/folder/a.txt"), parent: parent)
            weakParent = parent
            #expect(child?.parent === parent)
        }
        #expect(weakParent == nil)
        #expect(child?.parent == nil)
    }

    @Test("Re-fetching a folder doesn't duplicate its children")
    func refetchKeepsChildrenUnique() async throws {
        let directory = try makeDirectory(["a.txt": "alpha", "b.txt": "beta"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = PicoDocument(url: directory)

        try await folder.fetch()
        #expect(folder.children?.count == 2)

        try Data("gamma".utf8).write(to: directory.appendingPathComponent("c.txt"))
        try await folder.fetch()
        let names = folder.children?.map(\.filename).sorted()
        #expect(names == ["a.txt", "b.txt", "c.txt"])
        #expect(folder.children?.allSatisfy { $0.parent === folder } == true)
    }
}
