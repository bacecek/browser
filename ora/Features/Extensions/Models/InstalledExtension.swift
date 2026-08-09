import Foundation
@preconcurrency import WebKit

/// A loaded, installed Extension. Runtime value built from the on-disk registry;
/// carries the live WKWebExtension/WKWebExtensionContext for UI (icon, action, options page).
struct InstalledExtension: Identifiable {
    /// WebKit's unique identifier for the extension; also the on-disk directory name.
    let id: String
    let name: String
    let version: String
    let directoryURL: URL
    let webExtension: WKWebExtension
    let context: WKWebExtensionContext

    var hasOptionsPage: Bool {
        webExtension.hasOptionsPage
    }

    var hasBackgroundContent: Bool {
        webExtension.hasBackgroundContent
    }
}

/// Persisted registry entry for one installed Extension.
/// Stored as JSON in `<extensionsDirectory>/registry.json`.
struct ExtensionRegistryRecord: Codable, Identifiable {
    let id: String
    var name: String
    var version: String
    /// Directory name under the extensions directory holding the unpacked extension.
    var directoryName: String
    /// Raw values of user-approved permissions (install consent + runtime
    /// grants), re-applied on relaunch. Nothing outside this list is granted.
    var grantedPermissions: [String]
    /// Pattern strings of user-approved match patterns (install consent +
    /// runtime grants), re-applied on relaunch.
    var grantedMatchPatterns: [String]
    var installedAt: Date
}

enum ExtensionInstallError: LocalizedError {
    case invalidWebStoreReference(String)
    case downloadFailed(String)
    case invalidCRX
    case unzipFailed(String)
    case invalidManifest(String)
    case installationFailed(String)
    case installationCancelled
    case notInstalled(String)

    var errorDescription: String? {
        switch self {
        case let .invalidWebStoreReference(input):
            "Not a Chrome Web Store URL or extension ID: \(input)"
        case let .downloadFailed(reason):
            "Extension download failed: \(reason)"
        case .invalidCRX:
            "Downloaded file is not a valid CRX package"
        case let .unzipFailed(reason):
            "Could not unpack the extension: \(reason)"
        case let .invalidManifest(reason):
            "Invalid manifest.json: \(reason)"
        case let .installationFailed(reason):
            "Installation failed: \(reason)"
        case .installationCancelled:
            "Installation cancelled"
        case let .notInstalled(id):
            "No installed extension with id \(id)"
        }
    }
}
