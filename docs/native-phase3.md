# Native interface (Phase 3)

Phase 3 completes the development companion's answer and selection controls. It keeps both
interfaces in one package: **In Chrome** remains the default and **macOS companion
(experimental)** is an explicit choice. Follow the [local setup](native-phase2.md) to build,
register, and select the companion. Signing, distribution, and physical acceptance of the
completed interface belong to Phase 4.

## Using the interface

- Drag on the fitted frozen screenshot and release to ask. Arrow keys move the initial
  selection; Shift + arrows resize it. The selection summary reports its pixel bounds.
  Return or **Use selection** confirms; Escape or **Cancel selection** cancels. Keyboard
  and pointer selections use the same minimum displayed size.
- Answers stream as selectable plain text and fenced code. Code blocks have a language label
  and their own **Copy code** control; that copies the block's content without its fences.
  **Copy answer** copies the original answer, including fences. Other Markdown syntax stays
  literal. Reading above the bottom keeps the scroll position as new text arrives.
- **Stop** cancels the active answer. **Retry** is available after a stopped or failed answer.
  A follow-up becomes available when the request ends. The length hint uses the configured
  limit, and Return submits a nonblank question. Selection, paste, and editing use AppKit's
  text controls and standard editing shortcuts.
- **Preview** opens the accepted crop in a separate fitted window. Closing it leaves the
  conversation open. Escape or Command + W closes the current window; closing the answer
  ends its session. Full-image references are released after selection.

The panels keep their nonactivating configuration and resize pointer shield. Controls expose
accessibility labels and selection feedback, but adding an accessible control does not prove
that interacting with it preserves Chrome focus. VoiceOver, keyboard traversal, input methods,
preview, code Copy, fullscreen, and display changes still need physical acceptance against
this implementation. The previously accepted modifier-key limitation still applies.

## Checking installation

Settings offers an explicit **Check companion** action. It checks the platform and exchanges
only the existing versioned hello/ready handshake with a fresh local host, then disconnects.
It sends no screenshot, question, API key, system prompt, or conversation. The check does not
open a native window, change the saved interface, or start an answer. Opening Settings and
saving preferences do not run it automatically. A successful check establishes availability
at that moment; a later launch can still fail.

Missing, blocked, incompatible, silent, or disconnected hosts produce actionable status in
Settings. A capture-time failure still uses the toolbar badge and title, without injecting UI,
opening Settings, or activating a workspace. Installing or fixing a registration remains a
separate user action.

## Migration and verification

The extension-only interface remains supported in this development package. Its frame and
icon therefore remain web-accessible, and its workspace stays private. Selecting native mode
does not change those static manifest exposures. A native-only build and removing the
injected interface are separate release decisions.

Run the checks in [the setup guide](native-phase2.md#verification-and-remaining-work).
Native self-tests cover fence parsing, incremental rendering and cleanup, scroll retention,
selection geometry, and accessibility metadata in addition to transport and session checks.
The real Chrome-launched test uses mocked answers containing prose and code, then a follow-up;
it verifies connection lifecycle without paid API calls. These automated checks do not
establish physical focus or input privacy. Phase 4 must repeat and publish that matrix against
the packaged build before making broader interaction claims.
