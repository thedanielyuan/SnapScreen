# Native interface (Phase 3)

Phase 3 completes the development companion's answer and selection controls. It keeps both
interfaces in one package: **In Chrome** remains the default and **macOS companion
(experimental)** is an explicit choice. Follow the [local setup](native-phase2.md) to build,
register, and select the companion. Signing, distribution, and physical acceptance of the
completed interface belong to Phase 4.

## Using the interface

The companion matches the In Chrome interface's look and wording, so the two modes behave alike.

- **Selecting.** The frozen screenshot opens in a dark window on the display under the pointer,
  at its captured size when that fits. As in Chrome, drag and release to ask, or click to
  cancel; a badge shows the region's size in screenshot pixels. Return places a centred
  keyboard selection; arrow keys move it 10 points (1 with Option), Shift + arrows resize it,
  and Return again asks. Escape cancels. The visible instruction, like Chrome's, omits the
  keyboard controls; assistive technology receives them as help text and custom actions.
- **Answer window.** It opens beside the selected region when there is room. It holds the whole
  conversation: the accepted crop as a thumbnail (press it for a larger preview), each answer,
  and each follow-up question. Answers are selectable plain text with fenced code; a closed
  code block has its own **Copy**, which copies the block without its fences, and a finished
  answer's copy button copies the original answer, including fences. Other Markdown syntax
  stays literal. Reading above the bottom keeps the scroll position as new text arrives;
  asking a question scrolls to it.
- **Progress, Stop and Retry.** A spinner shows until text arrives; after five seconds it adds
  "Waiting for the answer…" or "Thinking…" and the elapsed time. While an answer runs, the
  composer's Send button becomes Stop. A stopped answer shows **Stopped** and **Retry**; a
  failure appears inline, with **Retry** on the newest one. A follow-up stopped before any text
  is dropped when you ask the next question, matching the conversation the extension keeps.
  When the extension removes older turns to stay within the conversation limit, the same turns
  leave the window, as they do in Chrome, and a notice appears above the new request.
- **Follow-ups.** The composer grows to six lines. Return asks a nonblank question; Shift +
  Return or Option + Return adds a line. You can draft while an answer runs. Input stops at the
  configured character limit, with a counter near it. Typing while an answer's text has focus
  continues in the composer. Selection, paste, and editing use AppKit's text system and its
  standard shortcuts.
- **Closing.** Escape or Command + W closes the current window when the key is released, so
  the release is not delivered to Chrome after the window disappears. Closing the preview
  returns to the conversation; closing the answer window ends its session. Full-image
  references are released after selection.

The panels keep their nonactivating configuration and resize pointer shield. Controls expose
accessibility labels and announcements, but adding an accessible control does not prove that
interacting with it preserves Chrome focus. VoiceOver, keyboard traversal, input methods,
preview, Copy, Stop, Retry, key-release closing, fullscreen, and display changes still need
physical acceptance against this implementation. The previously accepted modifier-key
limitation still applies.

## Checking installation

When **macOS companion (experimental)** is selected, Settings shows the companion's details and
an explicit **Check companion** action; with In Chrome selected they stay hidden. The check
verifies the platform and exchanges only the existing versioned hello/ready handshake with a
fresh local host, then disconnects. It sends no screenshot, question, API key, system prompt,
or conversation. The check does not open a native window, change the saved interface, or start
an answer. Opening Settings, changing the selection, and saving preferences do not run it. A
successful check establishes availability at that moment; a later launch can still fail.

Missing, blocked, incompatible, silent, or disconnected hosts produce actionable status in
Settings. A capture-time failure still uses the toolbar badge and title, without injecting UI,
opening Settings, or activating a workspace. Installing or fixing a registration remains a
separate user action.

## Migration and verification

The extension-only interface remains supported in this development package. Its frame
therefore remains web-accessible, and its workspace stays private. Selecting native mode
does not change those static manifest exposures. A native-only build and removing the
injected interface are separate release decisions.

Run the checks in [the setup guide](native-phase2.md#verification-and-remaining-work).
Native self-tests cover fence parsing, incremental rendering and cleanup, the conversation
thread and composer, scroll retention, selection and window geometry, key-release closing, and
accessibility metadata in addition to transport and session checks.
The real Chrome-launched test uses mocked answers containing prose and code, then a follow-up;
it verifies connection lifecycle without paid API calls. These automated checks do not
establish physical focus or input privacy. Phase 4 must repeat and publish that matrix against
the packaged build before making broader interaction claims.
