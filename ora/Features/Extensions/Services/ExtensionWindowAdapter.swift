import AppKit
import Foundation
@preconcurrency import WebKit

/// Adapter exposing one browser window (one `OraRoot` / `TabManager`) to WKWebExtension.
///
/// Tab membership choice: the adapter reports the tabs of ALL Spaces in the
/// window, in sidebar order (favorites, pinned, normal per Space). Every tab is
/// fed to the controller via `didOpenTab` regardless of its Space, so each of
/// those tabs must resolve to a window — restricting `tabs(for:)` to the active
/// Space would leave background-Space tabs windowless and break
/// `chrome.tabs.query`.
///
/// Private Windows are never wrapped: `ExtensionManager.registerWindow` refuses
/// them, so no adapter for a Private Window ever reaches the controller.
final class ExtensionWindowAdapter: NSObject, WKWebExtensionWindow {
    private(set) weak var tabManager: TabManager?
    weak var window: NSWindow?

    // chrome.tabs.query is polled heavily by extensions; cache the adapter list
    // and invalidate via ExtensionManager.tabCacheGeneration bumps.
    private var cachedTabs: [any WKWebExtensionTab]?
    private var cacheGeneration: UInt = 0

    init(tabManager: TabManager, window: NSWindow?) {
        self.tabManager = tabManager
        self.window = window
        super.init()
    }

    // MARK: - Identity

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ExtensionWindowAdapter else { return false }
        return other.tabManager === tabManager
    }

    override var hash: Int {
        guard let tabManager else { return 0 }
        return ObjectIdentifier(tabManager).hashValue
    }

    // MARK: - Ordering helpers (main thread)

    @MainActor
    func orderedTabs() -> [Tab] {
        tabManager?.allOpenTabs() ?? []
    }

    @MainActor
    func index(of tab: Tab) -> Int? {
        orderedTabs().firstIndex(where: { $0.id == tab.id })
    }

    // MARK: - WKWebExtensionWindow

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        MainActor.assumeIsolated {
            let generation = ExtensionManager.shared.tabCacheGeneration
            if generation != cacheGeneration {
                cachedTabs = nil
                cacheGeneration = generation
            }
            if let cachedTabs {
                return cachedTabs
            }
            let result = orderedTabs().map { ExtensionManager.shared.adapter(for: $0) }
            cachedTabs = result
            return result
        }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        MainActor.assumeIsolated {
            guard let active = tabManager?.activeTab else { return nil }
            return ExtensionManager.shared.adapter(for: active)
        }
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window else { return .normal }
        if window.isMiniaturized {
            return .minimized
        }
        if window.styleMask.contains(.fullScreen) {
            return .fullscreen
        }
        return .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        // Only non-private windows are ever registered.
        false
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        window?.frame ?? .zero
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        (window?.screen ?? NSScreen.main)?.frame ?? .zero
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window else {
            completionHandler(Self.goneError)
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window else {
            completionHandler(Self.goneError)
            return
        }
        window.performClose(nil)
        completionHandler(nil)
    }

    private static var goneError: NSError {
        NSError(
            domain: "ExtensionWindowAdapter",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Window no longer exists"]
        )
    }
}
