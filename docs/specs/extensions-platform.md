# Spec: WebExtension Platform (1Password first)

Status: ready-for-agent
Related: [ADR-0001](../adr/0001-wkwebextension-platform.md), [CONTEXT.md](../../CONTEXT.md), upstream PR the-ora/browser#137 (reference only)

## Problem Statement

I use Ora as my daily browser on macOS 26/27, but I cannot use it fully because my password manager — 1Password — only exists as a browser extension, and Ora has no extension support. The upstream project attempted extensions once (PR #137), but the work stalled and 1Password never functioned there. Without 1Password, every login is a manual round-trip to another app, which makes the browser unusable as a daily driver.

## Solution

Build a WebExtension platform into this fork on Apple's WKWebExtension family of APIs — the same extension engine Safari uses. Extensions are installed by pasting a Chrome Web Store link or ID (or loading an unpacked folder), appear as Extension Actions to the right of the URL bar, work in every Space, and never run in Private Windows. 1Password runs in standalone mode (sign-in inside the extension) as the first supported extension; when the user selects 1Password as their Password Provider, Ora's built-in autofill steps aside entirely. Desktop-app integration (Touch ID unlock via native messaging) follows as a second phase.

## User Stories

1. As a browser user, I want to install the 1Password extension by pasting its Chrome Web Store URL, so that I don't have to hunt for CRX files manually.
2. As a browser user, I want to install an extension by its Chrome Web Store ID, so that I can install extensions whose store page I don't have open.
3. As a developer-user, I want to load an unpacked extension folder, so that I can experiment with extensions not on the store.
4. As a browser user, I want installed extensions to load automatically on every launch, so that installation is a one-time act.
5. As a browser user, I want an extension's granted permissions to persist across restarts, so that I am not re-prompted every session.
6. As a browser user, I want to see a list of my installed extensions in Settings with name, icon, and version, so that I know what is running.
7. As a browser user, I want to uninstall an extension from Settings, so that I can remove what I no longer use.
8. As a browser user, I want to be prompted when an extension requests permissions or host access, so that nothing gets blanket access silently.
9. As a browser user, I want each extension's Extension Action shown to the right of the URL bar, so that I can reach it like in Chrome or Safari.
10. As a browser user, I want clicking an Extension Action to open its popup anchored to the button, so that the interaction feels native.
11. As a 1Password user, I want to sign in to my 1Password account inside the extension popup, so that I can use my vault without the desktop app.
12. As a 1Password user, I want 1Password's content script to run on every page in every Space, so that inline autofill suggestions appear on login forms.
13. As a 1Password user, I want the extension's keyboard shortcut (Cmd+\) to trigger autofill, so that I can fill credentials without touching the mouse.
14. As a browser user, I want extension keyboard shortcuts to work even when the toolbar is hidden, so that hiding chrome doesn't cost me functionality.
15. As a browser user, I want to select 1Password as my Password Provider in Settings, so that Ora's built-in autofill overlay stops competing with 1Password on login fields.
16. As a browser user, I want to switch back to Ora's built-in Password Provider, so that I have a fallback if the extension misbehaves.
17. As a privacy-conscious user, I want extensions to never run in Private Windows, so that private browsing leaves no trace in extension storage.
18. As a browser user, I want extensions to work identically in all Spaces with a single login, so that I don't re-authenticate per Space.
19. As a browser user, I want extensions to keep an accurate picture of my open tabs (including tabs Ora unloads in the background and webviews rebuilt after privacy-settings changes), so that extension features that depend on tab state don't break silently.
20. As a browser user, I want an extension's options page to open in a regular tab, so that I can configure extensions like uBlock Origin later.
21. As a browser user, I want a clear error message when an install fails (bad URL, network failure, malformed package), so that I know what went wrong.
22. As a fork maintainer, I want the platform to be a general WebExtension host rather than a 1Password shim, so that other extensions can be added without rework.
23. As a fork maintainer, I want automated tests around installation and provider switching, so that regressions surface when I evolve the fork.
24. As a 1Password user, I want (phase 2) the extension to unlock via the 1Password desktop app with Touch ID, so that I never type my master password in the browser.

## Implementation Decisions

- **Engine**: WKWebExtension / WKWebExtensionController / WKWebExtensionContext (macOS 26 baseline; deployment target raised from 15.0). No custom polyfill layer. See ADR-0001.
- **Written from scratch** in the current feature-module structure. Upstream PR #137 is reference material only; its core defects to avoid are: an empty window adapter, tab lifecycle events never fed to the controller, hand-rolled routing of `browser.tabs` messages, and blanket permission grants.
- **Controller topology**: one global controller shared by all Spaces. Its configuration attaches to every non-private page's webview configuration. Private Windows get no controller. Extension storage is the controller's own persistent store; a single 1Password login covers all Spaces.
- **Host adapters**: an adapter conforming to WKWebExtensionTab wraps each Tab; an adapter conforming to WKWebExtensionWindow wraps each window's tab list and active tab. The tab manager feeds every lifecycle change to the controller (open, close, activate, property changes, window focus). Two Ora-specific lifecycle wrinkles must be handled: background tab unloading by the alive-timeout sweep, and webview rebuilds triggered by privacy-settings changes — both must present a consistent open/close or properties-changed narrative to the controller.
- **Load ordering**: page creation already defers first navigation until content-blocker rules are attached; extension controller attachment happens as part of building the page configuration, before that gate opens.
- **Install pipeline**: paste a Chrome Web Store URL or bare extension ID → download CRX from Google's update endpoint → strip the CRX3 header → unzip → load as an unpacked directory from Application Support → load into the controller. Also a "load unpacked folder" path for development. Nook browser (GPL-3.0, license-compatible) is the reference implementation for CRX handling. No auto-update in v1; reinstall re-downloads.
- **Permissions**: requested via the controller delegate's prompt callbacks and surfaced through the existing dialog system; grants are persisted and re-applied on load. No blanket `<all_urls>` auto-grant; 1Password's requested permissions are granted through the same prompt flow.
- **Extension Actions UI**: one button per extension with an action, placed right of the URL bar; the popup uses the NSPopover the API provides, anchored to the button. When the toolbar is hidden there are no buttons in v1 — extension commands (keyboard shortcuts, e.g. 1Password's Cmd+\) still work, routed through the existing key-handling chain so they respect focus rules.
- **Password Provider switch**: the existing provider registry becomes live. Exactly one provider is active: selecting 1Password stops injecting the built-in password-manager script and disables the built-in overlay coordinators; selecting Ora restores them. The setting is global, not per-Space.
- **Settings**: a new Extensions section (install field, installed list, uninstall, per-extension permissions view) and the Password Provider picker in the existing Passwords section.
- **Phase 2 (separate effort, not in v1)**: native messaging bridge speaking Chrome's stdio protocol (locate the NM host manifest, spawn the host binary, 4-byte length-prefixed frames), enabling 1Password desktop-app integration after the user trusts the browser via 1Password's "Add Browser". The fork must be code-signed and live in /Applications for this.

## Testing Decisions

- Tests assert external behavior at two seams; adapter internals and controller callbacks are not asserted directly.
- **Seam 1 — the extension manager facade**: install from a store URL/ID (network stubbed with a URLProtocol, as the existing filter-list fetch tests already do), install from an unpacked folder, list installed, uninstall, and reload-on-relaunch with permissions intact. Tests use a tiny fixture WebExtension (manifest + trivial script) committed as a test resource; CRX-header stripping is covered with a fixture CRX byte blob.
- **Seam 2 — page configuration**: building a page configuration with the 1Password Password Provider selected excludes the built-in password-manager user script; with the Ora provider it is included; private-window configurations never carry the extension controller.
- Framework: swift-testing (`#expect`), matching the existing test suite. Prior art: the webview host reparenting tests and the privacy/filter-list tests with `RequestCountingURLProtocol`.
- Live 1Password behavior (login, inline autofill, Cmd+\) is verified by a manual smoke checklist, not automation. The standalone smoke test is the go/no-go gate for the whole effort.

## Out of Scope

- Native messaging / desktop-app integration and Touch ID unlock (phase 2).
- Extension auto-update and update-channel handling.
- Per-Space extension enablement or per-Space extension logins.
- Extensions in Private Windows.
- Extension buttons while the toolbar is hidden (shortcuts only).
- Any extension store UI beyond paste-a-link/ID; "Add to Ora" injection on Chrome Web Store pages.
- Firefox (.xpi) packages.
- Upstream-compatibility of any of this work (the fork diverges freely; nothing here is written for upstreaming).
- Removing Ora's built-in password manager (it stays as a selectable provider).

## Further Notes

- **Primary risk, unverified anywhere publicly**: whether 1Password's Chrome MV3 build actually functions under WebKit's WebExtension implementation (possible use of Chrome-only APIs such as `chrome.offscreen`, UA sniffing). The first milestone is a standalone smoke test on the bare skeleton; if it fails on missing APIs, the fallback is integrating 1Password via the `op` CLI into Ora's existing autofill seam — the provider registry already reserves a slot for that shape.
- The context's `unsupportedAPIs` surface can be used to make missing APIs cleanly `undefined` so extensions feature-detect instead of crashing.
- Reference implementations, all license-compatible or public: Nook browser (complete delegate, CRX pipeline, native messaging), DuckDuckGo's WebExtensions package (production-grade loader/event wiring), upstream PR #137 (what not to do).
- The upstream `runtime.connect(): No runtime.onConnect listeners found` failure from PR #137 is diagnostic of the background service worker never starting — background content must be loaded explicitly after the context loads, and load errors must be surfaced, not swallowed.
