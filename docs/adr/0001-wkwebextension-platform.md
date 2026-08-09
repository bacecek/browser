# Extensions via WKWebExtension, written from scratch

This fork diverges freely from upstream (deployment target raised to macOS 26) to build a WebExtension platform on Apple's WKWebExtension API — the same engine Safari uses. Upstream PR #137 tried the same API but is abandoned, based on the pre-refactor repo layout, and implements the WKWebExtensionTab/WKWebExtensionWindow protocols only fractionally (empty window wrapper, no tab lifecycle events fed to the controller) — which is exactly why 1Password's background worker never came up there. We reimplement from scratch in the current `Features/` structure, using PR #137, Nook browser (GPL-3.0, license-compatible), and DuckDuckGo's `SharedPackages/WebExtensions` as references.

## Considered Options

- Port PR #137 — rejected: porting cost with little salvageable code (~500 useful lines, mostly stubs).
- Custom WebExtension polyfill layer (Orion-style) — rejected: years of work; WKWebExtension exists now.
- No platform, integrate 1Password via `op` CLI into Ora's autofill — rejected as primary path: user wants the extension ecosystem; the `PasswordManagerProviderRegistry` seam remains available as a fallback.

## Consequences

- One global `WKWebExtensionController` for all Spaces (single 1Password login); extensions are excluded from Private Windows. Per-Space enablement was rejected for v1.
- 1Password runs standalone (sign-in inside the extension) in v1; native-messaging integration with the desktop app (Touch ID unlock, requires Chrome's stdio protocol + 1Password "Add Browser" trust) is phase 2.
- Install flow: download CRX from the Chrome Web Store update endpoint by ID/URL, strip CRX3 header, unzip, load unpacked; plus a load-unpacked-folder option. Auto-update deferred.
- The active Password Provider is exclusive: selecting 1Password disables Ora's built-in password-manager injection/overlay.
- Whether 1Password's Chrome build actually functions under WebKit's implementation is unverified anywhere publicly — the standalone smoke test is the first milestone and the go/no-go gate.
