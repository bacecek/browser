import AppKit
import SwiftUI
@preconcurrency import WebKit

struct ExtensionsSettingsView: View {
    @ObservedObject private var extensionManager = ExtensionManager.shared
    @EnvironmentObject private var toastManager: ToastManager

    @State private var webStoreReference = ""
    @State private var isInstalling = false
    @State private var pendingUninstall: InstalledExtension?
    @State private var installConsentPrompt: InstallConsentPrompt?

    var body: some View {
        SettingsSection {
            installCard
            installedCard
        }
        .alert(
            "Uninstall \"\(pendingUninstall?.name ?? "extension")\"?",
            isPresented: Binding(
                get: { pendingUninstall != nil },
                set: {
                    if !$0 {
                        pendingUninstall = nil
                    }
                }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingUninstall = nil }
            Button("Uninstall", role: .destructive) { confirmUninstall() }
        } message: {
            Text("Its files are deleted. Extension data may remain until the browser data is cleared.")
        }
        // The consent alert's continuation must never leak: if the Settings
        // view unmounts while consent is pending, resolve it as declined so
        // the awaiting install task finishes.
        .onDisappear { respondToInstallConsent(false) }
    }

    // MARK: - Install

    private var installCard: some View {
        SettingsCard(
            header: "Install Extension",
            description: "Paste a Chrome Web Store link or extension ID, or load an unpacked extension folder."
        ) {
            HStack(spacing: 8) {
                TextField("Chrome Web Store URL or extension ID", text: $webStoreReference)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { installFromWebStore() }
                    .disabled(isInstalling)

                Button("Install") { installFromWebStore() }
                    .disabled(isInstalling || trimmedReference.isEmpty)

                if isInstalling {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                }
            }

            Button("Load Unpacked…") { installUnpacked() }
                .disabled(isInstalling)
        }
        .alert(
            "Install \"\(installConsentPrompt?.name ?? "extension")\"?",
            isPresented: Binding(
                get: { installConsentPrompt != nil },
                set: {
                    if !$0 {
                        respondToInstallConsent(false)
                    }
                }
            )
        ) {
            Button("Cancel", role: .cancel) { respondToInstallConsent(false) }
            Button("Install") { respondToInstallConsent(true) }
        } message: {
            Text(installConsentMessage)
        }
    }

    // MARK: - Install consent

    /// Surfaces an install's requested permissions and host patterns as an
    /// alert; the install continues only after the user approves.
    private func requestInstallConsent(_ request: ExtensionInstallConsentRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            // Defensive: a prompt can never be replaced while pending, but if
            // one ever were, resolve it as declined instead of leaking it.
            respondToInstallConsent(false)
            let items = request.permissions.map(\.rawValue).sorted()
                + request.matchPatterns.map(\.string).sorted()
            installConsentPrompt = InstallConsentPrompt(
                name: request.extensionName,
                requestedItems: items
            ) { approved in
                continuation.resume(returning: approved)
            }
        }
    }

    private func respondToInstallConsent(_ approved: Bool) {
        guard let prompt = installConsentPrompt else { return }
        installConsentPrompt = nil
        prompt.respond(approved)
    }

    private var installConsentMessage: String {
        guard let prompt = installConsentPrompt, !prompt.requestedItems.isEmpty else {
            return "It requests no special permissions."
        }
        return "It will be able to use:\n" + ExtensionPermissionBulletList.format(prompt.requestedItems)
    }

    private var trimmedReference: String {
        webStoreReference.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func installFromWebStore() {
        let reference = trimmedReference
        guard !reference.isEmpty else { return }
        runInstall {
            let installed = try await WebStoreInstaller().install(
                reference: reference,
                into: extensionManager,
                consent: requestInstallConsent
            )
            webStoreReference = ""
            return installed
        }
    }

    private func installUnpacked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose an unpacked extension folder containing manifest.json"
        panel.prompt = "Load"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        runInstall {
            try await extensionManager.install(
                fromUnpackedDirectory: url,
                consent: requestInstallConsent
            )
        }
    }

    /// Shared install-task wrapper: drives the spinner, toasts the outcome,
    /// and treats a declined consent prompt as a silent no-op.
    private func runInstall(_ install: @escaping () async throws -> InstalledExtension) {
        guard !isInstalling else { return }
        isInstalling = true
        Task {
            do {
                let installed = try await install()
                toastManager.show("Installed \(installed.name)", icon: .system("puzzlepiece.extension"))
            } catch ExtensionInstallError.installationCancelled {
                // The user declined the requested permissions — nothing to report.
            } catch {
                toastManager.show(error.localizedDescription, type: .error)
            }
            isInstalling = false
        }
    }

    // MARK: - Installed list

    private var installedCard: some View {
        SettingsCard(
            header: "Installed Extensions",
            description: "Extensions run in every Space and never in Private Windows."
        ) {
            if extensionManager.installedExtensions.isEmpty {
                Text("No extensions installed.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(extensionManager.installedExtensions) { installed in
                        InstalledExtensionRow(installed: installed) {
                            pendingUninstall = installed
                        }
                        if installed.id != extensionManager.installedExtensions.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func confirmUninstall() {
        guard let target = pendingUninstall else { return }
        pendingUninstall = nil
        do {
            try extensionManager.uninstall(target.id)
            toastManager.show("Uninstalled \(target.name)", icon: .system("trash"))
        } catch {
            toastManager.show(error.localizedDescription, type: .error)
        }
    }
}

// MARK: - Install consent prompt state

private struct InstallConsentPrompt {
    let name: String
    /// Requested API permissions followed by requested host patterns.
    let requestedItems: [String]
    let respond: (Bool) -> Void
}

// MARK: - Row

private struct InstalledExtensionRow: View {
    let installed: InstalledExtension
    let onUninstall: () -> Void

    @State private var showPermissions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                iconView

                VStack(alignment: .leading, spacing: 2) {
                    Text(installed.name)
                        .font(.system(size: 13, weight: .medium))
                    Text("Version \(installed.version)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("Uninstall", role: .destructive, action: onUninstall)
            }

            DisclosureGroup("Granted permissions", isExpanded: $showPermissions) {
                if grantedItems.isEmpty {
                    Text("Nothing granted yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(grantedItems, id: \.self) { item in
                            Text(item)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon = installed.webExtension.icon(for: CGSize(width: 32, height: 32)) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 16))
                .foregroundColor(.secondary)
                .frame(width: 24, height: 24)
        }
    }

    /// Granted API permissions followed by granted host patterns.
    private var grantedItems: [String] {
        let permissions = installed.context.grantedPermissions.keys.map(\.rawValue).sorted()
        let hosts = installed.context.grantedPermissionMatchPatterns.keys.map(\.string).sorted()
        return permissions + hosts
    }
}
