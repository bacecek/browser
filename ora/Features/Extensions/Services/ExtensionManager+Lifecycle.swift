import AppKit
import Foundation
import os.log
@preconcurrency import WebKit

private let logger = Logger(subsystem: "com.orabrowser.ora", category: "Extensions")

// MARK: - Window and tab lifecycle feeding

//
// The host must narrate every tab/window event to the controller or extension
// APIs (chrome.tabs, content-script targeting, messaging) silently break.
// Ora-specific wrinkles handled here and in the adapters:
// - The 60s alive-timeout sweep unloads background tab webviews. That is NOT a
//   tab close: no event is sent, and the adapter's webView(for:) returns nil
//   until the tab is restored.
// - Privacy-settings changes rebuild a tab's WKWebView in place. Same tab
//   identity, new webview: the new page configuration carries the controller,
//   and navigation events report the reload as property changes.
// - Closing a pinned/fav tab only unloads its webview (the tab stays in the
//   sidebar), so it is treated as an unload, not a close.

extension ExtensionManager {
    // MARK: Adapters

    /// Stable adapter per tab, keyed by the persistent tab id.
    func adapter(for tab: Tab) -> ExtensionTabAdapter {
        if let existing = tabAdapters[tab.id] {
            return existing
        }
        let created = ExtensionTabAdapter(tab: tab)
        tabAdapters[tab.id] = created
        return created
    }

    func windowAdapter(for tabManager: TabManager) -> ExtensionWindowAdapter? {
        windowAdapters[ObjectIdentifier(tabManager)]
    }

    func windowAdapter(containing tab: Tab) -> ExtensionWindowAdapter? {
        if let tabManager = tab.tabManager, let adapter = windowAdapter(for: tabManager) {
            return adapter
        }
        // Tabs restored from persistence carry no tabManager until their
        // first activation, but the worker can already reference them through
        // browser.tabs — resolve membership through the windows' own tab
        // lists so every such tab still resolves to a window ("Tab for page N
        // was not found" otherwise).
        return orderedWindowAdapters.first { adapter in
            adapter.orderedTabs().contains { $0.id == tab.id }
        }
    }

    /// Whether this tab belongs to a registered (non-private) window.
    private func isTracked(_ tab: Tab) -> Bool {
        !tab.isPrivate && windowAdapter(containing: tab) != nil
    }

    // MARK: Window lifecycle

    /// Registers a browser window with the controller and adopts its existing
    /// tabs. Private Windows are never registered — extensions must not see
    /// them at all.
    func registerWindow(tabManager: TabManager, window: NSWindow?, isPrivate: Bool) {
        guard !isPrivate else { return }

        let key = ObjectIdentifier(tabManager)
        if let existing = windowAdapters[key] {
            // Same window stack, NSWindow became available (or changed).
            existing.window = window
            observeFocus(of: window, key: key, adapter: existing)
            return
        }

        let adapter = ExtensionWindowAdapter(tabManager: tabManager, window: window)
        windowAdapters[key] = adapter
        orderedWindowAdapters.append(adapter)

        // Window first, then its tabs, then the active tab.
        controller.didOpenWindow(adapter)
        if window == nil || window?.isKeyWindow == true {
            controller.didFocusWindow(adapter)
        }

        for tab in adapter.orderedTabs() {
            controller.didOpenTab(self.adapter(for: tab))
        }
        if let activeTab = tabManager.activeTab {
            let activeAdapter = self.adapter(for: activeTab)
            controller.didActivateTab(activeAdapter, previousActiveTab: nil)
            controller.didSelectTabs([activeAdapter])
        }
        bumpTabCacheGeneration()

        observeFocus(of: window, key: key, adapter: adapter)
        logger.info("Registered extension window with \(adapter.orderedTabs().count) tabs")
    }

    /// Reports the window closed and drops its adapter and focus observer.
    func unregisterWindow(tabManager: TabManager) {
        let key = ObjectIdentifier(tabManager)
        guard let adapter = windowAdapters[key] else { return }

        for tab in adapter.orderedTabs() {
            if let tabAdapter = tabAdapters[tab.id] {
                controller.didCloseTab(tabAdapter, windowIsClosing: true)
                tabAdapters[tab.id] = nil
            }
        }

        controller.didCloseWindow(adapter)
        windowAdapters[key] = nil
        orderedWindowAdapters.removeAll { $0 === adapter }
        if let token = windowFocusObservers[key] {
            NotificationCenter.default.removeObserver(token)
            windowFocusObservers[key] = nil
        }
        bumpTabCacheGeneration()
    }

    private func observeFocus(of window: NSWindow?, key: ObjectIdentifier, adapter: ExtensionWindowAdapter) {
        if let token = windowFocusObservers[key] {
            NotificationCenter.default.removeObserver(token)
            windowFocusObservers[key] = nil
        }
        guard let window else { return }

        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self, weak adapter] _ in
            MainActor.assumeIsolated {
                guard let self, let adapter else { return }
                self.controller.didFocusWindow(adapter)
            }
        }
        windowFocusObservers[key] = token
    }

    /// The adapter for the key window, falling back to the first registered one.
    func focusedWindowAdapter() -> ExtensionWindowAdapter? {
        orderedWindowAdapters.first(where: { $0.window?.isKeyWindow == true })
            ?? orderedWindowAdapters.first
    }

    // MARK: Tab lifecycle (called from TabManager and TabBrowserPageDelegate)

    func tabDidOpen(_ tab: Tab) {
        guard isTracked(tab) else { return }
        controller.didOpenTab(adapter(for: tab))
        bumpTabCacheGeneration()
    }

    func tabDidClose(_ tab: Tab) {
        guard !tab.isPrivate, let tabAdapter = tabAdapters[tab.id] else { return }
        controller.didCloseTab(tabAdapter, windowIsClosing: false)
        tabAdapters[tab.id] = nil
        bumpTabCacheGeneration()
    }

    func tabDidActivate(_ tab: Tab, previous: Tab?) {
        guard isTracked(tab) else { return }
        let newAdapter = adapter(for: tab)
        let previousAdapter = previous.flatMap { previousTab -> ExtensionTabAdapter? in
            previousTab.isPrivate ? nil : tabAdapters[previousTab.id]
        }
        controller.didActivateTab(newAdapter, previousActiveTab: previousAdapter)
        controller.didSelectTabs([newAdapter])
        if let previousAdapter {
            controller.didDeselectTabs([previousAdapter])
        }
        bumpTabCacheGeneration()
    }

    func tabPropertiesDidChange(_ tab: Tab, properties: WKWebExtension.TabChangedProperties) {
        guard isTracked(tab) else { return }
        controller.didChangeTabProperties(properties, for: adapter(for: tab))
        bumpTabCacheGeneration()
    }
}
