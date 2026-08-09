import Compression
import Foundation

// MARK: - Network stub

/// Serves a canned CRX response for any request, following the
/// RequestCountingURLProtocol pattern from the filter-list tests.
final class CRXStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var stubbedBody = Data()
    private static var stubbedStatusCode = 200
    private static var requestedURLs: [URL] = []

    static func stub(body: Data, statusCode: Int = 200) {
        lock.lock()
        stubbedBody = body
        stubbedStatusCode = statusCode
        requestedURLs = []
        lock.unlock()
    }

    static var lastRequestedURL: URL? {
        lock.lock()
        let url = requestedURLs.last
        lock.unlock()
        return url
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let body = Self.stubbedBody
        let statusCode = Self.stubbedStatusCode
        if let url = request.url {
            Self.requestedURLs.append(url)
        }
        Self.lock.unlock()

        let responseURL = request.url ?? URL(fileURLWithPath: "/dev/null")
        guard let response = HTTPURLResponse(
            url: responseURL,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - ZIP fixture writer

extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    mutating func appendLittleEndian16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }
}

/// Builds ZIP archives in-code for fixtures: `ZipArchive` in reverse (local
/// headers + central directory + end record; stored or raw-DEFLATE entries).
/// Validated against `/usr/bin/unzip` during development, so the CRCs and
/// layout are known-good.
enum ZipFixtureWriter {
    struct Entry {
        let name: String
        let data: Data
        var deflated = false
    }

    /// An entry with its on-disk representation resolved: compression method
    /// picked, payload compressed, CRC computed.
    private struct PreparedEntry {
        let name: String
        let originalSize: UInt32
        let method: UInt16
        let checksum: UInt32
        let payload: Data
    }

    static func archive(entries: [Entry]) -> Data {
        var localSection = Data()
        var centralSection = Data()

        for entry in entries {
            let localHeaderOffset = UInt32(localSection.count)
            let prepared = prepare(entry)
            appendLocalRecord(to: &localSection, prepared)
            appendCentralRecord(to: &centralSection, prepared, localHeaderOffset: localHeaderOffset)
        }

        var archive = localSection
        archive.append(centralSection)
        archive.appendLittleEndian(0x06054B50)
        archive.appendLittleEndian16(0) // disk number
        archive.appendLittleEndian16(0) // central directory disk
        archive.appendLittleEndian16(UInt16(entries.count))
        archive.appendLittleEndian16(UInt16(entries.count))
        archive.appendLittleEndian(UInt32(centralSection.count))
        archive.appendLittleEndian(UInt32(localSection.count))
        archive.appendLittleEndian16(0) // comment length
        return archive
    }

    private static func prepare(_ entry: Entry) -> PreparedEntry {
        var method: UInt16 = 0
        var payload = entry.data
        if entry.deflated, let deflatedPayload = deflateRaw(entry.data) {
            method = 8
            payload = deflatedPayload
        }
        return PreparedEntry(
            name: entry.name,
            originalSize: UInt32(entry.data.count),
            method: method,
            checksum: crc32(entry.data),
            payload: payload
        )
    }

    private static func appendLocalRecord(to localSection: inout Data, _ prepared: PreparedEntry) {
        let nameBytes = Data(prepared.name.utf8)
        localSection.appendLittleEndian(0x04034B50)
        localSection.appendLittleEndian16(20) // version needed
        localSection.appendLittleEndian16(0) // flags
        localSection.appendLittleEndian16(prepared.method)
        localSection.appendLittleEndian16(0) // mod time
        localSection.appendLittleEndian16(0x21) // mod date (1980-01-01)
        localSection.appendLittleEndian(prepared.checksum)
        localSection.appendLittleEndian(UInt32(prepared.payload.count))
        localSection.appendLittleEndian(prepared.originalSize)
        localSection.appendLittleEndian16(UInt16(nameBytes.count))
        localSection.appendLittleEndian16(0) // extra length
        localSection.append(nameBytes)
        localSection.append(prepared.payload)
    }

