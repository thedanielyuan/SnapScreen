# SnapScreen native companion implementation plan

Status: Phase 1 complete; Phase 2 bridge implemented as an experimental explicit mode. Initial platform: macOS. Updated 6 October 2026.

Phase 1 outcome: the final prototype keeps page focus and visibility and keeps native clicks,
drags, scrolling, resizing, and typed characters away from the page in the tested setups.
Fullscreen resizing now uses native edges plus a pointer shield. Modifier keys still reach page
key handlers: the activation shortcut's ⌥⇧ and ⌘ used for native shortcuts. On 6 October 2026
the user accepted that limitation and approved Phase 2 on the narrowed claim; see
[Phase 1 results](native-phase1-results.md). Phase 2 adds the extension bridge and development
companion described in [native setup and implementation notes](native-phase2.md). Phase 3 UI
completion and polish, and Phase 4 packaged physical acceptance and signing, remain. The new
implementation has no additional focus-preservation claim until those interactions are measured.

Build a small desktop companion that displays the snipping overlay and answer window outside
the webpage. Keep screenshot capture, API credentials, and Claude requests in the Chrome
extension. First prove which interactions preserve page focus, then decide whether to migrate
the full interface.

The target is to remove SnapScreen's injected page interface and minimize observable changes
during use. **This plan cannot guarantee 100% undetectability on every page.** Focus and
visibility behavior must be measured for each supported workflow and platform. Passing those
tests establishes specific behavior under tested conditions, not universal invisibility.

## What changes for the user

The user installs both the Chrome extension and a macOS app. They invoke SnapScreen in Chrome,
select a region in the desktop overlay, and read the answer in a floating desktop window.
Follow-up questions and answer controls also live in that window if their interaction tests
pass. The page remains usable around the answer window.

The desktop window replaces the existing injected popup in native mode. Making the existing
popup non-modal is therefore **not a prerequisite**. That would be a separate usability change
only if we retain the extension-only interface for users without the companion.

## Existing signals to remove

| Current behavior | Relevant implementation | Native-mode target |
| --- | --- | --- |
| A branded host is added to the page DOM | [result-frame-host.ts](../src/content/result-frame-host.ts) | No content-script injection or page DOM changes |
| Page listeners can observe coarse pointer activity on that host | [extension-smoke.mjs](../scripts/extension-smoke.mjs) | No embedded interactive surface |
| Snipping and answer controls take focus | [snip-overlay.ts](../src/content/snip-overlay.ts), [result-panel.ts](../src/content/result-panel.ts) | Measure native interaction before promising focus preservation |
| The fallback workspace activates another tab | [service-worker.ts](../src/background/service-worker.ts) | No automatic workspace, tab, or window activation during native capture |
| The icon and UI frame are web accessible | [manifest.json](../src/manifest.json) | Remove unnecessary exposed resources when their consumers are retired |

Chrome's isolated content scripts still share the page DOM. Closed shadow roots protect UI
contents but do not conceal the outer host. Existing hostile-page tests primarily protect
confidentiality; they do not establish invisibility.
[Chrome content-script documentation](https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts)

## Phase 1 Prove the interaction model

Build a minimal Swift and AppKit prototype with a frozen-image selection surface, a sample
answer, Copy, a follow-up text field, and Close. Use mocked answers throughout this phase.
Connect it to an experimental extension path that captures without injecting UI. Include cold
app launch and the real extension activation path in the experiment.

Before building the prototype, decide whether the Chrome-launched native host owns the AppKit
windows or relays to a separate app. Use `chrome.runtime.connectNative()` with an installed
test host to exercise that process arrangement from Phase 1 onward. Include both cold launch
and an already-running companion; manually launching a panel alone does not test the complete
activation path. If the process arrangement changes later, repeat the interaction tests.

Investigate AppKit's non-activating panels. Apple's documented behavior is that they do not
activate their owning application. This alone does not guarantee unchanged Chrome document
focus, especially when a field accepts keyboard input.
[Apple nonactivatingPanel documentation](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel)

