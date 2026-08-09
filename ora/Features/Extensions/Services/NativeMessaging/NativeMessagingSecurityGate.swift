import Foundation
@preconcurrency import WebKit

/// Chrome's access model for native messaging, exactly and nothing more: the
/// Extension must hold a granted `nativeMessaging` permission (through the
/// existing consent flow) AND the host manifest's `allowed_origins` must list
/// the extension's `chrome-extension://<id>/` origin. Ora's extension ids are
/// Chrome Web Store ids, so the origin match is direct. No extra runtime
/// prompts.
@MainActor
enum NativeMessagingSecurityGate {
    static func origin(forExtensionId extensionId: String) -> String {
        "chrome-extension://\(extensionId)/"
    }

    static func authorize(
        extensionId: String,
        context: WKWebExtensionContext,
        manifest: NativeMessagingHostManifest
    ) throws {
        guard context.hasPermission(.nativeMessaging) else {
            throw NativeMessagingError.permissionNotGranted(extensionId: extensionId)
        }

        // Manifests in the wild list origins with and without the trailing
        // slash; Chrome treats them the same.
        let expected = normalize(origin(forExtensionId: extensionId))
        guard manifest.allowedOrigins.contains(where: { normalize($0) == expected }) else {
            throw NativeMessagingError.originNotAllowed(extensionId: extensionId, hostName: manifest.name)
        }
    }

    private static func normalize(_ origin: String) -> String {
        origin.hasSuffix("/") ? String(origin.dropLast()) : origin
    }
}
