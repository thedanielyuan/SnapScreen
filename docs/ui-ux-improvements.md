# UI and UX improvements

Proposal, 10 October 2026. Changes to how SnapScreen looks and responds that keep what it does:
the same requests, features and limits, and windows that never activate the app, with Escape and
Command-W closing on key release. Offscreen renders of the current views confirmed items 1 and 3.
Items 1–4 matter most for daily use. All twelve are done, from 10 to 11 October 2026.

## Highest value

### 1. Size the conversation window to its answer (done)

Every conversation opened at 460 × 560 points (`SessionWindows.showConversation`), so a short
answer left most of the panel empty while it covered the page beside your selection.

Done on 10 October 2026:

- The panel is placed where it would fit at its largest, but opens at its smallest, 280 points of
  content: beside the selection, level with its top; above or below it, at the nearest edge
  (`openingFrame` in `UI/Geometry.swift`).
- As the answer streams, it grows to fit its thread and draft, away from the selection and then
  the other way at the screen's edge (`grownFrame`). It never shrinks, and the thread scrolls once
  it reaches its largest.
- Resizing it yourself stops the fitting, and the size you chose sets later conversations' width
  and largest height. That size is kept in memory until SnapScreen quits, so nothing new is stored
  and `docs/security.md` and `PRIVACY.md` don't change.
- Growing can hide the thread's scroller, which rewraps the thread and resizes the thumbnail, so
  fitting measures again until the panel holds still. The self-test checks this with legacy
  scrollers, and the live test checks that the first answer fits.

### 2. Keep the start of the answer in view (done)

`ConversationView` followed the bottom of the thread while you were within 24 points of it.
Answers stream faster than you read, so a long answer's first lines scrolled away while you were
still on them.

Done on 10 October 2026: when an answer starts, the thread follows it until its exchange's top
reaches the top, then holds there while the rest fills in below. Scrolling to the bottom follows
again, and asking a question still scrolls it into view.

### 3. Hanging indents for numbered and bulleted lines (done)

Answers write numbered parts, lettered options and bullets as plain lines. Wrapped lines returned
to the left margin, and the items ran together with no space between them.

Done on 10 October 2026:

- Each prose paragraph that starts with a marker (`1.`, `a)`, `(b)`, `-`, `•`, after up to eight
  spaces) gets a head indent the width of its marker, and 4 points above it unless it starts the
  text (`AnswerStyle.listItemParagraph`). A streamed update restyles only the paragraphs it
  touches. Years and decimals, such as `2026.` and `1.5`, stay plain lines.
- The text storage stays the literal answer, so selecting and copying are unchanged, and nothing
  else is interpreted as Markdown. The system prompt and `CodeFence.swift` don't change.
- `AnswerSegmentView.update` read the inserted text's start from the text view's string after
  inserting it, and that string is the live storage, so streamed text never got its paragraph
  style. It now counts first, so answers also get the line spacing `AnswerStyle` always declared:
  3 points for prose and 2 for code.

### 4. Hold Space to move the selection while dragging (done)

Releasing asks at once, so a drag that started in the wrong place meant cancelling and snipping
again.

Done on 10 October 2026: while a drag is in progress, holding Space moves the selection instead of
resizing it, as in ⌘⇧4, stopping at the image's edges. Releasing Space resizes again from the moved
corner, and releasing the mouse while moving asks about the moved region. Option and Shift do
nothing, since they're often still held from ⌥⇧S. The README mentions it.

## Medium

### 5. Copy from the keyboard (done)

Done on 11 October 2026: the Edit menu in `UI/EditMenu.swift` has Copy Answer (⇧⌘C) and Copy Code
(⌥⌘C), with no target, so `SessionWindows`, the conversation panel's delegate, receives them
through the responder chain and enables them only when there's something to copy. They press the
Copy buttons of the newest answer that offers Copy, even while a newer one streams, and of the
newest code block, so they show the same checkmark. Those buttons' tooltips name the shortcuts.
Copy now writes through `Clipboard`, which the self-test points at a private pasteboard.

### 6. Queue Return while an answer streams (done)

`ComposerView.submit` returned silently while a request ran, and the draft stayed in the field.

Done on 11 October 2026: Return while an answer is in progress queues the draft, and the field says
"Sends when this answer finishes". Once the answer finishes, the draft is sent as it then reads. If
the answer fails or you stop it, the draft stays in the field, unsent, and emptying the field
takes it out of the queue.

### 7. Recover from the four-window limit (done)

With four sessions open, a snip showed "Close a SnapScreen window before starting another snip."
and did nothing else.

Done on 11 October 2026: that notice has a Close Oldest button, which closes the conversation that
opened first, and the menu bar menu has Close All Conversations, enabled while one is open. The
core tells its delegate through a new `sessionControllerIsFull(_:)`, whose default shows the same
notice without a button, so the core's tests and fixtures don't change.

## Polish

8. **Reserve the thumbnail's space (done).** The thumbnail arrived with `.accepted`, after the
   crop, and pushed the loading row down. It now takes the selection's size in pixels at release
   (`ConversationView.reserveScreenshot`) and keeps it, so the crop fills its place without moving
   the thread. It doesn't show a crop of the frozen screen meanwhile: `CGImage.cropping` shares its
   pixels, which would keep the whole display in memory.
9. **Trim the panel's title bar (done).** Panels showed a disabled minimize button, a zoom button
   that stretched a floating panel over the app you're snipping, and the title "SnapScreen".
   `CompanionPanel.make` (`UI/Panels.swift`) now hides all three, for the conversation and the
   preview; the title stays for accessibility.
10. **Drop the tint inside a drawn selection (done).** `SelectionView.drawSelection` filled the
    region with 12% blue, so it looked different from what's sent. A dragged region now shows in
    its true colours, marked by the undimmed area and its border. The keyboard selection keeps
    its ring and fill, so the two remain distinguishable.
11. **Open the preview beside the conversation (done).** `SessionWindows.showPreview` centered it
    on the screen. It now passes the conversation panel's frame to `windowFrame`, so the preview
    opens to one side of it.
12. **Don't lose Settings edits (done).** Closing Settings dropped unsaved Default Prompt and limit
    edits without a word. Now closing saves them, and a newly typed key, as Save does
    (`SettingsWindowController.windowShouldClose`). If a value isn't allowed, Settings stays open
    showing why, and nothing is saved. The Save button stays, for saving without closing.

## Not proposed

These stay as they are: Escape and Command-W closing a conversation, release-to-ask, the
five-second delay before the loading label, and panels that never activate the app. As in
[standalone-app-plan.md](standalone-app-plan.md), a UI for customizing the shortcut, multi-display
capture and saved history aren't planned.
