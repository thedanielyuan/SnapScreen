# Focus preservation testing requirement

Requirement, 13 October 2026, for SnapScreen at `main` (`03550ce`) plus the working tree's live
test additions: Stop, Retry, text selection, move and resize in `--focus`, and the focus target's
resign notifications. The security section of `AGENTS.md` is the contract; this document is how
its focus clauses are verified. Change the two together.

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
| R5 | Keystrokes keep reaching the user's focused field, verbatim and in order. SnapScreen consumes nothing typed: the shortcut is a Carbon hot key, not a key monitor or an event tap. | The page's field |
| R6 | Every SnapScreen control acts on its first click, with no key window: selection drag, cancel click, Stop, Retry, Copy, the thumbnail, the preview's close button, the conversation's close button, text selection, title bar drag, edge resize and notice buttons. Each leaves R1 to R5 intact. | SnapScreen's process and the user's app |
| R7 | A click aimed at the user's app lands there. The outside-click monitor reads the press and can't consume it, so the click reaches the field and the field keeps focus. | The page |
| R8 | Every capture-flow window is a `PassivePanel`: it can't become key or main, has `.nonactivatingPanel`, floats, `becomesKeyOnlyIfNeeded`, doesn't hide on deactivate, `canHide` is false, and joins all Spaces including fullscreen. It's shown with `orderFront(nil)`, sits above the user's window in WindowServer order, and never becomes key while it or another panel closes or is replaced. | SnapScreen's process and `CGWindowListCopyWindowInfo` |
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
- Settings (R13) and the handback (R12): one blur/focus pair each.
- An outside click that dismisses a conversation produces the single blur/focus pair the click
  would produce with SnapScreen absent (measured 2026-10-11).
- Menu tracking: while any menu tracks, the menu bar item's or a right-click menu in a panel,
  AppKit makes the front app's window resign key without deactivating the app, and a page doesn't
  blur. Measured 2026-10-14 on macOS 27.0.1: the menu bar item's menu cost one resign event and
  about 550 ms non-key, with the page focused and visible throughout. The window must be key
  again the instant the menu closes. R3's key-window clause is evaluated outside menu tracking;
  R1, R2, R4 and R5 apply throughout.

## 2. Measurement

Four observers run together. Polling at 10 ms is the floor, and notifications catch a loss shorter
than a sample.

- **A, SnapScreen's process.** The test-hooks build is that process. `NSApp.isActive`,
  `keyWindow`, `mainWindow` and the frontmost PID, sampled at 10 ms in `--focus` and 50 ms in the
  CI live test, plus each panel's `PassivePanel` properties at every stage.
- **B, the user's app.** The isolated focus target samples `NSApp.isActive`, `window.isKeyWindow`
  and first responder identity at 10 ms, and observes `didResignActiveNotification` and
  `didResignKeyNotification`. Failures are counted by reason: `inactiveSamples`, `nonKeySamples`,
  `responderSamples`, `resignActiveEvents` and `resignKeyEvents`.
- **C, the page.** `document.hasFocus()`, `activeElement`, `blurCount`, `visibilityState`,
  `hiddenCount` and the field's text, read on demand.
- **D, WindowServer.** `CGWindowListCopyWindowInfo` ordering for R8, and
  `didActivateApplicationNotification` with timestamps for R1 and R12.

**Positive control.** Before anything is measured, the target opens a key window of its own and
confirms the page reports `!document.hasFocus()` and a blur. A run whose positive control fails
is invalid, whatever else it reports.

**Probe.** At every stage a real `x` keystroke is posted through WindowServer, and the field must
then hold exactly the expected string. This is R5, and the strongest single check of R3, since a
stolen key window swallows the character.

**Pass criteria.** Every observer reports zero failures at every stage. One bad 10 ms sample, one
blur, one hidden transition or one missing probe character fails the run with exit 1 and the
observer's counters. There is no tolerance and no averaging: the requirement is at all times.

Input is posted with `CGEvent` to `.cghidEventTap`, so the pointer, the hot key and the keystrokes
pass through WindowServer as a person's do. Capture and the API are fixtures: no run reads the
user's key, captures their display or contacts Anthropic.

## 3. Verification matrix

Each row is a stage of operation. `self` is `--self-test`; `CI` is `scripts/test-app-live.sh`,
which the `verify` job runs; `focus` is `--focus`; `full` is `--focus --fullscreen`.

