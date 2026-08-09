import CryptoKit
import Foundation
import os.log
@preconcurrency import WebKit

private let logger = Logger(subsystem: "com.orabrowser.ora", category: "Extensions")

/// What a fresh install asks the user to approve: the manifest's required
/// permissions and host patterns. Nothing is granted unless the user consents.
struct ExtensionInstallConsentRequest {
    let extensionName: String
    let permissions: Set<WKWebExtension.Permission>
    let matchPatterns: Set<WKWebExtension.MatchPattern>
}

// MARK: - Installation pipeline

extension ExtensionManager {
    /// Asks the user whether to install an extension given what it requests.
    /// Returning `false` aborts the install with no residue on disk.
    typealias InstallConsent = @MainActor (ExtensionInstallConsentRequest) async -> Bool

    /// Installs an unpacked extension directory (Chrome-format WebExtension).
    /// Surfaces the manifest's requested permissions and host patterns through
    /// `consent` before anything is granted; on approval copies the extension
    /// under the extensions directory, loads it into the controller, and
    /// persists it (with the approved grants) in the registry. Also the final
    /// step of every Web Store install, which passes the Chrome Web Store id
    /// as `canonicalId`.
    ///
    /// Installing an extension whose canonical id is already registered is an
    /// update (no auto-update in v1; reinstall re-downloads): after consent to
    /// the new version's requirements the old context is unloaded, the
    /// directory is replaced, and persisted grants the new manifest still
    /// requests carry over. Identity is ONLY the canonical id — names are
    /// attacker-controlled and non-unique, so they never decide updates.
    @discardableResult
    func install(
        fromUnpackedDirectory sourceURL: URL,
        canonicalId: String? = nil,
        consent: InstallConsent
    ) async throws -> InstalledExtension {
        ensureExtensionsDirectory()

        let manifest = try Self.validateManifest(inDirectory: sourceURL)

        // Stage into a temporary directory so a failed install never leaves a
        // half-copied extension behind.
        let stagingURL = extensionsDirectory
            .appendingPathComponent(Self.stagingDirectoryPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: sourceURL, to: stagingURL)

        do {
            let probeExtension = try await WKWebExtension(resourceBaseURL: stagingURL)
            // Canonical identity names the final directory and keys the
            // registry, keeping the extension's storage namespace stable
            // across versions. Store installs pass the Chrome Web Store id;
            // unpacked installs derive Chrome's id from the manifest "key"
            // when present; otherwise WebKit mints a fresh identifier and the
            // install can never be an update of anything already installed.
            let extensionId = canonicalId
                ?? Self.canonicalId(fromManifestKey: manifest["key"] as? String)
                ?? WKWebExtensionContext(for: probeExtension).uniqueIdentifier
            let previousRecord = registryRecords.first { $0.id == extensionId }

            // Explicit user consent to the (new) version's requirements before
            // anything is granted, copied into place, or unloaded.
            guard let approved = await approvedInstallRequest(
                for: probeExtension,
                manifest: manifest,
                consent: consent
            ) else {
                throw ExtensionInstallError.installationCancelled
            }

            unloadPreviousVersion(extensionId: extensionId, name: previousRecord?.name ?? extensionId)

            let finalURL = extensionsDirectory.appendingPathComponent(extensionId, isDirectory: true)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: stagingURL, to: finalURL)

            // Re-create the extension from the FINAL path: resources (service
            // worker, popup, icons) are served from resourceBaseURL at runtime.
            let webExtension = try await WKWebExtension(resourceBaseURL: finalURL)
            let record = registryRecord(
                for: webExtension,
                extensionId: extensionId,
                manifest: manifest,
                approved: approved,
                previousRecord: previousRecord
            )
            return try finalizeInstall(
                webExtension: webExtension,
                finalURL: finalURL,
                record: record,
                isUpdate: previousRecord != nil
            )
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
    }

    /// Builds the consent request from the manifest's required permissions and
    /// host patterns and surfaces it through `consent`. Optional items stay
    /// undecided and go through the runtime prompt flow later. Returns the
    /// approved request, or nil when the user declines.
    private func approvedInstallRequest(
        for webExtension: WKWebExtension,
        manifest: [String: Any],
        consent: InstallConsent
    ) async -> ExtensionInstallConsentRequest? {
        let optionalMatches = webExtension.optionalPermissionMatchPatterns
        let request = ExtensionInstallConsentRequest(
            extensionName: displayName(of: webExtension, manifest: manifest),
            permissions: webExtension.requestedPermissions,
            matchPatterns: webExtension.allRequestedMatchPatterns.filter { !optionalMatches.contains($0) }
        )
        return await consent(request) ? request : nil
    }

    /// Update path: retires the running old version (no-op on a fresh
    /// install) so its directory can be replaced and the new version loaded
    /// fresh.
    private func unloadPreviousVersion(extensionId: String, name: String) {
        guard let existingContext = contexts[extensionId] else { return }
        terminateNativeMessagingHosts(forExtension: extensionId)
        do {
            try controller.unload(existingContext)
        } catch {
            logger.error("""
            Could not unload previous version of '\(name, privacy: .public)': \
            \(error.localizedDescription, privacy: .public)
            """)
        }
        removeInstalledExtension(id: extensionId)
    }

