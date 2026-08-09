import AppKit
import Foundation
import os.log
@preconcurrency import WebKit

private let logger = Logger(subsystem: "com.orabrowser.ora", category: "Extensions")

/// Hosts the global WKWebExtensionController shared by all Spaces.
///
/// One controller for the whole app: Extensions are installed globally, run in
/// every Space with a single login, and never run in Private Windows (private
/// page configurations never attach the controller, and Private Windows are
/// never registered as extension windows). Installed extensions live unpacked
/// under `~/Library/Application Support/Ora/Extensions/<extensionId>/` next to
/// a `registry.json` manifest of installed ids and granted permissions.
@MainActor
final class ExtensionManager: NSObject, ObservableObject {
    static let shared = ExtensionManager()

    /// Fixed controller-storage identifier. Never change this value: extension
    /// storage (chrome.storage, IndexedDB, service-worker registrations) lives
    /// in a data store derived from it and would silently move to a fresh
    /// namespace on relaunch.
    private static let controllerIdentifier: UUID = {
        guard let identifier = UUID(uuidString: "8A0F5C7E-3D5B-4E1A-9C67-2F84D0B1A9E3") else {
            preconditionFailure("Invalid controller-storage identifier UUID")
        }
        return identifier
    }()

    /// The one controller attached to every non-private page configuration.
    let controller: WKWebExtensionController

    @Published private(set) var installedExtensions: [InstalledExtension] = []

    /// Seam for the UI layer: swap in a real dialog implementation.
    /// Defaults to deny-by-default — nothing is ever granted silently while no
    /// UI is registered (browser windows swap in ExtensionDialogPermissionPrompting).
    var permissionPrompting: ExtensionPermissionPrompting = DenyExtensionPermissionPrompting()

    let extensionsDirectory: URL

    /// Prefix of the temporary directories installs stage into (see
    /// ExtensionManager+Installation); residue is pruned at launch.
    static let stagingDirectoryPrefix = "staging-"

    /// Persisted registry, mirrored to `registry.json`.
    private(set) var registryRecords: [ExtensionRegistryRecord] = []

    /// Loaded contexts keyed by extension id.
    private(set) var contexts: [String: WKWebExtensionContext] = [:]

    // MARK: Host adapters (see ExtensionManager+Lifecycle)

    var tabAdapters: [UUID: ExtensionTabAdapter] = [:]
    var windowAdapters: [ObjectIdentifier: ExtensionWindowAdapter] = [:]
    var orderedWindowAdapters: [ExtensionWindowAdapter] = []
    var windowFocusObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    /// Bumped on every tab event; lets window adapters cache chrome.tabs.query results.
    private(set) var tabCacheGeneration: UInt = 0

    init(extensionsDirectory: URL? = nil) {
        self.extensionsDirectory = extensionsDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ora", isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true)

        let configuration = WKWebExtensionController.Configuration(identifier: Self.controllerIdentifier)
        // The background service worker's webview must use a page-like
        // configuration, otherwise chrome.runtime messaging between pages and
        // the worker breaks. Must be set BEFORE creating the controller —
        // `controller.configuration` returns a copy.
        let webViewConfiguration = WKWebViewConfiguration()
        webViewConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.webViewConfiguration = webViewConfiguration

        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
    }

    // MARK: - Lookup

    func context(for extensionId: String) -> WKWebExtensionContext? {
        contexts[extensionId]
    }

    func extensionId(for context: WKWebExtensionContext) -> String? {
        contexts.first(where: { $0.value === context })?.key
    }

    func bumpTabCacheGeneration() {
        tabCacheGeneration &+= 1
    }

    // MARK: - Loading installed extensions (app launch)

    private var loadTask: Task<Void, Never>?

    /// Idempotent launch load: the first caller starts `loadInstalledExtensions()`
    /// once; every caller (app launch, each page's deferred-navigation gate)
    /// awaits the same shared task so no page navigates before contexts exist.
    func ensureLoaded() async {
        if loadTask == nil {
            loadTask = Task { await loadInstalledExtensions() }
        }
        await loadTask?.value
    }

