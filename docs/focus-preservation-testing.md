# Focus preservation testing requirement

Requirement, updated 14 October 2026. The security section of `AGENTS.md` is the contract; this
document is how its focus clauses are verified. Change the two together. The tables identify
checks implemented in the repository, not a record that every listed environment has passed.

Section 9 records the passive-menu verification and the later error, timeout, notice and runner
verification on 14 October 2026, on macOS 27.0.1 (26A434). The latest automated focus suites pass;
the Chrome observations include an unexplained first fullscreen blur followed by four clean
runs. The broader environment and manual checks in section 4 remain unverified.

## 1. Requirement

SnapScreen must leave the application and webpage the user is working in focused at every moment
of its operation. Operation means everything from launch to quit: idling in the background, every
snip from the shortcut or the menu until its last window closes, every notice and failure, and
whatever another process does to SnapScreen. The one window that may take focus is Settings,
which the user opens on purpose, and it must hand focus back when it closes (R13).

Focus is measured at four layers, and every clause must hold at every sample:

| ID | Invariant | Observed from |
| --- | --- | --- |
| R1 | The user's app stays frontmost. SnapScreen's process is never `NSWorkspace.shared.frontmostApplication`, and no `didActivateApplicationNotification` names it. | WindowServer, any process |
| R2 | SnapScreen is never active: in its process `NSApp.isActive` is false and `keyWindow` and `mainWindow` are nil. | SnapScreen's process |
| R3 | The user's app stays active, its window stays key, and its first responder is the same object. `didResignActiveNotification` and `didResignKeyNotification` never fire there. | The user's app |
| R4 | A webpage notices nothing: `document.hasFocus()` stays true, `document.activeElement` is unchanged, no `blur` fires on the window or the focused element, `visibilityState` stays `visible`, and no `visibilitychange` to hidden fires. | The page |
| R5 | Keystrokes keep reaching the user's focused field, verbatim and in order, including while a SnapScreen menu is open. SnapScreen consumes nothing typed: the shortcut is a Carbon hot key, not a key monitor or an event tap; menus use pointer controls in passive panels. | The page's field |
| R6 | Every SnapScreen control acts on its first click, with no key window: selection drag, cancel click, Stop, Retry, Copy, the thumbnail, the preview's close button, the conversation's close button, text selection, title bar drag, edge resize, notice buttons, status-menu commands and context-menu Copy and Select All. Each leaves R1 to R5 intact except an explicit Settings action (R13). | SnapScreen's process and the user's app |
| R7 | A click aimed at the user's app lands there. The outside-click monitor reads the press and can't consume it, so the click reaches the field and the field keeps focus. | The page |
| R8 | Every capture-flow window, status menu and context menu for answer or error text is a `PassivePanel`: it can't become key or main, has `.nonactivatingPanel`, floats, `becomesKeyOnlyIfNeeded`, doesn't hide on deactivate, `canHide` is false, and joins all Spaces including fullscreen. It's shown with `orderFront(nil)`, sits above the user's window in WindowServer order, and never becomes key while it or another panel closes or is replaced. | SnapScreen's process and `CGWindowListCopyWindowInfo` |
| R9 | The user's content stays visible: the overlay is non-opaque, a fullscreen Space stays fullscreen, and the page's visibility never changes. | The page and the user's app |
| R10 | The overlay's crosshair shows while SnapScreen isn't frontmost (`BackgroundCursor`), only while the overlay is up, and the user's cursor returns after it. | The system cursor, any process |
| R11 | Nothing takes focus on SnapScreen's behalf: no Keychain password prompt during a request (the read fails instead), no Screen Recording prompt except from Open System Settings, and no activation from a LaunchServices launch by Finder, Spotlight, `open` or a login item. | WindowServer and the user's app |
| R12 | An activation SnapScreen didn't ask for is handed back after `handbackDelay` (150 ms) plus scheduling, under 500 ms end to end. The user's app sees at most one blur/focus pair, its first responder returns, and typing resumes. | WindowServer and the page |
| R13 | Settings, opened from the menu, a notice or reopening the running app, may take focus, as may the System Settings panes its buttons open. Closing Settings returns focus to the app that had it, with the same key window, first responder and page element, and leaves open passive panels visible. | WindowServer, the user's app and the page |

