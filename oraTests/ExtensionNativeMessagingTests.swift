import Foundation
@testable import Ora
import Testing
@preconcurrency import WebKit

/// Bundle anchor for locating test resources (the fixture echo host script).
private final class NativeMessagingTestsBundleToken {}

// MARK: - Frame codec

/// Chrome's native messaging wire format: native-endian uint32 byte length,
/// then that many bytes of UTF-8 JSON. Limits: 1 MB host→browser,
/// 4 GB browser→host.
struct NativeMessageCodecTests {
    @Test func roundTripsFramesAcrossArbitraryChunkBoundaries() throws {
        let first = Data(#"{"a":1}"#.utf8)
        let second = Data(#"{"b":"two"}"#.utf8)
        let stream = try NativeMessageCodec.encodeFrame(first) + NativeMessageCodec.encodeFrame(second)

        // Feed the stream byte by byte — frames must reassemble regardless of
        // how the pipe chunks the data.
        var decoder = NativeMessageFrameDecoder()
        var frames: [Data] = []
        for byte in stream {
            frames += try decoder.append(Data([byte]))
        }

        #expect(frames == [first, second])
        #expect(!decoder.hasPartialFrame)

        // And in one big chunk.
        var bulkDecoder = NativeMessageFrameDecoder()
        #expect(try bulkDecoder.append(stream) == [first, second])
    }

    @Test func encodeRejectsOversizeOutgoingMessage() {
        let payload = Data(repeating: 0x41, count: 32)
        #expect(throws: NativeMessagingError.self) {
            _ = try NativeMessageCodec.encodeFrame(payload, limit: 31)
        }
        // At the limit is fine.
        #expect(throws: Never.self) {
            _ = try NativeMessageCodec.encodeFrame(payload, limit: 32)
        }
    }

    @Test func decoderRejectsFrameLengthBeyondLimit() throws {
        // A length prefix over the host→browser limit is a protocol violation
        // even before any payload arrives.
        var header = Data()
        withUnsafeBytes(of: UInt32(100)) { header.append(contentsOf: $0) }

        var decoder = NativeMessageFrameDecoder(limit: 99)
        #expect(throws: NativeMessagingError.self) {
            _ = try decoder.append(header)
        }
    }

    @Test func truncatedFrameIsDetectedWhenStreamEnds() throws {
        let full = try NativeMessageCodec.encodeFrame(Data(#"{"a":1}"#.utf8))
        var decoder = NativeMessageFrameDecoder()
        let frames = try decoder.append(full.prefix(full.count - 2))

        #expect(frames.isEmpty)
        #expect(decoder.hasPartialFrame)
        #expect(throws: NativeMessagingError.self) {
            try decoder.finish()
        }

        // A drained decoder finishes cleanly.
        var cleanDecoder = NativeMessageFrameDecoder()
        _ = try cleanDecoder.append(full)
        #expect(throws: Never.self) { try cleanDecoder.finish() }
    }

    @Test func productionLimitsMatchChrome() {
        #expect(NativeMessageCodec.hostToBrowserLimit == 1024 * 1024)
        #expect(NativeMessageCodec.browserToHostLimit == Int(UInt32.max))
    }
}

// MARK: - Manifest resolution

/// Native Messaging Host manifests resolve Ora → user Chrome → system Chrome,
/// first match wins; a found-but-invalid manifest is an error, not a
/// fall-through.
struct NativeMessagingResolverTests {
    @Test func firstDirectoryInPrecedenceOrderWins() throws {
        let (resolver, directories) = try makeResolver()
        defer { cleanUp(directories) }
        try writeManifest(in: directories[0], hostName: "com.example.host", path: "/bin/ls")
        try writeManifest(in: directories[1], hostName: "com.example.host", path: "/bin/cat")
        try writeManifest(in: directories[2], hostName: "com.example.host", path: "/bin/echo")

        let manifest = try resolver.resolve(hostName: "com.example.host")
        #expect(manifest.path == "/bin/ls")
    }

