import Foundation

// MARK: - Errors

/// Everything that can go wrong between `runtime.connectNative` and a running
/// Native Messaging Host. Failures surface as the port error (visible to the
/// extension) and in the `Extensions` log category, so misconfiguration is
/// diagnosable without Web Inspector.
enum NativeMessagingError: Error, Equatable, LocalizedError {
    // Wire protocol
    case outgoingMessageTooLarge(byteCount: Int, limit: Int)
    case incomingMessageTooLarge(byteCount: Int, limit: Int)
    case truncatedMessage(pendingBytes: Int)

    // Manifest resolution
    case invalidHostName(String)
    case hostNotFound(String)
    case invalidManifest(hostName: String, reason: String)

    // Security gate
    case permissionNotGranted(extensionId: String)
    case originNotAllowed(extensionId: String, hostName: String)

    // Process lifecycle
    case hostNotRunning(String)
    case hostExitedWithoutReply(String)
    case messageNotSerializable

    var errorDescription: String? {
        switch self {
        case let .outgoingMessageTooLarge(byteCount, limit):
            "Message to native host is \(byteCount) bytes; the limit is \(limit)"
        case let .incomingMessageTooLarge(byteCount, limit):
            "Message from native host is \(byteCount) bytes; the limit is \(limit)"
        case let .truncatedMessage(pendingBytes):
            "Native host stream ended mid-message (\(pendingBytes) bytes pending)"
        case let .invalidHostName(name):
            "'\(name)' is not a valid native messaging host name"
        case let .hostNotFound(name):
            "No manifest found for native messaging host '\(name)'"
        case let .invalidManifest(hostName, reason):
            "Invalid manifest for native messaging host '\(hostName)': \(reason)"
        case let .permissionNotGranted(extensionId):
            "Extension \(extensionId) has no granted nativeMessaging permission"
        case let .originNotAllowed(extensionId, hostName):
            "Native messaging host '\(hostName)' does not allow extension \(extensionId)"
        case let .hostNotRunning(name):
            "Native messaging host '\(name)' is not running"
        case let .hostExitedWithoutReply(name):
            "Native messaging host '\(name)' exited without replying"
        case .messageNotSerializable:
            "Native message is not JSON-serializable"
        }
    }
}

// MARK: - Frame codec

/// Chrome's native messaging wire format: each frame is a native-endian
/// `uint32` byte length followed by that many bytes of UTF-8 JSON.
enum NativeMessageCodec {
    /// Chrome caps messages from the host at 1 MB.
    static let hostToBrowserLimit = 1024 * 1024

    /// Chrome documents 4 GB toward the host; the 4-byte length prefix caps a
    /// frame at `UInt32.max` anyway.
    static let browserToHostLimit = Int(UInt32.max)

    /// Encodes one browser→host frame. Oversize payloads are refused — the
    /// caller closes the port with the error, as Chrome does.
    static func encodeFrame(_ payload: Data, limit: Int = browserToHostLimit) throws -> Data {
        guard payload.count <= limit else {
            throw NativeMessagingError.outgoingMessageTooLarge(byteCount: payload.count, limit: limit)
        }
        var frame = Data(capacity: 4 + payload.count)
        withUnsafeBytes(of: UInt32(payload.count)) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }
}

/// Reassembles host→browser frames from an arbitrarily chunked stdout stream.
/// A length prefix over the limit is a protocol violation and poisons the
/// stream — the port must be closed with the error.
struct NativeMessageFrameDecoder {
    private let limit: Int
    private var buffer = Data()

    init(limit: Int = NativeMessageCodec.hostToBrowserLimit) {
        self.limit = limit
    }

    /// Bytes of an incomplete frame are still pending.
    var hasPartialFrame: Bool {
        !buffer.isEmpty
    }

    /// Appends a chunk and returns every frame it completed.
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            guard length <= limit else {
                throw NativeMessagingError.incomingMessageTooLarge(byteCount: length, limit: limit)
            }
            guard buffer.count >= 4 + length else { break }
            frames.append(buffer.subdata(in: (start + 4) ..< (start + 4 + length)))
            buffer.removeSubrange(start ..< (start + 4 + length))
        }
        return frames
    }

    /// Call when the stream ends: leftover bytes mean the host died
    /// mid-message.
    func finish() throws {
        guard buffer.isEmpty else {
            throw NativeMessagingError.truncatedMessage(pendingBytes: buffer.count)
        }
    }
}
