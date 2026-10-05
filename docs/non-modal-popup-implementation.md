# Nonmodal popup implementation plan

Keep SnapScreen's floating, draggable answer popup while allowing the user to click, scroll,
select text, and type on the surrounding webpage. The extension iframe must occupy only the
popup's bounds while an answer is visible. Full-screen interaction remains available for
selecting a snip and viewing an enlarged screenshot.

**Status:** implementation specification; the extension has not been changed by this document.
Based on the repository at `1eb64f7`. Completion requires the automated and manual acceptance
checks below; passing checks on the current code does not validate the proposed behaviour.

## User behaviour

| Action | Required result |
| --- | --- |
| Open an answer | Show the existing floating popup, with its screenshot, answer, composer, and header controls. |
| Click or select text outside the popup | Interact with the webpage and leave the popup open. |
| Scroll outside the popup | Scroll the webpage; the popup stays fixed in the viewport. |
| Scroll a long answer inside the popup | Scroll the answer, with the existing containment of scrolling at its edges. |
| Type in a webpage field | Continue typing there while the answer streams, completes, or fails. |
| Click the popup's Close button | Close the popup and cancel its active work using the existing session disposal path. |
| Press Escape while focused in the popup | Close it after Escape is released. Escape on the webpage belongs to the webpage. |
| Click New snip in the header | Remove the old UI before capture, enter full-screen selection, and open a fresh answer for the selected region. |
| Use the configured snip shortcut | Invoke the same existing browser command, including while the answer popup is open. The default is Alt+Shift+S, or Option+Shift+S on Mac. |
| Ask a follow-up in the composer | Continue the conversation about the original captured screenshot. Scrolling the page does not replace that screenshot. |
| Open the screenshot preview | Expand to the existing full-screen lightbox. Closing it restores the compact popup and its position. |
| Tab or Shift+Tab through the answer controls | Allow normal browser focus traversal out of and back into the popup. |

The shortcut is declared in [the manifest](../src/manifest.json) and handled by
`chrome.commands.onCommand` in [the service worker](../src/background/service-worker.ts).
Preserve Chrome's configurable shortcut assignment; do not add a competing document keydown
listener. A user who changed the shortcut keeps that assignment.

Navigation to a different document retains the existing teardown behaviour. Persisting a
conversation across navigation, adding a native Chrome side panel, saving screenshots, and
changing the model or API request are outside this implementation.

## Causes in the current code

- [result-frame-host.ts](../src/content/result-frame-host.ts) creates an iframe with
  `width: 100vw`, `height: 100vh`, and `pointer-events: auto`. Transparent areas still belong to
  that iframe's interactive surface.
- [result-panel.ts](../src/content/result-panel.ts) creates `.snapscreen-panel-backdrop`, assigns
  outside-click dismissal, marks the answer as `aria-modal="true"`, and calls `trapFocus` for it.
- `showResultPanel` replaces the panel contents and focuses a control on every complete render.
  Completion, failure, and Stop can therefore take focus away from a webpage field.
- The renderer's geometry and CSS assume its document viewport is the whole page. Shrinking
  the iframe without changing these assumptions would break positioning and repeatedly shrink
  dimensions derived from `100vw`, `100vh`, and `40vh`.

Removing the backdrop alone is insufficient. Setting `pointer-events: none` on the iframe
would also disable the popup's controls. Do not forward simulated clicks or wheel events to
the page, and do not move private UI into the page DOM.

## Architecture and ownership

Keep one authenticated extension-origin iframe inside the existing closed shadow host. Retain
the capability registration, one-time claim, READY buffering, and private `MessageChannel`.
Change the iframe's geometry and presentation without navigating or recreating it between
the answer and its screenshot lightbox.

The content-side `ResultFrameHost` owns the actual frame rectangle, available top-page
viewport, presentation state, and clamping. The frame renderer owns private DOM, intrinsic
content measurement, and local user interactions. The renderer reports measurements and
interaction intent; the host validates them and applies geometry to its private iframe.

Keep the outer host fixed and pointer-transparent. Apply changing styles to the private
iframe, not to the outer host: the existing `MutationObserver` treats outer-host attribute
changes as tampering and disposes the session. Preserve that protection.

Introduce an explicit presentation state in place of treating `setInteractive(boolean)` as
the complete state model:

