import Foundation
@testable import Ora
import Testing
@preconcurrency import WebKit

// MARK: - Packaging tests

/// The pure parsing/unpacking pieces of the install pipeline — no
/// ExtensionManager and no shared controller, so no serialization needed.
struct ExtensionPackagingTests {
    // MARK: Web Store reference parsing

    @Test func parsesBareExtensionID() {
        #expect(ChromeWebStoreDownloader.extensionID(from: ExtensionFixture.webStoreID)
            == ExtensionFixture.webStoreID)
        #expect(ChromeWebStoreDownloader.extensionID(from: "  \(ExtensionFixture.webStoreID)\n")
            == ExtensionFixture.webStoreID)
    }

    @Test func parsesWebStoreURLs() {
        let onePasswordID = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"
        let modern = "https://chromewebstore.google.com/detail/1password/\(onePasswordID)"
        let legacy = "https://chrome.google.com/webstore/detail/1password/\(onePasswordID)?hl=en"

        #expect(ChromeWebStoreDownloader.extensionID(from: modern) == onePasswordID)
        #expect(ChromeWebStoreDownloader.extensionID(from: legacy) == onePasswordID)
    }

    @Test func rejectsInvalidReferences() {
        #expect(ChromeWebStoreDownloader.extensionID(from: "") == nil)
        #expect(ChromeWebStoreDownloader.extensionID(from: "not-an-id") == nil)
        // 32 chars but outside the a–p alphabet.
        #expect(ChromeWebStoreDownloader.extensionID(from: String(repeating: "z", count: 32)) == nil)
        // 31 chars of the right alphabet.
        #expect(ChromeWebStoreDownloader.extensionID(from: String(repeating: "a", count: 31)) == nil)
        #expect(ChromeWebStoreDownloader.extensionID(from: "https://example.com/detail/whatever") == nil)
    }

    // MARK: CRX header stripping

    @Test func stripsCRX3Header() throws {
        let zipData = ExtensionFixture.makeZipData()
        let stripped = try CRXArchive.zipData(from: ExtensionFixture.makeCRXData())
        #expect(stripped == zipData)
    }

    @Test func rejectsMalformedCRX() {
        // Wrong magic.
        var wrongMagic = ExtensionFixture.makeCRXData()
        wrongMagic[0] = 0x50
        #expect(throws: ExtensionInstallError.self) { try CRXArchive.zipData(from: wrongMagic) }

        // Unsupported version.
        var badVersion = ExtensionFixture.makeCRXData()
        badVersion[4] = 7
        #expect(throws: ExtensionInstallError.self) { try CRXArchive.zipData(from: badVersion) }

        // Header length pointing past the end of the file.
        var crx = Data("Cr24".utf8)
        crx.appendLittleEndian(3)
        crx.appendLittleEndian(1_000_000)
        crx.append(Data(repeating: 0, count: 32))
        #expect(throws: ExtensionInstallError.self) { try CRXArchive.zipData(from: crx) }

        // Truncated.
        #expect(throws: ExtensionInstallError.self) { try CRXArchive.zipData(from: Data("Cr24".utf8)) }
    }

    // MARK: ZIP extraction

    @Test func extractsStoredAndDeflatedEntries() throws {
        let archive = ZipFixtureWriter.archive(entries: [
            .init(name: "manifest.json", data: Data(ExtensionFixture.manifest.utf8), deflated: true),
            .init(name: "background.js", data: Data(ExtensionFixture.backgroundScript.utf8)),
            .init(name: "assets/", data: Data()),
            .init(name: "assets/icon.txt", data: Data("icon-bytes".utf8), deflated: true)
        ])
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-zip-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        try ZipArchive.extract(archive, to: destination)

        let manifest = try Data(contentsOf: destination.appendingPathComponent("manifest.json"))
        let background = try Data(contentsOf: destination.appendingPathComponent("background.js"))
        let nested = try Data(contentsOf: destination.appendingPathComponent("assets/icon.txt"))
        #expect(manifest == Data(ExtensionFixture.manifest.utf8))
        #expect(background == Data(ExtensionFixture.backgroundScript.utf8))
        #expect(nested == Data("icon-bytes".utf8))
    }

    @Test func rejectsZipPathTraversal() {
        let hostile = ZipFixtureWriter.archive(entries: [
            .init(name: "../escaped.txt", data: Data("evil".utf8))
        ])
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-zip-traversal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        #expect(throws: ExtensionInstallError.self) {
            try ZipArchive.extract(hostile, to: destination)
        }
        #expect(!FileManager.default.fileExists(
            atPath: destination.deletingLastPathComponent().appendingPathComponent("escaped.txt").path
        ))
    }

    @Test func rejectsNonZipData() {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-zip-garbage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        #expect(throws: ExtensionInstallError.self) {
            try ZipArchive.extract(Data(repeating: 0x41, count: 128), to: destination)
        }
    }
}

