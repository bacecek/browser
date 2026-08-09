import AppKit
import Foundation
import os.log
@preconcurrency import WebKit

private let logger = Logger(subsystem: "com.orabrowser.ora", category: "Extensions")

/// UI side of Extension Actions: tracks which NSView anchors each Extension's
/// URL-bar button, presents the API-provided popup popover for the controller
/// delegate, republishes action changes (badge text, icon, enablement) to the
/// buttons, and routes extension keyboard commands.
@MainActor
final class ExtensionActionCoordinator: NSObject, ObservableObject {
    static let shared = ExtensionActionCoordinator()

    /// Bumped whenever WebKit reports an action update so Extension Action
    /// buttons re-read badge text, icon, and enablement.
    @Published private(set) var actionGeneration: UInt = 0

    /// Anchor views registered by visible Extension Action buttons, keyed by
    /// extension id. Weak: anchors die with the URL bar (hidden toolbar) and
    /// are re-registered when it mounts again.
    private var anchors: [String: NSHashTable<NSView>] = [:]

    /// The button the user just clicked; consumed by the next popup presentation.
    private var pendingAnchor: (extensionId: String, view: WeakViewBox)?

    /// The currently shown action popover, so a second click can dismiss it
    /// (needed under the DEBUG `.applicationDefined` behavior, harmless otherwise).
    private weak var shownPopover: NSPopover?

    private struct WeakViewBox {
        weak var view: NSView?
    }

    func noteActionUpdated() {
        actionGeneration &+= 1
    }

    // MARK: - Anchors

    func registerAnchor(_ view: NSView, extensionId: String) {
        let table = anchors[extensionId] ?? NSHashTable<NSView>.weakObjects()
        table.add(view)
        anchors[extensionId] = table
    }

    // MARK: - Action click

    /// Performs the Extension Action as a user click on `anchor`. Wakes the
    /// background content first (MV3 service workers terminate when idle), then
    /// lets WebKit either dispatch the action event or call back into
    /// `presentPopup` through the controller delegate.
    func performAction(for installed: InstalledExtension, anchor: NSView, activeTab: Tab?) {
        // A second click while the popup is open dismisses it (toggle).
        if let shownPopover, shownPopover.isShown {
            shownPopover.performClose(nil)
            self.shownPopover = nil
            return
        }
        pendingAnchor = (installed.id, WeakViewBox(view: anchor))
        let manager = ExtensionManager.shared
        manager.loadBackgroundContentLoudly(for: installed.context, name: installed.name)
        let tabAdapter: ExtensionTabAdapter? = activeTab.flatMap { tab in
            tab.isPrivate ? nil : manager.adapter(for: tab)
        }
        installed.context.performAction(for: tabAdapter)
    }

    // MARK: - Popup presentation (called by the controller delegate)

    func presentPopup(
        for action: WKWebExtension.Action,
        context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard action.presentsPopup, let popover = action.popupPopover else {
            completionHandler(nil)
            return
        }
        guard let anchor = resolveAnchor(for: ExtensionManager.shared.extensionId(for: context)) else {
            // No visible button (toolbar hidden, or a programmatic openPopup()
            // before any URL bar mounted) — v1 shows no popup in that state.
            completionHandler(NSError(
                domain: "ExtensionActionCoordinator",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No visible Extension Action button to anchor the popup"]
            ))
            return
        }
        if !popover.isShown {
            #if DEBUG
                // Keep the popup on screen when the app loses focus so it can be
                // inspected via Safari's Develop menu; a transient popover vanishes
                // the moment focus moves to Safari. Dismiss with a second click on
                // the button (see performAction) or Esc.
                popover.behavior = .applicationDefined
            #else
                popover.behavior = .transient
            #endif
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
        shownPopover = popover
        action.hasUnreadBadgeText = false
        noteActionUpdated()
        completionHandler(nil)
    }

    /// The clicked button if one is pending, otherwise any registered button
    /// for the extension, preferring the key window's.
    private func resolveAnchor(for extensionId: String?) -> NSView? {
        defer { pendingAnchor = nil }
        if let pendingAnchor, pendingAnchor.extensionId == extensionId,
           let view = pendingAnchor.view.view, view.window != nil
        {
            return view
        }
        guard let extensionId, let table = anchors[extensionId] else { return nil }
        let candidates = table.allObjects.filter { $0.window != nil }
        return candidates.first(where: { $0.window?.isKeyWindow == true }) ?? candidates.first
    }

    // MARK: - Keyboard commands

    /// Routes a key event to extension commands (chrome.commands, e.g.
    /// 1Password's Cmd+\). Registered in each non-private window's
    /// KeyModifierListener chain so commands fire even with the toolbar hidden
    /// and while a webview has focus. Returns true when a command consumed the
    /// event.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        // Commands always carry a modifier — never swallow plain typing in
        // text fields.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.isDisjoint(with: [.command, .control, .option]) else { return false }

        let manager = ExtensionManager.shared
        for (extensionId, context) in manager.contexts {
            guard let command = context.command(for: event) else { continue }
            let name = context.webExtension.displayName ?? extensionId
            manager.loadBackgroundContentLoudly(for: context, name: name)
            context.performCommand(command)
            logger.info("""
            Performed extension command '\(command.id, privacy: .public)' \
            for '\(name, privacy: .public)'
            """)
            return true
        }
        return false
    }
}
