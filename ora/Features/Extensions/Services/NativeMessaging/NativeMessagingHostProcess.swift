import Foundation
import os.log

private let logger = Logger(subsystem: "com.orabrowser.ora", category: "Extensions")

/// One running Native Messaging Host process behind one Native Port.
///
/// Spawned from a resolved host manifest with the extension's
/// `chrome-extension://<id>/` origin as the first argument (Chrome's
/// contract), speaking length-prefixed JSON frames over stdin/stdout.
/// One process per port: the process dies when the port closes, the extension
/// unloads, or Ora quits; the host exiting on its own closes the port
/// (`onClose` → `onDisconnect` in the extension). No respawn-on-crash.
@MainActor
final class NativeMessagingHostProcess {
    let hostName: String

    /// A complete host→browser frame arrived (raw JSON bytes). Main thread.
    var onMessage: ((Data) -> Void)?

    /// The host side ended the connection — process exit, stdout EOF, or a
    /// protocol violation (with the violation as the error). Fires at most
    /// once and never for browser-initiated `terminate()`. Main thread.
    var onClose: ((Error?) -> Void)?

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private var decoder = NativeMessageFrameDecoder()
    private var closed = false

    /// All stdout reads happen sequentially on this queue; decoded on main.
    private nonisolated let readQueue = DispatchQueue(label: "com.orabrowser.ora.native-messaging.read")
    /// Writes leave the main thread so a full pipe buffer can't stall the UI.
    private nonisolated let writeQueue = DispatchQueue(label: "com.orabrowser.ora.native-messaging.write")

    init(manifest: NativeMessagingHostManifest, extensionOrigin: String) {
        hostName = manifest.name
        process.executableURL = manifest.executableURL
        process.arguments = [extensionOrigin]
        process.currentDirectoryURL = manifest.executableURL.deletingLastPathComponent()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // A dead host must not kill Ora: writing to a pipe whose read end is
        // closed raises SIGPIPE (fatal, not a thrown error) unless the fd
        // opts out. With F_SETNOSIGPIPE the write fails with EPIPE instead,
        // which `send` treats as the host ending the connection.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    var isRunning: Bool {
        process.isRunning
    }

    func start() throws {
        do {
            try process.run()
        } catch {
            logger.error("""
            Could not launch native messaging host '\(self.hostName, privacy: .public)': \
            \(error.localizedDescription, privacy: .public)
            """)
            throw error
        }
        logger.info("Launched native messaging host '\(self.hostName, privacy: .public)'")
        startReadLoop()
    }

    /// Frames and writes one browser→host message. Oversize messages throw
    /// and the caller closes the port, as Chrome does.
    func send(_ payload: Data) throws {
        guard !closed, process.isRunning else {
            throw NativeMessagingError.hostNotRunning(hostName)
        }
        let frame = try NativeMessageCodec.encodeFrame(payload)
        let handle = stdinPipe.fileHandleForWriting
        writeQueue.async { [weak self, hostName] in
            do {
                try handle.write(contentsOf: frame)
            } catch {
                logger.error("""
                Write to native messaging host '\(hostName, privacy: .public)' failed: \
                \(error.localizedDescription, privacy: .public)
                """)
                // EPIPE (host crashed or closed its stdin): the host side
                // ended the connection — close the port like a host exit.
                DispatchQueue.main.async {
                    self?.hostEnded(error)
                }
            }
        }
    }

    /// Browser-initiated shutdown (port closed, extension unloaded, app
    /// quitting). Idempotent; does not fire `onClose`.
    func terminate() {
        guard !closed else { return }
        closed = true
        tearDown()
    }

    // MARK: - Host side ending

    /// Blocking sequential reader: chunks are decoded on the main thread in
    /// arrival order, EOF (host exited or closed stdout) ends the connection.
    private func startReadLoop() {
        let handle = stdoutPipe.fileHandleForReading
        readQueue.async { [weak self] in
            while true {
                let data = handle.availableData
                guard !data.isEmpty else { break }
                DispatchQueue.main.async {
                    self?.consume(data)
                }
            }
            DispatchQueue.main.async {
                self?.hostStreamEnded()
            }
        }
    }

    private func consume(_ data: Data) {
        guard !closed else { return }
        do {
            for frame in try decoder.append(data) {
                onMessage?(frame)
            }
        } catch {
            logger.error("""
            Native messaging host '\(self.hostName, privacy: .public)' violated the wire protocol: \
            \(error.localizedDescription, privacy: .public)
            """)
            hostEnded(error)
        }
    }

    private func hostStreamEnded() {
        guard !closed else { return }
        var error: Error?
        do {
            try decoder.finish()
        } catch let truncation {
            error = truncation
        }
        logger.info("Native messaging host '\(self.hostName, privacy: .public)' ended the connection")
        hostEnded(error)
    }

    private func hostEnded(_ error: Error?) {
        guard !closed else { return }
        closed = true
        // tearDown releases both handlers (their captures can retain this
        // process — the one-shot completion does); grab onClose first for its
        // one final call.
        let close = onClose
        tearDown()
        close?(error)
    }

    /// Releases both handlers — they are never called again after the
    /// connection ends, and keeping them would leak any process retained in
    /// their captures (one-shot completions retain the process itself).
    private func tearDown() {
        onMessage = nil
        onClose = nil
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
    }
}

// MARK: - One-shot (runtime.sendNativeMessage)

extension NativeMessagingHostProcess {
    /// Chrome's one-shot flow: spawn the host, write the single message, read
    /// the single reply, terminate the host. The host exiting first reports
    /// `hostExitedWithoutReply`. Returns the spawned process so the caller
    /// can track it for extension-unload / app-quit termination.
    @discardableResult
    static func sendOneShot(
        manifest: NativeMessagingHostManifest,
        extensionOrigin: String,
        payload: Data,
        completion: @escaping (Swift.Result<Data, Error>) -> Void
    ) throws -> NativeMessagingHostProcess {
        let process = NativeMessagingHostProcess(manifest: manifest, extensionOrigin: extensionOrigin)
        var didReply = false

        process.onMessage = { [weak process] reply in
            guard !didReply else { return }
            didReply = true
            process?.terminate()
            completion(.success(reply))
        }
        process.onClose = { error in
            guard !didReply else { return }
            didReply = true
            completion(.failure(error ?? NativeMessagingError.hostExitedWithoutReply(manifest.name)))
        }

        do {
            try process.start()
            try process.send(payload)
        } catch {
            // A synchronous failure (spawn error, oversize payload) must not
            // leak an already-started host.
            process.terminate()
            throw error
        }
        return process
    }
}
