import Foundation

/// Matches the DOCX reader's retained-media envelope, before decoding carriers.
final class OfficeMediaDecodeBudget {
    private let maximumImageBytes: Int
    private var remainingBytes: Int
    private var remainingImages: Int

    init(maximumImageBytes: Int = 32 * 1024 * 1024, maximumBytes: Int = 64 * 1024 * 1024, maximumImages: Int = 1024) {
        self.maximumImageBytes = maximumImageBytes
        remainingBytes = maximumBytes; remainingImages = maximumImages
    }

    func decode(_ base64: String) throws -> Data? {
        let available = min(maximumImageBytes, remainingBytes)
        guard remainingImages > 0, base64.utf8.count <= ((available + 2) / 3) * 4 else {
            throw ExporterError.serializationFailed("DOCX media exceeds the supported 32 MiB per-image, 64 MiB total, or 1,024-image limit")
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        guard data.count <= available else {
            throw ExporterError.serializationFailed("DOCX media exceeds the supported byte budget")
        }
        remainingBytes -= data.count; remainingImages -= 1
        return data
    }
}
