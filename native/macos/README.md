# macOS native companion

For versioned packages, managed install/upgrade/uninstall, and release gates, see
[Phase 4 distribution](../../docs/native-phase4.md) and the
[physical acceptance runner](../../docs/native-phase4-acceptance.md).

Development Phase 3 host for `com.snapscreen.companion`, protocol version 3. Chrome launches
the executable and that process owns its AppKit panels directly. There is one session per
process, no local server or shared application relay. Every new capture opens a new native
connection/process; closing the session ends the process.

Build on macOS with Xcode command-line tools installed:

```bash
npm run build:native
npm run test:native
```

The output is `native/macos/build/SnapScreenCompanion.app/Contents/MacOS/SnapScreenCompanion`.
The build targets the current machine's architecture and SDK. It is a local development
build, without a distribution signing or notarization flow. The self-test command runs
protocol, frame, PNG bounds, session-lifecycle, window geometry, selection, answer-rendering,
conversation, composer and key-release checks without showing windows, installing a host,
connecting to Chrome or requesting an API answer. Focus tests use hidden windows and do not
establish Chrome focus preservation.

To register a built host, first find the extension's exact ID in `chrome://extensions` and
the browser's **Profile Path** in `chrome://version`. Supply the profile's parent user-data
root, not its `Default` or `Profile 1` subdirectory. Registration is an explicit user action:

```bash
npm run install:native -- --extension-id <exact-32-character-id> --user-data-dir </absolute/browser/user-data/root>
```

The installer writes only
`<user-data-dir>/NativeMessagingHosts/com.snapscreen.companion.json`, with an absolute
executable path and one exact `chrome-extension://<id>/` allowed origin. It requires an
existing browser user-data directory and never chooses or launches a browser. An optional
`--executable </absolute/path>` selects another built executable. A conflicting registration
for a different extension is refused. To remove this registration:

```bash
npm run install:native -- --extension-id <exact-32-character-id> --user-data-dir </absolute/browser/user-data/root> --remove
```

Chrome, Chromium and Chrome for Testing have distinct user-data roots. Use the actual root
of the browser under test; temporary test roots isolate the installation from daily browsing.
Select native companion mode in extension Settings after installing. Neither this document
nor building/testing automatically registers a host with the user's Chrome installation.

The UI keeps Phase 1's nonactivating panels, release-to-submit region selection, edge-resize
pointer shield, scrolling, Copy, preview and follow-up entry, and matches the In Chrome
interface's look and wording. The full screenshot is fitted inside a dark selection window,
not aligned over the browser viewport; Return places a keyboard selection as it does in Chrome.
The host discards its full image when selection is sent; only the crop subsequently accepted
by the extension is shown, as a thumbnail that opens a larger preview. The answer window is a
conversation: answers in selectable plain text and fenced code (language labels and per-block
Copy), follow-up questions, inline progress, failures with Retry, and Stopped answers. Turns the
extension removes for the conversation limit leave the window too, with a notice. A refused
answer's streamed text is cleared as it is in the extension. The composer's Send button becomes
Stop while an answer runs. Incremental updates preserve the reading position when scrolled up.
Escape and Command-W close a window on key release, so the release is not sent to Chrome.
Sources: `SelectionView.swift`, `ConversationView.swift`, `AnswerView.swift`, `Composer.swift`,
`Controls.swift` and `Geometry.swift`, wired together in `main.swift`. See the
[Phase 3 notes](../../docs/native-phase3.md) for keyboard controls and remaining acceptance.

Both transport directions and message variants are bounded and validated. `Protocol.swift`
defines exact fields; `Session.swift` rejects stale generation and cross-connection/session
events. Incoming PNG dimensions are checked before decoding, with a maximum 16,384 pixels
per side and 80 million pixels total. The extension remains responsible for crop validation,
capture authorization, API credentials, request execution, limits and error sanitization.

The companion writes no screenshots, answers, drafts, clipboard probes or input telemetry to
disk or logs. Copy is an explicit clipboard write. EOF, malformed input, a handshake/wait
timeout or expiry clears all image, answer, draft and control references and leaves only an
interrupted-session notice in a visible panel. Chrome ends the host process about two seconds
after its connection closes, so that notice is brief; the extension badge reports the failure.
The process cannot reconnect or replay a request. A fresh extension invocation creates a fresh
process and session.

`npm run test:native-live` (after `npm run build`) builds a separate test variant with
`node scripts/native-companion-build.mjs --test-hooks --bundle <path>` in a temporary
directory, registers it only in a disposable Chromium profile, and drives complete sessions.
The hooks confirm the default selection, ask one follow-up, and close; they read their scenario
from a file named by `SNAPSCREEN_TEST_SCENARIO_FILE`. `--test-hooks` requires an explicit
`--bundle`, so the default build never contains them, and `npm run test:native` fails if it does.

The Phase 1 focus observations are bounded evidence, not an undetectability promise. A
packaged native build still needs the physical interaction matrix repeated. This development build does
not establish broader macOS/Chrome version support, alternate layouts/input methods or
multiple-display acceptance.