| # | Stage | Observers | Covered by |
| --- | --- | --- | --- |
| S1 | LaunchServices launches SnapScreen with no key saved: it stays in the background and shows the passive notice | A B C D | focus, full |
| S2 | Idle in the background with its menu bar item | A B C | focus, full |
| S3 | ⌥⇧S, as a real Carbon hot key, opens the overlay | A B C D | focus, full |
| S4 | Snip from the menu bar item opens the overlay, the menu period costing only key-window status; a click cancels it | A B C D | focus (a fullscreen Space hides the menu bar) |
| S5 | Overlay up under a still pointer, crosshair without activation | A B C | focus, full; crosshair availability: self |
| S6 | A selection drag and release replace the overlay with the conversation | A B C D | CI, focus, full |
| S7 | Waiting, thinking and streaming; Stop; Retry; the answer finishes | A B C D | CI (stream, finish); focus, full (Stop, Retry) |
| S8 | Copy from a code block | A B C | CI, focus, full |
| S9 | The thumbnail opens the preview; its close button re-presents the conversation | A B C D | CI (open); focus, full (open and close) |
| S10 | Text selection in the answer, title bar drag, and an edge resize through the pointer shield | A B C | focus, full |
| S11 | An outside click dismisses the finished conversation and lands in the user's field | A B C | CI (in-process press); focus, full (real click) |
| S12 | A new snip replaces an open conversation and preview once its region is selected; no panel becomes key during the close | A | CI, self |
| S13 | Close All Conversations from the menu | A B C D | focus |
| S14 | Settings from the menu, from the notice's Open Settings, and from reopening the running app; closing it returns focus with a conversation still open | A B C D | focus (all three); full (notice, reopen) |
| S15 | Another process activates SnapScreen; handback under 500 ms | A B C D | focus, full |
| S16 | Quit from the menu; a script's quit is refused | A B C | focus (menu); full (terminate); self (refusal) |
| S17 | Panel configuration of the overlay, conversation, preview, notice and pointer shield | A | self, CI, focus |
| S18 | Keychain prompts are off during a request, and the read fails rather than prompt when they can't be | A | self (with fakes) |

Environments covered by the automated runs:

| Variable | Covered | Not covered |
| --- | --- | --- |
| Target | An isolated `WKWebView` app with a focused `textarea` | Chrome, Safari, Edge, Firefox, native apps |
| Space | Normal window; fullscreen Space (`full`) | Stage Manager; a Space switch mid-snip |
| Display | The display under the pointer, 1 display in CI, 2× and 1× locally | Pointer on a secondary or negative-origin display; display removed mid-snip |
| Capture | Fixture image | Real ScreenCaptureKit path and macOS's capture alert |
| Keychain | Fakes in `self`; in-memory key in `focus` | A locked login keychain or an item that doesn't trust the build |
| macOS | 27.0.x | Each later major version |

## 4. Gaps and required verification

Each gap must be closed by the method given, with the pass criterion of section 2 unless stated.

| Gap | Required verification | Pass criterion |
| --- | --- | --- |
| Real browsers and native targets | The manual round in section 6, with a recorder page in the browser and a frontmost-app observer for native apps | No blur, focus or visibility change beyond the accepted exceptions; every typed character arrives |
| Multiple displays | Run `focus` with the pointer, and so the target, on each display, including one with a negative origin | The overlay covers only that display; the conversation opens on it; observers clean |
| Display removed while the overlay or conversation is up | Manual: unplug the external display mid-snip | The session closes without SnapScreen activating |
| Real capture and the capture alert | The manual round, on a build with Screen Recording granted | The alert is the only focus loss; repeat the run |
| Locked or distrusting keychain | Manual: `security lock-keychain`, then snip | The conversation reports the keychain failure; no password dialog appears |
| Selection timeout (120 s) and the overall timeout (10 min) | Add to `focus` through the controller's scheduler, so the test doesn't wait | The Session ended view shows with observers clean |
| Right-click menu in a panel at 10 ms | Add to `focus`: open it, hold, choose nothing, as `chooseMenuItem` already measures the menu bar item's menu | The page never blurs; the key window returns when the menu closes |
| Notice close button, hover pause, auto-dismiss, and the Screen Recording notice | Add to `focus` with the denied capture service | Observers clean; Open System Settings takes focus only when clicked |
| Failures in a conversation: API error, refusal, missing key | Add observers B and C around the CI stages, or add the stages to `focus` | Observers clean through Retry |
| Zoom by title bar double-click, where macOS is set to zoom | Add to `focus` if the gesture is kept | Observers clean |
| A sheet, popover or menu open in the user's app at ⌥⇧S | Manual | The sheet keeps focus; the overlay is usable |
| Space switch, Mission Control, sleep or wake, screen lock with the overlay up | Manual | SnapScreen never activates; the overlay cancels or survives without a focus change |
| Full Keyboard Access on; VoiceOver's custom actions | Manual | AX actions select and confirm without moving focus |
| Login item launch at login | Manual, after Open at login | No activation after login |

