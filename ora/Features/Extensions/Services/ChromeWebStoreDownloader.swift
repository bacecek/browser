import Foundation

/// Downloads CRX packages from the Chrome Web Store update endpoint.
/// The session is injectable so tests can stub the network with a URLProtocol.
struct ChromeWebStoreDownloader {
    var session: URLSession = .shared

    /// Chrome version advertised to the update endpoint.
    static let prodVersion = "131.0.0.0"

    /// Extracts a Chrome extension ID from a bare ID or a Web Store URL, e.g.
    /// `https://chromewebstore.google.com/detail/1password/aeblfdkhhhdcdjpifhhbdiojplfjncoa`.
    /// IDs are exactly 32 characters of a–p.
    static func extensionID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        if isValidExtensionID(trimmed) {
            return trimmed
        }

        guard let url = URL(string: trimmed) else { return nil }
        // Search path components (and query, for legacy detail links) for an ID.
        var candidates = url.pathComponents
        if let query = url.query {
            candidates.append(contentsOf: query.components(separatedBy: CharacterSet(charactersIn: "&=")))
        }
        return candidates.first(where: isValidExtensionID)
    }

    static func isValidExtensionID(_ candidate: String) -> Bool {
        candidate.count == 32 && candidate.allSatisfy { ("a" ... "p").contains($0) }
    }

    static func downloadURL(for extensionId: String) -> URL {
        let urlString = "https://clients2.google.com/service/update2/crx?response=redirect"
            + "&prodversion=\(prodVersion)&acceptformat=crx3&x=id%3D\(extensionId)%26uc"
        // swiftlint:disable:next force_unwrapping
        return URL(string: urlString)!
    }

    /// Fetches the raw CRX bytes for an extension ID.
    func downloadCRX(extensionId: String) async throws -> Data {
        let url = Self.downloadURL(for: extensionId)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw ExtensionInstallError.downloadFailed(error.localizedDescription)
        }

        if let httpResponse = response as? HTTPURLResponse, !(200 ... 299).contains(httpResponse.statusCode) {
            throw ExtensionInstallError.downloadFailed("HTTP \(httpResponse.statusCode) from Chrome Web Store")
        }
        guard !data.isEmpty else {
            throw ExtensionInstallError.downloadFailed("Empty response from Chrome Web Store")
        }
        return data
    }
}

/// CRX package parsing: a CRX is a signed header followed by a plain ZIP.
enum CRXArchive {
    /// Strips the CRX2/CRX3 header and returns the embedded ZIP data.
    ///
    /// CRX3 layout: magic "Cr24" (4B) + version (4B LE) + header length (4B LE)
    /// + protobuf header, then the ZIP. CRX2: magic + version + public-key and
    /// signature lengths (4B LE each), then key, signature, ZIP.
    static func zipData(from crxData: Data) throws -> Data {
        guard crxData.count > 16 else { throw ExtensionInstallError.invalidCRX }

        // Magic "Cr24"
        guard crxData[0] == 0x43, crxData[1] == 0x72, crxData[2] == 0x32, crxData[3] == 0x34 else {
            throw ExtensionInstallError.invalidCRX
        }

        let version = crxData.littleEndianUInt32(at: 4)
        let zipOffset: Int
        switch version {
        case 2:
            let publicKeyLength = Int(crxData.littleEndianUInt32(at: 8))
            let signatureLength = Int(crxData.littleEndianUInt32(at: 12))
            zipOffset = 16 + publicKeyLength + signatureLength
        case 3:
            let headerLength = Int(crxData.littleEndianUInt32(at: 8))
            zipOffset = 12 + headerLength
        default:
            throw ExtensionInstallError.invalidCRX
        }

        guard zipOffset > 0, zipOffset < crxData.count else {
            throw ExtensionInstallError.invalidCRX
        }
        return crxData.subdata(in: zipOffset ..< crxData.count)
    }
}
