# macOS native companion

Development Phase 2 host for `com.snapscreen.companion`, protocol version 2. Chrome launches
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
protocol, frame, PNG bounds, session-lifecycle and fitted-image geometry checks without
creating windows, installing a host, connecting to Chrome or requesting an API answer.

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

The UI reuses Phase 1's nonactivating panels, keyboard selection, release-to-submit region
selection, edge-resize pointer shield, scrolling, Copy, preview and follow-up entry. Stop and
Retry are included. The full screenshot is fitted inside a native selection window, not
aligned over the browser viewport. The host discards its full image when selection is sent;
only the crop subsequently accepted by the extension is available for preview. Answers use
plain text; fenced code styling and per-block Copy remain Phase 3 work.

Both transport directions and message variants are bounded and validated. `Protocol.swift`
defines exact fields; `Session.swift` rejects stale generation and cross-connection/session
events. Incoming PNG dimensions are checked before decoding, with a maximum 16,384 pixels
per side and 80 million pixels total. The extension remains responsible for crop validation,
capture authorization, API credentials, request execution, limits and error sanitization.

The companion writes no screenshots, answers, drafts, clipboard probes or input telemetry to
disk or logs. Copy is an explicit clipboard write. EOF, malformed input, a handshake/wait
timeout or expiry clears all image, answer, draft and control references. A surviving panel
contains only an interrupted-session notice and its window Close control. It cannot reconnect
or replay a request. A fresh extension invocation creates a fresh process and session.

The Phase 1 focus observations are bounded evidence, not an undetectability promise. A
packaged native build still needs the physical interaction matrix repeated. Phase 2 does
not establish broader macOS/Chrome version support, alternate layouts/input methods or
multiple-display acceptance.