Instrument a test webpage before activation. Record timestamped DOM mutations, frame count,
`focus`, `blur`, `focusin`, `focusout`, `document.hasFocus()`, `document.activeElement`,
`visibilitychange`, viewport changes, and pointer and keyboard activity. Log browser and
native-window state separately so that a failure can be attributed to the actual action.

Compare against ordinary page use and capture without an overlay. A page may remain visible
while losing focus; these require separate measurements.
[Page Visibility API](https://developer.mozilla.org/en-US/docs/Web/API/Page_Visibility_API)

| Interaction | What must be established |
| --- | --- |
| Shortcut and toolbar activation | Whether activation itself exposes focus or input changes; test each route separately |
| Overlay appearance and region selection | Whether showing the surface, moving the pointer, dragging, and confirming affect the page |
| Keyboard region selection and Escape | Whether input stays private and dismissal avoids stray keys reaching the page |
| Answer arrival and streaming | Whether rendering updates leave the page's focus and visibility unchanged |
| Move, resize, scroll, Copy, and screenshot preview | Whether each control introduces focus, pointer, or visibility changes |
| Follow-up typing, selection, paste, and input methods | Whether text entry can work privately while meeting the focus requirement |
| Close, cancellation, errors, and app restart | Whether cleanup or recovery introduces a tab switch or focus transition |

Start with a normal Chrome window and a focused page text field. Extend to macOS fullscreen,
multiple Chrome windows, multiple monitors, different display scales, Chrome zoom, different
keyboard layouts, and supported input methods. Record exact macOS and Chrome versions; do not
assume Chrome 116 support follows from testing a newer release.

**Deliverable:** the prototype, reproducible tests, and a results table listing each action's
observed signals and limitations.

**Decision before Phase 2:**

- If the complete workflow preserves the required focus and visibility properties in the
  supported matrix, proceed with those narrowly defined claims.
- If only selection and reading pass, present the evidence and decide whether that reduced
  scope is useful. Do not silently remove follow-ups or describe the full workflow as passing.
- If selection itself causes unacceptable focus changes, stop the migration and revisit the
  requirement. A desktop app is not automatically a solution.

For a workflow to pass, native-directed text, keys, selection drags, and clicks must neither
reach page handlers nor trigger page actions. Any transient focus or visibility transition
counts as a failure, even if the original state returns before dismissal. Record activation
signals separately and include them when judging the complete workflow.

Do not patch the site's focus or visibility APIs, remove its event listeners, or synthesize
page input to conceal transitions. Those changes add observable behavior and cannot erase
events already recorded by the page.

## Phase 2 Build the extension and native bridge

Current implementation: Settings explicitly selects native mode, with **In Chrome** remaining
the default. Each native session owns one Chrome-launched AppKit host process and port, with
no separate app relay or local IPC. The host registration permits one exact extension origin.
The manifest uses split incognito contexts; local credentials and preferences are still
shared within a Chrome profile. Native sessions never inject page UI or automatically open a
workspace or Settings. The initial selection surface fits the frozen image in a native
window; it does not claim viewport alignment. Source navigation after crop acceptance keeps
the conversation alive, but every new capture requires another extension invocation.
The sections below preserve the design contract for further work.

Use Chrome Native Messaging between the service worker and a locally installed native host.
Add the `nativeMessaging` permission and restrict the host's allowed extension origins.
Keep the bridge private to the extension; a website should have no bridge endpoint.
Use `chrome.runtime.connectNative()` for the bidirectional stream. Chrome keeps its host
process running for the port's lifetime; `sendNativeMessage()` starts a host for each message
and accepts only its first response.
[Chrome Native Messaging documentation](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)

If the host relays to a separate app, authenticate peers on that local connection and reject
unknown clients. The host's `allowed_origins` does not secure this additional IPC boundary.
Bind every session and window to its originating native connection and browsing context;
commands and answers must never cross Chrome profiles or regular/incognito contexts. A shared
app must route explicitly rather than sending data to whichever Chrome window is active.

| Component | Responsibility |
| --- | --- |
| Extension background | Capture, session identity, image cropping, conversation state, limits, Claude requests, cancellation, and sanitized errors |
| Existing options page | API key and extension preferences |
| Native bridge | Version negotiation and bounded, validated message transport |
| macOS app | Region selection, answer rendering, follow-up input, clipboard controls, and window lifecycle |

Implement the session flow in this order:

1. The user invokes the extension. Bind a new session to the initiating tab, window, and
   document version. Preserve `activeTab` authorization and the existing checks for a tab or
   document changing during capture. A desktop-only hotkey must not be assumed to grant
   Chrome's `activeTab` permission.
2. Verify that the companion is available, then capture the visible tab. Native mode must
   bypass the injected controller, frame host, page toast, and workspace activation paths.
3. Send the frozen image and opaque session identifier to the app. The app displays it with
   a known image rectangle and returns a normalized crop rectangle. The background validates
   that rectangle and crops its own retained image. Send the accepted crop back to the app
   for preview, then release the uncropped image and its decoded buffers in both processes.
   Retain only the selected region needed for preview and conversation until the session ends.
4. Submit the crop through the existing Anthropic client. Stream sanitized answer events to
   the app. The API key never enters the native protocol.
5. Correlate follow-ups, Stop, Retry, and Close with the session and generation. Cancel and
   release retained images when the session ends or disconnects. Ignore late events.
6. Require a valid source and authorization for each new capture. Do not reactivate another
   tab automatically to satisfy a native recapture request.

Define native session lifetime separately from source-tab lifetime. Navigation or closure
before crop acceptance invalidates the pending selection. Once the crop is accepted, the
captured conversation and follow-ups remain usable if the source navigates or closes, but
recapture becomes unavailable until the user invokes the extension again on a valid source.
Native conversation ownership must therefore be independent of the existing per-tab generation
cleanup. Keep its source binding only for capture authorization and recapture eligibility.

Keep a native port open while its sessions are active and disconnect when the last session
closes. A native connection keeps the service worker alive, but it does not preserve worker
memory after a crash or restart.
[Chrome service-worker lifecycle](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle)

For the initial release, loss of the bridge connection or authoritative worker state expires
all sessions on that connection. Cancel outstanding requests where possible, release images
and conversation state on both sides, and leave only an interrupted-session notice in any
surviving app window. Disable session commands and require a fresh extension invocation.
Reconnecting creates a new connection identity and never restores an expired session or
automatically replays a capture, follow-up, or paid API request.

For initial geometry tests, use the image's displayed bounds and pixel dimensions. Accurate
alignment directly over Chrome's content area is a separate problem: browser-window bounds
are not the same as viewport bounds. Prove the mapping through toolbar sizes, zoom, Retina
scaling, fullscreen, and monitor changes without injecting a geometry probe into the page.
Document whether the supported experience is an aligned overlay or a fitted frozen image.

Create a versioned, discriminated native protocol with runtime validators on both sides,
explicit session/request identifiers, size limits, and disconnect timeouts. Reject malformed,
stale, cross-session, and unsupported-version messages. Crop requests refer to an existing
session; the app cannot nominate arbitrary tabs or request API credentials.

Chrome currently limits native-to-extension messages to 1 MB and extension-to-native messages
to 64 MiB. Bound image payloads and stream batches accordingly; return crop coordinates rather
than round-tripping a large cropped image. Keep screenshot and conversation data out of logs
and persistent files.
[Native Messaging protocol limits](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging#native-messaging-protocol)

Preserve the existing background keepalive, request timeout, model settings, prompt caching,
request limits, and provider-error sanitization. Move reusable conversation logic out of its
content-specific ownership where necessary, with one authoritative session controller.

## Phase 3 Complete the native interface and migration

Implement the tested snipping controls, streamed plain text and fenced code, code Copy,
Stop, Retry, preview, and follow-ups. Keep native activation behavior explicit; a window can
be non-modal while still taking focus. Preserve keyboard accessibility, and report any
conflict between an accessible interaction and the proposed focus guarantee.

The explicit Settings mode and failure routing are available in Phase 2. Refine native-mode
availability information during Phase 3. If the app is missing, incompatible, or crashes,
cancel cleanly and expose a status through the extension badge or existing native surface.
Do not silently inject the old popup, activate a workspace, or open Settings during a native
session. Installation, permissions, and opening Settings are separate user actions and can
change focus.

Decide how to distribute the existing extension-only interface:

- During the prototype, retain it as a separate explicit mode with its existing protections.
- For a native-only release, retire its unused injection paths and web-accessible resources.
- If both modes remain in one package, identify resources that the injected mode still needs.
  Selecting native mode does not remove static manifest exposures. Consider a separate build
  only if removing those exposures is a release requirement.

Chrome documents web-accessible resources as a potential extension fingerprinting surface.
Removing those resources reduces that surface; it does not prove the extension is impossible
to identify.
[Web-accessible resources documentation](https://developer.chrome.com/docs/extensions/reference/manifest/web-accessible-resources)

The existing popup non-modal project remains outside this migration's critical path. Any
retained UI frame must keep its capability-attested private channel, and the workspace must
remain absent from web-accessible resources.

## Phase 4 Verify and distribute

Add native-protocol tests, mocked extension-to-companion integration coverage, crop-mapping
tests, and native interaction tests. Extend the browser suite to assert that native mode
never injects its page host or opens a workspace, including failure paths. Preserve all
existing confidentiality tests for any retained extension-only mode.

Add a macOS CI job that builds the Swift/AppKit target and runs native protocol validation,
message-framing, and session-lifecycle tests. The current Ubuntu job and npm checks cover the
extension only. Define reproducible native build/test commands when introducing the target,
and document and run them in that job.

Add an integration fixture that installs a test host and performs a real `connectNative()`
launch, version handshake, streaming exchange, and disconnect. Use a stable test extension ID,
an exact allowed origin, and an absolute host executable path. Register the host for the test
browser's actual user-data directory and remove the fixture afterward; do not depend on the
developer's Chrome installation. Chrome, Chrome for Testing, and Chromium can use different
host registration locations.
[Native host registration](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging#native-messaging-host-location)

Repeat the Phase 1 observation matrix against the packaged app and built extension. Include
navigation during capture, expired permissions, missing hosts, incompatible versions,
disconnection, oversized messages, concurrent sessions across Chrome profiles and supported
incognito contexts, and service-worker restart. Verify that source navigation after cropping
preserves follow-ups while disabling recapture, connection loss expires sessions without
request replay, and uncropped image references and buffers are released after crop acceptance.
Keep real OS interaction acceptance separate from headless CI: automated page tests alone
cannot establish native-window focus behavior.

Prepare macOS signing, notarization, host registration, install, upgrade, and uninstall flows.
Document supported architectures, OS/browser versions, and compatibility between app and
extension versions. Windows and Linux need their own native implementation and evidence;
macOS results do not establish their behavior.

Update `docs/security.md`, `PRIVACY.md`, `docs/chrome-web-store.md`, and installation guidance
when implementing the bridge. The desktop process now receives screenshots, answers, and
follow-up text, so it becomes an additional trusted data recipient. Document the new
permission and retention behavior while keeping keys confined to trusted extension contexts.

Run the repository checks after implementation changes:

```bash
npm run lint
npm run typecheck
npm test
npm run build
npm run test:browser
```

Use mocked API responses for this work. Any paid live API check remains subject to the
repository's explicit user-approval requirement.

## Release criteria and first deliverable

A native release requires no page UI injection in native mode, preserved credential
boundaries, reliable capture/session handling, and published interaction-test results for its
supported platforms. A focus-preservation claim applies only to actions that passed the
matrix. Distinguish detecting installed resources, noticing a focus change, and identifying
SnapScreen use; they are different observations.

Ordinary page JavaScript is the observer covered by this plan. It makes no concealment promise
against screen sharing, other extensions, native monitoring software, or browser/OS inspection.
It also cannot prevent a site from making guesses based on pauses or other user behavior.

**First implementation deliverable completed: a macOS interaction prototype, an instrumented
test page, and the measured results.** The user accepted the modifier-key limitation and
approved Phase 2. The experimental bridge now coexists with the default extension interface;
full migration and distribution still depend on the remaining implementation and acceptance
work above.
