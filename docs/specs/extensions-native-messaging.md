# Spec: Native Messaging (1Password desktop integration)

Status: ready-for-agent
Related: [ADR-0001](../adr/0001-wkwebextension-platform.md), [ADR-0002](../adr/0002-chrome-native-messaging.md), [extensions-platform.md](./extensions-platform.md), [CONTEXT.md](../../CONTEXT.md)

## Problem Statement

Phase 1 delivered a working WebExtension platform, but 1Password — the extension the platform was built for — cannot run standalone: its MV3 service worker calls `chrome.offscreen.createDocument` at startup to run WASM crypto, and WKWebExtension does not implement `chrome.offscreen` (absent from the SDK on macOS 26/27; cannot be polyfilled). The worker dies before registering any listeners, so the popup and content script hang forever. The way every real browser integration works around this — including 1Password-in-Safari and 1Password-in-Chrome with the desktop app — is native messaging: the crypto runs in the desktop 1Password app, and the extension talks to it over a local channel.

## Solution

Implement Chrome's native messaging protocol as a general mechanism of the extension platform. WebKit already routes `runtime.connectNative` and `runtime.sendNativeMessage` to two controller-delegate hooks (`webExtensionController(_:connectUsing:for:completionHandler:)` and `webExtensionController(_:sendMessage:toApplicationWithIdentifier:for:replyHandler:)`); Ora's job is to resolve the Native Messaging Host manifest, spawn the host process, and bridge stdio frames to the `WKWebExtensionMessagePort`. 1Password is the first consumer: its host manifest is already installed in Chrome's directory and points at `1Password-BrowserSupport` inside the app bundle. Additionally, `offscreen` is added to each context's `unsupportedAPIs` so extensions feature-detect its absence instead of crashing, and the two Phase-1 leftover bugs (options page `-1008`, `Tab for page N was not found`) are fixed.

## User Stories

1. As a 1Password user, I want the extension to connect to the desktop 1Password app, so that vault crypto runs there and no offscreen document is needed.
2. As a 1Password user, I want to unlock 1Password in the browser via the desktop app with Touch ID, so that I never type my master password in the browser.
3. As a 1Password user, I want inline autofill suggestions and Cmd+\ fill to actually work (they were specced in Phase 1 but blocked on the dead worker), so that the browser is usable as a daily driver.
4. As a browser user, I want any Extension holding the `nativeMessaging` permission to reach a Native Messaging Host that has allowed it, so that the platform stays general rather than a 1Password shim.
5. As a browser user, I want an Extension to be refused when the host's manifest does not list it in `allowed_origins` or the permission was not granted, so that no extension silently talks to native software.
6. As a fork maintainer, I want Ora to also read its own manifest directory, so that hosts installed specifically for Ora don't have to pollute Chrome's directories.
7. As a browser user, I want an extension's options page to open in a regular tab without `-1008`, so that extensions are configurable.
8. As a browser user, I want extensions to get correct answers from `browser.tabs` for every open page, so that tab-dependent features don't fail with `Tab for page N was not found`.
9. As a fork maintainer, I want automated tests around frame encoding, manifest resolution, and the security gate, so that regressions surface without a live 1Password.
10. As a browser user, I want a failed native connection to produce a visible error (port error + log), so that misconfiguration is diagnosable without Web Inspector.

## Implementation Decisions

