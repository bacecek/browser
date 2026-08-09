import Foundation
import Inject
import SwiftData
import SwiftUI

final class PrivacyMode: ObservableObject {
    @Published var isPrivate: Bool

    init(isPrivate: Bool) {
        self.isPrivate = isPrivate
    }
}

struct OraRoot: View {
    @StateObject private var appState = AppState()
    @StateObject private var keyModifierListener = KeyModifierListener()
    @StateObject private var updateService = UpdateService()
    @StateObject private var mediaController: MediaController
    @StateObject private var tabManager: TabManager
    @StateObject private var historyManager: HistoryManager
    @StateObject private var downloadManager: DownloadManager
    @StateObject private var privacyMode: PrivacyMode
    @StateObject private var sidebarManager = SidebarManager()
    @StateObject private var toolbarManager = ToolbarManager()
    @StateObject private var dialogManager = DialogManager()
    private let toastManager = ToastManager.shared

    @ObserveInjection var inject

    let tabContext: ModelContext
    let historyContext: ModelContext
    let downloadContext: ModelContext
    @State private var window: NSWindow?

    init(isPrivate: Bool = false) {
        _privacyMode = StateObject(wrappedValue: PrivacyMode(isPrivate: isPrivate))

        let container: ModelContainer
        let modelContext: ModelContext
        do {
            container = try ModelConfiguration.createOraContainer(isPrivate: isPrivate)
            modelContext = ModelContext(container)
        } catch {
            deleteSwiftDataStore("OraData.sqlite")
            fatalError("Failed to initialize ModelContainer: \(error)")
        }

        self.tabContext = modelContext
        self.downloadContext = modelContext
        self.historyContext = modelContext
        let historyManagerObj = StateObject(
            wrappedValue: HistoryManager(
                modelContainer: container,
                modelContext: modelContext
            )
        )
        _historyManager = historyManagerObj

        let media = MediaController()
        _mediaController = StateObject(wrappedValue: media)

        _tabManager = StateObject(
            wrappedValue: TabManager(
                modelContainer: container,
                modelContext: modelContext,
                mediaController: media
            )
        )

        _downloadManager = StateObject(
            wrappedValue: DownloadManager(
                modelContainer: container,
                modelContext: modelContext
            )
        )
    }

