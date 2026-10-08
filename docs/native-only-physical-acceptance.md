# Native-only physical acceptance record

Priority 1 is partially complete. Physical testing stopped at the operator's request on
8 October 2026 (Europe/London), and the remaining matrix was then skipped. Full acceptance
is not established, and no claim extends to a workflow or configuration marked Skipped
below. The shortcut's modifier-key events are a documented limitation; see priority 2 of the
[page observability plan](page-observability-improvements.md). Preparation on 7 October
verified the retained candidate and started an isolated Google Chrome session. The retained
extension and companion artifacts were unchanged throughout these trials.

## Candidate and collector

The [candidate record](native-only-candidate-verification.md) identifies the original
archives. All three archive checksums still match `SHA256SUMS`; the native-only extension
and production app match their recorded file hashes. The unchanged companion passed
318 production self-checks and contains no test hooks.

| Item | Identity |
| --- | --- |
| Native-only extension content | `6e0180d96e2af8bc9b7468e5207174aacbb5d0dcac60353aa5a17a65413338f7` |
| Production app content | `d7f7a690ac52fc9ba87c9f6ee7f6c94aed5599f1879ffa1ad367af0757abd5e5` |
| Current browser | Google Chrome 154.0.8037.98 |
| macOS / architecture | 27.0 (26A428) / arm64 |
| Assigned shortcut | Option-Shift-S |
| Observation | Raw CDP pipe; no Playwright attachment or focus emulation |
| API transport | Synthetic responses; external worker fetches blocked |

The repository collector previously blocked the PNG data URL that production cropping
fetches to obtain a Blob. The collector now decodes those local bytes without delegating
to network fetch. This repairs the disposable fixture only. Regression tests cover the
exact Blob bytes/type, string and Request inputs, blocked external/non-PNG URLs, invalid
base64, and absence of content in metadata. A browser regression exercised the retained
bundle's crop, downscale, and streamed answer paths with synthetic content and passed.

Evidence is retained locally under
`release/native-only-candidate-2026-10-07/physical-acceptance/priority-1-session/`:

- [Preflight and artifact hashes](../release/native-only-candidate-2026-10-07/physical-acceptance/priority-1-session/preflight.json)
- [Browser crop regression](../release/native-only-candidate-2026-10-07/physical-acceptance/priority-1-session/browser-crop-results.json)
- [Collector setup](../release/native-only-candidate-2026-10-07/physical-acceptance/priority-1-session/setup.json)
- [Stopped session and cleanup](../release/native-only-candidate-2026-10-07/physical-acceptance/priority-1-session/session-status.json)

These ignored local files must be retained alongside this record. Setup snapshots and
automated regressions are not physical acceptance passes.

## Earlier partial evidence

An earlier physical shortcut capture and follow-up used these same retained artifacts.
Its [review](../release/observability-assessment-2026-10-07/physical-acceptance-repaired/native-workflow-02-review.json)
records the operator confirming both synthetic answers appeared. During the 17.732-second
native session, the observer recorded no page text input, DOM mutation, or focus/visibility
loss. Invocation modifier events and pointer movements remained observable. A blur
2.433 seconds after close has no established cause, so clean post-close behavior is not
demonstrated. This used manual marks rather than a complete timed trial.

Earlier controls were incomplete or mixed with a native invocation. Repeat separate clean
page-input, application-switch, and tab-switch controls before accepting new native trials.
Do not convert the earlier partial result into a pass for the current browser or environment.

## Current review matrix

Each trial must follow the [physical procedure](native-phase4-acceptance.md). Require a
recorded timed trial with a valid focused-input start, complete start/end coverage, zero
dropped entries in both buffers, and the operator's visible result. Allow at least five
seconds after native close before the trial ends, and remain in Chrome until recording
finishes. Score focus preservation and input isolation separately; retain every modifier
event and transient focus/visibility change.

Later trials use a local audio helper: one ping after a valid collector start, and two
finish chimes after the report is saved. The helper only observes collector output and
plays sounds; it never changes page focus or synthesizes input. Its source hash and cue
timestamps are saved beside each affected report. Do not press the probe's Reset button
during a timed trial: a reset erases coverage even when the reported drop count stays zero.

