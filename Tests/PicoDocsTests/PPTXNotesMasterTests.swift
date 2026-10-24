import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

/// Speaker notes ship with the notes master PowerPoint expects beside them.
struct PPTXNotesMasterTests {
    static let notes = "Intro **bold** and [link](https://example.com)\n\n- one\n- two\n\n3. three\n4. four"
    static let deck = ConverterResult(sections: [
        .init(kind: .slide, markdown: "## One\n\nBody\n\n**Notes:** " + notes, metadata: ["notes": notes]),
        .init(kind: .slide, markdown: "## Two\n\nBody")
    ])

    static func entries(_ data: Data) throws -> [String] {
        try Archive(data: data, accessMode: .read).map(\.path)
    }

    @Test func notesDecksReferenceOneNotesMasterAndItsTheme() throws {
        let data = try PPTXExporter().write(Self.deck, format: .pptx)
        let xml = { (path: String) in try OfficeStackReviewTests.xml(data, path) }
        let presentation = try xml("ppt/presentation.xml")
        #expect(presentation.contains("</p:sldMasterIdLst><p:notesMasterIdLst><p:notesMasterId r:id=\"notesMaster\"/></p:notesMasterIdLst><p:sldIdLst>"))
        #expect(try xml("ppt/_rels/presentation.xml.rels").contains("Id=\"notesMaster\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesMaster\" Target=\"notesMasters/notesMaster1.xml\""))
        let types = try xml("[Content_Types].xml")
        #expect(types.contains("PartName=\"/ppt/notesMasters/notesMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.notesMaster+xml\""))
        #expect(types.contains("PartName=\"/ppt/theme/theme2.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\""))
        #expect(try xml("ppt/notesSlides/_rels/notesSlide1.xml.rels").contains("relationships/notesMaster\" Target=\"../notesMasters/notesMaster1.xml\""))
        #expect(try xml("ppt/notesMasters/_rels/notesMaster1.xml.rels").contains("relationships/theme\" Target=\"../theme/theme2.xml\""))
        #expect(try xml("ppt/theme/theme2.xml") == xml("ppt/theme/theme1.xml"))
        let master = try xml("ppt/notesMasters/notesMaster1.xml")
        #expect(master.contains("<p:ph type=\"sldImg\" idx=\"2\"/>"))
        #expect(master.contains("<p:ph type=\"body\" sz=\"quarter\" idx=\"3\"/>"))
        #expect(master.contains("<p:clrMap "))

        // Every internal relationship resolves to a written part, as the reader resolves it.
        let paths = Set(try Self.entries(data))
        for rels in paths where rels.hasSuffix(".rels") {
            let source = rels == "_rels/.rels" ? "" : rels.replacingOccurrences(of: "_rels/", with: "").replacingOccurrences(of: ".rels", with: "")
            let base = (source as NSString).deletingLastPathComponent
            for relation in try xml(rels).components(separatedBy: "<Relationship ").dropFirst() where !relation.contains("TargetMode=\"External\"") {
                let target = try #require(relation.components(separatedBy: "Target=\"").dropFirst().first?.components(separatedBy: "\"").first)
                #expect(paths.contains(PowerPointConverter.resolvePartPath(target, relativeTo: base)), "\(rels) → \(target)")
            }
        }
    }

    @Test func importedNotesAreUnchangedByTheMaster() async throws {
        let data = try PPTXExporter().write(Self.deck, format: .pptx)
        let relationship = "<Relationship Id=\"notesMaster\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesMaster\" Target=\"../notesMasters/notesMaster1.xml\"/>"
        let detached = try PowerPointThirdStackReviewTests.replacing(data, part: "ppt/notesSlides/_rels/notesSlide1.xml.rels") {
            #expect($0.contains(relationship))
            return $0.replacingOccurrences(of: relationship, with: "")
        }
        let withMaster = try await PicoDocsEngine.convert(data: data, filename: "master.pptx")
        let withoutMaster = try await PicoDocsEngine.convert(data: detached, filename: "detached.pptx")
        let notes = try #require(withMaster.sections.first?.metadata["notes"])
        #expect(notes.contains("**bold**"))
        #expect(notes.contains("https://example.com"))
        #expect(withMaster.sections.map(\.markdown) == withoutMaster.sections.map(\.markdown))
        #expect(withMaster.sections.map { $0.metadata["notes"] } == withoutMaster.sections.map { $0.metadata["notes"] })
        // Imported notes re-export with the master again.
        let rewritten = try PicoDocsEngine.write(withMaster, to: .pptx)
        #expect(try Self.entries(rewritten).contains("ppt/notesMasters/notesMaster1.xml"))
        let again = try await PicoDocsEngine.convert(data: rewritten, filename: "again.pptx")
        #expect(again.sections.first?.metadata["notes"]?.contains("**bold**") == true)
    }

    @Test func decksWithoutNotesOmitTheNotesMaster() throws {
        let source = ConverterResult(sections: [.init(kind: .slide, markdown: "## One\n\nBody"), .init(kind: .slide, markdown: "## Two\n\nBody")])
        let data = try PPTXExporter().write(source, format: .pptx)
        let paths = try Self.entries(data)
        #expect(paths.count == 14)
        #expect(!paths.contains { $0.hasPrefix("ppt/notesMasters/") || $0.hasPrefix("ppt/notesSlides/") || $0 == "ppt/theme/theme2.xml" })
        for part in ["ppt/presentation.xml", "ppt/_rels/presentation.xml.rels", "[Content_Types].xml"] {
            #expect(!(try OfficeStackReviewTests.xml(data, part)).contains("notesMaster"))
        }
    }

    @Test func notesMasterXMLSharesTheReaderAllowance() throws {
        let xml = "<root a='1'><child b='2'/></root>"
        let budget = PPTXExporter.PackageBudget(xmlBudget: .init(nodes: 4, attributes: 4))
        try budget.admitXML("ppt/notesMasters/notesMaster1.xml", xml)
        try budget.admitXML("ppt/slides/slide1.xml", xml)
        #expect(throws: ExporterError.self) { try budget.admitXML("ppt/notesSlides/notesSlide1.xml", "<root/>") }
        // Its relationship part is an independent parse.
        let separate = PPTXExporter.PackageBudget(xmlBudget: .init(nodes: 2, attributes: 2))
        try separate.admitXML("ppt/notesMasters/_rels/notesMaster1.xml.rels", xml)
        try separate.admitXML("ppt/notesMasters/notesMaster1.xml", xml)
    }
}
