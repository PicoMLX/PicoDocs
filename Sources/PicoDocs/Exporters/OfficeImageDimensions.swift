import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Dimensions for vector carriers that ImageIO may not decode, plus common
/// raster headers. Reads bounds without rendering or resolving external assets.
enum OfficeImageDimensions {
    static func read(_ data: Data) -> (Double, Double)? {
        let bytes = data.prefix(64)
        func unsigned(_ offset: Int, _ count: Int, littleEndian: Bool = true) -> UInt32? {
            guard offset >= 0, count <= 4, offset + count <= bytes.count else { return nil }
            let slice = bytes.dropFirst(offset).prefix(count)
            return (littleEndian ? Array(slice.reversed()) : Array(slice)).reduce(0) { ($0 << 8) | UInt32($1) }
        }
        func signed(_ offset: Int, _ count: Int) -> Double? {
            guard let value = unsigned(offset, count) else { return nil }
            return count == 2 ? Double(Int16(bitPattern: UInt16(value))) : Double(Int32(bitPattern: value))
        }
        func rect(_ offset: Int, _ count: Int) -> (Double, Double)? {
            guard let left = signed(offset, count), let top = signed(offset + count, count),
                  let right = signed(offset + 2 * count, count), let bottom = signed(offset + 3 * count, count) else { return nil }
            return valid(right - left, bottom - top)
        }
        if bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), let width = unsigned(16, 4, littleEndian: false), let height = unsigned(20, 4, littleEndian: false) {
            return valid(Double(width), Double(height))
        }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)),
           let width = unsigned(6, 2), let height = unsigned(8, 2) { return valid(Double(width), Double(height)) }
        if bytes.starts(with: Array("BM".utf8)), let header = unsigned(14, 4) {
            if header == 12, let width = unsigned(18, 2), let height = unsigned(20, 2) { return valid(Double(width), Double(height)) }
            if header >= 40, let width = signed(18, 4), let height = signed(22, 4) { return valid(width, abs(height)) }
        }
        // EMR_HEADER: the physical frame is in .01 mm and avoids device-pixel
        // aspect assumptions. Placeable WMF supplies logical bounding coordinates.
        if unsigned(0, 4) == 1, unsigned(40, 4) == 0x464D4520 { return rect(24, 4) ?? rect(8, 4) }
        if unsigned(0, 4) == 0x9AC6CDD7 { return rect(6, 2) }
        let reader = SVGSizeReader()
        let parser = XMLParser(data: data.prefix(65_536))
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        _ = parser.parse()
        return reader.size
    }

    static func valid(_ width: Double, _ height: Double) -> (Double, Double)? {
        width.isFinite && height.isFinite && width > 0 && height > 0 ? (width, height) : nil
    }

    private final class SVGSizeReader: NSObject, XMLParserDelegate {
        var size: (Double, Double)?
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { parser.abortParsing() }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { parser.abortParsing() }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            defer { parser.abortParsing() }
            guard elementName == "svg" || elementName.hasSuffix(":svg") else { return }
            func length(_ source: String?) -> Double? {
                guard let source else { return nil }
                let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
                let units: [(String, Double)] = [("px", 1), ("in", 96), ("cm", 96 / 2.54), ("mm", 96 / 25.4), ("pt", 96 / 72), ("pc", 16), ("Q", 96 / 101.6)]
                for (unit, factor) in units where text.hasSuffix(unit) {
                    return Double(text.dropLast(unit.count)).map { $0 * factor }
                }
                return Double(text)
            }
            if let width = length(attributes["width"]), let height = length(attributes["height"]), let valid = OfficeImageDimensions.valid(width, height) { size = valid; return }
            let box = attributes["viewBox"]?.split { $0.isWhitespace || $0 == "," }.compactMap { Double($0) } ?? []
            if box.count == 4 { size = OfficeImageDimensions.valid(box[2], box[3]) }
        }
    }
}