### Accepted exceptions

These are the only departures. Anything else fails.

- The shortcut's own chord: the Option and Shift keydowns of ⌥⇧S reach the app beneath; the S
  doesn't (`AGENTS.md`, known limitations).
- macOS's periodic alert for apps that capture the screen without the system picker can take
  focus for about two seconds on one snip. SnapScreen can't suppress it; a run that hits it is
  repeated, not failed.
- Settings (R13) and the handback (R12): at most one window blur/focus pair and one focused-element
  blur/focus pair for each deliberate round trip. The original first responder must return.
- An outside click may produce only the single blur/focus pair the same click would produce
  with SnapScreen absent (measured 2026-10-11). The automated click into the already-focused
  field requires zero focus events.

SnapScreen menus have no focus exception. Status commands and read-only text actions use
`PassiveMenu` instead of native `NSMenu` tracking. The original window must remain key and receive
every probe character while these menus are open, as well as after they close.

## 2. Measurement

Four observers run together. Polling at 10 ms is the floor, and notifications catch a loss shorter
than a sample.

- **A, SnapScreen's process.** The test-hooks build is that process. `NSApp.isActive`,
  `keyWindow`, `mainWindow` and the frontmost PID, sampled at 10 ms in `--focus` and 50 ms in the
  CI live test, plus each panel's `PassivePanel` properties at every stage.
- **B, the user's app.** The isolated focus target samples `NSApp.isActive`, `window.isKeyWindow`
  and first responder identity at 10 ms, and observes `didResignActiveNotification` and
  `didResignKeyNotification`. Failures are counted by reason: `inactiveSamples`, `nonKeySamples`,
  `responderSamples`, `resignActiveEvents` and `resignKeyEvents`. Its fullscreen style and count of
  fullscreen exits are checked throughout, including intentional Settings and handback transitions.
- **C, the page.** `document.hasFocus()`, `activeElement`, `blurCount`, `visibilityState`,
  `hiddenCount`, the field's text and pointer-event counts, read on demand. Window and field
  blur events are counted separately when checking an intentional focus transition.
- **D, WindowServer.** `CGWindowListCopyWindowInfo` ordering for R8, and
  `didActivateApplicationNotification` with timestamps for R1 and R12.

**Positive control for `--focus`.** Before anything is measured, the target opens a key window of its own and
confirms the page reports `!document.hasFocus()` and a blur. A run whose positive control fails
is invalid, whatever else it reports.

**Probe for `--focus`.** At every stage a real `x` keystroke is posted through WindowServer, and the field must
then hold exactly the expected string. This is R5, and the strongest single check of R3, since a
stolen key window swallows the character. Menus are held open during a probe: typing only after
they close cannot detect input they consumed while open. Outside-click delivery requires a
pointer-event increment in the target, not merely continued typing into a field already focused.

**Pass criteria.** Outside the accepted exceptions, every observer reports zero failures at every
stage. One bad 10 ms sample, one blur, one hidden transition or one missing probe character fails
the run with exit 1 and the observer's counters. Intentional Settings and handback transitions
allow only the bounded focus events above; restored focus alone cannot excuse repeated losses.
There is no tolerance or averaging for a passive interaction.

In `--focus`, input is posted with `CGEvent` to `.cghidEventTap`, so the pointer, the hot key and
the keystrokes pass through WindowServer as a person's do. The ordinary CI live run drives views
inside SnapScreen's process and never posts desktop input. Capture and the API are fixtures: no
run reads the user's key, captures their display or contacts Anthropic. The additional Chrome
protocol in section 6 observes a real browser during the ordinary live run; it has different
coverage from the `--focus` target.

## 3. Verification matrix

Each row is a stage of operation. `self` is `--self-test`; `CI` is `scripts/test-app-live.sh`,
which the `verify` job runs; `focus` is `--focus`; `full` is `--focus --fullscreen`.