    var body: some View {
        BrowserView()
            .background(WindowReader(window: $window))
            .background(
                WindowAccessor(
                    isFullscreen: Binding(
                        get: { appState.isFullscreen },
                        set: { newValue in appState.isFullscreen = newValue }
                    )
                )
            )
            .environment(\.window, window)
            .environmentObject(appState)
            .environmentObject(tabManager)
            .environmentObject(historyManager)
            .environmentObject(mediaController)
            .environmentObject(keyModifierListener)
            .environmentObject(CustomKeyboardShortcutManager.shared)
            .environmentObject(AppearanceManager.shared)
            .environmentObject(downloadManager)
            .environmentObject(updateService)
            .environmentObject(privacyMode)
            .environmentObject(sidebarManager)
            .environmentObject(toolbarManager)
            .environmentObject(dialogManager)
            .environmentObject(toastManager)
            .dialogs(manager: dialogManager)
            .modelContext(tabContext)
            .modelContext(historyContext)
            .modelContext(downloadContext)
            .withTheme()
            .enableInjection()
            .onChange(of: window) { _, newWindow in
                // (Re-)register this window with the extension controller once
                // the NSWindow exists. Private Windows are never registered.
                registerWithExtensionPlatform(window: newWindow)
            }
            .onDisappear {
                unregisterFromExtensionPlatform()
            }
            .onAppear {
                registerWithExtensionPlatform(window: window)
                downloadManager.toastManager = toastManager
                Task {
                    let containerIDs = await MainActor.run {
                        (try? tabContext.fetch(FetchDescriptor<TabContainer>()))?.map(\.id) ?? []
                    }
                    await AdBlockService.shared.start(containerIDs: containerIDs)
                }

                // Dialog keyboard shortcuts (highest priority — checked first)
                keyModifierListener.registerKeyDownHandler { event in
                    // Escape: dismiss top dialog
                    if event.keyCode == 53, !dialogManager.dialogs.isEmpty {
                        DispatchQueue.main.async { dialogManager.dismissTop() }
                        return true
                    }
                    // Return: confirm top dialog (only if it carries a confirm action)
                    if event.keyCode == 36, let onConfirm = dialogManager.dialogs.last?.onConfirm {
                        DispatchQueue.main.async {
                            onConfirm()
                            dialogManager.dismissTop()
                        }
                        return true
                    }
                    return false
                }

                keyModifierListener.registerKeyDownHandler { event in
                    guard !appState.isFloatingTabSwitchVisible else { return false }

                    if event.keyCode == 48 {
                        if event.modifierFlags.contains(.control) {
                            DispatchQueue.main.async {
                                appState.isFloatingTabSwitchVisible = true
                            }
                            return true
                        }
                    }
                    return false
                }

                registerExtensionCommandKeyHandler()

                registerQuitConfirmationObserver()

                if SettingsStore.shared.autoUpdateEnabled {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        updateService.checkForUpdatesInBackground()
                    }
                }
                NotificationCenter.default.addObserver(forName: .showLauncher, object: nil, queue: .main) { note in
                    Task { @MainActor in
                        guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                        if tabManager.activeTab != nil {
                            appState.showLauncher.toggle()
                        }
                    }
                }
                NotificationCenter.default.addObserver(forName: .closeActiveTab, object: nil, queue: .main) { note in
                    Task { @MainActor in
                        guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                        tabManager.closeActiveTab()
                    }
                }
                NotificationCenter.default.addObserver(forName: .restoreLastTab, object: nil, queue: .main) { note in
                    Task { @MainActor in
                        guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                        tabManager.restoreLastTab()
                    }
                }
                NotificationCenter.default.addObserver(forName: .findInPage, object: nil, queue: .main) { note in
                    Task { @MainActor in
                        guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                        if let activeTab = tabManager.activeTab {
                            appState.showFinderIn = activeTab.id
                        }
                    }
                }
                NotificationCenter.default.addObserver(forName: .toggleFullURL, object: nil, queue: .main) { note in
                    guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                    toolbarManager.showFullURL.toggle()
                }
                NotificationCenter.default.addObserver(forName: .toggleToolbar, object: nil, queue: .main) { note in
                    guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        toolbarManager.isToolbarHidden.toggle()
                    }
                }
                NotificationCenter.default.addObserver(forName: .reloadPage, object: nil, queue: .main) { note in
                    Task { @MainActor in
                        guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                        tabManager.activeTab?.reload()
                    }
                }
                NotificationCenter.default.addObserver(forName: .goBack, object: nil, queue: .main) { note in
                    Task { @MainActor in
                        guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                        tabManager.activeTab?.goBack()
                    }
                }
                NotificationCenter.default.addObserver(forName: .goForward, object: nil, queue: .main) { note in
                    Task { @MainActor in
                        guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                        tabManager.activeTab?.goForward()
                    }
                }
                NotificationCenter.default.addObserver(forName: .togglePinTab, object: nil, queue: .main) { note in
                    Task { @MainActor in
                        guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                        if let tab = tabManager.activeTab {
                            tabManager.togglePinTab(tab)
                        }
                    }
                }
                NotificationCenter.default.addObserver(forName: .nextTab, object: nil, queue: .main) { note in
                    guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                    appState.isFloatingTabSwitchVisible = true
                }
                NotificationCenter.default.addObserver(forName: .previousTab, object: nil, queue: .main) { note in
                    guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                    appState.isFloatingTabSwitchVisible = true
                }
                NotificationCenter.default.addObserver(forName: .setAppearance, object: nil, queue: .main) { note in
                    guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                    if let raw = note.userInfo?["appearance"] as? String,
                       let mode = AppAppearance(rawValue: raw)
                    {
                        AppearanceManager.shared.appearance = mode
                    }
                }
                NotificationCenter.default.addObserver(forName: .checkForUpdates, object: nil, queue: .main) { note in
                    guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                    updateService.checkForUpdates()
                }
                NotificationCenter.default.addObserver(forName: .selectTabAtIndex, object: nil, queue: .main) { note in
                    Task { @MainActor in
                        guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                        if let index = note.userInfo?["index"] as? Int {
                            tabManager.selectTabAtIndex(index)
                        }
                    }
                }
                NotificationCenter.default.addObserver(forName: .openURL, object: nil, queue: .main) { note in
                    Task { @MainActor in
                        let targetWindow = window ?? NSApp.keyWindow
                        if let sender = note.object as? NSWindow {
                            guard sender === targetWindow else { return }
                        } else {
                            guard NSApp.keyWindow === targetWindow else { return }
                        }
                        guard let url = note.userInfo?["url"] as? URL else { return }
                        tabManager.openTab(
                            url: url,
                            historyManager: historyManager,
                            downloadManager: downloadManager,
                            focusAfterOpening: true,
                            isPrivate: privacyMode.isPrivate
                        )
                    }
                }

