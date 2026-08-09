import Foundation

/// Sandbox-safe Chrome Web Store install pipeline.
///
/// Paste-a-link flow: parse the store URL or bare extension ID, download the
/// CRX from Google's update endpoint, strip the CRX header, and unzip fully
/// in-process (the App Sandbox cannot spawn `/usr/bin/unzip` — see
/// `ZipArchive`). The unpacked directory is then handed to
/// `ExtensionManager.install(fromUnpackedDirectory:canonicalId:)` together
/// with the parsed 32-char store id — the canonical identity that decides
/// whether the install updates an existing extension. The manager stages the
/// directory under the extensions directory, loads it into the controller,
/// and persists it in the registry. Every failure surfaces as an
/// `ExtensionInstallError` with a user-presentable message.
struct WebStoreInstaller {
    /// Injectable so tests can stub the network with a URLProtocol.
    var session: URLSession = .shared

    /// Full pipeline: Web Store URL or bare ID → installed Extension.
    /// `consent` surfaces the extension's requested permissions/hosts for
    /// explicit user approval before anything is granted or installed.
    @MainActor
    @discardableResult
    func install(
        reference: String,
        into manager: ExtensionManager,
        consent: ExtensionManager.InstallConsent
    ) async throws -> InstalledExtension {
        let (unpackedURL, canonicalId) = try await downloadAndUnpack(reference: reference)
        // The work directory is the unpacked directory's parent; installation
        // copies the extension out of it, so it is always removed afterwards.
        defer { try? FileManager.default.removeItem(at: unpackedURL.deletingLastPathComponent()) }
        return try await manager.install(
            fromUnpackedDirectory: unpackedURL,
            canonicalId: canonicalId,
            consent: consent
        )
    }

    /// Downloads and unpacks the extension into a fresh temporary work
    /// directory and returns the unpacked directory plus the parsed store id
    /// (the canonical identity handed to the manager). On success the caller
    /// removes the unpacked directory's parent when done; on failure the work
    /// directory is already cleaned up.
    func downloadAndUnpack(reference: String) async throws -> (unpackedURL: URL, canonicalId: String) {
        guard let extensionId = ChromeWebStoreDownloader.extensionID(from: reference) else {
            throw ExtensionInstallError.invalidWebStoreReference(reference)
        }

        let downloader = ChromeWebStoreDownloader(session: session)
        let crxData = try await downloader.downloadCRX(extensionId: extensionId)
        let zipData = try CRXArchive.zipData(from: crxData)

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-webstore-install-\(UUID().uuidString)", isDirectory: true)
        let unpackedURL = workDirectory.appendingPathComponent("unpacked", isDirectory: true)
        do {
            try ZipArchive.extract(zipData, to: unpackedURL)
        } catch {
            try? FileManager.default.removeItem(at: workDirectory)
            throw error
        }
        return (unpackedURL, extensionId)
    }
}