    @Test func laterDirectoriesAreSearchedWhenEarlierOnesMiss() throws {
        let (resolver, directories) = try makeResolver()
        defer { cleanUp(directories) }
        try writeManifest(in: directories[2], hostName: "com.example.host", path: "/bin/echo")

        let manifest = try resolver.resolve(hostName: "com.example.host")
        #expect(manifest.path == "/bin/echo")
        #expect(manifest.name == "com.example.host")
    }

    @Test func missingHostThrowsNotFound() throws {
        let (resolver, directories) = try makeResolver()
        defer { cleanUp(directories) }

        #expect(throws: NativeMessagingError.hostNotFound("com.example.host")) {
            _ = try resolver.resolve(hostName: "com.example.host")
        }
    }

    @Test func wrongTypeIsInvalid() throws {
        let (resolver, directories) = try makeResolver()
        defer { cleanUp(directories) }
        try writeManifest(in: directories[0], hostName: "com.example.host", path: "/bin/ls", type: "websocket")

        #expect(throws: NativeMessagingError.self) {
            _ = try resolver.resolve(hostName: "com.example.host")
        }
    }

    @Test func nameMismatchIsInvalid() throws {
        // The manifest file is named com.example.host.json but declares a
        // different host name inside.
        let (resolver, directories) = try makeResolver()
        defer { cleanUp(directories) }
        try writeManifest(
            in: directories[0],
            hostName: "com.example.other",
            path: "/bin/ls",
            fileName: "com.example.host.json"
        )

        #expect(throws: NativeMessagingError.self) {
            _ = try resolver.resolve(hostName: "com.example.host")
        }
    }

    @Test func relativePathIsInvalid() throws {
        let (resolver, directories) = try makeResolver()
        defer { cleanUp(directories) }
        try writeManifest(in: directories[0], hostName: "com.example.host", path: "bin/ls")

        #expect(throws: NativeMessagingError.self) {
            _ = try resolver.resolve(hostName: "com.example.host")
        }
    }

    @Test func nonExecutablePathIsInvalid() throws {
        let (resolver, directories) = try makeResolver()
        defer { cleanUp(directories) }
        let plainFile = directories[0].appendingPathComponent("not-executable")
        try Data("data".utf8).write(to: plainFile)
        try writeManifest(in: directories[0], hostName: "com.example.host", path: plainFile.path)

        #expect(throws: NativeMessagingError.self) {
            _ = try resolver.resolve(hostName: "com.example.host")
        }
    }

    @Test func malformedManifestJSONIsInvalid() throws {
        let (resolver, directories) = try makeResolver()
        defer { cleanUp(directories) }
        try Data("not json".utf8).write(to: directories[0].appendingPathComponent("com.example.host.json"))

        #expect(throws: NativeMessagingError.self) {
            _ = try resolver.resolve(hostName: "com.example.host")
        }
    }

    @Test func hostNamesOutsideChromeNamingRulesAreRejectedWithoutTouchingDisk() {
        let resolver = NativeMessagingHostResolver(searchDirectories: [])

        let badNames = [
            "", "Com.Example.Host", "com..example", ".com.example",
            "com.example.", "com/example", "com example"
        ]
        for badName in badNames {
            #expect(throws: NativeMessagingError.invalidHostName(badName)) {
                _ = try resolver.resolve(hostName: badName)
            }
        }
    }

    @Test func defaultSearchOrderIsOraThenUserChromeThenSystemChrome() {
        let directories = NativeMessagingHostResolver.defaultSearchDirectories()
        let paths = directories.map(\.path)
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        #expect(paths == [
            "\(home)/Library/Application Support/Ora/NativeMessagingHosts",
            "\(home)/Library/Application Support/Google/Chrome/NativeMessagingHosts",
            "/Library/Google/Chrome/NativeMessagingHosts"
        ])
    }

    // MARK: Helpers

    /// Three fixture manifest directories standing in for Ora, user Chrome,
    /// and system Chrome, in resolver precedence order.
    private func makeResolver() throws -> (NativeMessagingHostResolver, [URL]) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-nm-resolver-\(UUID().uuidString)", isDirectory: true)
        let directories = ["ora", "chrome-user", "chrome-system"].map {
            base.appendingPathComponent($0, isDirectory: true)
        }
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return (NativeMessagingHostResolver(searchDirectories: directories), directories)
    }

    private func cleanUp(_ directories: [URL]) {
        if let base = directories.first?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: base)
        }
    }

    private func writeManifest(
        in directory: URL,
        hostName: String,
        path: String,
        type: String = "stdio",
        allowedOrigins: [String] = ["chrome-extension://\(ExtensionFixture.webStoreID)/"],
        fileName: String? = nil
    ) throws {
        let manifest: [String: Any] = [
            "name": hostName,
            "description": "Test host",
            "path": path,
            "type": type,
            "allowed_origins": allowedOrigins
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest)
        try data.write(to: directory.appendingPathComponent(fileName ?? "\(hostName).json"))
    }
}

