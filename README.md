# SnapScreen

A Chrome extension that turns any on-screen question into an instant answer using Anthropic Claude.

Press a shortcut, drag a rectangle around anything on the page — a quiz question, an error
dialog, a chart — and SnapScreen sends that region to Claude's vision API and streams the
answer back into an overlay panel, where you can keep asking follow-ups about the same capture.

## Features

- **Snip mode** — click the toolbar icon or press `Alt+Shift+S` (`Option+Shift+S` on macOS)
- **Region selection** — drag a rectangle, or create and adjust one entirely from the keyboard
- **Universal tab capture** — works on every visible tab Chrome allows extensions to capture,
  including browser pages, the Chrome Web Store, PDFs, data URLs, and opted-in local files
- **Trusted fallback workspace** — protected tabs open their frozen screenshot in one reusable
  extension tab when Chrome blocks in-page UI injection
- **AI analysis** — sends the capture to Claude's vision API with your question
- **Follow-up questions** — ask more about the same screenshot without re-capturing
- **Streaming answers** — responses appear word by word as they're generated
- **Session controls** — stop, retry, copy an answer, enlarge the capture, or start a new snip
- **Request safeguards** — configurable question, image-size, image-dimension, and conversation limits
- **Dark & light mode** — the answer panel and settings page adapt to your system theme

## Requirements