// MARK: - Install pipeline tests

/// Serialized: each ExtensionManager owns a WKWebExtensionController with the
/// app-wide storage identifier, so instances must not race each other.
@Suite(.serialized)
@MainActor
struct ExtensionInstallTests {
    // MARK: Manager seam — install / uninstall / relaunch

    @Test func installFromUnpackedFolderAppearsInInstalledExtensions() async throws {
        let (manager, directory) = makeManager()
        defer { cleanUp(manager, directory: directory) }
        let source = try ExtensionFixture.makeUnpackedDirectory()
        defer { try? FileManager.default.removeItem(at: source) }

        let installed = try await manager.install(fromUnpackedDirectory: source, consent: approveAll)

        #expect(manager.installedExtensions.contains { $0.id == installed.id })
        #expect(installed.name == ExtensionFixture.name)
        #expect(installed.version == ExtensionFixture.version)
        #expect(FileManager.default.fileExists(
            atPath: installed.directoryURL.appendingPathComponent("manifest.json").path
        ))
        // Persisted for relaunch.
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("registry.json").path))
    }

    @Test func installRejectsFolderWithoutManifest() async throws {
        let (manager, directory) = makeManager()
        defer { cleanUp(manager, directory: directory) }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-empty-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }

        await #expect(throws: ExtensionInstallError.self) {
            try await manager.install(fromUnpackedDirectory: source, consent: approveAll)
        }
        #expect(manager.installedExtensions.isEmpty)
    }

    @Test func installConsentReceivesRequestedPermissionsAndCancelAbortsCleanly() async throws {
        let (manager, directory) = makeManager()
        defer { cleanUp(manager, directory: directory) }
        let source = try ExtensionFixture.makeUnpackedDirectory()
        defer { try? FileManager.default.removeItem(at: source) }

        var received: ExtensionInstallConsentRequest?
        await #expect(throws: ExtensionInstallError.self) {
            try await manager.install(fromUnpackedDirectory: source) { request in
                received = request
                return false
            }
        }

        // The consent prompt saw exactly what the manifest requires.
        let request = try #require(received)
        #expect(request.extensionName == ExtensionFixture.name)
        #expect(request.permissions == [.storage])

        // Cancelling leaves no residue: nothing loaded, nothing registered,
        // nothing on disk.
        #expect(manager.installedExtensions.isEmpty)
        #expect(manager.registryRecords.isEmpty)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func reinstallUpdatesInPlaceWithoutDuplicates() async throws {
        let (manager, directory) = makeManager()
        defer { cleanUp(manager, directory: directory) }

        let sourceV1 = try ExtensionFixture.makeUnpackedDirectory()
        defer { try? FileManager.default.removeItem(at: sourceV1) }
        let installed = try await manager.install(
            fromUnpackedDirectory: sourceV1,
            canonicalId: ExtensionFixture.webStoreID,
            consent: approveAll
        )
        // A runtime grant of an optional permission the new version still
        // requests — it must carry over without re-consent.
        manager.persistRuntimeGrants(for: installed.context, permissions: [.tabs])

        let sourceV2 = try ExtensionFixture.makeUnpackedDirectory(version: "2.0.0")
        defer { try? FileManager.default.removeItem(at: sourceV2) }
        let updated = try await manager.install(
            fromUnpackedDirectory: sourceV2,
            canonicalId: ExtensionFixture.webStoreID,
            consent: approveAll
        )

        // One entry, the canonical identity, new version — in memory and in
        // the registry.
        #expect(manager.installedExtensions.count == 1)
        #expect(installed.id == ExtensionFixture.webStoreID)
        #expect(updated.id == installed.id)
        #expect(updated.version == "2.0.0")
        #expect(manager.registryRecords.count == 1)
        #expect(manager.registryRecords.first?.version == "2.0.0")

        // Grants: the freshly consented required permission plus the
        // carried-over runtime grant.
        #expect(updated.context.hasPermission(.storage))
        #expect(updated.context.hasPermission(.tabs))

        // No duplicate or leftover directories: exactly the registry file and
        // the one extension directory.
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(entries == ["registry.json", updated.id].sorted())
    }

    @Test func sameDisplayNameNeverHijacksExistingInstall() async throws {
        let (manager, directory) = makeManager()
        defer { cleanUp(manager, directory: directory) }

        let victimSource = try ExtensionFixture.makeUnpackedDirectory()
        defer { try? FileManager.default.removeItem(at: victimSource) }
        let victim = try await manager.install(
            fromUnpackedDirectory: victimSource,
            canonicalId: ExtensionFixture.webStoreID,
            consent: approveAll
        )
        manager.persistRuntimeGrants(for: victim.context, permissions: [.tabs])

        // A DIFFERENT extension with the SAME display name and no canonical
        // id installs alongside — never as an update of the victim.
        let impostorSource = try ExtensionFixture.makeUnpackedDirectory(version: "9.9.9")
        defer { try? FileManager.default.removeItem(at: impostorSource) }
        let impostor = try await manager.install(fromUnpackedDirectory: impostorSource, consent: approveAll)

        #expect(impostor.name == victim.name)
        #expect(impostor.id != victim.id)
        #expect(manager.installedExtensions.count == 2)
        #expect(manager.registryRecords.count == 2)

        // The victim is untouched: its directory, live context, version, and
        // persisted grants all survive.
        #expect(FileManager.default.fileExists(
            atPath: victim.directoryURL.appendingPathComponent("manifest.json").path
        ))
        #expect(manager.context(for: victim.id) === victim.context)
        let victimRecord = try #require(manager.registryRecords.first { $0.id == victim.id })
        #expect(victimRecord.version == ExtensionFixture.version)
        #expect(victimRecord.grantedPermissions.contains("tabs"))
    }

    @Test func keylessUnpackedInstallsAreIndependent() async throws {
        let (manager, directory) = makeManager()
        defer { cleanUp(manager, directory: directory) }

        let firstSource = try ExtensionFixture.makeUnpackedDirectory()
        defer { try? FileManager.default.removeItem(at: firstSource) }
        let secondSource = try ExtensionFixture.makeUnpackedDirectory()
        defer { try? FileManager.default.removeItem(at: secondSource) }

        let first = try await manager.install(fromUnpackedDirectory: firstSource, consent: approveAll)
        let second = try await manager.install(fromUnpackedDirectory: secondSource, consent: approveAll)

        // No manifest "key", no canonical id: each install mints a fresh
        // identity — the second is NOT an update of the first.
        #expect(first.id != second.id)
        #expect(manager.installedExtensions.count == 2)
        #expect(manager.registryRecords.count == 2)
        #expect(manager.context(for: first.id) === first.context)
    }

    @Test func manifestKeyGivesStableIdentityAcrossReinstalls() async throws {
        // Chrome's derivation: SHA-256 of the decoded key, first 16 bytes,
        // nibbles mapped into a–p. Pinned against a precomputed value.
        #expect(ExtensionManager.canonicalId(fromManifestKey: ExtensionFixture.manifestKey)
            == ExtensionFixture.manifestKeyDerivedID)
        #expect(ExtensionManager.canonicalId(fromManifestKey: nil) == nil)
        #expect(ExtensionManager.canonicalId(fromManifestKey: "not base64 !!") == nil)

        let (manager, directory) = makeManager()
        defer { cleanUp(manager, directory: directory) }

        let sourceV1 = try ExtensionFixture.makeUnpackedDirectory(key: ExtensionFixture.manifestKey)
        defer { try? FileManager.default.removeItem(at: sourceV1) }
        let installed = try await manager.install(fromUnpackedDirectory: sourceV1, consent: approveAll)
        #expect(installed.id == ExtensionFixture.manifestKeyDerivedID)

        let sourceV2 = try ExtensionFixture.makeUnpackedDirectory(version: "2.0.0", key: ExtensionFixture.manifestKey)
        defer { try? FileManager.default.removeItem(at: sourceV2) }
        let updated = try await manager.install(fromUnpackedDirectory: sourceV2, consent: approveAll)

        // Same key → same derived id → an in-place update, not a duplicate.
        #expect(updated.id == installed.id)
        #expect(updated.version == "2.0.0")
        #expect(manager.installedExtensions.count == 1)
        #expect(manager.registryRecords.count == 1)
    }

    @Test func loadPrunesStagingResidue() async throws {
        let (manager, directory) = makeManager()
        defer { cleanUp(manager, directory: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A crash mid-install leaves a staging directory behind; an unrelated
        // directory must survive the conservative prune.
        let staging = directory.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        let unrelated = directory.appendingPathComponent("not-staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)

        await manager.loadInstalledExtensions()

        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test func uninstallRemovesExtension() async throws {
        let (manager, directory) = makeManager()
        defer { cleanUp(manager, directory: directory) }
        let source = try ExtensionFixture.makeUnpackedDirectory()
        defer { try? FileManager.default.removeItem(at: source) }

        let installed = try await manager.install(fromUnpackedDirectory: source, consent: approveAll)
        try manager.uninstall(installed.id)

        #expect(manager.installedExtensions.isEmpty)
        #expect(manager.context(for: installed.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: installed.directoryURL.path))

        // Gone from the registry a relaunch would read.
        let relaunched = ExtensionManager(extensionsDirectory: directory)
        await relaunched.loadInstalledExtensions()
        defer { cleanUp(relaunched, directory: directory) }
        #expect(relaunched.installedExtensions.isEmpty)
    }

    @Test func relaunchRestoresInstalledExtensionWithPermissions() async throws {
        let (manager, directory) = makeManager()
        let source = try ExtensionFixture.makeUnpackedDirectory()
        defer { try? FileManager.default.removeItem(at: source) }

        let installed = try await manager.install(fromUnpackedDirectory: source, consent: approveAll)
        let extensionId = installed.id
        // A runtime grant of an optional permission, persisted through the
        // real machinery (what the prompt delegate calls after user approval).
        manager.persistRuntimeGrants(for: installed.context, permissions: [.tabs])
        // Simulate app quit: unload the context but keep everything on disk.
        cleanUp(manager, directory: nil)

        let relaunched = ExtensionManager(extensionsDirectory: directory)
        await relaunched.loadInstalledExtensions()
        defer { cleanUp(relaunched, directory: directory) }

        #expect(relaunched.installedExtensions.count == 1)
        let restored = try #require(relaunched.installedExtensions.first)
        #expect(restored.id == extensionId)
        #expect(restored.name == ExtensionFixture.name)
        #expect(restored.version == ExtensionFixture.version)
        // The install-consented required permission round-trips.
        #expect(restored.context.hasPermission(.storage))
        // The runtime-granted optional permission round-trips.
        #expect(restored.context.hasPermission(.tabs))
        // A never-granted optional permission stays ungranted — relaunch
        // applies only persisted grants, no blanket manifest re-grant.
        #expect(!restored.context.hasPermission(.alarms))
    }

    // MARK: Extension context surface (offscreen, extension pages)

    @Test func loadedContextMarksOffscreenUnsupported() async throws {
        let (manager, directory) = makeManager()
        defer { cleanUp(manager, directory: directory) }
        let source = try ExtensionFixture.makeUnpackedDirectory()
        defer { try? FileManager.default.removeItem(at: source) }

        let installed = try await manager.install(fromUnpackedDirectory: source, consent: approveAll)

        // 1Password's worker must see chrome.offscreen === undefined and
        // feature-detect instead of crashing at startup.
        #expect(installed.context.unsupportedAPIs.contains("offscreen"))
    }

    @Test func extensionPagesGetTheContextWebViewConfiguration() async throws {
        let (manager, directory) = makeManager()
        defer { cleanUp(manager, directory: directory) }
        let source = try ExtensionFixture.makeUnpackedDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        let installed = try await manager.install(fromUnpackedDirectory: source, consent: approveAll)

        // An extension's own page must load in a webview carrying the
        // extension controller configuration (ordinary webviews reject
        // top-level webkit-extension:// navigation with -1008).
        let pageURL = try #require(URL(string: "webkit-extension://\(installed.id)/options.html"))
        let configuration = try #require(manager.extensionPageWebViewConfiguration(for: pageURL))
        #expect(configuration.webExtensionController === manager.controller)

        // Ordinary URLs and unknown extensions stay on the normal path.
        #expect(try manager.extensionPageWebViewConfiguration(for: #require(URL(string: "https://example.com"))) == nil)
        #expect(try manager.extensionPageWebViewConfiguration(
            for: #require(URL(string: "webkit-extension://unknownextension/options.html"))
        ) == nil)
    }

    // MARK: Web Store pipeline with stubbed network

    @Test func installsFromWebStoreURLWithStubbedNetwork() async throws {
        let (manager, directory) = makeManager()
        defer { cleanUp(manager, directory: directory) }
        CRXStubURLProtocol.stub(body: ExtensionFixture.makeCRXData())
        let installer = WebStoreInstaller(session: makeStubbedSession())

        let reference = "https://chromewebstore.google.com/detail/fixture/\(ExtensionFixture.webStoreID)"
        let installed = try await installer.install(reference: reference, into: manager, consent: approveAll)

        #expect(manager.installedExtensions.contains { $0.id == installed.id })
        #expect(installed.name == ExtensionFixture.name)
        // The parsed store id IS the canonical identity: it keys the registry
        // record (and names the on-disk directory).
        #expect(installed.id == ExtensionFixture.webStoreID)
        #expect(manager.registryRecords.first?.id == ExtensionFixture.webStoreID)
        // The CRX was requested from the update endpoint for the parsed ID.
        let requestedURL = try #require(CRXStubURLProtocol.lastRequestedURL)
        #expect(requestedURL.host == "clients2.google.com")
        #expect(requestedURL.absoluteString.contains(ExtensionFixture.webStoreID))
    }

    @Test func webStoreInstallRejectsInvalidReference() async {
        let installer = WebStoreInstaller(session: makeStubbedSession())

        await #expect(throws: ExtensionInstallError.self) {
            _ = try await installer.downloadAndUnpack(reference: "definitely not a store link")
        }
    }

    @Test func webStoreInstallSurfacesHTTPErrors() async {
        CRXStubURLProtocol.stub(body: Data("not found".utf8), statusCode: 404)
        let installer = WebStoreInstaller(session: makeStubbedSession())

        await #expect(throws: ExtensionInstallError.self) {
            _ = try await installer.downloadAndUnpack(reference: ExtensionFixture.webStoreID)
        }
    }

    @Test func webStoreInstallSurfacesMalformedCRX() async {
        CRXStubURLProtocol.stub(body: Data("this is not a CRX".utf8))
        let installer = WebStoreInstaller(session: makeStubbedSession())

        await #expect(throws: ExtensionInstallError.self) {
            _ = try await installer.downloadAndUnpack(reference: ExtensionFixture.webStoreID)
        }
    }

    // MARK: Helpers

    /// Install consent that approves everything, for tests not about consent.
    private let approveAll: ExtensionManager.InstallConsent = { _ in true }

    private func makeManager() -> (ExtensionManager, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-extension-tests-\(UUID().uuidString)", isDirectory: true)
        return (ExtensionManager(extensionsDirectory: directory), directory)
    }

    /// Unloads every context (so controllers do not accumulate live extensions
    /// across tests) and removes the manager's on-disk directory.
    private func cleanUp(_ manager: ExtensionManager, directory: URL?) {
        for installed in manager.installedExtensions {
            try? manager.controller.unload(installed.context)
        }
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeStubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CRXStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
