import AppKit
import Foundation
import os.log
@preconcurrency import WebKit

private let logger = Logger(subsystem: "com.orabrowser.ora", category: "Extensions")

// MARK: - WKWebExtensionControllerDelegate

//
// The action-related delegate methods (`presentActionPopup`, `didUpdate`)
// live in ExtensionManager+ActionPopup.swift; popup presentation anchors to
// the Extension Action buttons via ExtensionActionCoordinator.

extension ExtensionManager: WKWebExtensionControllerDelegate {
    // MARK: Windows

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        focusedWindowAdapter()
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        orderedWindowAdapters
    }

    // MARK: Tabs

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        guard let windowAdapter = focusedWindowAdapter(),
              let tabManager = windowAdapter.tabManager
        else {
            completionHandler(nil, Self.delegateError("No extension window available"))
            return
        }

        let historyManager = HistoryManager(
            modelContainer: tabManager.modelContainer,
            modelContext: tabManager.modelContext
        )

        var newTab: Tab?
        if let url = configuration.url, url.host != nil {
            newTab = tabManager.openTab(
                url: url,
                historyManager: historyManager,
                focusAfterOpening: configuration.shouldBeActive,
                isPrivate: false,
                loadSilently: !configuration.shouldBeActive
            )
        } else if let container = tabManager.activeContainer {
            // Hostless URLs (about:blank, extension pages) go through addTab.
            newTab = tabManager.addTab(
                url: configuration.url ?? URL(string: "about:blank")!,
                container: container,
                historyManager: historyManager,
                isPrivate: false
            )
        }

        guard let newTab else {
            completionHandler(nil, Self.delegateError("Could not create tab"))
            return
        }
        if configuration.shouldBePinned {
            tabManager.togglePinTab(newTab)
        }
        completionHandler(adapter(for: newTab), nil)
    }

    // MARK: Options page

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let optionsURL = extensionContext.optionsPageURL else {
            completionHandler(Self.delegateError("Extension has no options page"))
            return
        }
        guard let windowAdapter = focusedWindowAdapter(),
              let tabManager = windowAdapter.tabManager,
              let container = tabManager.activeContainer
        else {
            completionHandler(Self.delegateError("No extension window available"))
            return
        }

        let historyManager = HistoryManager(
            modelContainer: tabManager.modelContainer,
            modelContext: tabManager.modelContext
        )
        _ = tabManager.addTab(
            url: optionsURL,
            container: container,
            historyManager: historyManager,
            isPrivate: false
        )
        completionHandler(nil)
    }

    // MARK: Permission prompts (routed through the ExtensionPermissionPrompting seam)

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        resolvePermissionPrompt(
            requested: permissions,
            for: extensionContext,
            prompt: { name, completion in
                permissionPrompting.promptForPermissions(
                    extensionName: name,
                    permissions: permissions,
                    completion: completion
                )
            },
            settlement: PromptSettlement(
                kind: "Permissions",
                apply: { permission, isGranted in
                    extensionContext.setPermissionStatus(
                        isGranted ? .grantedExplicitly : .deniedExplicitly,
                        for: permission
                    )
                },
                persist: { [weak self] granted in
                    self?.persistRuntimeGrants(for: extensionContext, permissions: granted)
                }
            ),
            completionHandler: completionHandler
        )
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        resolvePermissionPrompt(
            requested: matchPatterns,
            for: extensionContext,
            prompt: { name, completion in
                permissionPrompting.promptForMatchPatterns(
                    extensionName: name,
                    matchPatterns: matchPatterns,
                    completion: completion
                )
            },
            settlement: PromptSettlement(
                kind: "Host",
                apply: { pattern, isGranted in
                    extensionContext.setPermissionStatus(
                        isGranted ? .grantedExplicitly : .deniedExplicitly,
                        for: pattern
                    )
                },
                persist: { [weak self] granted in
                    self?.persistRuntimeGrants(for: extensionContext, matchPatterns: granted)
                }
            ),
            completionHandler: completionHandler
        )
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        resolvePermissionPrompt(
            requested: urls,
            for: extensionContext,
            prompt: { name, completion in
                permissionPrompting.promptForURLAccess(extensionName: name, urls: urls, completion: completion)
            },
            settlement: PromptSettlement(
                kind: "URL-access",
                apply: { url, isGranted in
                    // URL grants are session-scoped: never denied explicitly
                    // (so WebKit can re-prompt later) and never persisted.
                    if isGranted {
                        extensionContext.setPermissionStatus(.grantedExplicitly, for: url)
                    }
                },
                persist: { _ in }
            ),
            completionHandler: completionHandler
        )
    }

    /// How one prompt kind settles after the seam answers: a per-item status
    /// application and persistence of the granted set.
    private struct PromptSettlement<Item: Hashable> {
        let kind: String
        let apply: (Item, _ isGranted: Bool) -> Void
        let persist: (Set<Item>) -> Void
    }

    /// Shared shape of all three permission prompts: ask the prompting seam,
    /// apply a status per requested item, persist the grants, log, complete.
    private func resolvePermissionPrompt<Item: Hashable>(
        requested: Set<Item>,
        for extensionContext: WKWebExtensionContext,
        prompt: (String, @escaping (Set<Item>) -> Void) -> Void,
        settlement: PromptSettlement<Item>,
        completionHandler: @escaping (Set<Item>, Date?) -> Void
    ) {
        let name = extensionContext.webExtension.displayName ?? "Extension"
        prompt(name) { granted in
            for item in requested {
                settlement.apply(item, granted.contains(item))
            }
            settlement.persist(granted)
            logger.info("""
            \(settlement.kind, privacy: .public) prompt for '\(name, privacy: .public)': \
            granted \(granted.count) of \(requested.count)
            """)
            completionHandler(granted, nil)
        }
    }

    // MARK: Helpers

    private static func delegateError(_ message: String) -> NSError {
        NSError(
            domain: "ExtensionManager",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