## 5. Procedure

Run in this order after any change to activation, panels, notices, the menu or Settings. The
focus runs post real input for about 20 seconds each, so ask the user first, and quit their copy,
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
`SnapScreen is already running.`, nothing was tested: stop that copy, whose binary is under
`build/test-hooks/`, not the user's, and rerun. Keep hands off the keyboard and pointer during a
run; the test refuses to post input unless the target is in front.

Results: exit 0 and a `passed` line naming the stages and the check count. Exit 1 names the first
failing check and quotes the target's report: `blurCount`, `hiddenCount`, `text`,
`nativeFailures` and `nativeFailureReasons`. A failure in `focus` with a clean CI run points at
WindowServer-level behavior; one in CI points at panel configuration or window ordering.

## 6. Manual round for real browsers and native apps

The tester sets the window state; the user performs the actions. A browser step uses a page like
the focus target's, with a focused `textarea` and listeners for `focus`, `blur`,
`visibilitychange`, `keydown` and pointer events. A native step uses an observer process that logs
the frontmost app and the target's AX focused window at 10 ms. Keep the terminal out of front.

1. Chrome, normal window, the page's field focused. Press ⌥⇧S, drag a region, release, and
   type a few characters while the answer streams.
2. Click Stop, Retry, Copy, the thumbnail, then the preview's close button, typing after each.
3. Click the page's field: the conversation closes and the click lands. Type again.
4. Chrome in a fullscreen Space: repeat steps 1 and 3.
5. Safari, normal window: repeat steps 1 and 3.
6. Preview with a PDF and its search field focused: ⌥⇧S, select, release, type into the field,
   close with the conversation's close button.
7. Rebuild with `SNAPSCREEN_BUILD_NUMBER` set, reopen, snip once: no Screen Recording or Keychain
   prompt.

Pass: the recorder logs no blur, focus or visibility change beyond the accepted exceptions, every
typed character arrives, the observer never lists SnapScreen as frontmost, and fullscreen holds.

## 7. Traceability

| Requirement | Implemented by | Checked by |
| --- | --- | --- |
| R1, R2 | `.accessory` policy and `LSUIElement` (`main.swift`); `applicationDidBecomeActive` handback (`AppDelegate.swift`) | self (policy), CI and focus (observer A), focus (D) |
| R3, R4, R5 | Consequence of R8 and the Carbon hot key (`Hotkey.swift`) | focus, full (observers B, C, probe) |
| R6 | `acceptsFirstMouse` in `SelectionView` and `NoticeButton`; `.activeAlways` tracking areas; `PointerShieldController` (`UI/Panels.swift`) | CI (Copy, preview, replacement); focus (every control through WindowServer) |
| R7 | `SessionWindows.watchOutsideClicks`: a global mouse-down monitor, active only while the answer is complete | CI (in-process); focus (real click into the field) |
| R8 | `PassivePanel` and `CompanionPanel`; `SelectionOverlay.make`; `SnipWindows.closeEarlier` after the new conversation shows | self (configuration, close order); CI and focus (`checkPassive`, `passive`) |
| R9 | Non-opaque overlay; `.fullScreenAuxiliary` | focus (page visibility); full (fullscreen holds) |
| R10 | `BackgroundCursor`, enabled only while the overlay is up | self (availability); manual (cursor seen) |
| R11 | `KeychainStore.readWithoutPrompt` and `KeychainPrompts.disallowed`; `CGPreflightScreenCaptureAccess`; `QuitRequest`; the single-instance guard | self (prompt control, quit refusal); focus (LaunchServices launch) |
| R12 | `AppDelegate.handbackDelay`; `ForegroundFocus.returnToPreviousApp` | focus, full (`yield`, handback under 500 ms) |
| R13 | `showSettings`; `settingsClosed`; `PassivePanel.canHide = false` | focus (synthetic Settings, then the notice's, the menu's and reopen's) |

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