- **Delegate hooks**: implement both `connectUsing:` (port-based, what 1Password uses) and `sendMessage:toApplicationWithIdentifier:` (one-shot). One-shot spawns a host, writes one message, reads one reply, terminates it.
- **Manifest resolution** (first match wins): `~/Library/Application Support/Ora/NativeMessagingHosts` → `~/Library/Application Support/Google/Chrome/NativeMessagingHosts` → `/Library/Google/Chrome/NativeMessagingHosts`. File name is `<host name>.json`. Validate: `type == "stdio"`, `name` matches the requested identifier and Chrome's naming rules, `path` absolute and executable.
- **Security gate**, exactly Chrome's model, no extra runtime prompts: the extension must hold a granted `nativeMessaging` permission (through the existing Phase-1 consent flow) AND `chrome-extension://<extensionId>/` must appear in the manifest's `allowed_origins`. Ora's extension IDs are Chrome Web Store IDs, so the match is direct.
- **Wire protocol**: each frame is a native-endian `uint32` byte length followed by that many bytes of UTF-8 JSON. Limits as Chrome: 1 MB host→browser, 4 GB browser→host; violation closes the port with an error. The extension origin is passed as the host process's first argument.
- **Process lifecycle**: one host process per Native Port, spawned on `connectNative`, terminated when the port closes, the extension unloads, or Ora quits. Host exit closes the port (fires `onDisconnect`). No respawn-on-crash; the extension reconnects if it wants to.
- **`unsupportedAPIs`**: add `offscreen` to every context so 1Password (and anything else) sees `chrome.offscreen === undefined` and can feature-detect instead of throwing.
- **Options page fix**: top-level `webkit-extension://` navigation is rejected in ordinary tab webviews; extension pages must be hosted in a webview carrying the extension controller's configuration for that context. Present it inside a regular tab per Phase-1 story 20; the webview construction path is the fix, not the tab UI.
- **Tabs bug fix**: audit the tab/window adapters until every page the worker can reference through `browser.tabs` resolves; `Tab for page N was not found` must not reproduce during the smoke test.
- **Trust setup is manual and documented** (see Further Notes): sudo-created `custom_allowed_browsers`, Developer-ID-signed build copied to `/Applications`, "untested browsers" toggle in 1Password settings. No automation in Ora.
- **New code** lives in `ora/Features/Extensions/Services/NativeMessaging/`; delegate additions go next to the existing `ExtensionManager+ControllerDelegate.swift`.

## Testing Decisions

- Same philosophy as Phase 1: assert external behavior at seams, keep adapter/delegate internals unasserted, swift-testing throughout.
- **Frame codec**: round-trip, malformed length, truncated payload, oversize in both directions.
- **Manifest resolution**: fixture directory trees in temp dirs covering precedence order, missing host, invalid manifest (wrong type, name mismatch, relative path).
- **Security gate**: no `nativeMessaging` grant → refused; origin absent from `allowed_origins` → refused; both satisfied → connected.
- **Integration**: a fixture echo host (small script committed as a test resource, reachable via a fixture manifest) — connect, exchange messages, close port, assert the process died; host self-exit fires disconnect.
- **Live 1Password** is a manual smoke checklist and the acceptance gate for the whole phase: desktop-app link established, Touch ID unlock, inline suggestions on a login form, Cmd+\ fill, popup shows vaults, options page opens, no `Tab for page N was not found` in logs.

## Out of Scope

- Automating the 1Password trust setup (admin-privileged file creation stays manual).
- Any UI for installing or managing Native Messaging Host manifests.
- Firefox-style NM manifest locations or `.xpi` anything.
- Reading manifest directories of other Chromium browsers (Chromium, Edge, Brave...).
- Windows/Linux specifics of the protocol (`--parent-window`, registry lookup).
- Polyfilling `chrome.offscreen` (impossible; `unsupportedAPIs` hides it, nothing more).
- Auto-respawn or keep-alive of crashed hosts.

## Further Notes

- **The carried risk**: it is not publicly verified that 1Password's worker skips the offscreen path when a desktop-app channel is available. Full implementation was chosen over a probe-first milestone with eyes open; if the final smoke still fails on offscreen, the fallback remains `op` CLI integration through the Password Provider seam (`PasswordManagerProviderRegistry`).
- **Trust setup steps** (document verbatim in the walkthrough when executing): 1) build Release/signed, copy `Ora.app` to `/Applications`; 2) `sudo mkdir -p "/Library/Application Support/1Password" && sudo sh -c 'echo Ora >> "/Library/Application Support/1Password/custom_allowed_browsers"'` (the entry is the browser's executable name); 3) in 1Password: Settings → Browser → allow untested/custom browsers; 4) first `connectNative` should trigger 1Password's "Add Browser" confirmation.
- Consequence of the trust model: a Debug build running from DerivedData cannot pass 1Password's verification. Protocol-level work is testable with the echo host from any build; only the live 1Password smoke needs the `/Applications` copy.
- 1Password's manifest on this machine: `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.1password.1password.json`, `allowed_origins` includes `aeblfdkhhhdcdjpifhhbdiojplfjncoa` (the store build we install).
- Reference implementation: Nook browser (GPL-3.0, license-compatible) — `NativeMessagingHandler.swift`; re-clone if the previous scratchpad copy is gone.
- Debug logging: reuse the `Extensions` os_log category; `log stream` invocations must run from a script file (inline predicates break in the Bash tool).
