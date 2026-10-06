# Phase 1 instrumented page

This local page measures signals available to ordinary webpage JavaScript. It does not hide
events, change browser focus APIs, remove site listeners, or synthesize user input. It makes
no API requests and loads no external resources.

Serve this directory over loopback HTTP using the experiment runner, or any static server.
Use a normal, foreground Chrome window with this page active. The input receives focus during
setup; verify that the `recording-start` entry reports `hasFocus: true`,
`activeElement.fixtureId: "page-input"`, `visibilityState: "visible"`, and `iframeCount: 0`.
The field's visual outline alone is not proof of document focus.

Before collecting native acceptance evidence, establish positive controls using actual OS
actions: switch to another application and verify `blur` plus `hasFocus: false`, return to
Chrome, then switch tabs and verify `visibilitychange` plus `hidden: true`. Restore the page
input and reset before each native trial. Retain the positive-control report separately.

Playwright normally enables CDP focus emulation, which can conceal the very signals this
experiment measures. A headless run validates the fixture's bookkeeping only. The collector
must record that focus emulation is disabled, and the positive controls must work in that same
headed browser session. Sending a disabling command through a separate CDP session is not
proof that every other session's override has been removed: Chromium's browser-side handler
maintains its own focus-emulation state and capture handle.
[Chromium emulation handler](https://chromium.googlesource.com/chromium/src/+/main/content/browser/devtools/protocol/emulation_handler.cc)
If the controls fail, native focus/visibility results are invalid, even when protocol and UI
functionality work. Repeat positive controls after reattachment, navigation/target changes,
or a collector configuration change.

## Collection API

The runner calls these methods through raw CDP `Runtime.evaluate` without opening DevTools or
clicking the page. Do not attach Playwright, or open/focus DevTools during a native-focus trial:
those change the experiment. For an already collected report, offline analysis is safe.

```js
// Evaluate these expressions through the raw collector, with Chrome physically foreground.
document.getElementById('page-input').focus();
globalThis.phase1Probe.reset();
globalThis.phase1Probe.mark('shortcut:cold:start');
// Perform a real OS interaction, then add a fixed action label.
globalThis.phase1Probe.mark('shortcut:cold:end');
globalThis.phase1Probe.snapshot();
```

The session runner exposes `trial`, `mark`, `reset`, `state`, `status`, and `save` commands,
plus setup and crash commands described in the [experiment README](../README.md). `reset` and
each trial start clear the page probe and the extension log together. Physically
focusing a terminal to enter commands creates a focus transition and must not be confused with
the native action under test. For physical testing, enter `trial <label>` instead:

```text
trial physical-toolbar-cold-01
```

You have 5 seconds to return to Chrome and click the fixture's page field. The runner then
resets only the in-memory probe log, records a start marker, and checks for a visible page with
document focus and `page-input` active. Perform the native action in the following 25 seconds.
The runner records an end marker and automatically saves `<label>.json` under
`experiments/native-phase1/build/results/`; do not return to the terminal until that window
ends. Choose a new label for every trial: automatic saves never overwrite an existing report.
An invalid starting state is saved with `trial.startValid: false` and cannot establish
acceptance. Overlapping trials and manual resets during a trial are rejected. Closing the
collector cancels a pending trial, so keep it running until automatic collection finishes.

For a physically performed application-switch control, start a timed trial, focus Chrome
during preparation, then switch to another application during the action window. For a
separate tab-switch control, switch away from the fixture tab during the action window.
Automation that directs input to an application or raises a window may not reproduce a
physical OS application switch; do not treat those commands alone as proof of that control.
Observe the expected page events and record how the action was performed.

When a separate process can send collector commands without changing the front application,
manual markers remain useful for fine-grained actions. Focus the fixture field with a real
click during setup, then reset through the collector without changing the front app.

`mark(label)` adds a timestamped marker. Use fixed action names, never user input or answer
text. `snapshot()` returns a JSON-compatible object and does not change the DOM. `reset()`
clears the log and restarts timing; it does not focus anything or alter page content. The
on-page **Reset and focus field** button is a convenience for manual setup and explicitly
updates the page before starting a new recording.

Each entry includes a monotonic elapsed time, epoch time for correlation with the native log,
and the current focus, visibility, iframe count, and viewport state. The probe records:

- DOM mutation metadata, including additions, removals, and attribute names, without values;
- window and element `focus`, `blur`, `focusin`, `focusout`, and visibility/page events;
- pointer, click, wheel, keyboard, input, composition, clipboard, and selection events;
- window/visual viewport resize and scroll;
- changes in sampled state, checked every 25 ms in addition to event listeners.

Samples cannot prove that no transition shorter than the sampling interval occurred; event
listeners provide additional evidence. Browser timer throttling can lengthen the interval.
DOM observation does not inspect shadow-root contents. The outer host of an injected shadow
root would still be recorded as an addition. Iframe count covers the light DOM.

The last 12,000 entries are retained in a bounded in-memory ring buffer. `droppedEntries`
greater than zero invalidates any claim that the entire trial had no signals: shorten and
repeat that trial. A mutation batch retains at most 30 record details and 10 added/removed
node descriptors per record, while keeping full batch and node counts. Printable key names,
key codes, input values, composition text, clipboard contents, attribute values, and image
pixels are never collected. Nonprinting control keys, event timing, coordinates, and fixture
element identifiers are collected. Use dummy text throughout the experiment.

Nothing renders during recording. **Inspect log** and **Download JSON** are explicit page
actions and necessarily appear in the log; each writes an end marker before its output action.
Prefer runner collection for native interaction trials. The downloaded file contains the
snapshot taken before the download click's effects; retain any earlier focus changes caused
by reaching the page controls when interpreting it.

Summarize one or more saved session reports (or downloaded probe snapshots) without printing
their raw contents:

```bash
node experiments/native-phase1/fixture/summarize.mjs experiments/native-phase1/build/results/trial.json
```

For native sessions, `sessions.mjs` groups a report by real invocation instead of by marker.
It judges focus against the state at invocation, separates the shortcut's activation modifier
events, and fails input isolation for any other page key, text, clipboard, or composition event,
any pressed-button pointer event, and any page click, press, or wheel event:

```bash
node experiments/native-phase1/fixture/sessions.mjs experiments/native-phase1/build/results/trial.json
```

The marker table groups each marker through the next marker, counts focus/visibility transitions,
DOM records, and page input/pointer/viewport events, and correlates native telemetry by its
extension receipt timestamp. It reports missing starts, dropped entries, and sampling limits.
It never labels the entire workflow as passed: compare these observations with the actual
actions and native state, and retain all not-tested rows. Ordinary page input is expected in
the control baseline but represents leakage when intended for the native window.
Pointer counts distinguish all recorded pointer/click/wheel events from those with `buttons > 0`.
Pressed-button events are highlighted with each marker interval's count and first/last UTC
and epoch timestamps. They expose pressed pointer activity that an undifferentiated hover count
could obscure. They are not automatically failures: page setup clicks legitimately appear in
the log. Attribute them to the native action using markers, native telemetry, and the physical
test procedure; a first/last timestamp range does not prove a continuous press throughout it.
Missing `environment.focusEmulation: false` produces an explicit invalid-focus-evidence warning;
the value itself is a configuration statement and still requires the positive controls above.

## Measurement matrix

Run separate short trials and record the exact macOS version, Chrome version, extension ID
and build, host arrangement, initial page state, monitor/scaling/zoom, input layout, and
activation route. Keep browser and native-window logs separate, correlating by epoch time
and action labels. The browser user agent alone may not reveal exact OS/browser versions.

| Trial | Actions and evidence to retain |
| --- | --- |
| Ordinary page use | Idle, click, type dummy text, select, paste, scroll; demonstrate that the probe sees expected page events. |
| Capture without overlay | Real extension shortcut and toolbar activation separately; capture, then stop. Record any activation signals. |
| Cold launch | Stop the host, invoke the actual extension route, and observe launch plus overlay appearance. |
| Already running | Keep the native connection/host alive and invoke again; record the same events. |
| Mouse selection | Move over overlay, drag a crop spanning colored cells, confirm; check transient focus changes and leaked pointer events. |
| Keyboard selection | Move/resize selection, confirm, then repeat with Escape; check leaked keys and page actions. |
| Answer display | Observe mocked arrival and streaming while the page field remains the initial active element. |
| Answer controls | Separately move, resize, scroll, Copy, and open/close screenshot preview. |
| Follow-up | Type dummy text, select text, paste, and test supported input methods separately; check focus and input leakage. |
| Cleanup and failures | Close, cancel, display a mock error, disconnect/restart; record focus, visibility, and unwanted page actions. |
| Environment variants | Repeat required trials in fullscreen, multiple Chrome windows/monitors, display scales, Chrome zoom, layouts, and input methods. |

For each result, retain `action`, `activationRoute`, `launchState`, `environment`, relevant
time bounds, observed page signals, native-window observations, and limitations. Label a row
**not tested** until its actual action has been performed. A mocked protocol exchange or
automated browser event is not evidence of real OS window focus behavior. Do not infer Chrome
116 behavior, fullscreen behavior, input-method behavior, or any other untested configuration
from a passing normal-window trial.

A trial fails the complete focus/privacy requirement if any transient document focus or
visibility transition occurs, or if native-directed text, keys, selection drags, or clicks
reach page handlers or cause page actions. A later restored state does not erase a failure.
Record shortcut/toolbar activation effects separately but include them when judging the
complete workflow. Mark incomplete or overflowed observations as inconclusive. Proceeding to
Phase 2 requires an explicit decision based on the measured scope, including follow-up input.