    /// Loads every registered extension into the controller, re-applying
    /// persisted permission grants and starting background content.
    /// Call once at launch, before any page navigates (via `ensureLoaded`).
    func loadInstalledExtensions() async {
        ensureExtensionsDirectory()
        pruneStagingResidue()
        registryRecords = loadRegistry()

        var loaded: [InstalledExtension] = []
        var prunedIds: Set<String> = []

        for record in registryRecords {
            let directoryURL = extensionsDirectory.appendingPathComponent(record.directoryName, isDirectory: true)
            let manifestURL = directoryURL.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else {
                logger.error("""
                Extension '\(record.name, privacy: .public)' missing on disk \
                at \(directoryURL.path, privacy: .public) — pruning
                """)
                prunedIds.insert(record.id)
                continue
            }

            do {
                let webExtension = try await WKWebExtension(resourceBaseURL: directoryURL)
                let installed = try loadIntoController(
                    webExtension: webExtension,
                    extensionId: record.id,
                    directoryURL: directoryURL,
                    record: record
                )
                loaded.append(installed)
            } catch {
                // Load errors must be loud — a silently dead background worker
                // is exactly how upstream PR #137 failed.
                logger.error("""
                FAILED to load extension '\(record.name, privacy: .public)' \
                (\(record.id, privacy: .public)): \
                \(error.localizedDescription, privacy: .public)
                """)
            }
        }

        if !prunedIds.isEmpty {
            registryRecords.removeAll { prunedIds.contains($0.id) }
            saveRegistry()
        }

        installedExtensions = loaded
        logger.info("Loaded \(loaded.count) of \(self.registryRecords.count) installed extensions")
    }

    /// Deletes staging directories a crash or quit mid-install left behind.
    /// Deliberately touches ONLY `staging-*` directories — anything else in
    /// the extensions directory that the registry does not know about is left
    /// alone.
    private func pruneStagingResidue() {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: extensionsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries where entry.lastPathComponent.hasPrefix(Self.stagingDirectoryPrefix) {
            try? fileManager.removeItem(at: entry)
            logger.info("Pruned staging residue \(entry.lastPathComponent, privacy: .public)")
        }
    }

    /// Creates a context for the extension, applies identity and grants, loads
    /// it into the controller, and starts background content. Shared by launch
    /// loading and fresh installation.
    func loadIntoController(
        webExtension: WKWebExtension,
        extensionId: String,
        directoryURL: URL,
        record: ExtensionRegistryRecord
    ) throws -> InstalledExtension {
        let context = WKWebExtensionContext(for: webExtension)
        configureContextIdentity(context, extensionId: extensionId)
        applyPersistedGrants(to: context, webExtension: webExtension, record: record)
        context.isInspectable = true

        contexts[extensionId] = context
        do {
            try controller.load(context)
        } catch {
            contexts[extensionId] = nil
            throw error
        }

        let name = webExtension.displayName ?? record.name
        loadBackgroundContentLoudly(for: context, name: name)

        return InstalledExtension(
            id: extensionId,
            name: name,
            version: webExtension.displayVersion ?? record.version,
            directoryURL: directoryURL,
            webExtension: webExtension,
            context: context
        )
    }

    /// Starts (or wakes) the extension's background content, logging failures
    /// loudly. MV3 service workers terminate after inactivity — call this again
    /// before interactions that message the worker (e.g. showing the popup).
    func loadBackgroundContentLoudly(for context: WKWebExtensionContext, name: String) {
        guard context.webExtension.hasBackgroundContent else { return }
        context.loadBackgroundContent { [weak self] error in
            if let error {
                logger.error("""
                BACKGROUND CONTENT FAILED for '\(name, privacy: .public)': \
                \(error.localizedDescription, privacy: .public)
                """)
                self?.logContextErrors(context, name: name)
            } else {
                logger.info("Background content running for '\(name, privacy: .public)'")
            }
        }
    }

    // MARK: - Context identity

