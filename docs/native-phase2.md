# Native companion bridge (Phase 2)

Phase 2 introduces an optional development macOS companion. The default interface remains
**In Chrome**. Native mode uses Chrome's capture authorization and background API client while
showing a fitted frozen screenshot and answers in a local AppKit process. Phase 3 interface
polish and Phase 4 physical acceptance, signing, and distribution remain outstanding.

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
no shared app relay or additional local IPC endpoint. Regular and incognito contexts are
separate, while Chrome shares the stored key and settings within a profile.

Up to four native sessions can remain open in each extension context. Close an existing
window before starting a fifth. An unfinished selection expires after two minutes.

Missing hosts, failed handshakes, unsupported versions, invalid transport messages, and
connection loss end the affected session. An extension badge reports failures without
injecting a page toast, opening a workspace or Settings, or switching interfaces. Inspect the
toolbar action's title for the error text. Reinstallation or reconnection requires a fresh
extension invocation and never replays a capture or API request. A worker restart also loses
the authoritative session; native windows cannot resume it.

## Data boundary

The local companion receives screenshots, crops, streamed answers, sanitized errors, and the
follow-up text entered there. It never receives the API key, system prompt, or structured API
history. Session content stays in memory and is discarded on close or disconnection; it is
not logged or persisted. Only an explicit Copy action writes answer text to the clipboard.
The existing Anthropic client keeps its model settings, prompt caching, request limits,
timeout, keepalive, and error sanitization. See the
[security contract](security.md#optional-macos-companion) and [privacy policy](../PRIVACY.md).

## Verification and remaining work

Run the extension checks in order, because the smoke test reads the freshly built `dist/`:

```bash
npm run lint
npm run typecheck
npm test
npm run build
npm run test:browser
npm run test:native
```

Phase 2 automated verification covers the local macOS build and native protocol/framing and
lifecycle self-tests, plus the built extension's mocked browser flow. These checks use no API
key and do not install a host in your existing browser. A real Chrome-launched companion
session has not been verified for this implementation; the browser smoke test substitutes a
mock native port. A paid live API test is not needed for a bridge-only change and must still
be approved before it is run.

Phase 3 must finish and polish the native UI, including accessibility and any remaining
selection, preview, or per-code-block controls. Phase 4 must exercise the real browser/host
launch in a disposable profile, repeat the physical interaction matrix against the completed
companion, and cover concurrent profiles/incognito, restarts, navigation, timeouts, and
oversized or malformed messages. Automated DOM assertions cannot establish native focus
behavior. Signing, notarization, upgrade/uninstall distribution, and cross-platform support
are not provided by this development build. The retained extension mode still needs its
web-accessible frame and icon resources.
