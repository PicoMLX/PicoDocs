import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

struct PowerPointSecondStackReviewTests {
    typealias B = PowerPointConverterTests

    @Test func manifestCardinalityIsBoundedBeforeDOMRetention() throws {
        let entries = (0..<16_385).map { "<Override PartName='/unused\($0)' ContentType='image/png'/>" }.joined()
        let zip = PagesConverterTests.makeZip([("[Content_Types].xml", Array(("<Types>" + entries + "</Types>").utf8))])
        let package = PowerPointPackage(archive: try #require(Archive(data: zip, accessMode: .read)))
        #expect(PowerPointConverter.contentType("unused0", archive: package) == nil)
        #expect(package.contentTypes == nil)
        #expect(throws: PicoDocsError.fileCorrupted) { try package.check() }
    }

    @Test func corePropertiesAreBoundedBeforeInflationAndJoining() throws {
        let core = "<cp:coreProperties xmlns:cp='http://schemas.openxmlformats.org/package/2006/metadata/core-properties' xmlns:dc='http://purl.org/dc/elements/1.1/'><dc:title>" + String(repeating: "x", count: 1024 * 1024) + "</dc:title></cp:coreProperties>"
        let rels = B.relationshipsXML([("core", "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties", "docProps/core.xml")])
        let zip = PagesConverterTests.makeZip([("_rels/.rels", Array(rels.utf8)), ("docProps/core.xml", Array(core.utf8))])
        let package = PowerPointPackage(archive: try #require(Archive(data: zip, accessMode: .read)))
        #expect(PowerPointConverter.coreProperties(package).title == nil)
        #expect(throws: PicoDocsError.fileCorrupted) { try package.check() }
    }

    @Test func directoryPartCollisionsCannotDependOnArchiveOrder() throws {
        for directoryFirst in [true, false] {
            let archive = try #require(Archive(data: Data(), accessMode: .create))
            for isDirectory in directoryFirst ? [true, false] : [false, true] {
                try archive.addEntry(with: isDirectory ? "ppt/presentation.xm/" : "ppt/presentation.xml", type: isDirectory ? .directory : .file, uncompressedSize: Int64(isDirectory ? 0 : 1)) { _, _ in isDirectory ? Data() : Data([65]) }
            }
            var bytes = Array(try #require(archive.data))
            let original = Array("ppt/presentation.xm/".utf8)
            for i in 0...(bytes.count - original.count) where bytes[i..<(i + original.count)].elementsEqual(original) { bytes[i + original.count - 1] = 108 }
            let crafted = try #require(Archive(data: Data(bytes), accessMode: .read))
            #expect(crafted.contains { $0.type == .directory && $0.path == "ppt/presentation.xml" })
            #expect(throws: PicoDocsError.fileCorrupted) { try PowerPointPackage(archive: crafted).check() }
        }
    }

    @Test func omittedPlaceholderIndexMatchesExplicitZero() async throws {
        let style2 = "<a:lstStyle><a:lvl1pPr><a:buChar char='•'/></a:lvl1pPr></a:lstStyle>"
        let style0 = "<a:lstStyle><a:lvl1pPr><a:buAutoNum startAt='5'/><a:defRPr b='1'/></a:lvl1pPr></a:lstStyle>"
        for zero in [" idx='0'", ""] {
            let layout = "<p:sldLayout \(B.namespaces)><p:cSld><p:spTree>" + B.shape(placeholder: "<p:ph type='body' idx='2'/>", paragraphs: [style2]) + B.shape(placeholder: "<p:ph type='body'\(zero)/>", paragraphs: [style0]) + "</p:spTree></p:cSld></p:sldLayout>"
            let shape = B.shape(placeholder: "<p:ph type='body'/>", paragraphs: ["<a:p><a:r><a:t>Inherited</a:t></a:r></a:p>"])
            let deck = B.deck(slides: [.init(file: "s.xml", shapes: shape, relationships: [("layout", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout", "../slideLayouts/l.xml")])], extraParts: [("ppt/slideLayouts/l.xml", Array(layout.utf8))])
            #expect(try await PicoDocsEngine.convert(data: deck, filename: "index.pptx").markdown() == "5. **Inherited**")
        }
    }

    @Test func notesPageTablesAreIncludedWithVisibilityAndGrouping() async throws {
        let table = "<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id='4' name='Table'/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr><a:graphic><a:graphicData uri='http://schemas.openxmlformats.org/drawingml/2006/table'><a:tbl><a:tr><a:tc><a:txBody><a:p><a:r><a:rPr b='1'/><a:t>Cell</a:t></a:r></a:p></a:txBody></a:tc></a:tr></a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
        for content in [table, "<p:grpSp>" + table + "</p:grpSp>"] {
            let note = "<p:notes \(B.namespaces)><p:cSld><p:spTree>" + content + table.replacingOccurrences(of: "name='Table'", with: "name='Hidden' hidden='1'").replacingOccurrences(of: "Cell", with: "Hidden") + "</p:spTree></p:cSld></p:notes>"
            let deck = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Title"), relationships: [("notes", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide", "../notesSlides/n.xml")])], extraParts: [("ppt/notesSlides/n.xml", Array(note.utf8))])
            let result = try await PicoDocsEngine.convert(data: deck, filename: "notes.pptx")
            #expect(result.markdown().contains("### Notes\n\n| **Cell** |"))
            #expect(result.sections.first?.metadata["notes"]?.contains("| **Cell** |") == true)
            #expect(!result.markdown().contains("Hidden"))
        }
    }

    @Test func imageCarrierReservationPrecedesSectionRetention() throws {
        let zip = PagesConverterTests.makeZip([("[Content_Types].xml", Array("<Types/>".utf8)), ("image.png", [1])])
        func attempt(_ remaining: Int) throws -> (PowerPointConverter.ImageCollector, PowerPointPackage, Int) {
            let package = PowerPointPackage(archive: try #require(Archive(data: zip, accessMode: .read)))
            var left = remaining
            let collector = PowerPointConverter.ImageCollector(reserveCarrierBytes: { cost in
                guard cost <= left else { return false }; left -= cost; return true
            })
            _ = collector.add(path: "image.png", filename: "*image*.png", archive: package)
            return (collector, package, left)
        }
        let accepted = try attempt(1000)
        try accepted.1.check()
        let section = try #require(accepted.0.sections.first)
        var actual = section.markdown.utf8.count
        actual += section.title?.utf8.count ?? 0
        actual += section.sourcePath?.utf8.count ?? 0
        for (key, value) in section.metadata where key != "base64" {
            actual += key.utf8.count
            actual += value.utf8.count
        }
        #expect(1000 - accepted.2 == actual)
        let exact = try attempt(actual); try exact.1.check(); #expect(exact.2 == 0)
        let rejected = try attempt(actual - 1)
        #expect(rejected.0.sections.isEmpty)
        #expect(throws: PicoDocsError.fileCorrupted) { try rejected.1.check() }
    }

    @Test func enormousQualifiedNamesAreRejectedByTheXMLParser() {
        let raw = Data(("<" + String(repeating: "x", count: 16 * 1024 * 1024) + "/>").utf8)
        #expect(PowerPointXML.normalize(raw) == nil)
    }
}