- Chrome 116 or newer
- An [Anthropic API key](https://console.anthropic.com/) — only needed when analysis runs;
  snipping itself works without one
- Node.js 22+ and npm, to build from source

## Setup

### 1. Get an API key

Create an API key at the [Anthropic Console](https://console.anthropic.com/).

### 2. Build the extension

```bash
npm install
npm run build
```

### 3. Load in Chrome

1. Open `chrome://extensions`
2. Enable **Developer mode**
3. Click **Load unpacked**
4. Select the `dist/` folder

The options page opens automatically on first install so you can paste your API key.

### 4. Configure

Right-click the SnapScreen icon → **Options**, or open the extension's options page. Enter
your API key and optionally customize the default prompt.

**Note:** An API key is only required for AI analysis after you capture a region. Snip mode
works without a key — you'll be prompted to add one when analysis runs.

### 5. Set keyboard shortcut (optional)

Visit `chrome://extensions/shortcuts` to confirm or change the snip shortcut. If the default
`Alt+Shift+S` doesn't work, it may be unassigned due to a conflict — assign it manually there.

## Usage

1. Navigate to the tab you want to capture
2. Click the SnapScreen icon or press `Alt+Shift+S` / `Option+Shift+S`
3. Drag to select a region, or press **Enter** to create a keyboard selection
4. Wait for the AI answer to appear in the overlay panel
5. Type a follow-up question if needed

On pages where Chrome does not permit content-script injection, SnapScreen opens a trusted
extension workspace containing the already-frozen screenshot. **New snip** briefly returns to
the source tab, captures it, and returns to the same workspace. **Close** returns to the source
tab and closes the workspace. If the source navigates or closes, the existing screenshot and
follow-up conversation remain available, but a new snip requires invoking SnapScreen again on
the source page.

For `file://` pages, Chrome asks for the optional local-file host permission. Chrome also has a
separate **Allow access to file URLs** toggle on the extension's Manage Extension page; the
workspace links there if that toggle is still off.

For keyboard selection, use the **arrow keys** to move the rectangle, **Shift + arrow keys**
to resize it, and **Enter** to confirm. Press **Esc** or click without dragging during
selection to cancel. Click outside the result panel to dismiss it.

## Project structure

- `src/background/` — Manifest V3 service worker: screen capture and Anthropic API calls
- `src/content/` — content script: crop selector and conversation state
- `src/ui/` — the extension-origin iframe that renders the answer panel and composer
- `src/workspace/` — trusted extension-page fallback for tabs that reject script injection
- `src/options/` — settings page (API key, default prompt, request limits)
- `src/lib/` — shared logic: API client, crop math, storage, request limits
- `scripts/extension-smoke.mjs` — Playwright browser smoke test

See [AGENTS.md](AGENTS.md) for the full command reference, code conventions, and the
security invariants that changes must preserve.

## Development

```bash
npm run dev
```

Load the `dist/` folder as an unpacked extension. Vite will rebuild on file changes — reload
the extension in `chrome://extensions` after changes.

Before submitting a change, run the automated checks (the whole set takes seconds):

```bash
npm run lint
npm run typecheck
npm test
npm run build
npm run test:browser
```

The browser smoke test (`test:browser`) launches Playwright's bundled Chromium, loads the
built `dist/` as an unpacked extension, drives a keyboard crop selection on a strict-CSP
fixture page with a mocked streamed Anthropic answer, and verifies that answer text, composer
input, and keyboard events stay isolated from the host page. It does not exercise toolbar
activation, Chrome's `activeTab` grant, or the real screenshot encoder. Install its browser
once with `npx playwright install chromium`, and build before running it.

## Limitations

- Captures only the **visible viewport** of the current tab (no full-page stitching)
- Chrome can omit or black out browser chrome, menus, permission dialogs, certificate/system
  surfaces, and DRM-protected video pixels; SnapScreen does not bypass those browser/OS limits
- Local files require both the optional `file:///*` permission and Chrome's per-extension
  **Allow access to file URLs** toggle
- Requires an internet connection and a valid Anthropic API key for AI analysis
- Requires Chrome 116 or newer

## Privacy

Your API key is stored unencrypted in `chrome.storage.local` on your device and is sent
directly to Anthropic's API only from trusted extension contexts: the background service for
screenshot analysis, and the options page when you choose **Test key**. It never passes
through a third-party server. SnapScreen restricts local extension storage to trusted
extension contexts, and its content scripts (the code injected into web pages) neither read
nor receive the key.

This is defense in depth, not credential encryption: anyone who can access or copy your
Chrome profile may still be able to extract the key. Use a dedicated Anthropic key with an
appropriate spend limit, revoke it if the profile is lost or compromised, and remove it from
SnapScreen when it is no longer needed. Screenshots are sent directly to Anthropic for
analysis and are not persisted by SnapScreen. Answer requests use Anthropic's prompt caching,
so Anthropic keeps the conversation, including the screenshot, cached for about 5 minutes
after its last use; this makes follow-up questions cheaper. A fallback screenshot remains
only in memory: the background holds it until the exact workspace claims its one-time
capability, after which the workspace page owns it. Only small source/workspace routing
metadata is kept in `chrome.storage.session` so a service-worker restart can reconnect the
workspace.

### Injected UI isolation

SnapScreen renders every injected interactive surface—the crop selector, result panel,
screenshot lightbox, composer, and toast—inside a full-viewport extension-origin iframe. The
iframe is mounted inside a closed-shadow outer `#snapscreen-ui-host`, so page CSS cannot
restyle the UI and ordinary page DOM APIs cannot locate the iframe or query its screenshot,
answer, composer value, lightbox, or controls. The host is removed when the UI is dismissed
so it does not affect page layout or captured pixels. The extension frame also remains
loadable on pages with a strict host Content Security Policy.

The isolated content script keeps capture and conversation state. It creates a fresh 32-byte
capability for each UI session, registers it with the background for its tab and top-level
document, places it in the hidden iframe URL fragment, and transfers one end of a
`MessageChannel` directly to that child with an exact extension `targetOrigin`. The exact
packaged child frame must claim that capability once before it acknowledges the channel;
claims expire and cannot be replayed or moved across tabs. Screenshot data, streamed answers,
composer submissions, and actions then travel only over the private port, never through
ordinary `window.postMessage`, page DOM events, or DOM attributes. Commands are validated and
buffered until attestation completes. Privileged actions such as opening Settings are sent
back to the trusted content controller rather than executed by the web-accessible frame, and
normal background commands reject extension-frame senders.

Pages that reject injection use a packaged workspace that is deliberately absent from
`web_accessible_resources`. Its exact top-level extension URL and tab must claim a one-time
session ID/nonce pair over a long-lived runtime port. Reconnects use a separate credential;
requests and streamed events are correlated and targeted to that authenticated workspace.
Workspace messages never supply the source tab ID, and the API key and Anthropic network
requests remain in the background worker.

This boundary protects confidentiality and prevents page capture listeners from cancelling
the frame's keyboard/input handling, but it is not a tamper-proof browser surface. Chrome
exposes coarse pointer activity retargeted to the outer host (not the internal target or
text); tests confirm that parent `preventDefault()` and `stopImmediatePropagation()` do not
block the child click. A hostile page can still remove, move, cover, or navigate the outer
host and cause denial of service or attempt clickjacking. The packaged frame is
web-accessible, but a page-created copy remains inert because it cannot register or claim a
legitimate session capability. A page can still imitate the extension visually with its own
HTML, so treat unexpected or context-sensitive prompts as untrusted, just as with any UI
rendered inside a web page.

## License

[MIT](LICENSE)
