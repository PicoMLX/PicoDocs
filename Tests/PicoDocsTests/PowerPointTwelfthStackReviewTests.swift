import Foundation
import Testing
import ZIPFoundation
@testable import PicoDocs

struct PowerPointTwelfthStackReviewTests {
    typealias B = PowerPointConverterTests
    typealias R = PowerPointThirdStackReviewTests
    typealias N = PowerPointFifthStackReviewTests

    @Test func zipDetectionBoundsRootRelationshipsBeforeParsing() {
        let relations = B.relationshipsXML([("office", N.rel + "officeDocument", "custom/deck.xml")])
        for bytes in [64 * 1024, 64 * 1024 + 1] {
            let padding = "<!--" + String(repeating: "x", count: bytes - relations.utf8.count - 7) + "-->"
            let root = relations.replacingOccurrences(of: "</Relationships>", with: padding + "</Relationships>")
            #expect(root.utf8.count == bytes)
            let main = "<p:presentation " + B.namespaces + "/>"
            let data = PagesConverterTests.makeZip([("_rels/.rels", Array(root.utf8)), ("custom/deck.xml", Array(main.utf8))])
            #expect(ContentTypeDetector.classifyZip(data) == (bytes == 64 * 1024 ? .pptx : .zip))
        }
    }

    @Test func shortLiteralHyphenLinesNeverBecomeSetextHeadings() async throws {
        for text in ["-", "--", "---"] {
            let shape = B.shape(placeholder: nil, paragraphs: ["<a:p><a:r><a:t>Heading</a:t></a:r><a:br/><a:r><a:t>\(text)</a:t></a:r></a:p>"])
            let result = try await PowerPointConverter().convert(B.deck(slides: [.init(file: "s.xml", shapes: shape)]), info: StreamInfo(detectedFormat: .pptx))
            let attributed = try AttributedString(markdown: result.markdown())
            let headings = attributed.runs.contains { $0.presentationIntent?.components.contains { if case .header = $0.kind { return true }; return false } == true }
            #expect(!headings)
            #expect(try DocumentRenderer.render(result, to: .plaintext).contains(text))
        }
    }
    static func filledShape(_ fill: String, placeholder: String? = nil) -> String {
        B.shape(placeholder: placeholder, paragraphs: []).replacingOccurrences(of: "<p:spPr/>", with: "<p:spPr>" + fill + "</p:spPr>")
    }
    @Test func groupImageFillsReachOnlyExplicitGroupFillChildren() async throws {
        let child = Self.filledShape("<a:grpFill/>")
        let group = "<p:grpSp><p:nvGrpSpPr><p:cNvPr id='10' name='Group'/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:blipFill><a:blip r:embed='fill'/></a:blipFill></p:grpSpPr>" + child + "</p:grpSp>"
        let data = B.deck(slides: [.init(file: "s.xml", shapes: group, relationships: [("fill", N.rel + "image", "../media/group.png")])], extraParts: [("ppt/media/group.png", [1, 2, 3])])
        let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
        #expect(result.markdown().contains("group.png"))
        let nested = group.replacingOccurrences(of: child, with: "<p:grpSp><p:grpSpPr><a:grpFill/></p:grpSpPr>" + child + "</p:grpSp>")
        let nestedResult = try await PowerPointConverter().convert(B.deck(slides: [.init(file: "s.xml", shapes: nested, relationships: [("fill", N.rel + "image", "../media/group.png")])], extraParts: [("ppt/media/group.png", [1, 2, 3])]), info: StreamInfo(detectedFormat: .pptx))
        #expect(nestedResult.markdown().contains("group.png"))
        let stopped = nested.replacingOccurrences(of: "<p:grpSpPr><a:grpFill/></p:grpSpPr>", with: "<p:grpSpPr><a:noFill/></p:grpSpPr>")
        let stoppedResult = try await PowerPointConverter().convert(B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Stop") + stopped, relationships: [("fill", N.rel + "image", "../media/group.png")])], extraParts: [("ppt/media/group.png", [1, 2, 3])]), info: StreamInfo(detectedFormat: .pptx))
        #expect(!stoppedResult.sections.contains { $0.kind == .image })
    }
    @Test func unreservedImageEscapesCannotAliasEmbeddedReferences() async throws {
        let embedded = B.Slide(file: "e.xml", shapes: R.picture("image"), relationships: [("image", N.rel + "image", "../media/image.png")])
        let outside = B.Slide(file: "x.xml", shapes: R.picture("outside", external: true), relationships: [("outside", N.rel + "image", "%69mage.png\" TargetMode=\"External")])
        let result = try await PowerPointConverter().convert(B.deck(slides: [embedded, outside], extraParts: [("ppt/media/image.png", [1, 2, 3])]), info: StreamInfo(detectedFormat: .pptx))
        let ref = try #require(result.sections.first { $0.kind == .image }?.metadata["markdownReference"])
        #expect(ref.hasPrefix("picodocs-embedded/"))
        #expect(PowerPointConverter.ImageCollector.referenceIdentity("%2Fimage.png") != PowerPointConverter.ImageCollector.referenceIdentity("/image.png"))
        #expect(PowerPointConverter.ImageCollector.referenceIdentity("./%2e/image.png") == "image.png")
    }
    @Test func placeholderTokensCollapseBeforeFurnitureAndStyleMatching() async throws {
        let title = B.titleShape("Visible")
        let footer = B.shape(placeholder: "<p:ph type=' sldNum '/>", paragraphs: ["<a:p><a:r><a:t>Furniture</a:t></a:r></a:p>"])
        let body = B.shape(placeholder: "<p:ph type=' body ' idx='1'/>", paragraphs: ["<a:p><a:r><a:t>Inherited</a:t></a:r></a:p>"])
        let layoutShape = B.shape(placeholder: "<p:ph type='&#9;body&#13;' idx='1'/>", paragraphs: []).replacingOccurrences(of: "<a:bodyPr/>", with: "<a:bodyPr/><a:lstStyle><a:lvl1pPr><a:buChar char='•'/><a:defRPr b='1'/></a:lvl1pPr></a:lstStyle>")
        let layout = "<p:sldLayout " + B.namespaces + "><p:cSld><p:spTree>" + layoutShape + "</p:spTree></p:cSld></p:sldLayout>"
        let data = B.deck(slides: [.init(file: "s.xml", shapes: title + footer + body, relationships: [("layout", N.rel + "slideLayout", "../slideLayouts/l.xml")])], extraParts: [("ppt/slideLayouts/l.xml", Array(layout.utf8))])
        let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
        #expect(!result.markdown().contains("Furniture"))
        #expect(result.markdown().contains("- **Inherited**"))
    }
    static func themeParts(layoutShapes: String = "", masterShapes: String = "", overrideXML: String? = nil) -> [(name: String, data: [UInt8])] {
        let layout = "<p:sldLayout " + B.namespaces + "><p:cSld><p:spTree>" + layoutShapes + "</p:spTree></p:cSld></p:sldLayout>"
        let master = "<p:sldMaster " + B.namespaces + "><p:cSld><p:spTree>" + masterShapes + "</p:spTree></p:cSld></p:sldMaster>"
        let base = "<a:theme " + B.namespaces + "><a:themeElements><a:fmtScheme name='Base'><a:fillStyleLst><a:solidFill><a:srgbClr val='FFFFFF'/></a:solidFill></a:fillStyleLst><a:bgFillStyleLst><a:solidFill><a:srgbClr val='FFFFFF'/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>"
        var parts: [(name: String, data: [UInt8])] = [
            ("ppt/slideLayouts/l.xml", Array(layout.utf8)),
            ("ppt/slideLayouts/_rels/l.xml.rels", Array(B.relationshipsXML([("master", N.rel + "slideMaster", "../slideMasters/m.xml"), ("fill", N.rel + "image", "../media/layout.png")] + (overrideXML == nil ? [] : [("override", N.rel + "themeOverride", "../theme/override.xml")])).utf8)),
            ("ppt/slideMasters/m.xml", Array(master.utf8)),
            ("ppt/slideMasters/_rels/m.xml.rels", Array(B.relationshipsXML([("theme", N.rel + "theme", "../theme/t.xml"), ("fill", N.rel + "image", "../media/master.png")]).utf8)),
            ("ppt/theme/t.xml", Array(base.utf8)),
            ("ppt/media/layout.png", [1, 2, 3]),
            ("ppt/media/master.png", [4, 5, 6])
        ]
        if let overrideXML {
            parts += [("ppt/theme/override.xml", Array(overrideXML.utf8)), ("ppt/theme/_rels/override.xml.rels", Array(B.relationshipsXML([("fill", N.rel + "image", "../media/override.png")]).utf8)), ("ppt/media/override.png", [7, 8, 9])]
        }
        return parts
    }
    @Test func layoutFormatSchemeOverridesResolveTheirOwnImages() async throws {
        let override = "<a:themeOverride " + B.namespaces + "><a:fmtScheme name='Override'><a:fillStyleLst><a:blipFill><a:blip r:embed='fill'/></a:blipFill></a:fillStyleLst><a:bgFillStyleLst><a:blipFill><a:blip r:embed='fill'/></a:blipFill></a:bgFillStyleLst></a:fmtScheme></a:themeOverride>"
        for background in [false, true] {
            let shape = B.shape(placeholder: nil, paragraphs: []).replacingOccurrences(of: "</p:sp>", with: "<p:style><a:fillRef idx='1'><a:srgbClr val='FFFFFF'/></a:fillRef></p:style></p:sp>")
            var data = B.deck(slides: [.init(file: "s.xml", shapes: background ? "" : shape, relationships: [("layout", N.rel + "slideLayout", "../slideLayouts/l.xml")])], extraParts: Self.themeParts(overrideXML: override))
            if background { data = try R.replacing(data, part: "ppt/slides/s.xml") { $0.replacingOccurrences(of: "<p:spTree>", with: "<p:bg><p:bgRef idx='1001'><a:srgbClr val='FFFFFF'/></p:bgRef></p:bg><p:spTree>") } }
            let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
            #expect(result.markdown().contains("override.png"))
        }
    }
    @Test func themeOverridesPreserveComponentPrecedenceAndExternalReservations() async throws {
        let matrix = "<a:fmtScheme name='Override'><a:fillStyleLst><a:blipFill><a:blip r:embed='fill'/></a:blipFill></a:fillStyleLst></a:fmtScheme>"
        let override = "<a:themeOverride " + B.namespaces + ">" + matrix + "</a:themeOverride>"
        let shape = B.shape(placeholder: nil, paragraphs: []).replacingOccurrences(of: "</p:sp>", with: "<p:style><a:fillRef idx='1'/></p:style></p:sp>")
        var parts = Self.themeParts(overrideXML: override)
        parts += [("ppt/theme/local.xml", Array(("<a:themeOverride " + B.namespaces + "><a:clrScheme name='OnlyColors'/></a:themeOverride>").utf8))]
        let relations = [("layout", N.rel + "slideLayout", "../slideLayouts/l.xml"), ("override", N.rel + "themeOverride", "../theme/local.xml")]
        let colorOnly = try await PowerPointConverter().convert(B.deck(slides: [.init(file: "s.xml", shapes: shape, relationships: relations)], extraParts: parts), info: StreamInfo(detectedFormat: .pptx))
        #expect(colorOnly.markdown().contains("override.png"))
        parts[parts.count - 1].data = Array(("<a:themeOverride " + B.namespaces + "><a:fmtScheme name='Local'><a:fillStyleLst><a:noFill/></a:fillStyleLst></a:fmtScheme></a:themeOverride>").utf8)
        let localStop = try await PowerPointConverter().convert(B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Stop") + shape, relationships: relations)], extraParts: parts), info: StreamInfo(detectedFormat: .pptx))
        #expect(!localStop.sections.contains { $0.kind == .image })

        var reserved = Self.themeParts(overrideXML: override)
        let relIndex = try #require(reserved.firstIndex { $0.name == "ppt/theme/_rels/override.xml.rels" })
        reserved[relIndex].data = Array(B.relationshipsXML([("outside", N.rel + "image", "%69mage.png\" TargetMode=\"External")]).utf8)
        reserved += [("ppt/media/image.png", [1, 2, 3])]
        let image = R.picture("image")
        let data = B.deck(slides: [.init(file: "s.xml", shapes: image, relationships: [("image", N.rel + "image", "../media/image.png"), ("layout", N.rel + "slideLayout", "../slideLayouts/l.xml")])], extraParts: reserved)
        let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
        let ref = try #require(result.sections.first { $0.kind == .image }?.metadata["markdownReference"])
        #expect(ref.hasPrefix("picodocs-embedded/"))
    }
    @Test func placeholderImagesUseTheNearestOwningFill() async throws {
        let ph = "<p:ph type='body' idx='1'/>"
        let image = Self.filledShape("<a:blipFill><a:blip r:embed='fill'/></a:blipFill>", placeholder: ph)
        let empty = B.shape(placeholder: ph, paragraphs: [])
        for owner in ["layout", "master"] {
            let parts = Self.themeParts(layoutShapes: owner == "layout" ? image : empty, masterShapes: owner == "master" ? image : "")
            let data = B.deck(slides: [.init(file: "s.xml", shapes: empty, relationships: [("layout", N.rel + "slideLayout", "../slideLayouts/l.xml")])], extraParts: parts)
            let result = try await PowerPointConverter().convert(data, info: StreamInfo(detectedFormat: .pptx))
            #expect(result.markdown().contains(owner + ".png"))
            let stopped = Self.filledShape("<a:noFill/>", placeholder: ph)
            let explicit = B.deck(slides: [.init(file: "s.xml", shapes: B.titleShape("Stop") + stopped, relationships: [("layout", N.rel + "slideLayout", "../slideLayouts/l.xml")])], extraParts: parts)
            let overridden = try await PowerPointConverter().convert(explicit, info: StreamInfo(detectedFormat: .pptx))
            #expect(!overridden.sections.contains { $0.kind == .image })
        }
    }
}