| # | Stage | Observers | Covered by |
| --- | --- | --- | --- |
| S1 | LaunchServices launches SnapScreen with no key saved: it stays in the background and shows the passive notice | A B C D | focus, full |
| S2 | Idle in the background with its menu bar item | A B C | focus, full |
| S3 | ⌥⇧S, as a real Carbon hot key, opens the overlay | A B C D | focus, full |
| S4 | The status menu stays passive while typing reaches the target; Snip opens the overlay and a click cancels it | A B C D | focus (a fullscreen Space hides the menu bar) |
| S5 | Overlay up under a still pointer, crosshair without activation | A B C | focus, full; crosshair availability: self |
| S6 | A selection drag and release replace the overlay with the conversation | A B C D | CI, focus, full |
| S7 | Waiting, thinking and streaming; Stop; Retry; the answer finishes | A B C D | CI (stream, finish); focus, full (Stop, Retry) |
| S8 | Copy from a code block | A B C | CI, focus, full |
| S9 | The thumbnail opens the preview; its close button re-presents the conversation | A B C D | CI (open); focus, full (open and close) |
| S10 | Text selection in the answer, title bar drag, and an edge resize through the pointer shield | A B C | focus, full |
| S11 | An outside click dismisses the finished conversation and increments the user's field's pointer-event count | A B C | CI (in-process press); focus, full (real click and target counter) |
| S12 | A new snip replaces an open conversation and preview once its region is selected; no panel becomes key during the close | A B C D | CI, self; focus, full (real pointer input and target observers) |
| S13 | Close All Conversations from the menu | A B C D | focus |
| S14 | Settings from the menu, from the notice's Open Settings, and from reopening the running app; closing it returns focus with a conversation still open | A B C D | focus (all three); full (notice, reopen) |
| S15 | Another process activates SnapScreen; handback under 500 ms | A B C D | focus, full |
| S16 | Quit from the menu; a script's quit is refused | A B C | focus (menu); full (terminate); self (refusal) |
| S17 | Panel configuration of the overlay, conversation, preview, notice, pointer shield and passive menus | A | self; CI and focus for the panels they open |
| S18 | Keychain prompts are off during a request, and the read fails rather than prompt when they can't be | A | self (with fakes) |
| S19 | The answer's context menu stays passive while typing reaches the target; Copy and Select All work; outside dismissal delivers the click | A B C | focus, full |
| S20 | The conversation's own close button ends the session while the target keeps receiving input | A B C | focus, full |
| S21 | Authentication, rate-limit, server, provider, streamed API, network, malformed-stream and incomplete-stream errors; Retry recovers; a failed conversation can close without Retry | A B C D | CI, focus, full |
| S22 | Refusal after visible partial text clears the refused answer and its Copy button before Retry | A B C D | CI, focus, full |
| S23 | A timeout before response headers or during the response body becomes a retryable error; a body timeout preserves the visible partial answer | A B C D | CI, focus, full; injected transport errors |
| S24 | Missing API key and a nonprompting Keychain read failure stay in the passive conversation; Retry rereads the key and succeeds | A B C D | CI, focus, full; in-memory key access |
| S25 | The error-text context menu supports Select All and Copy without taking focus | A B C D | CI (in-process actions); focus, full (real clicks, typing with the menu open and outside dismissal) |
| S26 | The scheduled selection-expiry callback closes an overlay, or shows Session ended during cropping; late crop completion cannot revive the session | A B C D | CI, focus, full; injected session scheduler |
| S27 | Expected and unexpected capture failures show their production notices; close dismisses them without activating the app | A B C D | CI, focus, full |
| S28 | Denied Screen Recording shows its real Snip-path notice; close, initial auto-dismiss and hover pause/restart stay passive; only the action button dispatches Open System Settings | A B C D | CI, focus, full; injected notice clock and inert System Settings action |

`FocusFailureTests.swift` and `FocusNoticeTests.swift` run the same S21–S28 scenarios through
`FocusTestDriver` in all three modes. CI sends events directly to views and invokes button
actions. `focus` and `full` use real pointer input, independent target observers and typing
probes. Error context-menu Copy uses a private pasteboard. Retry checks both the resulting answer
and the unchanged request body; key failures make no request until Retry obtains the fixture key.