// MARK: - Security gate

/// Chrome's model exactly: a granted `nativeMessaging` permission AND the
/// extension's origin in the host manifest's `allowed_origins`. No extra
/// prompts.
@MainActor
struct NativeMessagingSecurityGateTests {
    @Test func refusedWithoutNativeMessagingGrant() async throws {
        let (context, source) = try await makeFixtureContext()
        defer { try? FileManager.default.removeItem(at: source) }
        let manifest = makeManifest(allowedOrigins: ["chrome-extension://\(ExtensionFixture.webStoreID)/"])

        #expect(throws: NativeMessagingError.permissionNotGranted(extensionId: ExtensionFixture.webStoreID)) {
            try NativeMessagingSecurityGate.authorize(
                extensionId: ExtensionFixture.webStoreID,
                context: context,
                manifest: manifest
            )
        }
    }

    @Test func refusedWhenOriginIsNotAllowed() async throws {
        let (context, source) = try await makeFixtureContext()
        defer { try? FileManager.default.removeItem(at: source) }
        context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
        let manifest = makeManifest(allowedOrigins: ["chrome-extension://someotherextensionidentifierhere/"])

        #expect(throws: NativeMessagingError.originNotAllowed(
            extensionId: ExtensionFixture.webStoreID,
            hostName: "com.example.host"
        )) {
            try NativeMessagingSecurityGate.authorize(
                extensionId: ExtensionFixture.webStoreID,
                context: context,
                manifest: manifest
            )
        }
    }

    @Test func allowedWhenPermissionGrantedAndOriginListed() async throws {
        let (context, source) = try await makeFixtureContext()
        defer { try? FileManager.default.removeItem(at: source) }
        context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
        let manifest = makeManifest(allowedOrigins: ["chrome-extension://\(ExtensionFixture.webStoreID)/"])

        #expect(throws: Never.self) {
            try NativeMessagingSecurityGate.authorize(
                extensionId: ExtensionFixture.webStoreID,
                context: context,
                manifest: manifest
            )
        }
    }

    @Test func originMatchIgnoresTrailingSlashDifferences() async throws {
        // Manifests in the wild list origins both with and without the
        // trailing slash; Chrome treats them the same.
        let (context, source) = try await makeFixtureContext()
        defer { try? FileManager.default.removeItem(at: source) }
        context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
        let manifest = makeManifest(allowedOrigins: ["chrome-extension://\(ExtensionFixture.webStoreID)"])

        #expect(throws: Never.self) {
            try NativeMessagingSecurityGate.authorize(
                extensionId: ExtensionFixture.webStoreID,
                context: context,
                manifest: manifest
            )
        }
    }

    // MARK: Helpers

    private func makeFixtureContext() async throws -> (WKWebExtensionContext, URL) {
        let source = try ExtensionFixture.makeUnpackedDirectory()
        let webExtension = try await WKWebExtension(resourceBaseURL: source)
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = ExtensionFixture.webStoreID
        return (context, source)
    }

    private func makeManifest(allowedOrigins: [String]) -> NativeMessagingHostManifest {
        NativeMessagingHostManifest(
            name: "com.example.host",
            path: "/bin/ls",
            allowedOrigins: allowedOrigins
        )
    }
}

