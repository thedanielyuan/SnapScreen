# Native-only extension and physical acceptance plan

Status: first four implementation milestones complete; physical acceptance and trace review remain pending. Updated 7 October 2026.

This document specifies a separate native-only SnapScreen extension build and the evidence
needed to assess its interaction behavior. Build separation, the native-only worker and
Settings, and initial package/browser regression checks are implemented. `build:extension-native`
produces `dist-native/`; `test:browser-native` checks its boundaries against the ordinary build.
Both variants are covered by the CI verification steps. The native-only gate now creates and
extracts a temporary ZIP, verifies its complete asset graph and checksums, and exercises the
extracted assets through mocked native session lifecycles and a real worker stop/restart.
Milestone three adds a separate native-only release archive command, explicit native-runner
variant selection, and original/fixture artifact identities. CI checks both variants explicitly.
Milestone four verified both variants and the extracted native-only release ZIP with the
packaged production companion, retained candidate archives and checksums, and completed the
security/distribution documentation. See the [candidate verification record](native-only-candidate-verification.md).
Physical acceptance remains a later milestone; this document does not record a completed
physical acceptance run.

## Objective and limits

Remove the current extension's injected UI and public resource fingerprints from a dedicated
native-only package. Preserve capture, answers, follow-ups, and trusted credential handling.
Measure whether the packaged companion preserves page focus and visibility and whether
native-directed input reaches the webpage.

The intended evidence-backed claim is:

> The native-only package injects no page UI and exposes no web-accessible extension resources.
> In the configurations and workflows listed in its acceptance report, the recorded page
> focus, visibility, and input behavior matched the reported results.

This is not a guarantee of universal undetectability. Detecting installation, detecting an
individual capture, observing generic input activity, and observing departure from a page are
different questions. Actual application or tab switching remains observable through normal
browser signals. Privileged browser extensions, managed-device software, and operating-system
monitoring are outside the ordinary webpage threat model.

The current native prototype evidence includes observable modifier keys and an unexplained
2.6-second focus/visibility loss. The completed packaged companion still requires physical
acceptance. See [Phase 1 results](native-phase1-results.md) and
[packaged acceptance](native-phase4-acceptance.md). Do not transfer prototype results to a new
package or silently exclude known leaks from a report.

## 1. Create a separate build variant

Keep the existing extension build and add a native-only variant with its own manifest and
background entry point. Both variants use the version in `package.json` and the same native
protocol version. Share implementation modules rather than maintaining two copies of the
capture, API, and native-session logic.

| Concern | Existing build | Native-only build |
| --- | --- | --- |
| Extension build command | `npm run build` | `npm run build:extension-native` |
| Extension output | `dist/` | `dist-native/` |
| Interface | In Chrome or companion | Companion only |
| Background entry | `src/background/service-worker.ts` | Dedicated native-only entry |
| Page content script | Included | Excluded |
| Injected frame and workspace | Included | Excluded |
| Web-accessible resources | Present | Absent |
| Extension archive command | `npm run package` | `npm run package:extension-native` |

`npm run build:native` already builds the Swift companion. Preserve that meaning; the new
extension command must have a distinct name. Build outputs must not overwrite one another,
and `dist-native/` is ignored by Git. `package:extension-native` writes the distinct archive
`release/snapscreen-native-only-<version>.zip` after validating its source and extracted assets.
It also prints the archive and aggregate extension SHA-256 checksums. Publication remains an explicit release action; the tag
workflow still publishes only the ordinary extension.

### Manifest and dependency graph

- Retain `activeTab`, `storage`, `nativeMessaging`, and the required Anthropic API host access.
- Retain optional local-file access if local-file capture remains supported.
- Remove `scripting`, content-script declarations, and every `web_accessible_resources` entry
  from the native-only manifest.
- Keep trusted Settings, action/shortcut declarations, extension CSP, and required local icons.
  Referencing an icon from the manifest does not require making it web-accessible.
- Remove the `?script&iife` content-script import from the native-only dependency graph.
  CRX currently adds its generated output to web-accessible resources; editing the source
  manifest alone is insufficient.
- Exclude the result-frame and workspace HTML entries from the native-only Vite configuration.
  Include its trusted Settings page and verify that it is correctly bundled.
- Inspect generated output and packaged archives. Do not hand-edit `dist/` or `dist-native/`.

Use `vite.config.ts`, `src/manifest.json`, and the existing background worker as the starting
points. Add variant-specific files where that makes accidental inclusion of injected code
harder. Keep all dependencies development-only and retain the hand-written Anthropic client.

