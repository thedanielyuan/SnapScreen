# Native companion bridge (Phase 2)

Phase 2 introduces an optional development macOS companion. The default interface remains
**In Chrome**. Native mode uses Chrome's capture authorization and background API client while
showing a fitted frozen screenshot and answers in a local AppKit process.
[Phase 3](native-phase3.md) adds code blocks, selection feedback, keyboard controls, and an
explicit availability check. [Phase 4](native-phase4.md) adds packages and managed installation;
physical acceptance and a signed, notarized release remain.

The [Phase 1 observations](native-phase1-results.md) belong to the prototype and tested
conditions. They do not validate every interaction in this implementation. In particular,
modifier keys can reach the page. This mode does not promise universal focus preservation,
unobservability, or an overlay aligned with Chrome's viewport.

## Local setup

Requirements: macOS, Xcode command-line tools with `swiftc`, Node 22, and Chrome 116 or later.
The build targets the current Mac's architecture. Compatibility across supported macOS,
browser, and hardware versions still needs release acceptance testing.

```bash
npm ci
npm run build
npm run build:native
npm run test:native
```

Load `dist/` from **chrome://extensions → Developer mode → Load unpacked**, and copy that
extension's ID. Register the host using that exact ID and the user-data root of the browser
that loaded it:

```bash
npm run install:native -- --extension-id <extension-id> --user-data-dir <absolute-user-data-root>
```

For standard Google Chrome on macOS the usual root is
`~/Library/Application Support/Google/Chrome`; use its expanded absolute path. This is the
parent of profile folders such as `Default`, not the profile folder itself. Chrome for Testing,
Chromium, and browsers launched with `--user-data-dir` can use different roots. Confirm your
browser's actual location instead of registering the host in another installation.
[Chrome host registration](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging#native-messaging-host-location)

The command writes
`<user-data-root>/NativeMessagingHosts/com.snapscreen.companion.json`. Its only allowed origin
is `chrome-extension://<extension-id>/`; its executable path points to the absolute location of
`native/macos/build/SnapScreenCompanion.app/Contents/MacOS/SnapScreenCompanion`. Keep the
checkout in place or rerun registration after moving it. No development script registers a
host in your browser until you explicitly run the installation command.

Open SnapScreen Settings, select **macOS companion (experimental)**, and save. Configure the
API key there as usual. Saving Settings only changes the preference; the next toolbar click
or extension shortcut starts the companion. Real answers use your API key and incur normal
Anthropic API charges. Automated tests use mocked responses.

To return to the existing interface, select **In Chrome** and save. To remove this host's
registration:

```bash
npm run install:native -- --extension-id <extension-id> --user-data-dir <absolute-user-data-root> --remove
```

The removal command removes only the matching host manifest. The local build and extension
remain until you remove them separately. Closing a companion session ends its process and
connection.

## Session and failure behavior

1. A toolbar click or extension shortcut starts a session bound to its source tab, window,
   and document generation. The extension verifies the native handshake before capture.
2. The companion receives a frozen visible-tab image and returns normalized crop coordinates
   relative to its displayed image. The background validates and crops its own retained copy.
3. Both sides release the full screenshot after crop acceptance. The background owns the
   accepted crop and API conversation, and streams answer text to the companion.
4. Follow-ups, Stop, Retry, and Close are correlated to the session and current request.
   Neither the native UI nor its protocol can select arbitrary tabs or read API credentials.

Navigation or source-tab closure before crop acceptance invalidates selection. After crop
acceptance, the captured conversation and follow-ups remain usable even if that tab navigates
or closes. The companion has no recapture command: invoke the extension again on the desired
source for a new snip. Every native session owns its own connection and host process; there is
no shared app relay or additional local IPC endpoint. Sessions from incognito windows also get
their own connection and process, while Chrome shares the stored key and settings within a
profile.

Up to four native sessions can remain open at once, across regular and incognito windows.
Close an existing window before starting a fifth. An unfinished selection expires after two
minutes.

Missing hosts, failed handshakes, unsupported versions, invalid transport messages, and
connection loss end the affected session. An extension badge reports failures without
injecting a page toast, opening a workspace or Settings, or switching interfaces. Inspect the
toolbar action's title for the error text; the badge and title clear after five seconds. A
companion that is missing, incompatible, or silent during the handshake reports that it could
not start; losing it after the capture reports that the session ended. Navigation, a newer
invocation on the same tab, and the selection timeout end an unfinished selection without a
badge. Reinstallation or reconnection requires a fresh extension invocation and never replays
a capture or API request. A worker restart also loses the authoritative session; native
windows cannot resume it.

Chrome ends a host process about two seconds after its connection closes, so the companion's
interruption notice is only brief; the badge is the lasting signal. When older turns are
removed to stay within the conversation limit, the extension sends the companion how many it
removed (protocol version 3); the companion removes the same turns and shows a notice above the
new request. As in the In Chrome interface, text streamed before a refusal is discarded rather
than kept as an answer or sent back with a follow-up.

## Data boundary

The local companion receives screenshots, crops, streamed answers, sanitized errors, and the
follow-up text entered there. It never receives the API key, system prompt, or structured API
history. Session content stays in memory and is discarded on close or disconnection; it is
not logged or persisted. Only an explicit Copy action writes answer text to the clipboard.
The existing Anthropic client keeps its model settings, prompt caching, request limits,
timeout, keepalive, and error sanitization. See the
[security contract](security.md#macos-companion) and [privacy policy](../PRIVACY.md).

## Verification and remaining work

Run the checks in order, because the smoke and live tests read the freshly built `dist/`:

```bash
npm run lint
npm run typecheck
npm test
npm run build
npm run test:browser
npm run build:native
npm run test:native
npm run test:native-live
```

`test:native` runs the companion's protocol, framing, lifecycle, and interface self-tests and
the installer test. `test:native-live` launches Playwright's Chromium with a disposable profile,
registers a test build of the companion only in that profile, and runs real Chrome-launched
sessions against mocked answers. It covers the handshake, a 10 MB capture, a selection, a
streamed answer, a follow-up, Close and host exit, navigation before acceptance, and a missing
host. It also checks the Settings status for installed, missing, moved, foreign-origin, and
unstartable registrations against Chrome's real errors. Companion windows appear on screen for
a few seconds. That test build (`--test-hooks`) places and confirms the keyboard selection and
asks the follow-up by itself. `npm run build:native` never
compiles those hooks, and `test:native` fails if the registered build contains them. None of
these checks uses an API key or registers a host in your own browser. The browser smoke test
still substitutes a mock native port for its page-isolation checks. A paid live API test is
not needed for a bridge-only change and must still be approved before it is run.

Because the live test confirms selections programmatically, it establishes transport and
lifecycle behavior, not native focus behavior. [Phase 3](native-phase3.md) implements the
selection, preview, and per-code-block controls with accessibility metadata; physical
accessibility and focus acceptance remain unverified.
[Phase 4](native-phase4.md) adds versioned production packages, managed installation/upgrades/
uninstallation, signing/notarization preparation, and real packaged-host checks across browser
roots, malformed/oversized requests, disconnects, and worker restart. Its physical runner still
requires actual interaction trials, including supported incognito and environment variants.
Automated DOM assertions cannot establish native focus behavior. A signed/notarized release
and cross-platform support remain pending. The retained extension mode still needs its
web-accessible frame.
