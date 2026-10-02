import Foundation

/// Matches the DOCX reader's retained-media envelope, before decoding carriers.
final class OfficeMediaDecodeBudget {
    private let maximumImageBytes: Int
    private var remainingBytes: Int
    private var remainingImages: Int
    private var remainingProbeBytes: Int
    private var remainingProbes: Int

    init(maximumImageBytes: Int = 32 * 1024 * 1024, maximumBytes: Int = 64 * 1024 * 1024, maximumImages: Int = 1024) {
        self.maximumImageBytes = maximumImageBytes
        remainingBytes = maximumBytes; remainingImages = maximumImages
        remainingProbeBytes = ((maximumBytes + 2) / 3) * 4
        remainingProbes = maximumImages
    }

    /// Charge every attempted decode before Foundation scans or allocates it,
    /// including malformed candidates and released ambiguity probes. Committed
    /// storage has its own allowance so a successful probe is not charged twice.
    func decodeCandidate(_ base64: String) throws -> Data? {
        let encodedBytes = base64.utf8.count
        guard encodedBytes <= ((maximumImageBytes + 2) / 3) * 4 else {
            throw ExporterError.serializationFailed("DOCX image exceeds the supported per-image limit")
        }
        guard remainingProbes > 0, encodedBytes <= remainingProbeBytes else {
            throw ExporterError.serializationFailed("DOCX image candidate decoding exceeds the supported aggregate budget")
        }
        remainingProbeBytes -= encodedBytes; remainingProbes -= 1
        guard let data = Data(base64Encoded: base64) else { return nil }
        guard data.count <= maximumImageBytes else { throw ExporterError.serializationFailed("DOCX image exceeds the supported per-image limit") }
        return data
    }

    func reserve(_ data: Data) throws {
        guard remainingImages > 0, data.count <= remainingBytes else {
            throw ExporterError.serializationFailed("DOCX retained media exceeds the supported aggregate budget")
        }
        remainingBytes -= data.count; remainingImages -= 1
    }

    func decode(_ base64: String) throws -> Data? {
        let available = min(maximumImageBytes, remainingBytes)
        guard remainingImages > 0, base64.utf8.count <= ((available + 2) / 3) * 4 else {
            throw ExporterError.serializationFailed("DOCX media exceeds the supported 32 MiB per-image, 64 MiB total, or 1,024-image limit")
        }
        guard let data = try decodeCandidate(base64) else { return nil }
        guard data.count <= available else {
            throw ExporterError.serializationFailed("DOCX media exceeds the supported byte budget")
        }
        remainingBytes -= data.count; remainingImages -= 1
        return data
    }
}