### Native-only background and Settings

The dedicated worker must preserve:

- Trusted-context storage initialization and restricted Settings message handling.
- Real toolbar/shortcut activation, `activeTab` authorization, capture source checks, and
  activation/document-version tracking.
- Source invalidation on navigation or tab closure, respecting the existing distinction
  between selection and an already accepted crop.
- Native handshake validation, session/request identities, limits, cancellation, worker
  keepalive, and sanitized error reporting.
- API credentials, system prompt, and API history remaining in trusted extension contexts.
- Badge-based failures without injected UI, workspace creation, automatic Settings opening,
  or permission-dialog fallback during capture.

Native-only Settings retains key management, prompt/limits, companion setup information, and
the explicit **Check companion** action. It has no interface selector, and stale
`interfaceMode: 'extension'` storage cannot enable injection. Test this explicitly.

First-install setup is distinct from capture interaction. Existing onboarding behavior must
be documented and tested separately; an install-time Settings tab must not be mistaken for
an accepted capture workflow or reused as an in-session error fallback.

Do not change the native protocol just to add a build variant. If implementation does require
a protocol change, update both validators, both test suites, and the version handshake together.

## 2. Add automated package and behavior gates

`npm run test:browser-native` checks the build and a temporary ZIP extracted into a disposable
directory, then runs the browser against a copy of those extracted assets. The unmodified
assets are inspected before adding capture, native-transport, and API mocks. The existing
browser suite remains for the normal build. Both suites run in CI.

Milestone two coverage is implemented in:

| Gate | Coverage |
| --- | --- |
| `scripts/extension-native-package.mjs` and its Node tests | Manifest, strict CSP, bundled local asset graph, version/protocol alignment, excluded UI/test hooks, extracted-file SHA-256 equality, and negative controls |
| `scripts/extension-native-smoke.mjs` | Extracted Settings, compiled worker/Settings protocol handshakes, stale preferences, resource probes with accessible/inaccessible controls |
| `scripts/extension-native-lifecycle.mjs` | Real crop/SSE/conversation code with mocked transport: streaming, follow-ups, cancellation, Stop/Retry, provider sanitization, host failures, navigation/closure, concurrent sessions, cleanup, and CDP worker stop/restart without replay |
| `src/background/service-worker-native.integration.test.ts` | Source invalidation races through crop acceptance, session limits/supersession, stale identities, listener/timer cleanup, late answers, and separate first-install onboarding |

Shared protocol, provider-sanitization, storage, and exact-origin native installer tests remain
in the normal unit/native suites. The browser gate uses a disposable archive; milestone three
also provides the user-facing `package:extension-native` command and runner variant selection.
API responses are synthetic and the fixture blocks outbound API fetches. Worker restart is
a debugger-driven lifecycle diagnostic, not evidence of natural suspension, real host-process cleanup, genuine
toolbar/shortcut authorization, or physical focus/input behavior.

### Package checks

- The built manifest has no `scripting` permission, content scripts, or web-accessible resources.
- The package excludes the injected content bundle, result frame, and workspace.
- Settings and the worker load from packaged assets with the intended strict CSP.
- The archive version matches `package.json`; the native protocol matches the companion.
- No live-test hooks or acceptance shims appear in shipped artifacts.

### Webpage observations and functional checks

- From a controlled HTTP(S) webpage, probe the previous icon, content-script, and frame URLs
  using the known test extension ID. They must be inaccessible in the native-only package.
- Validate that probe with a known exposed resource in the normal build and a nonexistent
  resource as controls. A CSP that blocks every request must not create a false pass.
- Observe a static fixture page for extension-created DOM mutations and frames during native
  invocation, success, cancellation, and failure. Do not attribute unrelated dynamic page
  mutations to SnapScreen.
- Check that capture does not create or activate tabs, open Settings, or inject scripts on
  success or on missing, incompatible, disconnected, or malformed-host paths.
- Cover capture, crop acceptance, streaming, follow-ups, Stop, Retry, source invalidation,
  concurrent sessions, worker restart, and connection cleanup with mocked answers.
- Preserve credential isolation, provider-message sanitization, and exact-origin native-host
  registration tests.

Automated tests establish package properties and functional behavior. Headless browser tests,
mocked native transport, and programmatic UI input do not establish physical focus behavior.

## 3. Make runners select the extension explicitly

