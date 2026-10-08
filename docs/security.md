# Security and privacy

How SnapScreen handles your API key and screenshots, and how its UI is isolated from the pages
it runs on. The [privacy policy](../PRIVACY.md) is the short version.

## Native-only extension build

`npm run build:extension-native` produces a separate `dist-native/` extension that always uses
the macOS companion. Its dedicated worker has no content-script import, injection code,
workspace, or page-message handlers. Its manifest has no `scripting` permission, content
scripts, or web-accessible resources. The packaged Settings page and icons are private
extension resources. The ordinary `dist/` build retains its existing interface choice and
injected UI boundary described below.

Native-only Settings keeps credential management, prompt/limits, and the explicit **Check
companion** handshake. It has no interface selector; a previously stored `interfaceMode` is
ignored by both Settings and capture. Credentials, API requests, and history stay in trusted
extension contexts under the same native data contract below. Both builds open Settings on
first installation only. Native capture failures use badge feedback and never open Settings, another
tab, or a permission dialog. Local-file capture requires the user to enable file access in
Chrome's extension management page before invoking capture.

The native-only extension ZIP from `npm run package:extension-native` and the companion ZIP
from `npm run package:native` are separate artifacts. The extension packager validates the
build and extracted archive before accepting it, including the excluded UI and test shims.
Packaged and physical native runners reject companion builds with live-test hooks. The default
companion archive is unsigned and intended for local acceptance; creating the archives does
not publish or notarize them. Candidate hashes and automated check results belong to the
[candidate verification record](native-only-candidate-verification.md).

