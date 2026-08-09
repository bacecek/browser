# Handoff — Ora Browser, WebExtension platform (Phase 1)

Personal fork of the-ora/browser. Goal: run browser extensions (1Password first) on macOS 26/27. This doc covers what Phase 1 built, what works, what's blocked, and the decision the user is now facing. Written 2026-08-09.

## Read these first (don't re-derive)

- Spec: `docs/specs/extensions-platform.md` — the plan, user stories, seams, out-of-scope.
- Decision record: `docs/adr/0001-wkwebextension-platform.md` — why WKWebExtension, global controller, from-scratch, macOS 26 target.
- Glossary: `CONTEXT.md` — Space / Extension / Extension Action / Password Provider terms.
- Reference (what NOT to copy): upstream PR the-ora/browser#137 and merged #142 — same WKWebExtension attempt, abandoned; neither solves worker lifecycle, popup messaging, or the 1Password blocker below.

## Repo state

- Branch `main`, base commit `64e4af1`. **All Phase-1 work is UNCOMMITTED** (22 changed/new paths, `git status`). Nothing pushed.
- `project.yml` deployment target raised 15.0 → 26.0 (also `Info.plist` LSMinimumSystemVersion).
- Builds clean: `./scripts/xcbuild-debug.sh`. Tests green: 54/54 via `xcodebuild test -scheme ora -destination "platform=macOS,arch=arm64" CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO GENERATE_INFOPLIST_FILE=YES | xcbeautify`.
- New code lives in `ora/Features/Extensions/` (Services/, UI/, Models/). Wiring edits in BrowserPage, TabManager, TabBrowserPageDelegate, OraRoot, OraApp, OraBrowserScripts, SettingsStore, PasswordManagerProviderRegistry, PasswordsSettingsView, SettingsContentView, URLBar. Tests: `oraTests/Extension*.swift`, `oraTests/PasswordProviderTests.swift`.
- Implementation was produced by a Workflow run then hardened over 3 review/fix loops (code-review skill). Final review verdict was CLEAN before the manual smoke test began.

## What works (verified by manual smoke test)

- Install by Chrome Web Store URL/ID → CRX download → in-process unzip (`ZipArchive`, sandbox-safe) → load. Consent alert lists requested permissions/hosts before granting (no blanket auto-grant).
- Extension resources resolve over `webkit-extension://` and popups render. Consent-O-Matic (a non-offscreen extension) installs and loads.
- Tab/window adapters, lifecycle feeding, private-window exclusion, Password Provider switch — all as specced.

## THE BLOCKER — 1Password standalone cannot work (not our bug)

1Password's MV3 build calls `chrome.offscreen.createDocument('background/offscreen.html')` at service-worker startup to run its WASM crypto. **WKWebExtension does not implement `chrome.offscreen`** — confirmed: absent from the SDK's `WKWebExtensionPermission` enum and from all WebKit headers on macOS 26. So the worker throws at init → never registers its message listeners → popup and content script both hang on `Promise timed out`. This is an Apple API gap; it cannot be polyfilled (WKWebExtension has no hook to add `browser.*` APIs; `unsupportedAPIs` only hides them).

Evidence trail: WebKit log showed `WKWebExtensionContextError Code=6 (BackgroundContentFailedToLoad)`; worker console showed `Failed to load resource: requested URL not found`; manifest has `offscreen` permission + `background/offscreen.html` present; user's popup console: `[Popup] setup complete - rendering popup` then `[Shared] Promise timed out`.

**Only realistic path to a working 1Password = Phase 2: native messaging to the desktop 1Password app** (crypto runs in the app, no offscreen needed — how Safari/Chrome do it). Requires implementing Chrome's stdio native-messaging protocol (reference impl exists in Nook browser, GPL-3.0, cloned at `<scratchpad>/nook`), a Developer-ID-signed build in /Applications, and 1Password "Add Browser" trust. This is explicitly out-of-scope in the current spec.

