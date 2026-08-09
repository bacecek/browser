import AppKit
import Foundation
@preconcurrency import WebKit

// MARK: - Extension Action delegate callbacks (popup presentation, badge updates)

//
// The UI half of WKWebExtensionControllerDelegate. Popups anchor to the
// Extension Action buttons in the URL bar via ExtensionActionCoordinator.

extension ExtensionManager {
    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        ExtensionActionCoordinator.shared.presentPopup(
            for: action,
            context: extensionContext,
            completionHandler: completionHandler
        )
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext extensionContext: WKWebExtensionContext
    ) {
        ExtensionActionCoordinator.shared.noteActionUpdated()
    }
}