| Workflow | Status |
| --- | --- |
| Page click and typing control | Passed: [trace review](../release/native-only-candidate-2026-10-07/physical-acceptance/priority-1-session/control-page-input-01-review.json); valid 45-second window, 5 clicks and 90 input events, zero drops, no native activity; operator confirmed visible text |
| Application-switch control | Passed: [trace review](../release/native-only-candidate-2026-10-07/physical-acceptance/priority-1-session/control-application-switch-01-review.json); observed window blur/focus, zero drops, no native activity; operator confirmed application switching |
| Tab-switch control | Passed on retry: [trace review](../release/native-only-candidate-2026-10-07/physical-acceptance/priority-1-session/control-tab-switch-02-review.json); valid start, hidden/visible transitions, zero drops, no native activity; operator confirmed tab switching. First attempt retained as invalid because it started hidden |
| Shortcut capture and close | [Valid repeat reviewed](../release/native-only-candidate-2026-10-07/physical-acceptance/priority-1-session/native-cold-shortcut-close-02-review.json): operator confirmed correct crop, completed answer and close. Focus preserved across the recorded window and 21.7-second cleanup tail; strict input isolation fails because Option/Shift events reach the page |
| Pinned toolbar capture and close | [Valid repeat reviewed](../release/native-only-candidate-2026-10-07/physical-acceptance/priority-1-session/native-toolbar-close-02-review.json): operator confirmed correct crop, answer and close; focus preserved, no native-directed text or pressed-pointer input observed, 32-second cleanup tail. Unpressed pointer events remain visible |
| Independently confirmed cold host launch | Observed in [follow-up trial review](../release/native-only-candidate-2026-10-07/physical-acceptance/priority-1-session/native-followup-copy-01-review.json): exact candidate process absent immediately before scheduling, followed by toolbar invocation, handshake and capture |
| Selection, keyboard adjustment, cancellation | Skipped |
| Follow-up submission | [Partial review](../release/native-only-candidate-2026-10-07/physical-acceptance/priority-1-session/native-followup-copy-01-review.json): two protocol answers completed with no page events through the submitted follow-up; later webpage paste was intentional. This run did not include a recorded close |
| Native clipboard, multiline editing and limits | [Latest trace review](../release/native-only-candidate-2026-10-07/physical-acceptance/priority-1-session/native-code-copy-paste-01-review.json) has complete timing and close, with no page paste/text events; intended paste contents were not confirmed before the operator stopped. Clipboard correctness, multiline editing and limits remain unverified |
| Moving, native edge resize, scrolling, selection and both Copy controls | Skipped |
| Preview open/move/resize/independent close | Skipped |
| Waiting, Stop, error and Retry | Skipped |
| Concurrent sessions and cleanup | Skipped |
| Escape, Command-W, held keys and close during streaming | Skipped |
| Fullscreen, multiple windows/displays, scale and zoom | Skipped |
| Alternate layouts, IME, Full Keyboard Access and VoiceOver | Skipped |

Record keyboard/input method, display arrangement/scaling, browser zoom, and accessibility
settings with the operator's observations. Collector startup geometry can become stale;
use each trial's actual starting state. No support claim extends to an untested configuration.
The operator described the current setup as their usual configuration; exact layout, input
method, display arrangement/scaling, zoom, Full Keyboard Access, and VoiceOver settings
remain unverified. Do not infer defaults from that description.

The first shortcut trial began with the page body active rather than its text field and
is diagnostic only. The first toolbar trial lost its starting marker and most page coverage
when the probe reset; it also mixed multiple sessions. Both raw reports and invalid reviews
are retained. The complete repeat trials above are the evidence used for their narrow claims.
The collector exited normally and removed its disposable profile. A subsequent process
snapshot found no remaining acceptance Chrome process or retained candidate companion process.

## Collector change validation

Lint, typecheck, all 448 project unit tests, a fresh ordinary build, and browser smoke passed.
The unit run required `--exclude 'release/**'`: plain `npm test` discovers an earlier saved
Node test in the ignored evidence directory and reports that it contains no Vitest suite.
Both paid API tests remained skipped. The acceptance and extension-artifact Node suites
passed all 36 tests. The retained-bundle browser crop regression also passed; it observed
no Anthropic network attempts and left the original extension files unchanged.