| State | Frame appearance and hit testing | Focus behaviour |
| --- | --- | --- |
| Hidden or preparing | Invisible and pointer-transparent; may retain measurable dimensions during preparation. | Inert and excluded from keyboard navigation. |
| Snip | Full viewport, interactive, existing frozen screenshot and crop controls. | Existing modal crop behaviour. |
| Panel | Sized to the visible panel border box, interactive only there. | Nonmodal, with normal focus traversal. |
| Lightbox | Full viewport, interactive, enlarged screenshot. | Existing lightbox focus trap; underlying panel inert. |
| Toast only | Visible notification with pointer events disabled for the entire frame. | Never focuses or enters the Tab sequence. |

Mount a new frame hidden and noninteractive until authenticated and ready for the intended
surface. Do not create a temporary invisible full-screen blocker during loading or resizing.
Use `visibility: hidden` while measuring, rather than `display: none`, which prevents useful
layout measurement. Keep passive live-region notifications accessible; do not make a visible
toast inert simply to remove pointer interaction.

### Geometry and sizing

1. Use top-page CSS pixels for all outer rectangles. Send explicit viewport bounds and layout
   constraints to the frame. Account for the visible viewport offset and size during pinch
   zoom, and recompute on window and `visualViewport` resize or scroll events where available.
   Keep ordinary document scrolling separate from the fixed popup's position.
2. Retain the current preferred widths: 400 px normally and 520 px when code blocks are present.
   Clamp to the available viewport with the existing 16 px margin where space permits. Reduce
   the margin on tiny viewports instead of creating negative dimensions or unreachable controls.
3. In compact mode, lay out the panel at the frame's local origin with the assigned width.
   Remove the inner page-positioning offsets and the repeated 16 px inset. Compute its maximum
   height and the current `min(280px, 40vh)` answer-body cap from the parent viewport, not the
   compact iframe height. Give the panel natural content height up to that explicit cap.
4. Measure the panel border box with `ResizeObserver`. Update after image loading, composer
   growth, streaming content, error changes, and switching to the code-block width. A width
   change must be applied before accepting the corresponding height measurement.
5. Keep size and position independent. Height changes preserve the user's chosen position,
   subject to clamping. Use `anchorRect` only for initial placement; it must not pull the panel
   back to the original snip after dragging, scrolling, or receiving another response.
6. Coalesce geometry work to one update per animation frame. Deduplicate equal rounded sizes,
   and associate measurements with the current mode and sizing constraints. A height-only
   update must not change the constraints from which that height was measured. This prevents
   `ResizeObserver` feedback loops and stale-width measurements.
7. Preserve the shadow and rounded appearance without an invisible interactive gutter. Render
   the outer shadow on the private iframe element, or use another noninteractive decoration
   inside the closed root. Do not enlarge the hit box merely to fit the current child shadow.
8. Keep Close and New snip reachable in small windows. The answer body should yield height
   first; provide bounded internal scrolling if the remaining controls cannot all fit.

Use [clamp-to-viewport.ts](../src/lib/clamp-to-viewport.ts) where its assumptions apply, with a
small tested layout helper for the new constraints. Do not let both the parent and child
independently clamp the compact panel using different viewport sizes.

### Dragging a moving frame

Keep pointer capture on the existing header drag handle. Header buttons must still trigger
their actions rather than starting a drag. Keep the frame compact throughout the drag.

Do not reuse `ev.clientX - offsetX` against the compact frame: those coordinates change when
the frame itself moves. Use a drag-start outer rectangle plus screen-coordinate displacement,
converted to top-page CSS pixels. Obtain tab zoom through a small typed, read-only request
from the trusted content controller to the background, using `sender.tab.id` rather than a
caller-supplied tab ID. Refresh it at drag start; associate the asynchronous reply with that
drag so a late reply cannot move a released or replaced panel. Keep the latest pointer sample
while awaiting that reply.