## Real fixes made during the smoke test (in the uncommitted diff)

1. **Context identity bug (important, core fix)** — `ExtensionManager.configureContextIdentity` set `uniqueIdentifier = id` but `baseURL` host to an unrelated `ext-<hex>` value. They MUST share the host (WebKit serves resources from baseURL host; `runtime.id`/messaging use uniqueIdentifier). Mismatch → 404 on every extension resource. Fixed: both derive from `extensionId.lowercased()`. This is why popups render now.
2. Added `ExtensionManager.logContextErrors` — dumps `context.errors` to `log stream` so extension failures are visible without Web Inspector.

## Temporary/debug edits left in (decide whether to keep or revert)

- `ExtensionActionCoordinator`: popup uses `.applicationDefined` behavior under `#if DEBUG` (so it doesn't vanish on focus loss and can be inspected) + second-click-to-dismiss toggle. Harmless; DEBUG-only.
- `TabBrowserPageDelegate`: `navLogger` logging the real NSError on nav failure (category "Navigation"). Useful; harmless.

## Known open bug (our side, not yet fixed)

Extension **options page fails with `NSURLErrorDomain -1008` (ResourceUnavailable)**. We open it via `TabManager.addTab(url: optionsURL)` (see `ExtensionManager+ControllerDelegate.swift` `openOptionsPageFor`). The controller IS attached to the tab's webview (`BrowserPage.swift:56`), yet top-level navigation to a `webkit-extension://` options page in an ordinary tab is rejected — WebKit appears to load extension pages only in its own webviews. Needs a different presentation mechanism; not blocking the main use case. Also seen: `Tab for page N was not found` (window/tab adapter doesn't surface the page the worker queries via `browser.tabs`).

## Decision pending (user was asked, not yet answered)

1. Phase 2 — native messaging + desktop 1Password (only path to working 1Password).
2. Finish the platform for non-offscreen extensions (fix options page -1008, verify popup/content/tabs) — 1Password stays broken until Phase 2.
3. Re-evaluate: if only 1Password autofill is wanted, drop the extension platform and integrate via `op` CLI into Ora's existing autofill seam (`PasswordManagerProviderRegistry` reserves the slot). This was the runner-up option in the original design grill.

The `/handoff` argument was "о первой фазе" (about Phase 1) — this session's outcome is Phase 1 delivered + the offscreen blocker discovered. The next session most likely starts by getting the user's answer to the decision above.

## Environment / repro notes

- macOS 27.0, Xcode 27 (SDK MacOSX27.0). App runs from DerivedData: `~/Library/Developer/Xcode/DerivedData/Ora-*/Build/Products/Debug/Ora.app`.
- Installed extensions live in `~/Library/Application Support/Ora/Extensions/<id>/` + `registry.json`. Debug code is in `Ora.debug.dylib` (Inject), so `strings` on the main binary won't show new literals.
- Live extension logs: `log stream --level debug --predicate 'process == "Ora" AND (subsystem == "com.orabrowser.ora" OR category == "Extensions")'`. NOTE: run `log` from a script file, not inline in the Bash tool — inline predicates errored with `(eval):log:1: too many arguments`.
- Web Inspector for extension views needs Safari → Settings → Advanced → enable Develop menu; targets appear under Develop → [Mac name] only while the view is alive (the DEBUG non-transient popup helps).

## Suggested skills for the next session

- `grilling` + `to-spec` — if the user picks Phase 2 (native messaging), grill the design then write `docs/specs/extensions-native-messaging.md` (mirror the existing spec's structure; reference Nook's `NativeMessagingHandler.swift`).
- `code-review` — before committing the uncommitted Phase-1 diff (`/code-review` since `64e4af1`), and after any Phase-2 work.
- `domain-modeling` — extend `CONTEXT.md` with Phase-2 terms (Native Messaging Host, Connect Port) if that path is chosen.