The time substitutions preserve production behavior under test: selection expiry invokes the
callback scheduled for 120 seconds, and the notice clock checks its eight-second initial
deadline, hover cancellation and three-second grace period after leaving. Timeout cases inject
`URLError(.timedOut)` into the transport before headers and after displayed response text. They
verify client mapping, failure UI, focus and Retry; they do not wait for or prove the real
transport's 60-second idle or ten-minute overall deadlines. The Screen Recording test calls the
real `AppDelegate.snip()` denial branch and clicks its real button, but substitutes an inert
action for opening System Settings. It proves dispatch requires that click; it does not measure
the actual System Settings window's focus transition.

Environments covered by the automated runs:

| Variable | Covered | Not covered |
| --- | --- | --- |
| Target | An isolated `WKWebView` app with a focused `textarea`; section 6 adds a repeatable Chrome recorder protocol around the ordinary live suite | Chrome's full real-input scenario matrix; Safari, Edge, Firefox and other native apps |
| Space | Normal window; fullscreen Space (`full`) | Stage Manager; a Space switch mid-snip |
| Display | The display under the pointer, 1 display in CI, 2× and 1× locally | Pointer on a secondary or negative-origin display; display removed mid-snip |
| Capture | Fixture image | Real ScreenCaptureKit path and macOS's capture alert |
| Keychain | Fakes in `self`; in-memory key in `focus` | A locked login keychain or an item that doesn't trust the build |
| macOS | 27.0.x | Other supported macOS versions and each later major version |

## 4. Gaps and required verification

Each gap must be closed by the method given, with the pass criterion of section 2 unless stated.

| Gap | Required verification | Pass criterion |
| --- | --- | --- |
| Real browsers and native targets | The Chrome recorder protocol and manual interaction round in section 6, with a frontmost-app observer for native apps | No blur, focus or visibility change beyond the accepted exceptions; every typed character arrives |
| Multiple displays | Run `focus` with the pointer, and so the target, on each display, including one with a negative origin | The overlay covers only that display; the conversation opens on it; observers clean |
| Display removed while the overlay or conversation is up | Manual: unplug the external display mid-snip | The session closes without SnapScreen activating |
| Real capture and the capture alert | The manual round, on a build with Screen Recording granted | The alert is the only focus loss; repeat the run |
| Locked or distrusting keychain | Manual: `security lock-keychain`, then snip | The conversation reports the keychain failure; no password dialog appears |
| Real transport deadline timing | Exercise `URLSessionTransport` with an unresponsive local server and an idle or indefinitely streaming response | The idle and overall timers cancel at their configured deadlines; S23 already covers focus after their mapped timeout error |
| Actual Open System Settings transition | Click the denied-permission notice's action during the manual round | System Settings takes focus only after the explicit click; S28 already covers passive display, dismissal and action dispatch with an inert substitute |
| Zoom by title bar double-click, where macOS is set to zoom | Add to `focus` if the gesture is kept | Observers clean |
| A sheet, popover or menu open in the user's app at ⌥⇧S | Manual | The sheet keeps focus; the overlay is usable |
| Space switch, Mission Control, sleep or wake, screen lock with the overlay up | Manual | SnapScreen never activates; the overlay cancels or survives without a focus change |
| Full Keyboard Access on; VoiceOver's custom actions | Manual | AX actions select and confirm without moving focus |
| Login item launch at login | Manual, after Open at login | No activation after login |

## 5. Procedure

Run in this order after any change to activation, panels, notices, the menu or Settings. The
focus runs post real input throughout each run, so ask the user first, and quit their copy,
since ⌥⇧S is exclusive.

```bash
pkill -x SnapScreen
```

```bash
swift build && swift test && scripts/build-app.sh
```

```bash
build/SnapScreen.app/Contents/MacOS/SnapScreen --self-test
```

```bash
scripts/test-app-live.sh
```

```bash
scripts/test-app-live.sh --focus
```

```bash
scripts/test-app-live.sh --focus --fullscreen
```

```bash
open build/SnapScreen.app
```

