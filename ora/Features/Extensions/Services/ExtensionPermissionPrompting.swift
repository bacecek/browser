import Foundation
@preconcurrency import WebKit

/// Seam for extension permission prompts.
///
/// The controller delegate routes every WebKit permission prompt
/// (`promptForPermissions`, `promptForPermissionMatchPatterns`,
/// `promptForPermissionToAccess`) through this protocol. The default
/// `DenyExtensionPermissionPrompting` denies everything, so nothing is ever
/// granted silently. Browser windows replace
/// `ExtensionManager.shared.permissionPrompting` with
/// `ExtensionDialogPermissionPrompting`, which presents real dialogs through
/// the existing dialog system.
@MainActor
protocol ExtensionPermissionPrompting: AnyObject {
    func promptForPermissions(
        extensionName: String,
        permissions: Set<WKWebExtension.Permission>,
        completion: @escaping (Set<WKWebExtension.Permission>) -> Void
    )

    func promptForMatchPatterns(
        extensionName: String,
        matchPatterns: Set<WKWebExtension.MatchPattern>,
        completion: @escaping (Set<WKWebExtension.MatchPattern>) -> Void
    )

    func promptForURLAccess(
        extensionName: String,
        urls: Set<URL>,
        completion: @escaping (Set<URL>) -> Void
    )
}

/// Default prompting policy: deny everything. Active only while no browser
/// window has registered a real dialog implementation, so a prompt with no UI
/// to show it never grants anything; WebKit re-prompts on the next relevant
/// user action once a window is available.
@MainActor
final class DenyExtensionPermissionPrompting: ExtensionPermissionPrompting {
    func promptForPermissions(
        extensionName: String,
        permissions: Set<WKWebExtension.Permission>,
        completion: @escaping (Set<WKWebExtension.Permission>) -> Void
    ) {
        completion([])
    }

    func promptForMatchPatterns(
        extensionName: String,
        matchPatterns: Set<WKWebExtension.MatchPattern>,
        completion: @escaping (Set<WKWebExtension.MatchPattern>) -> Void
    ) {
        completion([])
    }

    func promptForURLAccess(
        extensionName: String,
        urls: Set<URL>,
        completion: @escaping (Set<URL>) -> Void
    ) {
        completion([])
    }
}
