import AppKit
import Foundation
@preconcurrency import WebKit

/// Formats permission-ish items as the "•  item" list shown by both the
/// runtime permission dialogs and the install-consent alert.
enum ExtensionPermissionBulletList {
    static func format(_ items: [String]) -> String {
        items.map { "•  \($0)" }.joined(separator: "\n")
    }
}

/// Real-dialog implementation of the permission-prompt seam: routes WebKit's
/// permission prompts through a browser window's DialogManager as an
/// Allow/Deny confirm (all-or-nothing per prompt). Allowed grants are
/// persisted by the controller delegate via `persistRuntimeGrants`, so an
/// Allow survives relaunch.
///
/// Browser windows register their DialogManager on appear (OraRoot); Private
/// Windows and the Settings window never register. With no registered browser
/// window a prompt is denied — WebKit re-prompts on the next relevant user
/// action.
@MainActor
final class ExtensionDialogPermissionPrompting: ExtensionPermissionPrompting {
    static let shared = ExtensionDialogPermissionPrompting()

    private struct Entry {
        weak var dialogManager: DialogManager?
        weak var window: NSWindow?
    }

    private var entries: [Entry] = []

    /// Registers a browser window's DialogManager and makes dialog prompting
    /// the active seam (replacing the deny-by-default implementation).
    func register(dialogManager: DialogManager, window: NSWindow?) {
        entries.removeAll { $0.dialogManager == nil || $0.dialogManager === dialogManager }
        entries.append(Entry(dialogManager: dialogManager, window: window))
        ExtensionManager.shared.permissionPrompting = self
    }

    func unregister(dialogManager: DialogManager) {
        entries.removeAll { $0.dialogManager == nil || $0.dialogManager === dialogManager }
    }

    /// The key window's DialogManager, else any live one.
    private var currentDialogManager: DialogManager? {
        entries.last(where: { $0.window?.isKeyWindow == true && $0.dialogManager != nil })?.dialogManager
            ?? entries.last(where: { $0.dialogManager != nil })?.dialogManager
    }

    // MARK: - ExtensionPermissionPrompting

    func promptForPermissions(
        extensionName: String,
        permissions: Set<WKWebExtension.Permission>,
        completion: @escaping (Set<WKWebExtension.Permission>) -> Void
    ) {
        confirm(
            title: "\"\(extensionName)\" requests permissions",
            message: bulletList(permissions.map(\.rawValue))
        ) { allowed in
            completion(allowed ? permissions : [])
        }
    }

    func promptForMatchPatterns(
        extensionName: String,
        matchPatterns: Set<WKWebExtension.MatchPattern>,
        completion: @escaping (Set<WKWebExtension.MatchPattern>) -> Void
    ) {
        confirm(
            title: "\"\(extensionName)\" wants to read and change websites",
            message: bulletList(matchPatterns.map(\.string))
        ) { allowed in
            completion(allowed ? matchPatterns : [])
        }
    }

    func promptForURLAccess(
        extensionName: String,
        urls: Set<URL>,
        completion: @escaping (Set<URL>) -> Void
    ) {
        confirm(
            title: "\"\(extensionName)\" wants to access these sites",
            message: bulletList(urls.map { $0.host ?? $0.absoluteString })
        ) { allowed in
            completion(allowed ? urls : [])
        }
    }

    // MARK: - Helpers

    private func bulletList(_ items: [String]) -> String {
        ExtensionPermissionBulletList.format(items.sorted())
    }

    private func confirm(title: String, message: String, completion: @escaping (Bool) -> Void) {
        guard let dialogManager = currentDialogManager else {
            completion(false)
            return
        }
        dialogManager.confirm(
            title: title,
            message: message,
            confirmLabel: "Allow",
            onConfirm: { completion(true) },
            onCancel: { completion(false) }
        )
    }
}
