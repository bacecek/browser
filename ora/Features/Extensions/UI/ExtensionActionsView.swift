import AppKit
import SwiftUI
@preconcurrency import WebKit

/// One button per installed Extension, right of the URL field.
/// Absent in Private Windows, and gone entirely when the toolbar is hidden
/// (the whole URLBar unmounts — extension keyboard commands keep working
/// through KeyModifierListener).
struct ExtensionActionsView: View {
    let foregroundColor: Color
    @ObservedObject private var extensionManager = ExtensionManager.shared

    var body: some View {
        ForEach(extensionManager.installedExtensions) { installed in
            ExtensionActionButton(installed: installed, foregroundColor: foregroundColor)
        }
    }
}

private struct ExtensionActionButton: View {
    let installed: InstalledExtension
    let foregroundColor: Color

    @EnvironmentObject private var tabManager: TabManager
    @ObservedObject private var coordinator = ExtensionActionCoordinator.shared
    @State private var isHovering = false
    @State private var anchorView: NSView?

    /// The action for the active tab (tab-specific badge/icon), falling back
    /// to the default action. Re-read whenever WebKit reports an update.
    private var action: WKWebExtension.Action? {
        _ = coordinator.actionGeneration
        let adapter = tabManager.activeTab.flatMap { tab -> ExtensionTabAdapter? in
            tab.isPrivate ? nil : ExtensionManager.shared.adapter(for: tab)
        }
        return installed.context.action(for: adapter)
    }

    var body: some View {
        let action = self.action
        let isEnabled = action?.isEnabled ?? true

        Button {
            guard let anchorView else { return }
            coordinator.performAction(for: installed, anchor: anchorView, activeTab: tabManager.activeTab)
        } label: {
            ZStack(alignment: .topTrailing) {
                iconView(for: action)
                    .frame(width: 30, height: 30)
                    .background(
                        ConditionallyConcentricRectangle(cornerRadius: 10)
                            .fill(isHovering && isEnabled ? foregroundColor.opacity(0.1) : Color.clear)
                    )

                if let badgeText = action?.badgeText, !badgeText.isEmpty {
                    Text(badgeText)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 3)
                        .frame(minWidth: 12)
                        .frame(height: 12)
                        .background(Capsule().fill(Color.red))
                        .offset(x: 3, y: -1)
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovering = $0 }
        .help(action?.label ?? installed.name)
        .accessibilityLabel(Text(action?.label ?? installed.name))
        .background(
            ExtensionActionAnchor(extensionId: installed.id) { view in
                anchorView = view
            }
        )
    }

    @ViewBuilder
    private func iconView(for action: WKWebExtension.Action?) -> some View {
        let iconSize = CGSize(width: 16, height: 16)
        if let icon = action?.icon(for: iconSize) ?? installed.webExtension.icon(for: iconSize) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isHovering ? foregroundColor : foregroundColor.opacity(0.7))
        }
    }
}

/// Invisible NSView behind the button: the concrete anchor for the popup
/// popover, registered with the coordinator so programmatic
/// `action.openPopup()` calls can find a button too. Same trick as
/// URLBarMenuButton's MenuSourceView.
private struct ExtensionActionAnchor: NSViewRepresentable {
    let extensionId: String
    let onViewCreated: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        DispatchQueue.main.async {
            ExtensionActionCoordinator.shared.registerAnchor(view, extensionId: extensionId)
            onViewCreated(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