    /// Registers a freshly copied extension with the controller and persists
    /// its registry record. Removes the final directory on load failure.
    private func finalizeInstall(
        webExtension: WKWebExtension,
        finalURL: URL,
        record: ExtensionRegistryRecord,
        isUpdate: Bool
    ) throws -> InstalledExtension {
        let installed: InstalledExtension
        do {
            installed = try loadIntoController(
                webExtension: webExtension,
                extensionId: record.id,
                directoryURL: finalURL,
                record: record
            )
        } catch {
            try? FileManager.default.removeItem(at: finalURL)
            throw ExtensionInstallError.installationFailed(error.localizedDescription)
        }

        upsertRecord(record)
        upsertInstalledExtension(installed)
        let action = isUpdate ? "Updated" : "Installed"
        logger.info("""
        \(action, privacy: .public) extension '\(record.name, privacy: .public)' \
        v\(record.version, privacy: .public) (\(record.id, privacy: .public))
        """)
        return installed
    }

    /// Builds the registry record for a fresh install or update: the
    /// user-approved grants plus, on an update, the previously persisted
    /// grants the new manifest still requests — anything the new manifest
    /// dropped is forgotten.
    private func registryRecord(
        for webExtension: WKWebExtension,
        extensionId: String,
        manifest: [String: Any],
        approved: ExtensionInstallConsentRequest,
        previousRecord: ExtensionRegistryRecord?
    ) -> ExtensionRegistryRecord {
        var grantedPermissions = Set(approved.permissions.map(\.rawValue))
        var grantedMatchPatterns = Set(approved.matchPatterns.map(\.string))
        if let previousRecord {
            let stillRequestedPermissions = webExtension.requestedPermissions
                .union(webExtension.optionalPermissions)
                .map(\.rawValue)
            grantedPermissions.formUnion(
                Set(previousRecord.grantedPermissions).intersection(stillRequestedPermissions)
            )
            let stillRequestedMatches = webExtension.allRequestedMatchPatterns
                .union(webExtension.optionalPermissionMatchPatterns)
                .map(\.string)
            grantedMatchPatterns.formUnion(
                Set(previousRecord.grantedMatchPatterns).intersection(stillRequestedMatches)
            )
        }

        return ExtensionRegistryRecord(
            id: extensionId,
            name: displayName(of: webExtension, manifest: manifest),
            version: webExtension.displayVersion ?? (manifest["version"] as? String ?? ""),
            directoryName: extensionId,
            grantedPermissions: Array(grantedPermissions),
            grantedMatchPatterns: Array(grantedMatchPatterns),
            installedAt: Date()
        )
    }

    /// User-facing name with the manifest fallback chain. Display only —
    /// never used as identity (see `install`'s canonical-id rules).
    private func displayName(of webExtension: WKWebExtension, manifest: [String: Any]) -> String {
        webExtension.displayName ?? (manifest["name"] as? String ?? "Extension")
    }

    /// Chrome's stable extension id derived from the manifest "key" field
    /// (the base64-encoded DER public key), using Chrome's own derivation:
    /// SHA-256 of the decoded key bytes, first 16 bytes, each nibble mapped
    /// into the a–p alphabet. A keyed unpacked extension therefore gets the
    /// same id it has in Chrome and updates itself across reinstalls.
    /// Returns nil when `key` is absent or not valid base64 — the install is
    /// then treated as keyless and minted a fresh identity.
    static func canonicalId(fromManifestKey key: String?) -> String? {
        guard let key, let keyData = Data(base64Encoded: key) else { return nil }
        return SHA256.hash(data: keyData)
            .prefix(16)
            .flatMap { [$0 >> 4, $0 & 0x0F] }
            .map { String(UnicodeScalar(UInt8(ascii: "a") + $0)) }
            .joined()
    }

    /// Unloads the extension, deletes its directory, and forgets it in the registry.
    func uninstall(_ extensionId: String) throws {
        guard let record = registryRecords.first(where: { $0.id == extensionId }) else {
            throw ExtensionInstallError.notInstalled(extensionId)
        }

        terminateNativeMessagingHosts(forExtension: extensionId)
        if let context = contexts[extensionId] {
            do {
                try controller.unload(context)
            } catch {
                logger.error("""
                Could not unload context for '\(record.name, privacy: .public)': \
                \(error.localizedDescription, privacy: .public)
                """)
            }
        }

        let directoryURL = extensionsDirectory.appendingPathComponent(record.directoryName, isDirectory: true)
        try? FileManager.default.removeItem(at: directoryURL)

        removeInstalledExtension(id: extensionId)
        removeRecord(id: extensionId)
        logger.info("Uninstalled extension '\(record.name, privacy: .public)' (\(extensionId, privacy: .public))")
    }

    // MARK: - Helpers

    /// Minimal manifest.json validation before handing the directory to WebKit.
    static func validateManifest(inDirectory directory: URL) throws -> [String: Any] {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ExtensionInstallError.invalidManifest("No manifest.json in \(directory.lastPathComponent)")
        }
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw ExtensionInstallError.invalidManifest(error.localizedDescription)
        }
        guard let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExtensionInstallError.invalidManifest("manifest.json is not a JSON object")
        }
        guard manifest["manifest_version"] is Int else {
            throw ExtensionInstallError.invalidManifest("Missing manifest_version")
        }
        guard manifest["name"] is String else {
            throw ExtensionInstallError.invalidManifest("Missing name")
        }
        return manifest
    }
}
