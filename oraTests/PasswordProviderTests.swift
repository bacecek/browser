import Foundation
@testable import Ora
import Testing
import WebKit

/// Seam-2 tests: page configuration behavior for the Password Provider switch
/// and the extension-controller attachment rules.
struct PasswordProviderTests {
    @Test func onePasswordProviderExcludesBuiltInPasswordManagerScript() {
        let configuration = BrowserPageConfiguration.oraDefault(
            userScripts: OraBrowserScripts.userScripts(passwordProvider: .onePassword),
            privacySettings: SpacePrivacySettings()
        )

        #expect(!configuration.userScripts.contains { $0.name == "ora-password-manager" })
    }

    @Test func oraProviderIncludesBuiltInPasswordManagerScript() {
        let configuration = BrowserPageConfiguration.oraDefault(
            userScripts: OraBrowserScripts.userScripts(passwordProvider: .ora),
            privacySettings: SpacePrivacySettings()
        )

        #expect(configuration.userScripts.contains { $0.name == "ora-password-manager" })
    }

    @Test func onePasswordProviderIsAvailableWithoutBuiltInSurfaces() {
        let descriptor = PasswordManagerProviderRegistry.shared.descriptor(for: .onePassword)

        #expect(descriptor.kind == .onePassword)
        #expect(descriptor.isAvailable)
        #expect(descriptor.usesBuiltInVault == false)
        #expect(descriptor.usesBuiltInOverlay == false)
    }

    @Test @MainActor func privateWindowConfigurationCarriesNoExtensionController() {
        let profile = BrowserEngine.shared.makeProfile(identifier: UUID(), isPrivate: true)
        let page = BrowserEngine.shared.makePage(
            profile: profile,
            configuration: BrowserPageConfiguration.oraDefault(
                userScripts: OraBrowserScripts.userScripts(passwordProvider: .ora),
                privacySettings: SpacePrivacySettings()
            ),
            delegate: nil
        )
        defer { page.teardown() }

        #expect(page.extensionHostWebView.configuration.webExtensionController == nil)
    }

    @Test @MainActor func regularWindowConfigurationCarriesSharedExtensionController() {
        let profile = BrowserEngine.shared.makeProfile(identifier: UUID(), isPrivate: false)
        let page = BrowserEngine.shared.makePage(
            profile: profile,
            configuration: BrowserPageConfiguration.oraDefault(
                userScripts: OraBrowserScripts.userScripts(passwordProvider: .ora),
                privacySettings: SpacePrivacySettings()
            ),
            delegate: nil
        )
        defer { page.teardown() }

        #expect(page.extensionHostWebView.configuration.webExtensionController === ExtensionManager.shared.controller)
    }
}