    private static func appendCentralRecord(
        to centralSection: inout Data,
        _ prepared: PreparedEntry,
        localHeaderOffset: UInt32
    ) {
        let nameBytes = Data(prepared.name.utf8)
        centralSection.appendLittleEndian(0x02014B50)
        centralSection.appendLittleEndian16(20) // version made by
        centralSection.appendLittleEndian16(20) // version needed
        centralSection.appendLittleEndian16(0) // flags
        centralSection.appendLittleEndian16(prepared.method)
        centralSection.appendLittleEndian16(0) // mod time
        centralSection.appendLittleEndian16(0x21) // mod date
        centralSection.appendLittleEndian(prepared.checksum)
        centralSection.appendLittleEndian(UInt32(prepared.payload.count))
        centralSection.appendLittleEndian(prepared.originalSize)
        centralSection.appendLittleEndian16(UInt16(nameBytes.count))
        centralSection.appendLittleEndian16(0) // extra length
        centralSection.appendLittleEndian16(0) // comment length
        centralSection.appendLittleEndian16(0) // disk number
        centralSection.appendLittleEndian16(0) // internal attributes
        centralSection.appendLittleEndian(0) // external attributes
        centralSection.appendLittleEndian(localHeaderOffset)
        centralSection.append(nameBytes)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
        }
        return ~crc
    }

    private static func deflateRaw(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + 1024
        var output = Data(count: capacity)
        let encodedCount = output.withUnsafeMutableBytes { outputBuffer -> Int in
            data.withUnsafeBytes { inputBuffer -> Int in
                guard
                    let outputPointer = outputBuffer.bindMemory(to: UInt8.self).baseAddress,
                    let inputPointer = inputBuffer.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_encode_buffer(
                    outputPointer,
                    capacity,
                    inputPointer,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard encodedCount > 0 else { return nil }
        return Data(output.prefix(encodedCount))
    }
}

// MARK: - Extension fixture

/// A minimal manifest-v3 extension (manifest + trivial background worker),
/// available as an unpacked directory, a ZIP, or a CRX3 blob.
enum ExtensionFixture {
    static let name = "Ora Fixture Extension"
    static let version = "1.2.3"
    /// 32 chars of a–p, the Chrome extension ID alphabet.
    static let webStoreID = "abcdefghijklmnopabcdefghijklmnop"

    /// A base64 "key" manifest field (Chrome derives the extension id from
    /// its decoded bytes) and the id that derivation yields for it.
    static let manifestKey = "b3JhLWZpeHR1cmUtcHVibGljLWtleS1kZXItYnl0ZXM="
    static let manifestKeyDerivedID = "ckdpdgfggcndkeflocgbjdogakddnhdb"

    static let manifest = manifestJSON(version: version)

    static func manifestJSON(version: String, key: String? = nil) -> String {
        let keyField = key.map { "\"key\": \"\($0)\"," } ?? ""
        return """
        {
            "manifest_version": 3,
            \(keyField)
            "name": "\(name)",
            "version": "\(version)",
            "description": "Fixture for install pipeline tests",
            "permissions": ["storage"],
            "optional_permissions": ["tabs", "alarms", "nativeMessaging"],
            "background": { "service_worker": "background.js" }
        }
        """
    }

    static let backgroundScript = "console.log(\"fixture background running\");\n"

    static func makeUnpackedDirectory(version: String = version, key: String? = nil) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-fixture-extension-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(manifestJSON(version: version, key: key).utf8)
            .write(to: directory.appendingPathComponent("manifest.json"))
        try Data(backgroundScript.utf8).write(to: directory.appendingPathComponent("background.js"))
        return directory
    }

    static func makeZipData() -> Data {
        ZipFixtureWriter.archive(entries: [
            .init(name: "manifest.json", data: Data(manifest.utf8), deflated: true),
            .init(name: "background.js", data: Data(backgroundScript.utf8))
        ])
    }

    /// CRX3: "Cr24" + version 3 + header length + opaque header bytes + ZIP.
    static func makeCRXData(headerFiller: Int = 64) -> Data {
        var crx = Data("Cr24".utf8)
        crx.appendLittleEndian(3)
        crx.appendLittleEndian(UInt32(headerFiller))
        crx.append(Data(repeating: 0xAB, count: headerFiller))
        crx.append(makeZipData())
        return crx
    }
}