For ordinary page zoom, convert screen displacement by the tab zoom factor; account separately
for visual viewport scale when pinch zoom is active. Do not divide by `devicePixelRatio`,
which also includes display density. Prove the conversion with browser tests at multiple zoom
levels and on a high-density display before relying on it. Chrome exposes the tab factor via
[`chrome.tabs.getZoom`](https://developer.chrome.com/docs/extensions/reference/api/tabs#method-getZoom).
Avoid `movementX` and `movementY` as a shortcut: their units vary by browser and operating
system, as documented by [MDN](https://developer.mozilla.org/en-US/docs/Web/API/MouseEvent/movementX).

Give each drag an ID. Clamp proposed positions in the host and ignore moves for an inactive
drag. End a drag on pointerup, pointercancel, lost pointer capture, blur, disposal, mode change,
or viewport/zoom change. Keep the drag handle stable across answer updates, or end its drag
before replacing it. Release pointer capture and clear listeners and cursors on every path.

### Protocol and transition ordering

Extend the unions and both validators in [ui-protocol.ts](../src/lib/ui-protocol.ts). Use named
variants for these responsibilities; the names below are proposed implementation names:

| Direction | Variant | Payload and purpose |
| --- | --- | --- |
| Controller to frame | `SNAPSCREEN_UI_LAYOUT` | Session, mode revision, constraint revision, surface mode, parent viewport, frame rectangle, and explicit layout limits. Confirms applied geometry. |
| Frame to controller | `SNAPSCREEN_UI_SURFACE_METRICS` | Matching revisions, requested width class, and measured size for the panel or notification. |
| Frame to controller | `SNAPSCREEN_UI_LIGHTBOX` | Matching session and mode revision, request ID, and open or close intent. |
| Frame to controller | `SNAPSCREEN_UI_DRAG` | Matching session and mode revision, drag ID, begin/move/end phase, and bounded finite coordinates appropriate to that phase. |

Validate discriminants, required fields, finite numbers, positive sizes and zoom factors,
bounded values, and nonnegative integer revisions. Reject wrong sessions, unknown modes,
stale revisions, and messages incompatible with the active surface. Allow legitimate negative
screen coordinates on monitors to the left or above the primary screen. Clamp geometry against
the actual current viewport after validation; do not trust the child to select an unlimited
frame rectangle. Measurements alone must never switch the surface to full-screen mode.

The host owns mode revisions; increment them on surface transitions and invalidation. Sizing
constraints have a separate revision that changes when width or viewport constraints change,
not on every height acknowledgement or drag movement. Attach these revisions to commands that
initiate or restore a surface, not only measurement replies. A disposed host ignores everything.

The drag zoom request also needs a discriminated variant in
[messages.ts](../src/lib/messages.ts), a validated response, and an `isControllerMessage` case
in [workspace-protocol.ts](../src/lib/workspace-protocol.ts). Preserve rejection of direct
extension-frame senders by normal background command handlers. A typed zoom-change event, if
used to cancel a drag promptly, likewise needs its `isControllerEvent` validator and explicit
content-side handling. Workspace rendering does not need the compact-frame zoom request.

Implement transitions in this order:

- **Snip to capture gap:** invalidate snip work, clear its visible UI, and make the frame hidden
  and noninteractive. Existing cancellation still works if the host disappears during cropping.
- **Capture gap to answer:** apply compact constraints while hidden, render and measure, fit the
  actual frame, then reveal it. Authorize initial focus only if the user has not resumed work
  on the page or moved to another tab during the gap.
- **Answer to lightbox:** retain the panel rectangle and state; request the mode change; expand
  the frame; acknowledge the new layout; then show and focus the lightbox. A delayed panel
  measurement cannot shrink it.
- **Lightbox to answer:** consume the closing action, remove the lightbox, restore and reclamp
  the saved compact geometry, remeasure changed content if needed, then restore the thumbnail's
  focus when appropriate. The Escape that closes the preview must not also close the answer.
- **New snip, Close, or disposal:** invalidate outstanding geometry and drag callbacks before
  teardown. No queued measurement, response, or animation frame may reveal the old panel again.

Currently `showResultPanel` unconditionally calls `closeScreenshotLightbox`. Change this so an
ordinary answer completion or failure does not dismiss an explicitly opened preview. Update
the panel beneath it while preserving the preview's modality; reconnect the return-focus
target if the thumbnail DOM is replaced. Explicit teardown and a new capture still close it.

If layout negotiation fails, use the existing bounded UI-unavailable cleanup path. A stalled
transition must not leave an invisible full-screen frame capturing the user's input.

### Focus and keyboard behaviour

Remove the answer backdrop and its outside-click handler. Keep its accessible name and
`role="dialog"`, but omit `aria-modal="true"`. Remove the answer's Tab trap; retain the separate
snip and screenshot-lightbox traps. Do not set `inert`, `overflow: hidden`, or a scroll lock on
the underlying webpage.

Before rerendering, determine whether focus actually belongs to the panel. In the extension
frame, checking `document.activeElement` is insufficient: it may still identify an internal
control after focus has moved to the parent page. Check document focus ownership as well;
[`document.hasFocus()`](https://developer.mozilla.org/en-US/docs/Web/API/Document/hasFocus)
distinguishes those situations. Keep the same-document test/workspace adapter's focus lookup
compatible with the closed shadow root used in unit tests.

- Preserve composer draft, selection, and an equivalent focused control when replacing DOM
  that the user is actively using. Prefer stable header and composer elements where practical.
- If the user is focused on the page or in another tab, streaming, completion, failure, Stop,
  retry, resizing, and clipboard completion must not focus the panel.
- Retain useful initial focus after a user-invoked snip only while it still belongs to that
  interaction. The host should track focus handoff during hidden preparation and confirm it
  before requesting child focus; no page input values or keystrokes need to be recorded.
- Guard the clipboard fallback before `helper.select()` or `execCommand('copy')`, as well as
  before `returnFocus.focus()`: selecting the helper can itself focus the frame. A rejected
  asynchronous clipboard request must not steal focus after the user left. Report failure
  without focusing when the fallback is no longer appropriate.
- On final close, restore the appropriate connected page element only if the extension still
  owns focus. The current unconditional restore in `ResultFrameHost.#dispose` must not override
  a newer page focus. Store element references only, and release them at disposal.
- Keep the Escape keydown/keyup pairing. Do not remove the focused iframe on keydown and leak
  its keyup to the page. Preserve this across a response rerender and repeated Escape presses.

Do not synthesize page key events to implement Tab traversal. Verify Chrome's real traversal
between the page and the compact frame, in both directions, with actual keyboard input.

### New snips, notifications, and workspace compatibility

Preserve the existing `REQUEST_SNIP`, `PREPARE_SNIP_CAPTURE`, `START_SNIP`, cancellation, and
capture/request/screenshot correlation paths. Toolbar invocation and the Chrome command must
continue to work when focus is in either the popup or the page. Remove the old popup before
`captureVisibleTab` captures pixels, and cancel its generation through the existing controller.
The new snip remains a fresh session; late events from the old one must be ignored.

For the header New snip action, make the frame noninteractive immediately while the background
prepares capture. If that request fails, surface the error without leaving a blank interactive
frame or an invisible generation running. Retain the existing Settings and retry actions.

For errors while a panel is open, place the notification within its existing bounds. Do not
expand the frame to span the distance between the panel and a viewport-bottom toast. A
standalone toast may use a full-viewport, entirely pointer-transparent frame, with no focus or
Tab interception. Clean it up on its existing timeout and invalidate delayed measurements.

[workspace.ts](../src/workspace/workspace.ts) uses the same renderer directly in a top-level
extension document. Make compact-frame layout an explicit renderer adapter or mode; retain
document-relative geometry for the workspace. Its lightbox, keyboard snipping, direct controls,
source-page recapture restrictions, and one-time capability protocol must continue to work.

## Files and implementation order

1. **Define geometry and state transitions.** Add a small pure layout helper with co-located
   tests. Extend `ui-protocol.ts` and its validators/tests for revisions, geometry, and intents.
   Add the typed zoom lookup and required workspace validator alongside its background handler.
2. **Implement the frame host.** Update `result-frame-host.ts` and `ui-proxy.ts` to own modes,
   constraints, fit/reveal ordering, dragging, conditional focus restoration, and cleanup.
   Preserve attestation and the outer-host mutation guard.
3. **Adapt the renderer.** Update `result-frame.ts`, `result-frame.css`, `result-panel.ts`, and
   `overlay.css` for the compact layout adapter, intrinsic measurement, nonmodal answer,
   guarded focus, lightbox handshake, and notification placement. Keep the workspace adapter
   functional; update `workspace.css` selectors if backdrop removal leaves obsolete rules.
4. **Verify the complete interaction.** Add the focused unit cases and separate benign browser
   fixture below. Keep all hostile-page and build checks. Complete actual shortcut/capture and
   zoom/drag acceptance before declaring the feature complete.
5. **Update documentation.** Revise [security.md](security.md), which currently describes every
   surface as a full-viewport iframe. Document compact answers, full-screen modal surfaces,
   passive toasts, and intentional page interaction. Update README usage for outside clicks and
   closing. Permissions and data handling should remain unchanged; if implementation changes
   either, update [PRIVACY.md](../PRIVACY.md) and [chrome-web-store.md](chrome-web-store.md) too.

Follow [AGENTS.md](../AGENTS.md) for branch creation from `origin/main`, style, commits, and PR
delivery. Do not add runtime dependencies, broaden permissions, change capture persistence,
alter the API/model/prompt, or remove the Vite entries for the frame and workspace. Build `dist/`
normally; never edit it by hand.

## Verification requirements

### Unit and integration coverage

| Existing test location | Required additions or updates |
| --- | --- |
| `src/lib/ui-protocol.test.ts` | All new valid variants; missing fields; wrong sessions; stale/invalid revisions; nonfinite or invalid dimensions; negative screen coordinates; preserved READY buffering. |
| Layout helper and `src/lib/clamp-to-viewport.test.ts` | Standard/code width, variable content height, tiny viewports, visual viewport offsets, resizing, position preservation, and equivalent measurement deduplication. |
| `src/content/result-frame-host.test.ts` | Hidden/full-screen/compact transitions, stale geometry after disposal, correct iframe styles, untouched outer host, conditional focus restoration, and failure cleanup. |
| `src/content/ui-proxy.test.ts` | Mode sequencing, lightbox requests, capture gap cancellation, resnip failure, toast behaviour, drag cancellation, and rejection of out-of-order events. |
| `src/content/result-panel.test.ts` | No answer backdrop or modal attribute; no answer Tab trap; focus/draft preservation; completion/error/Stop while page owns focus; guarded clipboard restoration; lightbox survives background updates and returns correctly. |
| `src/content/capture-controller.test.ts` | Old session cancellation and no revival after resnip/close, retaining its existing in-page/workspace adapter matrix. |
| `src/content/snip-overlay.test.ts` | Preserve full-screen selection, keyboard crop controls, Escape-release handling, and frozen-image coordinate correctness. |
| `src/background/service-worker.integration.test.ts` and `src/lib/workspace-protocol.test.ts` | Trusted sender enforcement for zoom lookup; response validation; correct tab targeting; browser command reaches the existing capture flow; all added message cases. |

Update tests that explicitly expect the answer to be modal. Keep assertions for snip and
lightbox modality. DOM tests alone cannot prove iframe hit testing, real focus traversal,
layout measurements, or pointer capture across a moving frame.

### Browser regression checks

Extend [scripts/extension-smoke.mjs](../scripts/extension-smoke.mjs) with a separate benign,
scrollable fixture containing a button, selectable text, and inputs. Use actual pointer,
wheel, and keyboard input for interactions, and DOM inspection only for observations.
Do not use forced clicks, synthetic `dispatchEvent`, direct `element.click()`, or programmatic
scrolling as evidence that the user can interact through the former overlay area.

Keep the hostile fixture separately. Its `installHostProbe` deliberately cancels page pointer
events, and `assertHostPageIsolation` rejects page keyboard events. Mixing normal page typing
into that same observation window would produce a misleading failure; deleting its checks
would hide a security regression. The existing strict CSP also means benign fixture setup
must use the harness's controlled evaluation/init scripts or allowed resources.

Required browser cases:

1. **Page interaction during and after generation.** Hold the mocked API response, open the
   popup, click a page button outside it, and verify its handler runs while the popup stays
   open. Wheel-scroll outside and observe changed page scroll position without panel movement.
   Select page text. Repeat after answer completion.
2. **Focus retention.** Click a page input and type, release the API gate, wait for the answer
   to complete, then continue typing without refocusing. Assert the input value, selection,
   and focus are correct. Cover failure too; use deterministic unit tests for other rerenders.
3. **Independent answer scrolling.** Wheel over a long answer and verify the answer scrolls
   while the page does not, including at the answer's scroll boundary.
4. **Keyboard traversal.** Tab and Shift+Tab across both panel boundaries using page-level
   keyboard input. Avoid locator `.press()` for this check because it focuses the locator.
   Escape on the page does not close the panel; Escape inside closes on keyup.
5. **Actual bounds and dragging.** Verify frame and panel bounds agree in compact mode. Drag
   using real mouse movement beyond the old bounds; check displacement, pointer capture,
   viewport clamping, and continued button operation. Repeat after code-width expansion,
   composer growth, viewport shrink, and delayed geometry messages. Use a small rounding
   tolerance rather than exact floating-point equality.
6. **Lightbox round trip.** Open the preview, verify full-screen geometry and confined focus,
   complete an answer while it is open, then close it. Verify restored compact geometry,
   correct focus, preserved conversation, and immediately working outside interactions.
7. **Capture gap and teardown.** Hold cropping before the result arrives. Confirm the hidden
   frame neither paints nor intercepts pointer/Tab input. Type in a page input, release cropping,
   wait for the answer to appear, then continue typing without refocusing. Also switch tabs
   during preparation and verify the new answer does not reclaim focus. Close or replace the
   session and deliver late events; the old surface must remain absent.
8. **Follow-up after page interaction.** Scroll or change page content, then submit a follow-up.
   Assert that the request retains the original captured image payload and earlier conversation,
   with no new capture. Comparing image dimensions alone is insufficient.
9. **Isolation and fallback.** Retain hostile-page keyboard/input and pointer-target checks,
   closed shadow root, strict-CSP operation, non-web-accessible workspace, and synchronous
   content-script build assertions. Check that screenshot data,
   composer text, and answer/code sentinels do not appear in page-visible text, values,
   attributes, or ordinary message traffic. Exercise workspace snip, answer, and lightbox.

Retain the existing capability rejection, replay, and sender checks in
`src/background/ui-capability-registry.test.ts`, `src/background/service-worker.integration.test.ts`,
and `src/lib/ui-protocol.test.ts`. Those are unit/integration checks; do not label them browser
coverage unless equivalent real-browser cases are added.

The existing API response gate proves pending-to-complete behaviour. Its single
`route.fulfill()` does not simulate separately timed streaming chunks; use controlled chunk
delivery if a test claims to exercise that timing. Prefer condition waits and explicit gates
to arbitrary sleeps, and keep the harness's total deadline bounded.

### Real Chrome acceptance

The smoke helper `injectAndStartSnip` injects synthetic start/crop messages. It bypasses
`chrome.commands`, `handleStartSnip`, capture preparation, and actual screenshots. It cannot
prove that the real shortcut works or that an old popup is absent from captured pixels.
Perform these checks with a freshly built and reloaded unpacked extension:

- With a popup open, scroll the page, then press the configured shortcut while focused on the
  page. Repeat while focused in the popup composer and while an answer is still pending.
- Confirm the old popup disappears before the frozen screenshot. Select a region crossing
  where it used to be; the new screenshot must contain only page content. Confirm the new
  question uses a fresh conversation and the old generation cannot append to it.
- Repeat using the header New snip button and the toolbar action. Test Escape cancellation
  during selection, then start another snip normally.
- Test mouse selection and keyboard selection. Verify both against the frozen capture after
  page scrolling, normal browser zoom changes, and a viewport resize.
- Drag at 80%, 100%, 125%, and 200% page zoom, and on a high-density display. Exercise pinch
  zoom where available, moving across displays, release outside the frame, and zoom/resize
  during a drag. The panel must not jump, accelerate, get stuck, or leave an invisible blocker.
- Check a small viewport, a long code answer, a multiline composer, and light/dark appearance.
  Confirm Close, New snip, and the composer remain usable.
- Check keyboard-only navigation and a screen reader: the answer is nonmodal; snip and
  lightbox remain modal; completed answers do not steal focus from a webpage input.

Use mocked responses where possible. Any real provider request spends credit and is separate
from this UI change; do not trigger the paid live-API workflow for it.

### Required commands and completion evidence

Run the repository's checks in this order, with the live API key unset for the mock test run:

```bash
npm run lint
npm run typecheck
env -u SNAPSCREEN_LIVE_API_KEY npm test
npm run build
npm run test:browser
```

CI additionally runs `npm audit --audit-level=moderate`. Report any upstream advisory
separately from failures introduced by this change. Use `npm run build`, not `npm run dev`,
for the extension under test.

The implementation is ready only when the new interaction tests and existing security checks
pass, the real shortcut/capture and zoom checks are recorded, and all temporary instrumentation
is removed. Record the checked commit, browser/platform versions, automated results, and any
manual checks still outstanding in the PR. Do not describe unperformed acceptance checks as
passing.
