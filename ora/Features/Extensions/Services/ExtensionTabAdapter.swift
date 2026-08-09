import AppKit
import Foundation
@preconcurrency import WebKit

/// Adapter exposing one `Tab` to WKWebExtension.
///
/// One adapter exists per Tab for the Tab's whole lifetime (side table in
/// `ExtensionManager.tabAdapters`, keyed by the persistent tab id). Identity is
/// the tab id so the controller sees a stable tab across webview rebuilds:
/// when Ora's alive-timeout sweep unloads a background tab, or a
/// privacy-settings change rebuilds the webview, the tab itself stays open from
/// the extension's point of view — `webView(for:)` just returns nil until the
/// webview is restored. Never triggers lazy webview creation.
final class ExtensionTabAdapter: NSObject, WKWebExtensionTab {
    private(set) weak var tab: Tab?
    let tabID: UUID

    init(tab: Tab) {
        self.tab = tab
        self.tabID = tab.id
        super.init()
    }

    // MARK: - Identity (stable across lookups and webview rebuilds)

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ExtensionTabAdapter else { return false }
        return other.tabID == tabID
    }

    override var hash: Int {
        tabID.hashValue
    }

    // MARK: - State

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        // nil while the tab is unloaded (alive-timeout sweep) — the tab still
        // exists for extensions; do not rebuild the webview here.
        tab?.browserPage?.extensionHostWebView
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        tab?.url
    }

    func pendingURL(for context: WKWebExtensionContext) -> URL? {
        guard let tab, tab.isLoading else { return nil }
        return tab.url
    }

    func title(for context: WKWebExtensionContext) -> String? {
        tab?.title
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !(tab?.isLoading ?? false)
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let tab else { return 0 }
        return MainActor.assumeIsolated {
            ExtensionManager.shared.windowAdapter(containing: tab)?.index(of: tab) ?? 0
        }
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard let tab else { return nil }
        return MainActor.assumeIsolated {
            ExtensionManager.shared.windowAdapter(containing: tab)
        }
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        guard let tab else { return false }
        return MainActor.assumeIsolated {
            // Restored tabs have no tabManager until first activation; fall
            // back to the window that lists the tab.
            let tabManager = tab.tabManager
                ?? ExtensionManager.shared.windowAdapter(containing: tab)?.tabManager
            return tabManager?.activeTab?.id == tab.id
        }
    }

    func isPinned(for context: WKWebExtensionContext) -> Bool {
        guard let tab else { return false }
        return tab.type != .normal
    }

    func isMuted(for context: WKWebExtensionContext) -> Bool {
        false // Ora has no per-tab mute
    }

    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool {
        tab?.isPlayingMedia ?? false
    }

    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        true
    }

    // MARK: - Actions

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let tab else {
            completionHandler(Self.goneError)
            return
        }
        MainActor.assumeIsolated {
            tab.tabManager?.activateTab(tab)
        }
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let tab else {
            completionHandler(Self.goneError)
            return
        }
        MainActor.assumeIsolated {
            tab.tabManager?.closeTab(tab: tab)
        }
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        tab?.reload()
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        tab?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        tab?.goForward()
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let tab, tab.browserPage != nil else {
            completionHandler(Self.goneError)
            return
        }
        // `navigate(to:)` rebuilds the webview with the extension context's
        // configuration when the target is an extension page (an ordinary
        // webview rejects top-level webkit-extension:// with -1008), e.g.
        // chrome.tabs.update({url: "<extension page>"}).
        MainActor.assumeIsolated {
            tab.navigate(to: url)
        }
        completionHandler(nil)
    }

    func zoomFactor(for context: WKWebExtensionContext) -> Double {
        Double(tab?.browserPage?.extensionHostWebView.pageZoom ?? 1.0)
    }

    func setZoomFactor(
        _ zoomFactor: Double,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        tab?.browserPage?.extensionHostWebView.pageZoom = zoomFactor
        completionHandler(nil)
    }

    private static var goneError: NSError {
        NSError(
            domain: "ExtensionTabAdapter",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Tab no longer exists"]
        )
    }
}
