import Compression
import Foundation

/// Minimal in-process ZIP extraction for Chrome Web Store payloads.
///
/// Foundation has no unzip API and the App Sandbox cannot spawn
/// `/usr/bin/unzip`, so this walks the ZIP central directory itself and
/// inflates entries with libcompression (`COMPRESSION_ZLIB` decodes the raw
/// DEFLATE streams ZIP stores). Covers what the Web Store produces: stored
/// (method 0) and deflated (method 8) entries. ZIP64, encryption, and
/// multi-disk archives are rejected with a typed error.
enum ZipArchive {
    private struct Entry {
        let name: String
        let compressionMethod: Int
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int

        var isDirectory: Bool {
            name.hasSuffix("/")
        }
    }

    private static let endOfCentralDirectorySignature: UInt32 = 0x06054B50
    private static let centralDirectorySignature: UInt32 = 0x02014B50
    private static let localHeaderSignature: UInt32 = 0x04034B50

    /// Extracts every entry of `zipData` into `destination` (created if needed).
    static func extract(_ zipData: Data, to destination: URL) throws {
        // Normalize so all offsets below are absolute even if handed a slice.
        let data = Data(zipData)
        let entries = try centralDirectoryEntries(in: data)
        guard entries.contains(where: { !$0.isDirectory }) else {
            throw ExtensionInstallError.unzipFailed("Archive contains no files")
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        for entry in entries {
            let entryURL = try safeDestinationURL(for: entry.name, under: destination)
            if entry.isDirectory {
                try fileManager.createDirectory(at: entryURL, withIntermediateDirectories: true)
                continue
            }
            try fileManager.createDirectory(
                at: entryURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let contents = try entryContents(of: entry, in: data)
            try contents.write(to: entryURL)
        }
    }

    // MARK: - Central directory

    private static func centralDirectoryEntries(in data: Data) throws -> [Entry] {
        let eocdOffset = try endOfCentralDirectoryOffset(in: data)
        let entryCount = readUInt16(data, at: eocdOffset + 10)
        let directorySize = Int(data.littleEndianUInt32(at: eocdOffset + 12))
        let directoryOffset = Int(data.littleEndianUInt32(at: eocdOffset + 16))

        guard entryCount != 0xFFFF, directoryOffset != 0xFFFFFFFF else {
            throw ExtensionInstallError.unzipFailed("ZIP64 archives are not supported")
        }
        guard directoryOffset + directorySize <= eocdOffset else {
            throw ExtensionInstallError.unzipFailed("Central directory out of bounds")
        }

        var entries: [Entry] = []
        var offset = directoryOffset
        for _ in 0 ..< entryCount {
            guard offset + 46 <= data.count, data.littleEndianUInt32(at: offset) == centralDirectorySignature else {
                throw ExtensionInstallError.unzipFailed("Malformed central directory")
            }
            let compressionMethod = readUInt16(data, at: offset + 10)
            let compressedSize = Int(data.littleEndianUInt32(at: offset + 20))
            let uncompressedSize = Int(data.littleEndianUInt32(at: offset + 24))
            let nameLength = readUInt16(data, at: offset + 28)
            let extraLength = readUInt16(data, at: offset + 30)
            let commentLength = readUInt16(data, at: offset + 32)
            let localHeaderOffset = Int(data.littleEndianUInt32(at: offset + 42))

            guard compressedSize != 0xFFFFFFFF, uncompressedSize != 0xFFFFFFFF,
                  localHeaderOffset != 0xFFFFFFFF
            else {
                throw ExtensionInstallError.unzipFailed("ZIP64 archives are not supported")
            }
            guard offset + 46 + nameLength <= data.count else {
                throw ExtensionInstallError.unzipFailed("Malformed central directory")
            }
            let nameData = data.subdata(in: (offset + 46) ..< (offset + 46 + nameLength))
            guard let entryName = String(bytes: nameData, encoding: .utf8) else {
                throw ExtensionInstallError.unzipFailed("Non-UTF-8 entry name in central directory")
            }
            entries.append(Entry(
                name: entryName,
                compressionMethod: compressionMethod,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            ))
            offset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func endOfCentralDirectoryOffset(in data: Data) throws -> Int {
        let recordLength = 22
        guard data.count >= recordLength else {
            throw ExtensionInstallError.unzipFailed("Not a ZIP archive")
        }
        // The record sits at the very end, before an optional comment of up to 64 KB.
        let searchLowerBound = max(0, data.count - recordLength - 0xFFFF)
        var offset = data.count - recordLength
        while offset >= searchLowerBound {
            if data.littleEndianUInt32(at: offset) == endOfCentralDirectorySignature {
                return offset
            }
            offset -= 1
        }
        throw ExtensionInstallError.unzipFailed("Not a ZIP archive (no end-of-central-directory record)")
    }

    // MARK: - Entry data

    private static func entryContents(of entry: Entry, in data: Data) throws -> Data {
        let headerOffset = entry.localHeaderOffset
        guard headerOffset >= 0, headerOffset + 30 <= data.count,
              data.littleEndianUInt32(at: headerOffset) == localHeaderSignature
        else {
            throw ExtensionInstallError.unzipFailed("Malformed local header for \(entry.name)")
        }
        // Name/extra lengths in the local header can differ from the central directory's.
        let nameLength = readUInt16(data, at: headerOffset + 26)
        let extraLength = readUInt16(data, at: headerOffset + 28)
        let dataOffset = headerOffset + 30 + nameLength + extraLength
        guard dataOffset + entry.compressedSize <= data.count else {
            throw ExtensionInstallError.unzipFailed("Truncated data for \(entry.name)")
        }
        let compressed = data.subdata(in: dataOffset ..< dataOffset + entry.compressedSize)

        switch entry.compressionMethod {
        case 0:
            guard compressed.count == entry.uncompressedSize else {
                throw ExtensionInstallError.unzipFailed("Size mismatch for stored entry \(entry.name)")
            }
            return compressed
        case 8:
            return try inflate(compressed, uncompressedSize: entry.uncompressedSize, name: entry.name)
        default:
            throw ExtensionInstallError.unzipFailed(
                "Unsupported compression method \(entry.compressionMethod) for \(entry.name)"
            )
        }
    }

    private static func inflate(_ compressed: Data, uncompressedSize: Int, name: String) throws -> Data {
        guard uncompressedSize > 0 else { return Data() }
        guard !compressed.isEmpty else {
            throw ExtensionInstallError.unzipFailed("Empty deflate stream for \(name)")
        }
        var output = Data(count: uncompressedSize)
        let decodedCount = output.withUnsafeMutableBytes { outputBuffer -> Int in
            compressed.withUnsafeBytes { inputBuffer -> Int in
                guard
                    let outputPointer = outputBuffer.bindMemory(to: UInt8.self).baseAddress,
                    let inputPointer = inputBuffer.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_decode_buffer(
                    outputPointer,
                    uncompressedSize,
                    inputPointer,
                    compressed.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decodedCount == uncompressedSize else {
            throw ExtensionInstallError.unzipFailed("Could not inflate \(name)")
        }
        return output
    }

    // MARK: - Path safety

    /// Resolves an archive path under `destination`, rejecting absolute paths
    /// and `..` traversal so a hostile archive cannot write outside it.
    private static func safeDestinationURL(for name: String, under destination: URL) throws -> URL {
        let components = name.split(separator: "/").map(String.init)
        guard !name.hasPrefix("/"), !components.isEmpty, !components.contains("..") else {
            throw ExtensionInstallError.unzipFailed("Unsafe path in archive: \(name)")
        }
        return components.reduce(destination) { $0.appendingPathComponent($1) }
    }

    // MARK: - Little-endian readers

    private static func readUInt16(_ data: Data, at offset: Int) -> Int {
        Int(data[offset]) | (Int(data[offset + 1]) << 8)
    }
}

/// Shared by the ZIP and CRX binary parsers (see `CRXArchive`). The offset is
/// an absolute index into the data's underlying storage, so hand this whole
/// `Data` values, not slices.
extension Data {
    func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