Preconditions for `--focus`: Accessibility approval for the terminal, which event posting
(`CGPreflightPostEventAccess`) and the menu bar item lookup (`AXIsProcessTrusted`) need; no
SnapScreen copy holding ⌥⇧S; and no earlier test-hooks copy running. If the script prints
`SnapScreen is already running.`, the duplicate live/focus launch fails with a nonzero exit and
nothing was tested: stop that copy, whose binary is under `build/test-hooks/`, not the user's, and
rerun. Keep hands off the keyboard and pointer during a run; the test refuses to post input unless
the target is in front.

Results require exit 0 and the exact completion line for the requested mode:
`SnapScreen test completed: live`, `SnapScreen test completed: focus`, or
`SnapScreen test completed: focus fullscreen`. `run-verified-test.sh` rejects missing or mismatched
markers and explicit failure output, even if the test process exits 0. The human-readable
`passed` line names the stages and check count. `test-live-runner.sh` exercises the runner's false
success cases on every invocation of the live script. A failed focus check reports the target's
`blurCount`, `hiddenCount`, `text`, `nativeFailures` and `nativeFailureReasons`. A failure in
`focus` with a clean CI run points at WindowServer-level behavior; one in CI points at panel
configuration or window ordering.

## 6. Chrome recorder and manual round for real browsers and native apps

### Repeatable Chrome recorder protocol

Use `scripts/fixtures/focus-recorder.html` in the installed Chrome application. It records window
and field focus events, visibility transitions, keystrokes and pointer presses in memory, with
no network requests or storage. Open the file as a normal local tab, using Chrome's native UI.
Do not attach an automation debugger or enable DevTools focus emulation: either changes the
conditions this protocol is intended to observe.

1. In a normal Chrome window, click **Start / reset measurement**. Wait at least 150 ms for the
   reset to finish. Confirm the visible report reads `focused: true`, `activeElement: "field"`,
   `visibility: "visible"`, with an empty event list.
2. Verify the recorder before testing SnapScreen. Focus Chrome's address bar with Command-L and
   return to the field; the report must record the loss and restoration of page/field focus.
   Switch to a temporary tab and back; the report must include `visibility hidden` and
   `visibility visible`. The **Positive control: move field focus** button provides an additional
   field-blur check. If any expected event is absent, the recorder run is invalid.
3. Run the ordinary `scripts/test-app-live.sh` with Chrome kept in front and its recorder field
   focused. A tool runner can start it without activating a Terminal window. For a manual run,
   enter `sleep 10 && scripts/test-app-live.sh` in Terminal, return to Chrome and reset the
   recorder within the delay. Leave Chrome untouched while the suite runs through the real
   windows, including S21–S28. The test's capture, API, errors and clocks remain fixtures.
4. Once the test windows have all closed, inspect and preserve the visible recorder report before
   bringing Terminal forward. Require no window/field blur or focus events and no visibility
   transitions since reset, with the field still focused. Then inspect the runner output and
   require exit 0 and `SnapScreen test completed: live`. A clean page alone does not prove that
   any SnapScreen test ran.
5. Put Chrome into its actual fullscreen Space through its native window control and repeat the
   positive controls, reset and ordinary live suite. Require the same clean report and runner
   marker, and confirm Chrome remains fullscreen. Restore the original Chrome window state and
   close only the fixture tabs created for this protocol.

These Chrome runs measure the real browser's focus and visibility during production panel
presentation, replacement, error, timeout and notice handling. The ordinary live driver sends
selection and hover events to SnapScreen's views and invokes button actions inside its process;
it does not send real mouse events through WindowServer or type into Chrome. Therefore it does
not establish Chrome-specific delivery of input to passive controls or continued typing while
menus are open. The automated `--focus` and `--focus --fullscreen` runs provide those real
`CGEvent` and typing checks against the isolated `WKWebView` target. Record Chrome and WKWebView
results separately, with browser/macOS versions, window mode and recorder positive controls.

### Manual interaction round

The tester sets the window state; the user performs the actions. A browser step uses a page like
the recorder above, with a focused `textarea` and listeners for `focus`, `blur`, `visibilitychange`,
`keydown` and pointer events. A native step uses an observer process that logs the frontmost app
and the target's AX focused window at 10 ms. Keep the terminal out of front.

1. Chrome, normal window, the page's field focused. Press ⌥⇧S, drag a region, release, and
   type a few characters while the answer streams.
