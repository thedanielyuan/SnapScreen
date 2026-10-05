# SnapScreen product improvements

Reviewed on 5 October 2026 against `4dd698e` (version 1.1.0); line links are as of that commit.
Every problem below was checked in the code, and the Open Settings bug in 1.1 was reproduced in
Chromium. Priorities are judgment calls: there's no usage data, and this wasn't a hands-on
usability or accessibility review. Nothing here is implemented yet.

Section 1 fixes behavior that's broken or misleading today and is small enough to ship before
launch. Section 2 should follow the launch work in [REMEDIATION_PLAN.md](../REMEDIATION_PLAN.md).

Effort includes tests and doc updates. **S**: a day or less. **M**: a few days.

| #   | Item                                                     | Effort |
| --- | -------------------------------------------------------- | ------ |
| 1.1 | Fix the missing-API-key flow                             | S      |
| 1.2 | Keep a first answer's text when it fails mid-stream      | S      |
| 1.3 | Stop pulling the reader to the bottom while streaming    | S      |
| 1.4 | Fix the workspace's "reload this tab" advice             | S      |
| 2.1 | Show that a slow answer is still working                 | S      |
| 2.2 | Measure answer quality before changing prompts or models | M      |

## 1. Fix first

### 1.1 Fix the missing-API-key flow

A user without a key can snip, and then sees "No API key configured" with an Open Settings
button. On regular web pages that button does nothing: the content script calls
`chrome.runtime.openOptionsPage()` ([ui-proxy.ts](../src/content/ui-proxy.ts#L131)), which
content scripts can't use, so it throws `chrome.runtime.openOptionsPage is not a function`. The
unit test stubs that API ([ui-proxy.test.ts](../src/content/ui-proxy.test.ts#L77)), and the smoke
test cancels its no-key snip before the error appears, so neither catches it. The button only
works in the workspace, which is an extension page.

The error also lacks the Try again button most errors have
([`appendError`](../src/content/result-panel.ts#L591)). The capture stays in memory while the
panel is open, but after saving a key the user can't use it and has to snip again.

- Have the content script ask the background to open the options page, with a new `messages.ts`
  variant and its `isControllerMessage` case in `workspace-protocol.ts`. Click the button in the
  smoke test.
- Show Try again next to Open Settings.
- `START_SNIP` already tells the content script whether a key is set (`hasApiKey`,
  [messages.ts](../src/lib/messages.ts#L41)), but nothing reads it. Use it to mention the missing
  key in the snip overlay, or remove it.
- The options page puts the four request limits next to the key and prompt
  ([options.html](../src/options/options.html#L45)). Move them into a collapsed Advanced section.

**Done when:** on a regular web page, a user without a key can snip, open Settings from the
error, save a key, come back, and get an answer to the same capture without snipping again.

### 1.2 Keep a first answer's text when it fails mid-stream

If the first answer fails partway, for example on a network error or the 240-second timeout,
[`settleGenerationFailure`](../src/content/capture-controller.ts#L266) throws away the text that
already streamed and shows only the error. Follow-ups already handle this: a failed follow-up
keeps its partial text, marks it failed, and offers Retry and Remove. A first answer the user
stops also keeps its text.

Give failed first answers the same treatment: keep the partial text, mark it as interrupted, and
offer Try again.

**Done when:**

- A first answer that fails after streaming some text still shows that text, marked as
  interrupted rather than complete.
- Try again replaces it with a new answer to the same capture.
- A follow-up asked after an interrupted first answer succeeds.

### 1.3 Stop pulling the reader to the bottom while streaming

Each streamed chunk scrolls the answer to the bottom
([`updateStreamingAnswer`](../src/content/result-panel.ts#L975)), and so does the re-render when
the answer finishes ([`showResultPanel`](../src/content/result-panel.ts#L282)). A reader who
scrolls up to the start of a long answer gets pulled back down with every chunk.

Follow new text only when the reader is already at or near the bottom.

**Done when:** a reader who scrolls up during streaming stays put through the end of the answer,
and one who stays at the bottom still sees new text arrive.

### 1.4 Fix the workspace's "reload this tab" advice

When the workspace tab loses its background connection, it says "Reload this tab or capture
again" ([workspace.ts](../src/workspace/workspace.ts#L224)). Reloading can't work. The workspace
removes its one-time session ID and nonce from the URL when it loads
([L55](../src/workspace/workspace.ts#L55)), so a reloaded tab only says the workspace has
expired, and the background no longer has the screenshot once the workspace has claimed it
([security.md](security.md#screenshots)).

Tell users to close the tab and snip again from the original page instead. Don't make reload
work: that would mean keeping the screenshot and a reusable credential around, which the security
design deliberately avoids.

**Done when:** no workspace message suggests reloading.

## 2. Next

### 2.1 Show that a slow answer is still working

With adaptive thinking, a hard question can stream no text for over 30 seconds. Meanwhile the
panel shows only a spinner, announced as "Loading"
([`createPendingIndicator`](../src/content/result-panel.ts#L423)), so a long wait looks like a
hang.

After a few seconds, show the elapsed time with a short status, such as "Thinking… 0:24". Say
"Thinking" only if the stream shows a thinking block has started; otherwise say something like
"Waiting for the answer". No made-up progress bars. Keep the adaptive-thinking and effort
settings.

**Done when:** a 30-second wait shows a running timer and a working Stop button, and screen
readers hear a useful status once rather than every second.

### 2.2 Measure answer quality before changing prompts or models

The only test against the real API sends a 1×1 image and checks that some text comes back
([anthropic.live.test.ts](../src/lib/anthropic.live.test.ts#L19)), and the prompt tests check
only wording ([screenshot-qa-prompt.test.ts](../src/lib/screenshot-qa-prompt.test.ts#L7)).
Nothing shows whether a prompt edit or a model upgrade makes answers better or worse.

Build a set of 20–30 non-sensitive screenshots: charts, tiny text, maths, multiple choice, code
with and without a stated language, cut-off crops where the right answer is to ask for a retake,
and a few follow-up conversations. Give each one an expected answer a script can check (a
number, an option, a phrase), or a short rubric where judgment is needed. Add a script that runs
them through the production request code and prints scores and latency.

Each run spends API credit, so keep it out of `npm test` and CI and run it only with approval.
Keep the daily live API check separate.

**Done when:**

- One command runs the set and prints a summary that can be compared before and after a change.
- The set includes cases where asking for a retake or a programming language is the right
  answer.
- Nothing in CI or `npm test` runs it.

## Left out

- **Saved history.** Writing screenshots or conversations to disk would break the privacy
  policy's promise that "SnapScreen never writes screenshots or conversations to disk." Revisit
  only as an explicit opt-in, with a policy update.
- **Conversation export.** Every answer and code block already has a Copy button.
- **Guided setup with a sample snip.** Settings already opens on install, with Test key and the
  shortcut; 1.1 fixes the real gap.

Every item also follows [AGENTS.md](../AGENTS.md): validator cases for new message variants, no
changes to the system prompt or earlier messages between turns, and updates to
[PRIVACY.md](../PRIVACY.md), [security.md](security.md), and
[chrome-web-store.md](chrome-web-store.md) when permissions or data handling change.
