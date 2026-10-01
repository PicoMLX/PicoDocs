import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

struct PowerPointFifthStackReviewTests {
    typealias B = PowerPointConverterTests
    typealias R = PowerPointThirdStackReviewTests
    static let rel = R.rel

    static func text(_ value: String, placeholder: String? = nil) -> String {
        B.shape(placeholder: placeholder, paragraphs: ["<a:p><a:r><a:t>" + value + "</a:t></a:r></a:p>"])
    }
    static let groupProperties = "<p:nvGrpSpPr><p:cNvPr id='1' name=''/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"
    static let colorMap = "<p:clrMap bg1='lt1' tx1='dk1' bg2='lt2' tx2='dk2' accent1='accent1' accent2='accent2' accent3='accent3' accent4='accent4' accent5='accent5' accent6='accent6' hlink='hlink' folHlink='folHlink'/>"

    static func deck(masterShapes: String, localShapes: String, visibility: String? = nil, masterRels: [(id: String, type: String, target: String)] = [], extra: [(name: String, data: [UInt8])] = []) -> Data {
        let visible = visibility.map { " showMasterSp='" + $0 + "'" } ?? ""
        let note = "<p:notes " + B.namespaces + visible + "><p:cSld><p:spTree>" + groupProperties + localShapes + "</p:spTree></p:cSld></p:notes>"
        let master = "<p:notesMaster " + B.namespaces + "><p:cSld><p:spTree>" + groupProperties + masterShapes + "</p:spTree></p:cSld>" + colorMap + "</p:notesMaster>"
        let parts: [(name: String, data: [UInt8])] = [
            ("ppt/notesSlides/n.xml", Array(note.utf8)),
            ("ppt/notesSlides/_rels/n.xml.rels", Array(B.relationshipsXML([("master", rel + "notesMaster", "../notesMasters/m.xml")]).utf8)),
            ("ppt/notesMasters/m.xml", Array(master.utf8)),
            ("ppt/notesMasters/_rels/m.xml.rels", Array(B.relationshipsXML(masterRels).utf8))
        ]
        return B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Slide"), relationships: [("notes", rel + "notesSlide", "../notesSlides/n.xml")])], extraParts: parts + extra)
    }

    @Test func visibleNotesMasterContentUsesItsOwnRelationships() async throws {
        let table = "<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id='5' name='Master table'/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr><p:xfrm><a:off x='0' y='0'/><a:ext cx='1' cy='1'/></p:xfrm><a:graphic><a:graphicData uri='http://schemas.openxmlformats.org/drawingml/2006/table'><a:tbl><a:tblPr/><a:tblGrid><a:gridCol w='1'/></a:tblGrid><a:tr h='1'><a:tc><a:txBody><a:bodyPr/><a:p><a:r><a:t>Master cell</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc></a:tr></a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
        let picture = R.picture("logo")
        let group = "<p:grpSp>" + Self.groupProperties + Self.text("Grouped master") + picture + "</p:grpSp>"
        let hidden = Self.text("Hidden master").replacingOccurrences(of: "name=\"Shape\"", with: "name=\"Shape\" hidden='1'")
        let master = Self.text("Master notice") + table + group + hidden
            + Self.text("Master body prompt", placeholder: "<p:ph type='body'/>")
            + Self.text("Master footer", placeholder: "<p:ph type='ftr'/>")
        let source = Self.deck(masterShapes: master, localShapes: Self.text("Local note", placeholder: "<p:ph type='body'/>") + R.picture("logo", external: true), masterRels: [("logo", Self.rel + "image", "../media/master.png")], extra: [("ppt/media/master.png", [1, 2, 3])])
        let data = try R.replacing(source, part: "ppt/notesSlides/_rels/n.xml.rels") {
            $0.replacingOccurrences(of: "</Relationships>", with: "<Relationship Id='logo' Type='" + Self.rel + "image' Target='master.png' TargetMode='External'/></Relationships>")
        }
        let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
        let notes = try #require(result.sections.first?.metadata["notes"])
        #expect(notes.contains("Master notice"))
        #expect(notes.contains("| Master cell |"))
        #expect(notes.contains("Grouped master"))
        #expect(!notes.contains("Hidden master"))
        #expect(!notes.contains("Master body prompt"))
        #expect(!notes.contains("Master footer"))
        #expect(notes.contains("Local note"))
        let inheritedRange = try #require(notes.range(of: "Master notice"))
        let localRange = try #require(notes.range(of: "Local note"))
        #expect(inheritedRange.lowerBound < localRange.lowerBound)
        let carrier = try #require(result.sections.first { $0.kind == .image })
        #expect(carrier.sourcePath == "ppt/media/master.png")
        let reference = try #require(carrier.metadata["markdownReference"])
        #expect(reference != "master.png")
        #expect(notes.contains("![Notes](" + reference + ")"))
        #expect(notes.contains("![Notes](master.png)"))
        #expect(result.markdown().contains("### Notes\n\n" + notes))
    }

    @Test(arguments: ["0", "false"])
    func hiddenNotesMasterDoesNotContributeContent(visibility: String) async throws {
        let data = Self.deck(masterShapes: Self.text("Master notice") + R.picture("logo"), localShapes: Self.text("Local note", placeholder: "<p:ph type='body'/>") , visibility: visibility, masterRels: [("logo", Self.rel + "image", "../media/master.png")], extra: [("ppt/media/master.png", [1, 2, 3])])
        let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
        #expect(result.sections.first?.metadata["notes"] == "Local note")
        #expect(result.sections.filter { $0.kind == .image }.isEmpty)
    }

    @Test func masterOnlyNotesRemainVisible() async throws {
        let data = Self.deck(masterShapes: Self.text("Master-only notice"), localShapes: "")
        let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
        #expect(result.sections.first?.metadata["notes"] == "Master-only notice")
        #expect(result.markdown().contains("### Notes\n\nMaster-only notice"))
    }

    @Test func notesInheritanceChargesMasterAndLocalContentTogether() throws {
        let data = Self.deck(masterShapes: Self.text("Master notice"), localShapes: Self.text("Local note"))
        let expected = "Master notice\n\nLocal note"
        func readNotes(maximum: Int) throws -> String? {
            let archive = PowerPointPackage(archive: try Archive(data: data, accessMode: .read))
            var parts = PowerPointConverter.PartCache(archive: archive)
            let path = "ppt/slides/s.xml"
            let relationships = PowerPointConverter.relationships(archive, forPart: path)
            let budget = PowerPointConverter.RenderBudget(maximumBytes: maximum, archive: archive)
            let notes = PowerPointConverter.notes(forSlide: path, relationships: relationships, archive: archive, parts: &parts, renderBudget: budget)
            try archive.check()
            return notes
        }
        #expect(try readNotes(maximum: expected.utf8.count) == expected)
        #expect(throws: PicoDocsError.fileCorrupted) { _ = try readNotes(maximum: expected.utf8.count - 1) }
    }

}
