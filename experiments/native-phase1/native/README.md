# Native Phase 1 host

Build on macOS with the Xcode command-line tools:

```sh
sh experiments/native-phase1/native/build.sh
experiments/native-phase1/build/SnapScreenPhase1.app/Contents/MacOS/SnapScreenPhase1 --self-test
```

The build is a local, unsigned AppKit app bundle. Its executable is the Chrome native host:
Chrome launches it through `connectNative()`, and that same process owns the windows. There
is no relay process, listening socket, separately launched app, or call to activate the app.
Use the experiment runner to register and launch it through Chrome. Opening the bundle by
hand does not exercise the required activation path.

The executable uses native messaging on stdin/stdout. Normal execution writes only framed
version-1 JSON to stdout; `--self-test` is a separate CLI mode. The input frame limit is 8 MiB
and the output limit is 256 KiB. Malformed input, unsupported versions, invalid image data,
truncation, and EOF shut down the process and clear its windows. A hello handshake is required
before capture. A warm connection may accept successive capture sessions; there is only one
session at a time. Reset clears the matching session without terminating the process.

Selection uses a fitted frozen screenshot, not an overlay aligned to the live Chrome viewport.
Releasing a drag submits the region at once, like the extension's snip overlay; a click or a
drag under 5 displayed points cancels. Arrows move the default region by a displayed pixel,
Shift + arrows resize its bottom and right edges, Enter accepts it, and Escape cancels it. A
Cancel selection button cancels with the mouse. Capture dimensions are checked through ImageIO before pixel
decode (16,384 pixels per dimension and 80 million total pixels). Full-image references are
released after selection; the selected crop remains in memory for preview until reset or close.

The answer panel renders mock deltas from the extension. It supports native title-bar movement,
selectable and scrollable answer text, Copy answer, Screenshot preview, a native follow-up
field with Enter/Ask submission, and Close. Follow-up submission waits for the current mocked
stream to finish. This does not call a provider API.

All panels resize from their edges and corners with AppKit's native live resize; the answer
panel's minimum size is 560 × 350 points. Reshaping a window under the pointer briefly exposes
whatever is beneath it, and over Chrome the page then saw hover events with the button pressed.
A **pointer shield** prevents this: a screen-sized, non-opaque, nearly transparent (alpha
1/255), nonactivating panel ordered directly beneath the panels whenever one appears. It
ignores mouse events, so the page stays usable around the panels, except while a panel is
pressed within 8 points of its edge (raised before AppKit starts the resize) or is
live-resizing. It never becomes key, needs no permission, and is removed with the session.
Creating it at resize start was measurably too late in fullscreen; see the results.
Telemetry records `<surface>.shield_raised`, `shield.lowered`, and `live_resize_begin` /
`live_resize_end`. Native pointer-drag metadata is sampled at most four times a second,
separately from frame changes. While a press that began in a panel is held, the host also
records `<surface>.pressed_pointer_left` / `_returned` / `_released_outside` as the pointer
crosses that panel's frame; the 100 ms timer covers nested tracking loops.

Telemetry includes epoch milliseconds, current app activation, whether the host has a key
window, the session identifier, and named interaction/focus events. It is emitted through the
native port and as JSON lines to stderr. It contains no key values, screenshot pixels, answer
text, follow-up content, or clipboard contents. Modifier keys are named by transition only
(`<surface>.modifier_command_down`, for example). The follow-up field's editor reports
`followup.select_all` and input-method composition events (`followup.composition_update` /
`_committed` / `_cleared`) without reading the text. After a paste, the host compares the field with the last copied mock answer in memory, ignoring
whitespace, and records only `followup.paste_matches_copy`, `_differs_from_copy`, or
`_without_copy`. Selecting answer text records `answer.text_selected` /
`answer.text_selection_cleared`. Shown panels and follow-up editing events carry an
`inputSource` identifier such as `com.apple.keylayout.US`; identifiers outside
`[A-Za-z0-9_.-]{1,120}` are sent as `other`. The host never writes screenshots or
conversation data to files. The experiment's evidence runner controls any metadata export.

Window and scroll telemetry begins from a post-show baseline. The `selection.shown`,
`answer.shown`, and `preview.shown` events include numeric window `frame` bounds; the answer
baseline also includes the scroll viewport's `scroll` bounds. Initial creation and centering
are excluded from movement measurements. Each window has its own surface identity, so creating
or moving a preview cannot be labeled as an answer-window movement.

The host compares window frame origins and sizes using AppKit notifications and a 100 ms
main-thread timer registered in common and event-tracking run-loop modes. It observes the
answer's clip-view bounds through notifications and that timer, including scrollbar and
keyboard scrolling. `answer.scroll_changed` records a change of viewport origin; a viewport
size change alone does not count. The numeric `frame` and `scroll` records contain only
`x`, `y`, `width`, and `height` in AppKit points, capped to an absolute magnitude of one million.
`geometrySource` identifies `baseline`, `notification`, `poll`, or a final `close` observation.
Unchanged samples emit no events. Standalone preview close emits `preview.closed`; session or
parent cleanup emits `preview.closed_with_parent`. Session cleanup removes the scroll observer,
and process shutdown invalidates the timer.

These records establish geometry changes, not their cause. Layout or streamed content can
also change scroll origin. Correlate changes with recorded input and the user's action notes;
raw wheel events remain separate. Polling catches persistent changes but can miss a change
that returns to its previous value between samples. Missing telemetry cannot prove that no
brief change occurred. The new self-tests verify baseline/change classification and duplicate
suppression; actual AppKit observations still require a new physical interaction run.

The panel style is `nonactivatingPanel`; it is deliberately allowed to become key so selection
keys and text entry can be tested. This is an implementation choice to measure, not proof that
Chrome document focus or visibility remains unchanged. Consult the experiment results before
making any claim about those properties.