2. Click Stop, Retry, Copy, the thumbnail, then the preview's close button, typing after each.
3. Right-click answer text, type while its context menu remains open, use Copy and Select All,
   then dismiss it with an outside click. Open the status menu and type while it stays open too.
   The original field must receive every character without losing its key window or focus.
4. Click the page's field: the conversation closes, and the recorder counts the click. Type again.
5. Chrome in a fullscreen Space: repeat steps 1, 3 (context menu) and 4.
6. Safari, normal window: repeat steps 1, 3 and 4.
7. Preview with a PDF and its search field focused: ⌥⇧S, select, release, type into the field,
   close with the conversation's close button.
8. Rebuild with `SNAPSCREEN_BUILD_NUMBER` set, reopen, snip once: no Screen Recording or Keychain
   prompt.

Pass: the recorder logs no blur, focus or visibility change beyond the accepted exceptions, every
typed character arrives, the observer never lists SnapScreen as frontmost, and fullscreen holds.

## 7. Traceability

| Requirement | Implemented by | Checked by |
| --- | --- | --- |
| R1, R2 | `.accessory` policy and `LSUIElement` (`main.swift`); `applicationDidBecomeActive` handback (`AppDelegate.swift`) | self (policy), CI and focus (observer A), focus (D) |
| R3, R4, R5 | R8, the Carbon hot key (`Hotkey.swift`) and pointer-only `PassiveMenu` controls | focus, full (observers B, C, probes with menus open) |
| R6 | `acceptsFirstMouse` in `SelectionView` and `NoticeButton`; `.activeAlways` tracking areas; `PointerShieldController` (`UI/Panels.swift`); passive menu controls | CI (view actions including failure Retry, notice buttons and error menus); focus (WindowServer interactions in section 3); remaining controls in section 4 |
| R7 | `SessionWindows.watchOutsideClicks` while the answer is complete; `PassiveMenu` dismissal monitors while its panel is visible; neither consumes outside clicks | CI (in-process); focus, full (real clicks and target pointer-event counts) |
| R8 | `PassivePanel`, `CompanionPanel` and `PassiveMenu`; `SelectionOverlay.make`; `SnipWindows.closeEarlier` after the new conversation shows | self (configuration, close order); CI and focus (`checkPassive`, `passive`, menu observers) |
| R9 | Non-opaque overlay; `.fullScreenAuxiliary` | focus (page visibility); full (fullscreen holds) |
| R10 | `BackgroundCursor`, enabled only while the overlay is up | self (availability); manual (cursor seen) |
| R11 | `KeychainStore.readWithoutPrompt` and `KeychainPrompts.disallowed`; `CGPreflightScreenCaptureAccess`; `QuitRequest`; the single-instance guard | self (prompt control, quit refusal); CI, focus, full (injected key failure and denied Screen Recording); focus (LaunchServices launch) |
| R12 | `AppDelegate.handbackDelay`; `ForegroundFocus.returnToPreviousApp` | focus, full (`yield`, handback under 500 ms, bounded window/field blur and focus counts) |
| R13 | `showSettings`; `settingsClosed`; `PassivePanel.canHide = false` | focus (synthetic Settings, then notice, menu and reopen); full (synthetic Settings, notice and reopen); bounded focus transitions and restored first responder |

## 8. Change control

- Any change to activation, panels, notices, the menu, Settings, `ForegroundFocus`,
  `handbackDelay` or `PassivePanel` requires `focus` and `full` to pass before merge, in addition
  to CI's `verify` job.
- A new window, control or entry point gets a row in section 3 and a stage in `focus` in the same
  change. A new way to take or hand back focus gets a requirement here and a clause in
  `AGENTS.md`.
- The accepted exceptions list only grows with a measurement that shows macOS leaves no
  alternative, recorded with the date and the macOS version.
- Rerun the full procedure on each major macOS release, and record the result in this document.

## 9. Verification record

On 14 October 2026, source revision `dc4675ca82e322c5019d21f9a4a64add7796e16b` passed on macOS
27.0.1 (26A434):