Implemented: the live, packaged, and physical native runners accept `--extension-dir`.
Omitting it selects the repository `dist/`, regardless of the current working directory.
An explicit relative path resolves from the current working directory; absolute paths are also
accepted. A shared validator checks the selected built manifest and variant, rejects missing or
invalid builds, and records the absolute path, variant, per-file SHA-256 hashes, and aggregate
hash. Native-only CI passes `--extension-dir dist-native` explicitly, with no fallback to `dist/`.
`npm run test:extension-artifacts` covers runner arguments, defaults and relative paths, invalid
variants, source/fixture identity, and native-only packaging regressions on any supported host.
The same checks run within `test:native` on macOS.

Reuse `scripts/native-companion-acceptance-fixture.mjs`. Its disposable fixture must preserve
the real action/shortcut callbacks, permission checks, capture, crop, native bridge,
conversation controller, and stream parser. Only its API responses and observation metadata
are instrumented. Keep mock fetches from falling through to Anthropic.

The fixture changes the extension key/name and wraps its worker. Record original extension
hashes, fixture hashes, and each modification separately. The live suite deliberately builds
a separate disposable `SNAPSCREEN_TEST_HOOKS` app for functional controls. Packaged and physical
runners keep the production native app unmodified and reject test-hook apps.

Use disposable browser roots for testing. Native host registrations currently authorize one
exact extension origin per browser-root registration; a separately installed native-only
extension may have a different ID. Do not assume both variants can share an existing
registration. Follow the [explicit variant-switch procedure](native-phase4.md#switch-extension-variants)
for a real installation; it removes the old exact-origin registration before adding the new
one. Keeping each variant in a separate browser user-data root avoids switching registrations.
A Chrome profile directory inside the same root does not isolate host registration.

## 4. Build and verify the candidate

Completed on 7 October 2026 for source commit `f120ea5fef71ecda7295d8d6ee783d059fb03b37`.
The [verification record](native-only-candidate-verification.md) identifies the retained archives,
extracted production app, checksums, environment, and passing automated checks. It records
local unsigned acceptance artifacts, not a published release or physical acceptance result.

Use macOS with Xcode command-line tools and Node.js 22 or later. Install dependencies with
`npm ci` and the test browser with `npx playwright install --no-shell chromium` when needed.

Run the repository's standard checks and native checks, then package the companion. These
commands already exist. Explicitly unset the live API key for the unit-test process:

```bash
npm run lint
npm run typecheck
env -u SNAPSCREEN_LIVE_API_KEY npm test
npm run build
npm run test:browser
npm run build:native
npm run test:native
npm run test:native-live
npm run package:native
npm run test:native-packaged
```

Keep paid live API tests disabled for this work. The model, beta headers, and request fields
need not change. Any separately requested paid check follows the repository's approval rule.

For the native-only candidate, also run:

```bash
npm run build:extension-native
npm run test:browser-native
npm run test:native-live -- --extension-dir dist-native
npm run test:native-packaged -- --extension-dir dist-native
npm run package:extension-native
```

Verify the extracted native-only extension ZIP as well as the build directory. Run packaged
companion tests with the candidate extension. Package both artifacts from the same reviewed
commit, record their checksums, and use the extracted production companion for physical trials.
Existing package commands print artifact paths; do not guess which local build was tested.

The default companion package is unsigned and intended for local acceptance. Signing and
notarization remain explicit opt-in. A later signed/notarized artifact requires its own
installation checks and an appropriate physical acceptance rerun.

## 5. Collect physical acceptance evidence

Follow [the existing physical acceptance procedure](native-phase4-acceptance.md). Extend it
for the selected build rather than replacing its raw-CDP collector with UI automation.
Do not enable focus emulation, alter page focus/visibility APIs, or synthesize the native input
used for acceptance. The human operator uses the real keyboard and pointer; the agent prepares
the candidate, operates the collector between trials, and reviews evidence.

From the repository root, select the native-only candidate explicitly:

```bash
npm run experiment:native-packaged -- \
  --extension-dir dist-native \
  --app "/absolute/path/to/extracted/SnapScreenCompanion.app" \
  --browser "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --trial-seconds 90 \
  --output "/absolute/path/to/acceptance-results"
```

The runner uses a disposable browser profile and host registration. It uses a dummy key and synthetic answers, records metadata,
and removes its temporary browser setup on normal cleanup. Everyday profiles and registrations
must remain untouched.

### Establish positive controls first

Pin the fixture extension, close setup dialogs, and focus the fixture's input. Record separate
physical trials for ordinary page clicking/typing, switching applications, and switching
Chrome tabs. Confirm the expected input, focus/blur, and visibility events appear. Stop if the
observer cannot detect these known changes; clean native traces would then be inconclusive.

### Record one clear workflow per trial

Use labels such as `trial shortcut-selection`. The runner provides five seconds to return to
Chrome, followed by the configured action window. Reports save automatically. Stay out of the
terminal until recording finishes, because returning to it causes a real application switch.

| Trial group | Physical actions and required observations |
| --- | --- |
| Activation | Shortcut and pinned toolbar; cold, warm, and concurrent sessions; confirm actual capture |
| Selection | Drag, tiny-drag/click cancellation, supported keyboard selection, and Escape; confirm crop outcome |
| Answer window | Move, repeatedly resize edges/corners, scroll, select text, Copy answer/code; verify native outcome |
| Preview | Open, move, resize, and independently close; verify return to the expected surface |
| Follow-ups | Type, select all, cut/copy/paste, multiline, modifiers, character limit, and IME where supported |
| Request states | Streaming, waiting, Stop, error, and Retry; verify correct behavior and absence of page fallback |
| Closing | Close button, Escape, Command-W, held close keys, and close while streaming; check stray events |
| Accessibility | Tab/Shift-Tab, Full Keyboard Access, and VoiceOver; record any focus tradeoff |
| Environments | Windowed/fullscreen, multiple windows/displays, mixed scaling, zoom, layouts and input methods claimed as supported |

Set `scenario slow` or `scenario error` before the corresponding trial. Treat `disconnect`
and `restart-worker` as lifecycle diagnostics, not physical interaction passes. A debugger-
attached worker restart cannot establish natural service-worker suspension behavior.

Repeat cold and warm workflows and fast resizing; one clean run is insufficient to resolve
an intermittent failure. Record repetition counts and all failures. Test additional OS,
browser, hardware, and display configurations before claiming support for them.

### Review each trace

A usable report requires `trial.startValid: true`, zero dropped entries in both observation
buffers, and timestamps covering the complete action. Pair it with the operator's observation
that the native action succeeded. Silence alone could mean the action never happened.

Record focus/visibility and input isolation as separate outcomes. Any unexpected transient
focus or visibility change fails focus preservation even if the final state recovers.
Expected changes in the application/tab-switch positive controls confirm the observer works.
Ordinary pointer activity deliberately directed at the webpage is separate from native-directed
input leakage.

Option/Shift activation events and Command modifier events are known limitations. Include them
in the evidence. They prevent a strict zero-observable-input claim even when text and other
native-directed keys remain private. Do not relabel such a trial as complete input isolation.

## 6. Report results and define completion

For each reviewed trial, record:

- Source commit, extension variant, original and fixture hashes, app/package hashes, and signing status.
- Browser/macOS versions, architecture, keyboard layout/IME, display/scaling, zoom, accessibility
  settings, and profile/incognito configuration where applicable.
- Trial label, action performed, visible native outcome, observation validity, and repetition count.
- DOM/resource checks, focus/visibility result, input leakage, anomalies, and linked trace filenames.
- A result of pass, fail, or inconclusive for each applicable criterion, with known limitations.

Use synthetic content only. Reports must not store screenshots, API keys, answers, follow-up
text, clipboard contents, or printable key values. Keep the existing metadata-only recording
contract. Raw collector reports remain `pending-physical-review` until reviewed explicitly.

Implementation is complete when both variants build independently, native-only output passes
the new package/resource checks, existing behavior remains covered, candidate packages pass
their automated suites, and installation/registration instructions match the new variant.
Update `docs/security.md`, `PRIVACY.md`, and `docs/chrome-web-store.md` for the variant's changed
permissions and boundaries. Extend CI to build and test both outputs explicitly.

Physical acceptance is a separate gate. It is complete only for the configurations actually
reviewed, with failures resolved or recorded as limitations against a narrowed claim. Deliver
the candidate archives, checksums, automated results, reviewed matrix, and remaining issues.
Do not turn a reduced-observability result into a universal detection probability or an
undetectability guarantee.

## Implementation order

1. Complete: build separation, manifests, native-only bootstrap, and Settings behavior.
2. Complete: extend build/resource/browser checks to extracted temporary archives and full mocked lifecycle coverage.
3. Complete: explicit native-runner variant selection, separate extension packaging, argument/variant checks, and artifact identities.
4. Complete: verified both variants and the extracted native-only candidate ZIP with the packaged production companion; retained archives/checksums and completed security/distribution documentation. See the [verification record](native-only-candidate-verification.md).
5. Pending: collect positive controls and physical trials with the human operator.
6. Pending: review traces, repair measured defects, repeat affected trials, and publish bounded results.