    /// Deterministic identity so extension storage stays in the same namespace
    /// across relaunches (WebKit otherwise mints a fresh id per context).
    ///
    /// The base URL's host and `uniqueIdentifier` MUST be the same value: WebKit
    /// serves the extension's own resources (service worker, popup, their
    /// imports) from the base URL host, while `runtime.id`/messaging use
    /// `uniqueIdentifier`. If they differ, every resource request 404s and the
    /// background service worker fails to load. Our ids (Chrome Web Store,
    /// Chrome-derived, and UUIDs) are all valid lowercase hosts, so the id
    /// itself is the host — which also gives extensions their real `runtime.id`.
    private func configureContextIdentity(_ context: WKWebExtensionContext, extensionId: String) {
        let host = extensionId.lowercased()
        context.uniqueIdentifier = host
        if let baseURL = URL(string: "webkit-extension://\(host)") {
            context.baseURL = baseURL
        } else {
            logger.error("Could not build base URL for extension id \(extensionId, privacy: .public)")
        }
    }

    /// Logs any parse-time or runtime errors WebKit recorded for the context,
    /// so extension failures are visible in `log stream` without Web Inspector.
    func logContextErrors(_ context: WKWebExtensionContext, name: String) {
        for error in context.errors {
            logger.error("""
            EXTENSION ERROR for '\(name, privacy: .public)': \
            \(error.localizedDescription, privacy: .public)
            """)
        }
    }

    // MARK: - Permission grants

    /// Re-applies ONLY the persisted grants from the registry record — the
    /// permissions and hosts the user approved at install time plus any
    /// runtime grants persisted since. Nothing from the manifest is granted
    /// unconditionally; undecided items go through the delegate's prompt flow
    /// at runtime.
    private func applyPersistedGrants(
        to context: WKWebExtensionContext,
        webExtension: WKWebExtension,
        record: ExtensionRegistryRecord
    ) {
        let savedPermissions = Set(record.grantedPermissions)
        for permission in webExtension.requestedPermissions.union(webExtension.optionalPermissions)
            where savedPermissions.contains(permission.rawValue)
        {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }

        let savedMatches = Set(record.grantedMatchPatterns)
        for match in webExtension.allRequestedMatchPatterns.union(webExtension.optionalPermissionMatchPatterns)
            where savedMatches.contains(match.string)
        {
            context.setPermissionStatus(.grantedExplicitly, for: match)
        }
    }

    /// Persists runtime-granted permissions/match patterns so they survive
    /// relaunch (re-applied by `applyPersistedGrants`).
    func persistRuntimeGrants(
        for context: WKWebExtensionContext,
        permissions: Set<WKWebExtension.Permission> = [],
        matchPatterns: Set<WKWebExtension.MatchPattern> = []
    ) {
        guard let extensionId = extensionId(for: context),
              let index = registryRecords.firstIndex(where: { $0.id == extensionId })
        else { return }

        var record = registryRecords[index]
        record.grantedPermissions = Array(
            Set(record.grantedPermissions).union(permissions.map(\.rawValue))
        )
        record.grantedMatchPatterns = Array(
            Set(record.grantedMatchPatterns).union(matchPatterns.map(\.string))
        )
        registryRecords[index] = record
        saveRegistry()
    }

    // MARK: - Registry persistence

    var registryFileURL: URL {
        extensionsDirectory.appendingPathComponent("registry.json")
    }

    func ensureExtensionsDirectory() {
        try? FileManager.default.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)
    }

    private func loadRegistry() -> [ExtensionRegistryRecord] {
        guard let data = try? Data(contentsOf: registryFileURL) else { return [] }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([ExtensionRegistryRecord].self, from: data)
        } catch {
            logger.error("Could not read extension registry: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func saveRegistry() {
        ensureExtensionsDirectory()
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(registryRecords)
            try data.write(to: registryFileURL, options: .atomic)
        } catch {
            logger.error("Could not save extension registry: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Registry mutation (used by installation)

    func upsertRecord(_ record: ExtensionRegistryRecord) {
        if let index = registryRecords.firstIndex(where: { $0.id == record.id }) {
            registryRecords[index] = record
        } else {
            registryRecords.append(record)
        }
        saveRegistry()
    }

    func removeRecord(id: String) {
        registryRecords.removeAll { $0.id == id }
        saveRegistry()
    }

    func upsertInstalledExtension(_ installed: InstalledExtension) {
        if let index = installedExtensions.firstIndex(where: { $0.id == installed.id }) {
            installedExtensions[index] = installed
        } else {
            installedExtensions.append(installed)
        }
    }

    func removeInstalledExtension(id: String) {
        installedExtensions.removeAll { $0.id == id }
        contexts[id] = nil
    }
}
