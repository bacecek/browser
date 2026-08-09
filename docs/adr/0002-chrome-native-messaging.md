# Native messaging via Chrome's protocol, reading Chrome's manifest directories

To make 1Password (and any future extension that needs a desktop companion) work, Ora implements Chrome's native messaging protocol — stdio host processes, 4-byte-length-prefixed JSON frames, host manifests with `allowed_origins` — behind WebKit's two controller-delegate hooks (`connectUsing:` / `sendMessage:toApplicationWithIdentifier:`). Manifest lookup reads Ora's own directory first, then Chrome's user and system `NativeMessagingHosts` directories. Trust on the 1Password side is established manually via its documented `custom_allowed_browsers` mechanism (signed build in `/Applications`).

## Considered Options

- `op` CLI integration into Ora's built-in autofill — rejected as primary path (same reasoning as ADR-0001): the user wants the extension ecosystem, and the CLI gives no inline autofill UX. Remains the fallback if 1Password's worker still requires `chrome.offscreen` even with a desktop channel — a risk that stays unverified until the final smoke test, since a full implementation was deliberately chosen over a probe-first milestone.
- Inventing an Ora-specific manifest format/location only — rejected: 1Password already installs a Chrome manifest pointing at its BrowserSupport binary; reading Chrome's directories makes existing hosts work with zero setup. Ora's own directory is still read (first) so Ora-only hosts don't have to squat in Chrome's.
- Reading every Chromium-family browser's directories (Edge, Brave, Chromium) — rejected: more surface, and manifests aimed at other browsers may embed browser-specific assumptions.
- Automating the 1Password trust setup (privileged helper / osascript) — rejected for a single-user fork: one manual sudo step, documented in the spec.

## Consequences

- The mechanism is extension-agnostic: any Extension with a granted `nativeMessaging` permission and a host manifest listing its origin can connect. Security semantics are identical to Chrome (no extra prompts).
- Live 1Password integration only works for a Developer-ID-signed build running from `/Applications` — 1Password's BrowserSupport verifies the client's code signature. Debug builds from DerivedData can exercise the protocol only against test hosts.
- Ora's extension IDs being Chrome Web Store IDs (a Phase-1 decision) is now load-bearing: `allowed_origins` matching depends on it.
- If Apple ever ships `chrome.offscreen` or first-party native messaging in WKWebExtension, this layer shrinks but nothing above it changes.