// MARK: - Echo host integration

/// End-to-end over a real process: the committed fixture echo host is
/// installed behind a fixture manifest in a temp directory, resolved like any
/// host, and spoken to over real pipes.
@MainActor
struct NativeMessagingEchoHostTests {
    @Test func connectExchangesMessagesAndClosingKillsTheHost() async throws {
        let echoHost = try installEchoHost()
        defer { echoHost.cleanUp() }
        let process = try startEchoHostProcess(echoHost)
        var received: [Data] = []
        process.onMessage = { received.append($0) }

        try process.send(Data(#"{"ping":1}"#.utf8))
        #expect(await waitUntil { !received.isEmpty })

        // The reply proves both the exchange and that the extension origin was
        // passed as the host's first argument.
        let reply = try JSONSerialization.jsonObject(with: #require(received.first)) as? [String: Any]
        #expect(reply?["origin"] as? String == "chrome-extension://\(ExtensionFixture.webStoreID)/")
        #expect((reply?["echo"] as? [String: Any])?["ping"] as? Int == 1)

        // A second exchange over the same port.
        try process.send(Data(#"{"ping":2}"#.utf8))
        #expect(await waitUntil { received.count == 2 })

        // Closing the port kills the process.
        process.terminate()
        #expect(await waitUntil { !process.isRunning })
    }

    @Test func hostSelfExitFiresDisconnect() async throws {
        let echoHost = try installEchoHost()
        defer { echoHost.cleanUp() }
        let process = try startEchoHostProcess(echoHost)
        var closed = false
        process.onClose = { _ in closed = true }

        try process.send(Data(#"{"exit":true}"#.utf8))

        #expect(await waitUntil { closed })
        #expect(await waitUntil { !process.isRunning })
    }

    @Test func writingToHostThatClosedStdinEndsConnectionInsteadOfCrashing() async throws {
        let echoHost = try installEchoHost()
        defer { echoHost.cleanUp() }
        let process = try startEchoHostProcess(echoHost)
        var received: [Data] = []
        var closed = false
        process.onMessage = { received.append($0) }
        process.onClose = { _ in closed = true }

        // The host closes its stdin but keeps running — the shape of a host
        // dying mid-session: `isRunning` is still true when the next write
        // happens, so only the write itself can discover the closed pipe.
        try process.send(Data(#"{"close_stdin":true}"#.utf8))
        #expect(await waitUntil { !received.isEmpty })

        // Without F_SETNOSIGPIPE on the stdin write fd this write raises
        // SIGPIPE and kills the whole app (exit 141) instead of failing with
        // EPIPE and closing the port.
        try process.send(Data(#"{"ping":1}"#.utf8))

        #expect(await waitUntil { closed })
        #expect(await waitUntil { !process.isRunning })
    }

    @Test func oneShotSpawnsWritesReadsAndTerminates() async throws {
        let echoHost = try installEchoHost()
        defer { echoHost.cleanUp() }
        let manifest = try echoHost.resolver.resolve(hostName: echoHost.hostName)

        var result: Swift.Result<Data, Error>?
        let process = try NativeMessagingHostProcess.sendOneShot(
            manifest: manifest,
            extensionOrigin: "chrome-extension://\(ExtensionFixture.webStoreID)/",
            payload: Data(#"{"once":true}"#.utf8)
        ) { result = $0 }

        #expect(await waitUntil { result != nil })
        let reply = try JSONSerialization.jsonObject(with: #require(try result?.get())) as? [String: Any]
        #expect((reply?["echo"] as? [String: Any])?["once"] as? Bool == true)
        // One-shot semantics: the host dies right after the reply.
        #expect(await waitUntil { !process.isRunning })
    }

    @Test func oneShotReleasesItsProcessOnceFinished() async throws {
        let echoHost = try installEchoHost()
        defer { echoHost.cleanUp() }
        let manifest = try echoHost.resolver.resolve(hostName: echoHost.hostName)

        var result: Swift.Result<Data, Error>?
        var process: NativeMessagingHostProcess? = try NativeMessagingHostProcess.sendOneShot(
            manifest: manifest,
            extensionOrigin: "chrome-extension://\(ExtensionFixture.webStoreID)/",
            payload: Data(#"{"once":true}"#.utf8)
        ) { result = $0 }
        weak let weakProcess = process

        #expect(await waitUntil { result != nil })
        #expect(await waitUntil { weakProcess?.isRunning != true })

        // Dropping the caller's reference must free the process: its handlers
        // are released when the exchange ends, so no self-retain cycle
        // (process → onClose → completion → process) keeps it, its pipes, or
        // the open stdout descriptor alive.
        process = nil
        #expect(await waitUntil { weakProcess == nil })
    }

    @Test func oneShotReportsHostExitWithoutReply() async throws {
        let echoHost = try installEchoHost()
        defer { echoHost.cleanUp() }
        let manifest = try echoHost.resolver.resolve(hostName: echoHost.hostName)

        var result: Swift.Result<Data, Error>?
        // {"exit":true} makes the echo host quit without replying. The
        // process must stay referenced while awaiting the outcome (production
        // tracks it in the manager's registry).
        let process = try NativeMessagingHostProcess.sendOneShot(
            manifest: manifest,
            extensionOrigin: "chrome-extension://\(ExtensionFixture.webStoreID)/",
            payload: Data(#"{"exit":true}"#.utf8)
        ) { result = $0 }

        #expect(await waitUntil { result != nil })
        if case .success = try #require(result) {
            Issue.record("Expected a host-exited-without-reply error")
        }
        #expect(await waitUntil { !process.isRunning })
    }

    // MARK: Helpers

    private struct EchoHostInstall {
        let hostName: String
        let resolver: NativeMessagingHostResolver
        let directory: URL

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Copies the committed echo host script into a temp directory, makes it
    /// executable, and writes a host manifest next to it.
    private func installEchoHost() throws -> EchoHostInstall {
        let bundle = Bundle(for: NativeMessagingTestsBundleToken.self)
        let scriptURL = try #require(
            bundle.url(forResource: "native-echo-host", withExtension: "py"),
            "echo host fixture missing from test bundle"
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-nm-echo-\(UUID().uuidString)", isDirectory: true)
        let hostsDirectory = directory.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        try FileManager.default.createDirectory(at: hostsDirectory, withIntermediateDirectories: true)

        let executable = directory.appendingPathComponent("native-echo-host.py")
        try FileManager.default.copyItem(at: scriptURL, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let hostName = "com.ora.tests.echo"
        let manifest: [String: Any] = [
            "name": hostName,
            "description": "Ora test echo host",
            "path": executable.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(ExtensionFixture.webStoreID)/"]
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: hostsDirectory.appendingPathComponent("\(hostName).json"))

        return EchoHostInstall(
            hostName: hostName,
            resolver: NativeMessagingHostResolver(searchDirectories: [hostsDirectory]),
            directory: directory
        )
    }

    /// Resolves and starts the echo host exactly as a `connectNative` would:
    /// manifest resolution, then spawn with the extension origin as argv[1].
    private func startEchoHostProcess(_ install: EchoHostInstall) throws -> NativeMessagingHostProcess {
        let manifest = try install.resolver.resolve(hostName: install.hostName)
        let process = NativeMessagingHostProcess(
            manifest: manifest,
            extensionOrigin: "chrome-extension://\(ExtensionFixture.webStoreID)/"
        )
        try process.start()
        return process
    }

    private func waitUntil(
        timeout: TimeInterval = 10,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}