| Command | Result |
| --- | --- |
| `swift build` | Passed |
| `swift test` | Passed: 79 core tests |
| `scripts/build-app.sh` | Passed |
| `build/SnapScreen.app/Contents/MacOS/SnapScreen --self-test` | Passed: 325 checks |
| `scripts/test-app-live.sh` | Passed: 145 checks |
| `scripts/test-app-live.sh --focus` | Passed: 590 checks |
| `scripts/test-app-live.sh --focus --fullscreen` | Passed: 513 checks |

The focus runs verified typing while passive menus remained open, context-menu Select All and
Copy, delivery of the outside click, replacement of an open conversation and preview, the
conversation's close button, bounded intentional Settings and handback transitions, and retained
fullscreen mode. The target was the instrumented local `WKWebView` app; capture and API responses
were fixtures, and Copy used a private pasteboard. These results do not establish behavior in the
other browsers, real capture and Keychain states, display arrangements or system interactions
listed in section 4.

### Error, timeout, notice and runner verification

On 14 October 2026, the working tree on `fix/focus-test-coverage`, based on
`6ff6637`, was verified on macOS 27.0.1 (26A434) with Chrome 155.0.8059.40:

| Check | Result |
| --- | --- |
| `swift build` | Passed |
| `swift test` | Passed: 79 core tests; credit-spending live API tests skipped |
| `scripts/build-app.sh` | Passed, with the existing development signing identity |
| Production `--self-test` | Passed: 325 checks |
| Runner regressions | Passed: 21 checks, including zero-exit/no-marker and wrong-mode cases |
| Actual duplicate launches | `--live-test` and `--focus-test` each exited 1 with no completion marker; the wrapper preserved both failures |
| Ordinary live suite | Passed: 576 checks and the exact `live` completion marker |
| Normal real-input focus suite | Passed: 1,312 checks and the exact `focus` completion marker |
| Fullscreen real-input focus suite | Passed: 1,237 checks and the exact `focus fullscreen` completion marker |
| Chrome, normal window | Live suite passed 573 checks; recorder stayed focused on `field`, visible, with zero events |
| Chrome, first fullscreen observation | App checks passed 576 checks, but the recorder reported one field blur and one window blur; this observation did not pass |
| Chrome, four timestamped fullscreen runs | Live suites passed 579, 574, 572 and 573 checks; the recorder stayed focused on `field`, visible, with zero events cumulatively across all four runs |

Check counts include polling and therefore vary slightly between runs. The full build/core/app/
live sequence was run in order after integrating the new scenarios. The first new normal focus
run exposed an observation race: the denied-permission notice was checked before WindowServer
had presented it. The test now waits for its window number to appear, with focus observers still
running, before asserting window order. Normal and fullscreen focus runs then passed with all
S21–S28 scenarios enabled. Independent review also added pointer-monitor cleanup between
scenarios and guarded the shell regression suite against recursion if argument validation breaks.

Chrome was controlled through its native UI, without a browser debugger attached to the
recorder. In both window modes, focusing the address bar produced the expected window and field
blur, and visiting a temporary tab produced hidden/visible transitions. Each measurement began
after resetting those positive-control events. The first fullscreen observation reported blur
17.842 seconds after reset, while page visibility stayed visible. Its timing was insufficient to
attribute the event to SnapScreen, test exit or an external action; it is retained as an unexplained
observation, not discounted as a passing run. ISO timestamps were then added to the recorder.

The clean fullscreen measurement began at `2026-10-14T10:40:26.858Z`. The first rerun executed
from 10:40:32 to 10:40:44 UTC, followed by three repetitions from 10:42:00 to 10:42:35 UTC. The
recorder was not reset between those four runs; its final window/field focus and blur counters,
hidden/visible counters and event list were all zero, including the intervals after test exit.
These observations support focus preservation in the tested paths, but do not establish an
unconditional Chrome guarantee given the earlier unexplained event.

Chrome runs use the in-process live driver; WindowServer pointer and typing probes run against
the independent `WKWebView` target. Canvas LMS itself was not exercised. Transport errors and
notice clocks are controlled fixtures, and the real System Settings action is substituted, as
described in section 3. Chrome's original tab and normal-window state were restored, all test
processes were stopped, and the previously running production SnapScreen app was reopened.