                NotificationCenter.default
                    .addObserver(forName: .spacePrivacySettingsChanged, object: nil, queue: .main) { note in
                        Task { @MainActor in
                            guard let containerId = note.userInfo?["containerId"] as? UUID else { return }
                            tabManager.refreshPrivacySettings(for: containerId)
                        }
                    }

                NotificationCenter.default
                    .addObserver(forName: .passwordProviderChanged, object: nil, queue: .main) { _ in
                        Task { @MainActor in
                            tabManager.refreshTabsForPasswordProviderChange()
                        }
                    }

                // Clear cache and reload
                NotificationCenter.default
                    .addObserver(forName: .clearCacheAndReload, object: nil, queue: .main) { note in
                        Task { @MainActor in
                            guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                            if let activeTab = tabManager.activeTab {
                                let host = activeTab.url.host ?? ""
                                let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                                PrivacyService
                                    .clearCacheForHost(
                                        for: domain,
                                        container: activeTab.container
                                    ) { [weak toastManager] in
                                        DispatchQueue.main.async {
                                            activeTab.reload()
                                            toastManager?.show("Cache cleared for \(domain)", icon: .system("trash"))
                                        }
                                    }
                            }
                        }
                    }

                // Clear cookies and reload
                NotificationCenter.default
                    .addObserver(forName: .clearCookiesAndReload, object: nil, queue: .main) { note in
                        Task { @MainActor in
                            guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }

                            if let activeTab = tabManager.activeTab {
                                let host = activeTab.url.host ?? ""
                                let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                                PrivacyService
                                    .clearCookiesForHost(
                                        for: host,
                                        container: activeTab.container
                                    ) { [weak toastManager] in
                                        DispatchQueue.main.async {
                                            activeTab.reload()
                                            toastManager?.show("Cookies cleared for \(domain)", icon: .system("trash"))
                                        }
                                    }
                            }
                        }
                    }
            }
    }
}

// MARK: - Extension platform wiring

private extension OraRoot {
    /// Cmd+Q quit confirmation.
    func registerQuitConfirmationObserver() {
        NotificationCenter.default.addObserver(forName: .quitRequested, object: nil, queue: .main) { note in
            guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
            guard window != nil else {
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }
            dialogManager.confirm(
                title: "Quit Ora?",
                message: "Are you sure you want to quit?",
                iconImage: Image("OraColorLogo"),
                confirmLabel: "Quit",
                variant: .destructive,
                onConfirm: { NSApp.reply(toApplicationShouldTerminate: true) },
                onCancel: { NSApp.reply(toApplicationShouldTerminate: false) }
            )
        }
    }

    /// (Re-)registers this window with the extension controller and the
    /// permission-prompt seam. Private Windows are never registered.
    func registerWithExtensionPlatform(window: NSWindow?) {
        ExtensionManager.shared.registerWindow(
            tabManager: tabManager,
            window: window,
            isPrivate: privacyMode.isPrivate
        )
        if !privacyMode.isPrivate {
            ExtensionDialogPermissionPrompting.shared.register(
                dialogManager: dialogManager,
                window: window
            )
        }
    }

    func unregisterFromExtensionPlatform() {
        ExtensionManager.shared.unregisterWindow(tabManager: tabManager)
        ExtensionDialogPermissionPrompting.shared.unregister(dialogManager: dialogManager)
    }

    /// Extension keyboard commands (e.g. 1Password's Cmd+\) — routed through
    /// the key chain so they fire even with the toolbar hidden and while a
    /// webview has focus. Never in Private Windows, and only when this window
    /// is key.
    func registerExtensionCommandKeyHandler() {
        keyModifierListener.registerKeyDownHandler { event in
            MainActor.assumeIsolated {
                guard !privacyMode.isPrivate else { return false }
                guard let window, window.isKeyWindow else { return false }
                return ExtensionActionCoordinator.shared.handleKeyDown(event)
            }
        }
    }
}
