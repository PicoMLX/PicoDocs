import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

struct PowerPointEighthStackReviewTests {
    typealias B = PowerPointConverterTests
    typealias R = PowerPointThirdStackReviewTests
    typealias N = PowerPointFifthStackReviewTests

    @Test func explicitBackgroundImagesKeepOtherwiseEmptySlides() async throws {
        for shapes in ["", B.titleShape("Visible text")] {
            let seed = B.deck(slides: [.init(file: "s.xml", shapes: shapes, relationships: [("bg", N.rel + "image", "../media/background.png")])], extraParts: [("ppt/media/background.png", [1, 2, 3])])
            let data = try R.replacing(seed, part: "ppt/slides/s.xml") {
                $0.replacingOccurrences(of: "<p:spTree>", with: "<p:bg><p:bgPr><a:blipFill><a:blip r:embed='bg'/><a:stretch><a:fillRect/></a:stretch></a:blipFill></p:bgPr></p:bg><p:spTree>")
            }
            let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
            #expect(result.sections.filter { $0.kind == .slide }.count == 1)
            #expect(result.sections.filter { $0.kind == .image }.count == 1)
            #expect(result.markdown().contains("![image](background.png)"))
            if !shapes.isEmpty { #expect(result.markdown().contains("Visible text")) }
        }
    }

    @Test func relocatedLargePresentationRoutesWithinConverterLimits() async throws {
        let archive = try Archive(data: B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Large moved deck"))]), accessMode: .read)
        var parts: [(name: String, data: [UInt8])] = []
        for entry in archive {
            var bytes = Data(); _ = try archive.extract(entry) { bytes.append($0) }
            var name = entry.path
            if name == "ppt/presentation.xml" {
                name = "custom/deck.xml"
                let text = String(decoding: bytes, as: UTF8.self)
                bytes = Data(text.replacingOccurrences(of: "</p:presentation>", with: "<!--" + String(repeating: "x", count: 1024 * 1024 + 1) + "--></p:presentation>").utf8)
            }
            if name == "ppt/_rels/presentation.xml.rels" {
                name = "custom/_rels/deck.xml.rels"
                bytes = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "slides/s.xml", with: "../ppt/slides/s.xml").utf8)
            }
            if name == "_rels/.rels" || name == "[Content_Types].xml" {
                bytes = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "ppt/presentation.xml", with: "custom/deck.xml").utf8)
            }
            parts.append((name, Array(bytes)))
        }
        let data = PagesConverterTests.makeZip(parts)
        let hinted = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
        #expect(hinted.markdown() == "## Large moved deck")
        #expect(ContentTypeDetector.classify(data, info: StreamInfo()).detectedFormat == .pptx)
        #expect(try await PicoDocsEngine.convert(data: data).markdown() == hinted.markdown())
    }

    @Test func inheritedBackgroundUsesItsOwningPartAndExplicitOverrides() async throws {
        let background = "<p:bg><p:bgPr><a:blipFill><a:blip r:embed='bg'/></a:blipFill></p:bgPr></p:bg>"
        for owner in ["layout", "master"] {
            let layout = "<p:sldLayout " + B.namespaces + "><p:cSld>" + (owner == "layout" ? background : "") + "<p:spTree/></p:cSld></p:sldLayout>"
            let master = "<p:sldMaster " + B.namespaces + "><p:cSld>" + (owner == "master" ? background : "") + "<p:spTree/></p:cSld></p:sldMaster>"
            let layoutRelations = B.relationshipsXML([("master", N.rel + "slideMaster", "../slideMasters/m.xml")] + (owner == "layout" ? [("bg", N.rel + "image", "../media/background.png")] : []))
            let masterRelations = B.relationshipsXML(owner == "master" ? [("bg", N.rel + "image", "../media/background.png")] : [])
            let seed = B.deck(slides: [.init(file: "s.xml", shapes: "", relationships: [("layout", N.rel + "slideLayout", "../slideLayouts/l.xml")])], extraParts: [("ppt/slideLayouts/l.xml", Array(layout.utf8)), ("ppt/slideLayouts/_rels/l.xml.rels", Array(layoutRelations.utf8)), ("ppt/slideMasters/m.xml", Array(master.utf8)), ("ppt/slideMasters/_rels/m.xml.rels", Array(masterRelations.utf8)), ("ppt/media/background.png", [1, 2, 3])])
            let result = try await PowerPointConverter().convert(seed, info: StreamInfo(detectedFormat: .pptx))
            #expect(result.markdown() == "![image](background.png)")
            #expect(result.sections.last?.sourcePath == "ppt/media/background.png")
            let overridden = try R.replacing(seed, part: "ppt/slides/s.xml") {
                $0.replacingOccurrences(of: "<p:spTree>", with: "<p:bg><p:bgPr><a:solidFill><a:srgbClr val='FFFFFF'/></a:solidFill></p:bgPr></p:bg><p:spTree>" + B.titleShape("Override"))
            }
            let overrideResult = try await PowerPointConverter().convert(overridden, info: StreamInfo(detectedFormat: .pptx))
            #expect(overrideResult.markdown() == "## Override")
            #expect(!overrideResult.sections.contains { $0.kind == .image })
        }
    }

    @Test func textBoxesUseBodyStyleWhileShapesUseOtherStyle() async throws {
        let shape = N.text("Shape text")
        let textBox = N.text("Box text").replacingOccurrences(of: "<p:cNvSpPr/>", with: "<p:cNvSpPr txBox='1'/>")
        let layout = "<p:sldLayout " + B.namespaces + "><p:cSld><p:spTree/></p:cSld></p:sldLayout>"
        let bodyStyle = "<p:bodyStyle><a:lvl1pPr><a:buAutoNum startAt='7' type='arabicPeriod'/><a:defRPr b='1'/></a:lvl1pPr></p:bodyStyle>"
        let otherStyle = "<p:otherStyle><a:lvl1pPr><a:buNone/><a:defRPr i='1'/></a:lvl1pPr></p:otherStyle>"
        let master = "<p:sldMaster " + B.namespaces + "><p:cSld><p:spTree/></p:cSld><p:txStyles>" + bodyStyle + otherStyle + "</p:txStyles></p:sldMaster>"
        let relations = B.relationshipsXML([("master", N.rel + "slideMaster", "../slideMasters/m.xml")])
        let data = B.deck(slides: [.init(file: "s.xml", shapes: shape + textBox, relationships: [("layout", N.rel + "slideLayout", "../slideLayouts/l.xml")])], extraParts: [("ppt/slideLayouts/l.xml", Array(layout.utf8)), ("ppt/slideLayouts/_rels/l.xml.rels", Array(relations.utf8)), ("ppt/slideMasters/m.xml", Array(master.utf8))])
        let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
        #expect(result.markdown() == "*Shape text*\n\n7. **Box text**")
    }

    @Test func cancellationTakesPrecedenceWhenNormalizationReturnsNil() async throws {
        let data = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Slide"))])
        let cancelled = try await Task {
            let archive = try Archive(data: data, accessMode: .read)
            let package = PowerPointPackage(archive: archive)
            let xml = try #require(package.read("ppt/presentation.xml"))
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(PowerPointXML.normalize(xml) == nil)
            #expect(package.failure == nil)
            // The main-presentation failure path checks before throwing corruption;
            // other part readers can already have recorded a corruption error.
            for recordCorruption in [false, true] {
                if recordCorruption { package.fail(PicoDocsError.fileCorrupted) }
                do {
                    try package.check()
                    Issue.record("Cancellation must win over missing or corrupt XML")
                } catch is CancellationError { }
            }
            return true
        }.value
        #expect(cancelled)
    }
}
