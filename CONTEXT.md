# Ora Browser (personal fork)

Personal fork of the-ora/browser focused on a WebExtension platform (1Password first). Diverges freely from upstream; macOS 26+ only.

## Language

**Space**:
A user-facing browsing context with its own tabs, cookies, and storage. One sidebar page per Space.
_Avoid_: Container (the code's `TabContainer` name), profile

**Extension**:
A Chrome-format WebExtension installed globally into the browser. Active in every Space, never in Private Windows.
_Avoid_: Plugin, add-on

**Extension Action**:
An Extension's button in the URL bar and the popup it opens.
_Avoid_: Toolbar icon

**Password Provider**:
The single source of autofill on web pages — either Ora's built-in vault or the 1Password Extension. Exactly one is active at a time.
_Avoid_: Autofill engine

**Private Window**:
A window whose data lives only in memory and is never touched by Extensions.
_Avoid_: Incognito