The native-only build requires its own exact extension ID in the host registration. It cannot
implicitly share or replace another variant's registration. Each browser user-data root has
one registration; a second Chrome profile within that root does not isolate it. Use separate
browser roots, or explicitly remove the old ID's registration before adding the new one as
described in the [variant-switch procedure](native-phase4.md#switch-extension-variants).
Automated package and mocked browser checks cover these build boundaries. Physical focus and
input acceptance was only partially completed; the
[physical acceptance record](native-only-physical-acceptance.md) lists the tested workflows,
and no claim extends beyond them. Removing web-accessible resources does not
establish universal undetectability or focus preservation.

## Optional macOS companion

Settings defaults to the existing **In Chrome** interface. Selecting **macOS companion
(experimental)** routes subsequent user invocations through the background's Native Messaging
bridge. Native mode does not inject a content script or page UI, open a workspace, or open
Settings automatically. Missing, incompatible, or disconnected hosts end the session and
report an extension badge error; they never trigger an automatic switch to the injected mode.
Opening or saving Settings does not start or probe the companion. The explicit **Check
companion** button performs only a version handshake on a separate short-lived connection,
then disconnects without creating a session or native window. It sends no screenshot, key,
question, or conversation; only the trusted options page can initiate this check.

Chrome launches one native host process for each session's `connectNative()` connection. The
host owns its AppKit windows directly; there is no separate app relay, local socket, HTTP
endpoint, or other IPC boundary. The installed host manifest permits only the exact chosen
extension origin. The native protocol validates its version, bounded message shapes, and
connection/session/request identities before accepting actions. It exposes no command for
reading credentials, choosing arbitrary tabs, or initiating another capture.

The local host is an additional trusted data recipient. It receives the frozen screenshot,
accepted crop, streamed answer text, sanitized errors, and the follow-up text entered in its
own window. The API key, shared system prompt, and structured API conversation history stay
in the extension. The background owns cropping, history, request limits, API calls, and
cancellation. Screenshot and conversation content are kept in process memory, never logged
or written to files. After crop acceptance both sides release the full screenshot and decoded
image buffers; only the crop and current conversation remain. Copy writes text to the system
clipboard only on an explicit user action; clipboard contents can outlive the session.

Navigation or closure of the source tab before crop acceptance cancels selection. Once a crop
is accepted, its conversation and follow-ups can continue without the source tab. A new capture
always requires another user invocation of the extension on a valid source. Closing a session,
losing its port, or losing authoritative worker state cancels pending work and discards session
data. Reconnection never restores that session or replays a request. Each session, including
one started from an incognito window, has its own connection and process, so commands and
answers cannot cross sessions or browsing contexts. Chrome shares local storage, including API
credentials and interface preferences, between regular and incognito use in the same profile.
[Chrome incognito behavior](https://developer.chrome.com/docs/extensions/reference/manifest/incognito)

This is an experimental companion, not yet a signed/notarized macOS release. Phase 4 packages
include a separate user-local installer. It writes the app, a receipt of its version/digest and
browser registration paths, and exact-origin native host manifests. These files contain no
screenshots, API credentials, or conversation content. There is no automatic updater. See
[packaging and removal](native-phase4.md). The fitted frozen-image
surface does not promise alignment with Chrome's content area. Phase 1's measured observations
do not establish the completed companion's interaction behavior. Packaged-candidate trials
confirmed that the shortcut's modifier keys reach page handlers: Chrome delivers the presses
before it recognizes the shortcut, and releases can arrive before the companion takes keyboard
focus. This is a documented limitation. Escape and Command-W close a companion window when the
key is released, so that release is not delivered to Chrome after the window disappears. The
ordinary package retains the web-accessible result frame required by its default injected mode.
See
[setup and remaining verification](native-phase2.md) and the
[Phase 1 results](native-phase1-results.md).

## Local native interaction experiment

`experiments/native-phase1/` builds a separate, unpacked test extension. Its only permissions
are `activeTab` and `nativeMessaging`; it cannot read the production extension's storage or
API key. A Chrome-launched Swift process receives screenshots and follow-up text in memory,
renders AppKit panels, and exchanges canned answers. The test host allows only the experiment's
exact extension origin and is registered in the runner's disposable browser profile. There
is no additional app relay or web-facing messaging endpoint. Messages are bounded and validated
on both sides; sessions expire on disconnection, with no capture or request replay.

The probe and transport logs contain event/state metadata, including bounded numeric native
window frames, answer scroll offsets, input-source identifiers, and modifier-key names, never
image pixels or question text. A paste check compares follow-up text with the copied mock
answer in memory and logs only the result. A transparent, nonactivating shield window beneath
the panels takes mouse events only while a panel is being resized. Saved reports
include tested-build SHA-256 hashes. Copy puts the canned answer on the system clipboard. The experiment has no Anthropic
requests and does not change the shipped extension's manifest or isolation boundary. A
nonactivating panel is not a focus-preservation guarantee; see the
[observed results](native-phase1-results.md) before drawing interaction conclusions.

## API key

Your API key is stored unencrypted in `chrome.storage.local` on your device and is sent
directly to Anthropic's API only from trusted extension contexts: the background service for
screenshot analysis, and the options page when you choose **Test key**. It never passes
through a third-party server. SnapScreen restricts local extension storage to trusted
extension contexts, and its content scripts (the code injected into web pages) neither read
nor receive the key. The native companion never receives it either.

This is defense in depth, not credential encryption: anyone who can access or copy your
Chrome profile may still be able to extract the key. Use a dedicated Anthropic key with an
appropriate spend limit, revoke it if the profile is lost or compromised, and remove it from
SnapScreen when it is no longer needed.

## Screenshots

Screenshots are sent directly to Anthropic for analysis and are not persisted by SnapScreen.
Anthropic retains API inputs and outputs under its own
[data-retention policy](https://privacy.claude.com/en/articles/7996866-how-long-do-you-store-my-organization-s-data).
Answer requests use Anthropic's prompt caching, so Anthropic keeps the conversation, including
the screenshot, cached for about 5 minutes after its last use; this makes follow-up questions
cheaper. A fallback screenshot remains only in memory: the background holds it until the exact
workspace claims its one-time capability, after which the workspace page owns it. Only small
source/workspace routing metadata is kept in `chrome.storage.session` so a service-worker
restart can reconnect the workspace.

## Injected UI isolation (In Chrome mode)

SnapScreen renders every injected interactive surface—the crop selector, result panel,
screenshot lightbox, composer, and toast—inside a full-viewport extension-origin iframe. The
iframe is mounted inside a closed-shadow outer `#snapscreen-ui-host`, so page CSS cannot
restyle the UI and ordinary page DOM APIs cannot locate the iframe or query its screenshot,
answer, composer value, lightbox, or controls. The host is removed when the UI is dismissed
so it does not affect page layout or captured pixels. The extension frame also remains
loadable on pages with a strict host Content Security Policy.

The isolated content script keeps capture and conversation state. It creates a fresh 32-byte
capability for each UI session, registers it with the background for its tab and top-level
document, places it in the hidden iframe URL fragment, and transfers one end of a
`MessageChannel` directly to that child with an exact extension `targetOrigin`. The exact
packaged child frame must claim that capability once before it acknowledges the channel;
claims expire and cannot be replayed or moved across tabs. Screenshot data, streamed answers,
composer submissions, and actions then travel only over the private port, never through
ordinary `window.postMessage`, page DOM events, or DOM attributes. Commands are validated and
buffered until attestation completes. Privileged actions such as opening Settings are sent
back to the trusted content controller rather than executed by the web-accessible frame, and
normal background commands reject extension-frame senders.

## Fallback workspace (In Chrome mode)

Pages that reject injection use a packaged workspace that is deliberately absent from
`web_accessible_resources`. Its exact top-level extension URL and tab must claim a one-time
session ID/nonce pair over a long-lived runtime port. Reconnects use a separate credential;
requests and streamed events are correlated and targeted to that authenticated workspace.
Workspace messages never supply the source tab ID, and the API key and Anthropic network
requests remain in the background worker.

## Limits of the isolation boundary

This boundary protects confidentiality and prevents page capture listeners from cancelling
the frame's keyboard/input handling, but it is not a tamper-proof browser surface. Chrome
exposes coarse pointer activity retargeted to the outer host (not the internal target or
text); tests confirm that parent `preventDefault()` and `stopImmediatePropagation()` do not
block the child click. A hostile page can still remove, move, cover, or navigate the outer
host and cause denial of service or attempt clickjacking. The packaged frame is the ordinary
build's only web-accessible resource; its icons, content script, workspace, and Settings stay
private, and `npm run test:browser` checks them with webpage resource probes. A page-created
copy of the frame remains inert because it cannot register or claim a legitimate session
capability, but the frame's stable URL still lets a webpage detect that the ordinary extension
is installed. A page can still imitate the extension visually with its own
HTML, so treat unexpected or context-sensitive prompts as untrusted, just as with any UI
rendered inside a web page.
