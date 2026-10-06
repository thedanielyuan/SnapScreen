# Phase 1 native interaction results

**Phase 2 decision (6 October 2026): proceed with a narrowed claim.** In the final rounds, selection, mock-answer streaming, edge
resizing, moving, scrolling, Copy, the screenshot preview, plain-text follow-ups, and Close kept
page focus and visibility with no DOM changes. Once the pointer shield's first-use delay was
fixed, no native-directed clicks, drags, scrolls, or typed characters reached the page. One
2.6-second focus and visibility loss in round 2 remains unexplained. **Strict input isolation
still fails for modifier keys.** The activation shortcut's ⌥⇧ and each ⌘ pressed for a native
shortcut such as ⌘V reached page key handlers as bare modifier events. The user accepted that
limitation for Phase 2. Several matrix environments remain untested (see
[Not tested](#not-tested)). These observations do not establish undetectability.

## Final build and product decisions

Final rounds ran on 6 October 2026, 19:08–20:24 Europe/London. They used the same macOS 27.0
(26A428), arm64, Chrome for Testing 149.0.7827.55 and raw-CDP collector as the earlier runs.
The user performed every action with their own mouse and keyboard; no CUA input was used. The
collector's `fullscreen`, `normal` and window-move commands (CDP `Browser.setWindowBounds`) set
up window state before a round, never during one.

The user set three interaction requirements during these rounds:

- Panels resize from their edges and corners like a normal window. The **Resize window ↘**
  content handle was removed.
- Releasing a selection drag submits it immediately, with no Enter or button. A click or a drag
  under 5 points cancels, matching the extension's `MIN_CROP_SIZE`.
- Keyboard region selection, Escape cancellation, and the Cancel selection button are not
  required. The prototype still has them; they were not physically tested.

The final build is native host SHA-256 `02acdb70d98d2db129748635bffe0d15e0022b14af8c2e12a61e3eb05e7859ba`
with experiment extension `background.mjs` `0e2ff070…fa76`, `protocol.mjs` `b7ead9d6…2e52`,
`config.mjs` `5f6dc75b…f838`, and `manifest.json` `8eb871a1…84cf`. Rebuilding the current
source reproduces that host hash.

## Fullscreen resize leak: cause and fix

Round 1 tested the content handle in a maximized Chrome window. One fast handle drag again gave
the page **36 pressed-pointer events** (12 each of `pointerover`, `pointermove`, `pointerout`,
`buttons=1`), like the earlier border-resize failure. Each over/out pair coincided with a large
frame step while the window edge lagged behind the pointer. Selection drags that left the
selection window caused no page events. The leak therefore follows **reshaping a window under
the pointer**, which briefly exposes Chrome, not a captured drag leaving the window.

The fix keeps AppKit's native edge resizing and adds a **pointer shield**. This is a
screen-sized, non-opaque, nearly transparent (alpha 1/255), nonactivating panel ordered directly
beneath the experiment panels. It ignores the mouse, so the page stays usable around the panels,
except while a panel is pressed within 8 points of its edge or is live-resizing. Then it is the
hit-test target under the reshaping window. It never becomes key, and Chrome reported no
visibility change while it was present. The first version created and ordered the shield at
resize start. In true fullscreen that was about 20 ms too late once. The final build places the
shield when each panel appears and only toggles its mouse handling.

| Round | Build | Chrome window | Resize evidence | Pressed page pointer events |
| --- | --- | --- | --- | --- |
| 1 | Content handle | Maximized, built-in display, DPR 2 | 7 handle drags | **36**, during one fast drag |
| 2 | Edge resize, shield at resize start | Maximized, built-in, DPR 2 | 3 live resizes; pointer left the window 21 times | 0 |
| 2b | Same, plus release-to-submit | Maximized, built-in, DPR 2 | 1 live resize | 0 |
| 3 | Same as 2b | macOS fullscreen, external, DPR 1 | 2 live resizes; 63 exits | **3**, 22 ms after the first raise |
| 4 | Final | macOS fullscreen, external, DPR 1 | 1 live resize; 20 exits | 0 |

Round 4 is a single session with one resize. Repeat fast fullscreen resizes before relying on
the fix. Fullscreen attempts made through Chrome's own controls in rounds 1–2b produced a
maximized "Fill" window instead. The collector's `window` output confirmed real fullscreen
(`windowState: "fullscreen"`) in rounds 3 and 4.

## Final rounds by session

Times are UTC. Every session started from the real ⌥⇧S shortcut; its ⌥⇧ key events reached the
page in all of them. Focus is judged against the state at invocation.
[Generated session summary](../experiments/native-phase1/results/2026-10-06-final-rounds-summary.md).

| Round | Session | Actions | Focus / visibility | Input isolation |
| --- | --- | --- | --- | --- |
| 1 | 18:08:28 cold | Selection drag leaving its window, answer, Copy, Close | Pass | Pass |
| 1 | 18:09:07 warm | Handle resizes, follow-up, Copy, preview, Close | Pass | **Fail**: 36 pressed hover events |
| 2 | 18:18:46 cold | Three edge resizes, follow-up, Copy, preview opened and closed by its own button | **Fail**: hidden and blurred for 2.6 s at 18:19:20.9 | Pass |
| 2 | 18:19:28 warm | Selection, answer, Close | Pass | Pass |
| 2 | 18:21:16 warm | Selection, answer, Close; page field not focused at start | No change from start | Pass |
| 2b | 18:30:16 cold | Release-to-submit, resize, moves, scroll, Copy, ⌘V twice, ⌘A twice, three follow-ups, Close | **Fail** after ⌘Tab at 18:30:34 | **Fail**: ⌘ (`Meta`) key events |
| 3 | 18:37:22 cold | Click on the selection, which cancelled | No change from start | Pass |
| 3 | 18:37:24 warm | Selection, two follow-ups, Copy, preview, two resizes, Close | No change from start | **Fail**: 3 pressed hover events |
| 4 | 19:23:44 cold | Click on the selection, which cancelled | Pass | Pass |
| 4 | 19:23:46 warm | Selection, fast resize, three follow-ups, four Copies, preview, Close | Pass | Pass |

In the round 2 failure, the native answer panel resigned key 91 ms before the page blurred.
Chrome reported no window-focus change, and no native action was recorded at that moment. Its
trigger was not identified; treat it as unresolved. The round 2b focus loss followed a page
`Meta` key-down and Chrome reporting no focused window. That matches a ⌘Tab to another app
mid-session, a user action. Before round 2b, an application switch blurred the page and a tab
switch produced `visibilitychange` to hidden, as expected. In rounds 3 and 4, leaving and
returning to Chrome's fullscreen Space between steps produced the same blur, hidden, and visible
transitions.

## Modifier keys reach the page

In round 2b each ⌘ pressed for ⌘V or ⌘A in the native follow-up field produced a page
`keydown`/`keyup` with `key: "Meta"`: four presses and three releases, the first about 110 ms
before the native key-down. The V and A keys, the pasted text, and the typed text never reached
the page. The field received both pastes, which matched the copied answer in memory, and both
select-alls. Chrome stayed focused throughout. Modifier presses aimed at the native window are
therefore page-observable, as are the activation shortcut's ⌥⇧. In round 4 the native panel also
recorded ⌥ releasing while it was key, at the same time as the page's activation `keyup`.

No page ⇧ or ⌥ events occurred during any follow-up typing. However, builds before the final one
did not log native modifier presses, and the final round's follow-ups used none. Whether ⇧ and ⌥
leak like ⌘ is therefore unknown. The final build logs native modifier transitions
(`<surface>.modifier_<name>_<down|up>`), so a repeat can attribute them. Avoiding the leak would require activating the companion app, which blurs the
page, or a system-wide event tap, which needs an Accessibility permission. Neither was tried.

## Other final results

- **Copy:** two in-memory comparisons showed the follow-up field's pasted text matched the copied
  answer. No clipboard contents were logged.
- **Preview:** opened and closed with its own close button in rounds 2, 3 and 4
  (`preview.closed`, page unaffected). This resolves the earlier missing standalone-close event.
- **Selection:** release-to-submit works. A click without a drag cancels as designed.
- **Follow-up typing:** follow-ups of 2–13 characters reached the native field only. Each round
  used the U.S. keyboard layout.
- **Hover:** unpressed page hover events occurred while the pointer was physically over the page.

## Not tested

- The pinned toolbar button. The Extensions-menu route lost page focus in the earlier automated
  run, and the shortcut exposes ⌥⇧.
- Native-logged ⇧ and ⌥ in the answer window, answer text selection (requested in round 3, but
  no `answer.text_selected` event was recorded), and preview resizing.
- Chrome zoom, multiple Chrome windows, moving between displays or scales during a session,
  keyboard layouts other than U.S., and input methods.
- Physical host crash and restart. These have automated and unit coverage only.
- Chrome 116, other macOS versions, and packaged or signed builds.

## Phase 2 decision

On 6 October 2026 the user chose to **proceed with a narrowed claim**. SnapScreen's native mode
makes no page DOM changes and keeps page focus and visibility. Native clicks, drags, scrolling,
resizing, and typed characters do not reach the page in the tested setups. Modifier keys,
including the activation shortcut's, remain observable. The alternative was to hold Phase 2
until the modifier leak was resolved, at the activation or permission cost described above.

Early Phase 2 work should re-measure ⇧ and ⌥ in the answer window, the pinned toolbar route, and
fast fullscreen resizes, because the claim's wording depends on them. Do not describe the
complete workflow as passing strict input isolation.

## Final verification

- Repository lint, TypeScript check, 327 unit tests, production build, and browser smoke test
  pass. The shipping extension is unchanged.
- Experiment extension: 17 Node tests pass. Native host: 79 self-checks pass, covering protocol
  and framing, bounded data, fitted geometry, release-to-submit minimum, edge detection,
  modifier names, input-source tokens, paste comparison, and pressed-pointer tracking.
- [Round evidence](../experiments/native-phase1/results/) is metadata only:
  `2026-10-06-round1-content-handle-evidence.json`, `-round2-edge-shield-`, `-round2b-workflow-`,
  `-round3-fullscreen-`, and `-round4-fullscreen-fix-evidence.json`. Each holds every page
  event from 1.5 seconds before each invocation to the session's end, and that session's native
  and extension records. Repetitive pointer-move and answer-chunk records are counted, not kept.
  Each also holds the tested-build hashes and the source report hash. No paid API request was
  made.

## Earlier runs on previous builds

The sections below record the same day's earlier runs. They are kept as written. The content
resize handle they describe was replaced by edge resizing with the pointer shield above.

### Fullscreen: focus preserved, resize input isolation failed

Chrome entered macOS fullscreen before the handoff marker. Its View menu subsequently showed
**Exit Full Screen**, confirming the mode; that inspection happened after the report was
saved. Both physical sessions began with the original page input focused. The viewport stayed
2560×1296 at DPR 1 and visual scale 1; the report header retains the earlier startup viewport.
See [fullscreen evidence and source/build hashes](../experiments/native-phase1/results/2026-10-06-physical-fullscreen-evidence.json).

| Session (Europe/London) | Recorded actions | Result |
| --- | --- | --- |
| 18:44:39–18:44:54 | Selection, mock answer, 6-character follow-up and reply, Copy, preview, answer Close | Focus and visibility preserved; shortcut modifiers and unpressed hover/motion observable |
| 18:44:58–18:45:09 | Selection, answer, resize, move, Close | Focus and visibility preserved, but pressed-pointer events reached page handlers during resize |

The second session delivered **36 trusted page pointer events with `buttons=1`**: 12 each of
`pointerover`, `pointermove`, and `pointerout`, from 18:45:04.326 to 18:45:06.239. They fall
between native pointer-down at 18:45:04.272 and pointer-up at 18:45:06.518, alongside 197
native resize notifications. The preceding page pointer state was unpressed; no page
pointer-down/up, click, text input, DOM mutation, or focus/visibility change occurred during
the native sessions. Thus this is recorded native-drag observability, not evidence of a page
click or resulting page action. Both collectors report zero dropped entries.

The native window used AppKit's built-in `.resizable` border. System resize tracking or Chrome
hover updates when window edges expose the page are possible mechanisms; the recording does
not distinguish them. Native frames and page coordinates use different coordinate spaces,
and browser position was captured only at report time, so exact per-event hit-testing is not
established. The first subsequent blur occurred about 5.825 seconds after final Close with
Chrome window-focus loss.

The candidate build replaces answer border resizing with a labelled **Resize window ↘**
native content handle, whose mouse-down/drag/up handlers update the frame. It also supports
arrow-key resizing when the handle is focused. This retains resizing while testing
different input ownership. Apple's [mouse-event guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingMouseEvents/HandlingMouseEvents.html)
documents that handler pattern; it does not guarantee isolation from Chrome. The candidate
must be physically remeasured before being described as a fix. No page event suppression or
additional permissions are involved.

### Physical geometry retry

The repaired recorder captured a complete physical session at **18:40:11–18:40:36 Europe/London**.
See [geometry evidence, source hash, and tested-build hashes](../experiments/native-phase1/results/2026-10-06-physical-geometry-evidence.json).
Chrome's original page input stayed active, the document stayed focused and visible, and no
focus/visibility transition or DOM mutation was recorded from invocation through Close.

| Action | Recorded evidence | Page result during session |
| --- | --- | --- |
| Selection and mock answer | Native drag/confirmation and completed stream | Focus and visibility retained |
| Scroll | Two native scroll inputs after answer completion; clip origin changes from 0 through 184 points and returns to 0 (including elastic overscroll) | No page wheel events |
| Resize | Frame changes from 640×552 to 921×603 points, including intermediate sizes | No page clicks/drags or focus changes |
| Move | Later origin changes with fixed 921×603 size, ending at (396, 1659) | No page clicks/drags or focus changes |
| Follow-up, Copy, preview | An 8-character follow-up and response, four Copy handler calls, preview shown | No page text input or clipboard events |
| Close | Answer Close and preview cleanup with parent | Focus retained through cleanup |

Page pointer motion/hover and the shortcut's Alt/Shift events were still observable. Copy
handler telemetry does not verify clipboard contents. No independent preview Close was
recorded. A page heading click 1.13 seconds after Close blurred the input while the document
remained focused. Document blur followed about 3.47 seconds after Close, alongside Chrome
window-focus loss. These later events are preserved separately.

This run used a 2560×1440 screen configuration, 1200×707 viewport, DPR 1, and visual viewport
scale 1 on the same macOS 27.0/Chrome 149 versions. Earlier physical runs used 1728×1117 at
DPR 2. The recordings cover two configurations, but do not establish behavior while changing
displays/scales or the physical arrangement of the monitors. All 458 page and 716 extension
entries were retained without drops. This resolves the missing physical movement/resize/scroll
evidence below for that normal-window run. The later fullscreen resize failure is recorded
above; zoom and the rest of the supported matrix remain open.

### Physical controls tests

The user performed another cold/warm pair using the same browser, OS, viewport, and display
configuration. See [controls evidence and source hash](../experiments/native-phase1/results/2026-10-06-physical-controls-evidence.json).
The browser was raised before the handoff marker; no CUA input occurred during these sessions.
The marker itself was unfocused while the user read instructions. Both actual invocations
began with the original page input focused and the document visible.

| Physical session (Europe/London) | Recorded actions | Focus result |
| --- | --- | --- |
| 18:30:14–18:30:37 | Selection, answer, Copy, a 5-character follow-up, further Copy, Close | Focus preserved through the follow-up response; page blur at 18:30:32.556, before later Copy and Close |
| 18:30:55–18:31:06 | Selection, answer, preview shown, Copy, answer Close | Page focused and visible throughout |

The first session's blur coincided with native key resignation and Chrome reporting no focused
window. Its cause is not identified; the complete session does not pass. Native key focus
returned later, but document focus did not return before Close. In the second session, page
blur occurred about 20.48 seconds after Close, alongside another Chrome window-focus loss.
No visibility transition, DOM mutation, page text input, clipboard event, wheel event, or
native-directed click/drag was recorded within either capture-to-Close interval. Shortcut
modifiers and some pointer motion/hover remain page-visible. Both collectors report zero drops.

Copy ran 29 times across the sessions. Its telemetry confirms the handler ran; clipboard
contents were not read back or verified by pasting. Preview display is confirmed, but no
standalone `preview.closed` event was recorded: closing the answer also cleans up its preview.
No native scroll or resize events were recorded. Window movement is also unverified: the
recorded move events coincide with initial centering; preview construction can emit
`answer.moved` before the preview window is assigned its role. These are not evidence of
physical title-bar dragging. The user separately confirmed that the window visibly moved and
resized and the answer text scrolled. That functional report is retained; the existing
telemetry does not corroborate it. Their measured focus result therefore remains unverified,
as does independent preview closure.

The subsequent instrumentation repair records each surface's frame after it is shown and
tracks frame changes through notifications and a 100 ms timer in normal and event-tracking
run-loop modes. Answer clip-view origin changes are recorded independently of wheel events,
covering scrollbar and keyboard scrolling. Baselines are distinct from changes; preview
windows have a stable surface identity before setup. Parent-driven preview cleanup has its
own event. Reports also identify the exact tested build by file hashes. Geometry observations
do not prove user causation, and polling cannot rule out transitions between samples. The
repair was verified by the physical geometry retry above; it does not retroactively validate
the missing data in this earlier run.

### Physical follow-up tests

After the automated runs below, the user performed the actions with their actual keyboard and
mouse. The collector stayed on raw CDP; no CUA input was used during these trials. See the
[physical evidence and source hashes](../experiments/native-phase1/results/2026-10-06-physical-evidence.json).
The tests used the corrected Edit-menu build on the same macOS/Chrome versions, a 1728×1117
screen, 1200×707 viewport, DPR 2, and visual viewport scale 1.

Physical Chrome window-focus changes matched page blur/focus events within a few milliseconds.
The control recording contains five losses and four returns; it does not identify which app
was foreground. This addresses the missing real Chrome focus-switch calibration in the
automated runs. It does not prove a cause for those earlier automated transitions.

| Physical session (Europe/London) | Evidence | Focus and input result |
| --- | --- | --- |
| 18:19:48–18:19:57 | Drag, confirm, mock answer, one 2-character follow-up and response | Page focused and visible throughout; no page text/input/click/drag events |
| 18:20:09–18:20:22 | Drag, confirm, mock answer, follow-ups of 4, 1, and 1 characters with responses | Page focused and visible throughout; no page text/input/click/drag events |

The first subsequent blur occurred about 1.68 seconds after its follow-up completed, alongside
native key resignation and Chrome window-focus loss; its Close happened later. The exact
action/app causing that departure is not logged. In the second session, Close followed the
last response by 91 ms; page blur occurred another 1.64 seconds later with Chrome window-focus
loss, followed by hidden visibility. Those later departures are retained separately, not
counted as transitions during native typing or streaming. Three additional submissions while
streaming were rejected; no paid request was involved.

Both sessions exposed the shortcut's Option/Shift presses/releases to the page. Hover and
pointer-movement events also occurred; without native window/pointer geometry they cannot
all be attributed to outside-panel movement. Neither selection drags nor follow-up clicks,
typed characters, or submission keys appeared in the page log. No DOM mutation or iframe
changes were recorded in the measured native intervals. Logs report zero dropped entries.

This supports a narrow claim about the observed physical selection and short-follow-up flow,
not the complete interaction matrix. Longer editing, physical paste and input methods,
clipboard-content verification, independent preview closure, scroll, window movement/resize, direct pinned-toolbar activation, and broader
platform/display coverage remain to be established. The historical automated observations
below are retained rather than overwritten.

### Deliverable and environment

The [prototype and run instructions](../experiments/native-phase1/README.md) include a Swift
AppKit native host, separate unpacked experimental extension, instrumented page, metadata
collector, and tests. All answers are mocked. The shipping extension is unchanged.

Run on 6 October 2026, macOS 27.0 (26A428), arm64, Chrome for Testing 149.0.7827.55. Chrome
launched the window-owning host through `connectNative()` using a temporary profile and an
exact allowed extension origin. Cold host PID 36297 was reused for warm captures; explicit
shutdown followed by a new shortcut invocation launched PID 36407. The fitted screenshot is
not aligned over the original browser viewport.

The browser initially reported a 2560×1440 screen at DPR 1. After setup, it reported 1728×1117;
all entries from the ordinary-page baseline onward had a stable 1200×707 viewport at DPR 2,
visual viewport scale 1, and zero page scroll. This is one observed configuration, not a
multi-display or scale-transition validation. Chrome 116 compatibility was not tested.

Evidence: [complete metadata observations](../experiments/native-phase1/results/2026-10-06-observations.json)
and [generated interval summary](../experiments/native-phase1/results/2026-10-06-summary.md).
The initial run has 152 retained page entries and 259 extension/native records, with zero
dropped entries. The [corrected editing rerun](../experiments/native-phase1/results/2026-10-06-editing-rerun.json)
and its [summary](../experiments/native-phase1/results/2026-10-06-editing-summary.md) are separate.
No screenshot pixels or entered text are in these files.

### Observations

The table describes the **initial build**, before the editing fix below. Each row is an
interval bounded by explicit probe markers. Native telemetry confirms actions
where noted. “No recorded change” describes this automated run and is not a physical-input
acceptance result. In all interaction intervals after the controls, the page remained visible;
there were no DOM mutation records, new iframes, viewport changes, or automatic new page tabs.

| Action | Observed page signals | Native/functional evidence | Assessment |
| --- | --- | --- | --- |
| Ordinary page typing | 35 keyboard/input/selection events; focus retained | Dummy text entered in page field | Input logging control works |
| Capture-only shortcut | No recorded focus, input, or DOM change | Screenshot captured; no native connection | Baseline established for automated input |
| Cold shortcut and selection appearance | No recorded focus, visibility, or input change | Real action callback → handshake → screenshot → native selection | Bridge and cold launch work; focus acceptance pending |
| Selection drag | No page pointer/input events | `selection.drag_start` and `selection.drag_end` | Native selection works; physical drag acceptance pending |
| Keyboard selection, Enter, answer stream | No page keyboard/input events or focus changes | Move, resize-selection, confirmation, 14 answer deltas and completion | Functional, with no recorded page leakage |
| Follow-up typing | No page input or focus events | 27 native key-down/edit records, populated native field | Functional; physical typing/IME acceptance pending |
| Select-all, paste, follow-up submission | No page clipboard/input or focus events | Submission retained the original 27-character question; paste did not replace it | **Editing bug found; repaired and retested below** |
| Copy and answer scroll | No page clipboard, wheel, input, or focus events | `answer.copied`, `answer.scroll`, scrollbar moved | Controls work |
| Screenshot preview and its Close | No page events or focus changes | `preview.shown`, `preview.closed`; crop displayed | Preview works; exact visual crop calibration incomplete |
| Answer move and resize attempts | No page signals | Pointer events, but no matching native moved/resized events | **Inconclusive action execution** |
| Answer Close | No page input or focus events | `answer.closed`; session becomes idle; same host remains | Cleanup works |
| Warm shortcut | No page input or focus events | Second selection, same host PID, no new handshake | Warm process reuse works |
| Escape cancellation | No page Escape/input event | `selection.cancelled`; session removed | No recorded stray key |
| Open Chrome Extensions menu | Input blur, focusout, window blur; `hasFocus=false`; still visible | Real toolbar menu opened | **Fails strict focus requirement** |
| Invoke from that menu | Window/input focus and focusin restore `hasFocus=true` | Selection appears on same host | Restoration does not undo the earlier failure |
| Diagnostic shutdown and cold restart | No page focus/input/visibility change | Old port closes; next real shortcut gets a new PID | No capture replay or tab activation |
| Terminate host during selection | No page focus/input/visibility change | Session expires, connection closes, error status/badge | No injected/workspace fallback |

The menu-induced focus loss began at epoch milliseconds `1791305732458` and focus returned at
`1791305743935.3`, about 11.48 seconds later. Both transitions are retained. This tests the
**unpinned Extensions-menu route**; a directly pinned toolbar button remains untested.

### Editing repair and rerun

The initial AppKit app had no Edit menu, so Cmd+A/Cmd+V did not perform their normal text-field
actions. Added standard responder-chain Select All, Cut, Copy, Paste, Undo, and Redo commands.
In a fresh browser/host session, the native accessibility state confirmed selected text, then
the replacement pasted text **before** submission. The extension received 23 characters and
streamed the follow-up. Native `followup.edited` also confirms an edit in the paste interval.

That rerun began with the page field focused. At epoch `1791306164591.1`, input/window blur and
focusout changed `hasFocus` to false. Selection confirmation followed at `1791306167069.1`,
about 2.48 seconds later. Focus remained false through typing, paste, and submission, while
visibility remained visible and page input/DOM logs remained quiet. The exact transition
trigger is unresolved: the run included app-targeted CUA observation and input. This is a
recorded strict-focus failure for the run, not evidence that adding the Edit menu caused it.
The initial build's silent native intervals do not validate the corrected build.

### Limitations of the earlier automated focus result

An initial exploration used Playwright's headed browser, which enables
`Emulation.setFocusEmulationEnabled(true)`. Its focus readings were discarded. The final
runner launches the browser directly and uses raw CDP only to read probe data and mark
intervals. It never attaches through Playwright or sends an Emulation command. Page focus
and visibility APIs and listeners are left intact.

Browser-focus and tab-switch controls produced blur/`hasFocus=false` and
`visibilitychange`/hidden transitions, so those probe paths work. However, CUA attempts to
switch applications (Cmd+Tab, clicking another app's title, raising its window) did not verify
a real application focus switch and did not produce page blur. The automation can target app
input without reproducing the physical switching behavior being tested. Native telemetry
reported key-window and activation changes, but those are separate observations and cannot
replace a successful OS focus control. Consequently, zero recorded transitions in the native
rows cannot establish the requested focus guarantee.

Remaining physical tests can use the runner's timed `trial <label>` mode: return to Chrome and focus
the field during the five-second preparation interval, perform the action during the following
25 seconds, then inspect the automatically saved result. The manual sessions above instead
used continuous recording, with focused starting states and native event boundaries identified
afterward. Establish app-switch and tab-switch positive controls for each new environment;
repeat both cold/warm shortcuts and the remaining controls without app-targeted automation.

Still untested: independent preview closure, clipboard contents, answer text selection, input methods and
keyboard layouts, multiple browser windows, display/scale transitions, browser zoom,
repeated physical trials across that broader matrix, older Chrome/macOS versions, and packaged/signed distribution.
Missing/incompatible host and malformed messages have unit coverage, not OS acceptance results.

### Verification

- Repository lint, TypeScript check, 327 unit tests, production build, and browser smoke test pass.
- Experimental extension: 16 Node tests pass, including source invalidation, superseded capture,
  malformed/oversized messages, bounded geometry telemetry, missing host, warm/cold lifecycle,
  and no UI fallback.
- Native host: 61 checks pass for protocol/framing, bounded data, fitted geometry,
  geometry observation baselines/change classification, and content-resize frame math.
- Real Chrome-to-host connection, screenshot capture, mock stream, follow-up, disconnect,
  and cold restart were exercised; no paid API request was made.

Physical selection and follow-up evidence supports continuing Phase 1 testing, but fullscreen
border resizing currently fails the native-input isolation requirement. Resolve that failure
or explicitly decide a narrower supported workflow. Complete the remaining physical controls
and supported matrix, and decide explicitly whether
page-visible shortcut modifiers and the menu-route focus loss meet the intended requirement.
Do not silently narrow the original workflow or treat these runs as approval for the full
companion.
