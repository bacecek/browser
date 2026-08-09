import AppKit
import Foundation
import os.log
@preconcurrency import WebKit

private let logger = Logger(subsystem: "com.orabrowser.ora", category: "Extensions")

// MARK: - Native messaging (runtime.connectNative / runtime.sendNativeMessage)

//
// WebKit routes both APIs to these two controller-delegate hooks; Ora resolves
// the Native Messaging Host manifest (Ora → user Chrome → system Chrome),
// enforces Chrome's security gate, spawns the host process, and bridges stdio
// frames to the WKWebExtension.MessagePort. See NativeMessaging/ for the
// codec, resolver, gate, and process pieces this glues together.

/// One live Native Port: the WebKit-side port (retained — releasing it would
/// disconnect), the host process behind it, and the owning extension so
/// unload/uninstall can kill the right hosts. One-shot sends have no port.
struct NativeMessagingConnection {
    let extensionId: String
    let port: WKWebExtension.MessagePort?
    let process: NativeMessagingHostProcess
}

extension ExtensionManager {
    // MARK: Delegate hooks

    /// `runtime.connectNative`: port-based, what 1Password uses.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        do {
            let authorized = try authorizeNativeHost(
                applicationIdentifier: port.applicationIdentifier,
                for: extensionContext
            )
            let process = NativeMessagingHostProcess(
                manifest: authorized.manifest,
                extensionOrigin: authorized.origin
            )
            attach(port: port, to: process, extensionId: authorized.extensionId)
            try process.start()
            registerNativeConnection(NativeMessagingConnection(
                extensionId: authorized.extensionId,
                port: port,
                process: process
            ))
            completionHandler(nil)
        } catch {
            logger.error("""
            connectNative to '\(port.applicationIdentifier ?? "<nil>", privacy: .public)' refused: \
            \(error.localizedDescription, privacy: .public)
            """)
            completionHandler(error)
        }
    }

    /// `runtime.sendNativeMessage`: one-shot — spawn the host, write the one
    /// message, read the one reply, terminate the host.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for extensionContext: WKWebExtensionContext,
        replyHandler: @escaping (Any?, (any Error)?) -> Void
    ) {
        do {
            let authorized = try authorizeNativeHost(
                applicationIdentifier: applicationIdentifier,
                for: extensionContext
            )
            let payload = try Self.encodeNativePayload(message)
            // The completion unregisters exactly its own connection, by
            // process identity. The reference only exists after sendOneShot
            // returns; the completion cannot observe it nil because it is
            // always dispatched onto this same main thread, after this turn.
            var spawnedProcess: NativeMessagingHostProcess?
            let process = try NativeMessagingHostProcess.sendOneShot(
                manifest: authorized.manifest,
                extensionOrigin: authorized.origin,
                payload: payload
            ) { [weak self] result in
                MainActor.assumeIsolated {
                    switch result {
                    case let .success(replyData):
                        do {
                            try replyHandler(Self.decodeNativePayload(replyData), nil)
                        } catch {
                            replyHandler(nil, error)
                        }
                    case let .failure(error):
                        replyHandler(nil, error)
                    }
                    if let spawnedProcess {
                        self?.unregisterNativeConnections { $0.process === spawnedProcess }
                    }
                }
            }
            spawnedProcess = process
            registerNativeConnection(NativeMessagingConnection(
                extensionId: authorized.extensionId,
                port: nil,
                process: process
            ))
        } catch {
            logger.error("""
            sendNativeMessage to '\(applicationIdentifier ?? "<nil>", privacy: .public)' refused: \
            \(error.localizedDescription, privacy: .public)
            """)
            replyHandler(nil, error)
        }
    }

    // MARK: Resolution + security gate

    private struct AuthorizedNativeHost {
        let extensionId: String
        let manifest: NativeMessagingHostManifest
        let origin: String
    }

    /// The shared front door of both hooks: known extension, resolvable host
    /// manifest, and Chrome's security gate (granted `nativeMessaging`
    /// permission + origin listed in `allowed_origins`).
    private func authorizeNativeHost(
        applicationIdentifier: String?,
        for extensionContext: WKWebExtensionContext
    ) throws -> AuthorizedNativeHost {
        guard let extensionId = extensionId(for: extensionContext) else {
            throw NativeMessagingError.permissionNotGranted(extensionId: extensionContext.uniqueIdentifier)
        }
        let manifest = try nativeMessagingResolver.resolve(hostName: applicationIdentifier ?? "")
        try NativeMessagingSecurityGate.authorize(
            extensionId: extensionId,
            context: extensionContext,
            manifest: manifest
        )
        return AuthorizedNativeHost(
            extensionId: extensionId,
            manifest: manifest,
            origin: NativeMessagingSecurityGate.origin(forExtensionId: extensionId)
        )
    }

    // MARK: Port ↔ process bridging

    private func attach(port: WKWebExtension.MessagePort, to process: NativeMessagingHostProcess, extensionId: String) {
        // Extension → host. The port must be captured weakly in its own
        // handler — a strong capture makes the port retain itself forever
        // (the registry keeps it alive for as long as it is connected).
        port.messageHandler = { [weak self, weak process, weak port] message, error in
            MainActor.assumeIsolated {
                guard let process else { return }
                if let error {
                    logger.error("""
                    Native port message error: \(error.localizedDescription, privacy: .public)
                    """)
                    return
                }
                do {
                    try process.send(Self.encodeNativePayload(message))
                } catch {
                    logger.error("""
                    Dropping message to native host '\(process.hostName, privacy: .public)': \
                    \(error.localizedDescription, privacy: .public)
                    """)
                    // Chrome closes the connection on a protocol violation.
                    process.terminate()
                    port?.disconnect(throwing: error)
                    self?.unregisterNativeConnections { $0.process === process }
                }
            }
        }

        // Host → extension.
        process.onMessage = { [weak port] frame in
            guard let port else { return }
            do {
                try port.sendMessage(Self.decodeNativePayload(frame), completionHandler: nil)
            } catch {
                logger.error("""
                Dropping malformed JSON from native host: \(error.localizedDescription, privacy: .public)
                """)
            }
        }

        // Host exit (or protocol violation) fires the extension's onDisconnect.
        process.onClose = { [weak self, weak port, weak process] error in
            port?.disconnect(throwing: error)
            if let process {
                self?.unregisterNativeConnections { $0.process === process }
            }
        }

        // Port closed by the extension (or WebKit) kills the host process.
        port.disconnectHandler = { [weak self, weak process] _ in
            MainActor.assumeIsolated {
                guard let process else { return }
                process.terminate()
                self?.unregisterNativeConnections { $0.process === process }
            }
        }
    }

    // MARK: Payload conversion

    /// The port hands over JSON-serializable objects (dictionaries for the
    /// typical `postMessage({...})`); the wire wants their UTF-8 JSON bytes.
    private static func encodeNativePayload(_ message: Any?) throws -> Data {
        guard let message else { throw NativeMessagingError.messageNotSerializable }
        do {
            return try JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed])
        } catch {
            throw NativeMessagingError.messageNotSerializable
        }
    }

    private static func decodeNativePayload(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    // MARK: Connection registry (one process per port; see ExtensionManager.nativeMessagingConnections)

    private func registerNativeConnection(_ connection: NativeMessagingConnection) {
        nativeMessagingConnections[ObjectIdentifier(connection.process)] = connection
    }

    private func unregisterNativeConnections(where predicate: (NativeMessagingConnection) -> Bool) {
        for (key, connection) in nativeMessagingConnections where predicate(connection) {
            nativeMessagingConnections[key] = nil
        }
    }

    /// Kills every host the extension holds open. Called when the extension
    /// unloads (uninstall or update).
    func terminateNativeMessagingHosts(forExtension extensionId: String) {
        for (key, connection) in nativeMessagingConnections where connection.extensionId == extensionId {
            connection.process.terminate()
            connection.port?.disconnect()
            nativeMessagingConnections[key] = nil
        }
    }

    /// Kills every running host. Called when Ora quits.
    func terminateAllNativeMessagingHosts() {
        for connection in nativeMessagingConnections.values {
            connection.process.terminate()
            connection.port?.disconnect()
        }
        nativeMessagingConnections.removeAll()
    }
}
