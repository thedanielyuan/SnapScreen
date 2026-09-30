# SnapScreen Improvement Plan

> **Historical document:** This audit describes an earlier version of SnapScreen and is retained for context only. Several findings and proposed features below have since been implemented or superseded; verify every item against the current code before acting on it.

A read-only audit of the codebase (all of `src/`, the manifest, build config, and styles) with prioritized recommendations. **No changes have been made** — this document is the deliverable; each item should be approved before implementation.

Effort scale: **XS** = minutes, **S** = under an hour, **M** = a few hours, **L** = a day or more.

---

## 1. Codebase Improvements

### 1.1 Infrastructure & tooling

#### C1. Initialize a git repository — **XS, highest leverage**
- **What:** The project is not under version control at all. `git init`, commit the current state, and optionally add a remote.
- **Why:** Every other change in this plan is risky without a way to diff and roll back. The existing `.gitignore` is already suitable (covers `node_modules`, `dist`, `.DS_Store`).
- **Affected:** repo root.

#### C2. Add a typecheck gate — **XS**
- **What:** `vite build` bundles without ever running the TypeScript compiler, so type errors ship silently despite the strict `tsconfig.json`. Add `"typecheck": "tsc --noEmit"` to `package.json` and chain it into `build` (`"build": "tsc --noEmit && vite build"`).
- **Why:** The strict compiler options (`strict`, `noUnusedLocals`, etc.) are currently decorative — nothing enforces them.
- **Affected:** `package.json`.

#### C3. Add a test runner and first tests — **S–M**
- **What:** Install Vitest and cover the pure-logic modules, which need no browser mocking:
  - `src/lib/clamp-to-viewport.ts` — clamping math, oversized-panel edge cases
  - `src/lib/plain-text.ts` — `stripMarkdown` (nested markers, backticks in math answers)
  - `src/lib/crop.ts` — `dataUrlToBase64`
  - `src/lib/anthropic.ts` — history-assembly logic (after C5 is resolved)
- **Why:** Zero tests today. These modules encode the trickiest logic (coordinate math, string munging, conversation state) and are the most likely regression points.
- **Affected:** `package.json`, new `*.test.ts` files.

#### C4. Remove dead assets and cruft — **XS**
- **What:** Delete unreferenced files: `src/assets/hero.png`, `src/assets/vite.svg`, `src/assets/typescript.svg`, `public/icons.svg`, `public/favicon.svg` (both ship to `dist/` but nothing links them), scattered `.DS_Store` files, and the empty `.cursor/` directory.
- **Why:** `hero.png` alone bloats the packaged extension; unused files confuse future readers about what's load-bearing.
- **Affected:** `src/assets/`, `public/`.

### 1.2 Correctness bugs & latent issues

#### C5. Dead (and subtly broken) history branch in `analyzeImage` — **XS**
- **What:** `src/lib/anthropic.ts:40–56` has a `history?.length` code path, but the content script never sends history with `ANALYZE` (`src/content/index.ts:109–113`), so it's dead code — and if it were ever exercised, it would re-send the prompt *without* the screenshot. Delete the branch (recommended) or fix it properly.
- **Why:** Dead code that looks load-bearing is worse than no code; anyone extending re-analysis will trip over it.
- **Affected:** `src/lib/anthropic.ts`.

#### C6. Adaptive-thinking token squeeze on Sonnet 5.5 — **XS, user-visible impact**
- **What:** The API request (`src/lib/anthropic.ts:95–100`) omits the `thinking` parameter. On `claude-sonnet-5-5`, omitting it means **adaptive thinking runs by default**, and thinking tokens count against the hard `max_tokens: 1024` cap. A hard question can burn most of the budget on (invisible) thinking and return a truncated or empty answer — surfacing as the cryptic "No response text received" error — plus added latency for a tool whose whole point is instant answers.
- **Recommendation (model string stays `claude-sonnet-5-5`):** either add `thinking: { type: "between_tools" }` (Sonnet 5.5 rejects `"disabled"`) with `output_config: { effort: "low" }` for fast snappy answers, or keep adaptive thinking and raise `max_tokens` substantially (e.g. 4096+). The first option fits this product better.
- **Affected:** `src/lib/anthropic.ts` (`callApi`).

#### C7. No `stop_reason` handling — **S**
- **What:** `callApi` (`src/lib/anthropic.ts:122–129`) reads `content` without checking `stop_reason`. A `max_tokens` truncation is returned as if complete; a `refusal` returns empty content and surfaces as "No response text received."
- **Why:** Users get either silently cut-off answers or a misleading error. Branch on `stop_reason` and map to clear messages ("Answer was cut off — try a smaller region" / "Claude declined to answer this").
- **Affected:** `src/lib/anthropic.ts`.

#### C8. Crop coordinates can exceed the bitmap — **XS**
- **What:** `src/lib/crop.ts:12–22` computes `sx/sy/sw/sh` as `Math.round(rect.* * devicePixelRatio)` with no clamping. Selections at the right/bottom screen edge (especially at fractional DPRs like 1.25/1.5) can push `sx + sw` past `bitmap.width`, producing a blank strip in the capture.
- **Fix:** clamp source rect to `bitmap.width`/`bitmap.height` before `drawImage`.
- **Affected:** `src/lib/crop.ts`.

#### C9. No request timeout — **XS**
- **What:** The `fetch` in `callApi` has no timeout; a hung connection leaves the panel spinner running forever (the only escape is closing the panel).
- **Fix:** combine the caller's abort signal with `AbortSignal.timeout(60_000)` via `AbortSignal.any`.
- **Affected:** `src/lib/anthropic.ts`.

#### C10. Duplicated response delivery — **XS**
- **What:** The service worker delivers results twice: via `chrome.tabs.sendMessage({type: 'ANALYZE_RESULT', ...})` *and* via `sendResponse({ok: true, ...result})` (`src/background/service-worker.ts:200–206`, `247–253`). The content script fires its messages without a callback, so the `sendResponse` payload (including the full history and screenshot data) is serialized and dropped.
- **Fix:** keep the push (`tabs.sendMessage`) path; slim `sendResponse` to a bare ack.
- **Affected:** `src/background/service-worker.ts`.

#### C11. Duplicated session-reset logic — **XS**
- **What:** `cleanup()` and `resetSessionState()` in `src/content/index.ts:18–34` are near-identical (differ only in sending `CANCEL_GENERATION` and clearing `lastRect`). Consolidate into one function with a flag or have one call the other.
- **Affected:** `src/content/index.ts`.

### 1.3 Security & privacy

#### C12. Keep the API key out of the content-script world — **S**
- **What:** The content script reads `chrome.storage.local.get(['apiKey'])` directly (`src/content/index.ts:86`) just to pick a hint string. Storing the key in `chrome.storage.local` and calling the API browser-side (with the `anthropic-dangerous-direct-browser-access` header, `src/lib/anthropic.ts:93`) is inherent to the no-backend design — but the *content script* running in web pages has no need to touch the key at all.
- **Fix:** have the background pass a `hasApiKey: boolean` with `START_SNIP`, and document the key-storage tradeoff in the README's Privacy section.
- **Affected:** `src/content/index.ts`, `src/background/service-worker.ts`, `README.md`.

#### C13. Validate message senders — **XS**
- **What:** The service worker's `onMessage` listener trusts any sender. Risk is low in MV3 (web pages can't message the extension without `externally_connectable`), but checking `sender.id === chrome.runtime.id` and requiring `sender.tab` for tab-scoped messages is a one-line hardening.
- **Affected:** `src/background/service-worker.ts`.

### 1.4 Documentation consistency

#### C14. README overclaims dark-mode support — **XS (doc fix) or M (real feature, see U4)**
- **What:** README lists "Dark mode — UI adapts to your system theme," but the result panel is hardcoded dark (`src/content/overlay.css:44–71`, including `color-scheme: dark`); only the options page adapts. Either correct the README or implement the light theme (U4 below).
- **Affected:** `README.md` (and optionally `overlay.css`).

---

## 2. UI/UX Features

#### U1. Streaming responses — **M–L, biggest UX win**
- **What:** Answers currently appear only when fully generated. Add `stream: true` to the existing `fetch` (the raw SSE format is straightforward — `content_block_delta` events carry `text_delta` chunks), relay chunks from the service worker to the content script, and append text incrementally in the panel.
- **Why:** Perceived latency is the core metric for a "instant answer" tool; streaming makes even slow answers feel fast, and pairs naturally with a working Stop button (U2).
- **Affected:** `src/lib/anthropic.ts`, `src/background/service-worker.ts`, `src/lib/messages.ts` (new chunk message), `src/content/result-panel.ts`.

#### U2. Stop and Retry controls — **S**
- **What:** While pending, show a Stop button (the plumbing already exists: `CANCEL_GENERATION` + `abortByTab` in the service worker). On errors, show a Retry button — today only the `no_api_key` error offers an action (Open Settings).
- **Why:** Right now the only way to stop a generation is to close the panel and lose the thread; transient network/server errors force a full re-snip.
- **Affected:** `src/content/result-panel.ts`, `src/content/index.ts`.

#### U3. Copy-answer button — **S**
- **What:** One-click copy of the assistant's answer text (small icon button per assistant bubble or in the header); optionally a "copy screenshot" action on the thumbnail/lightbox.
- **Why:** The primary use case (get an answer, paste it somewhere) currently requires manual text selection inside a small scrollable panel.
- **Affected:** `src/content/result-panel.ts`, `src/content/overlay.css`.

#### U4. Light theme for the panel — **M**
- **What:** The panel already routes all its colors through CSS variables on `.snapscreen-panel`. Add a `prefers-color-scheme: light` block redefining those variables (and flip `color-scheme`).
- **Why:** Delivers the dark/light adaptation the README promises; a dark panel over light pages is visually jarring.
- **Affected:** `src/content/overlay.css`.

#### U5. Pointer cursors on interactive elements — **XS**
- **What:** Nearly every interactive element forces `cursor: default !important` — close button, send button, screenshot thumbnail, lightbox close, and the drag handle (`src/content/overlay.css`, multiple rules). Use `pointer` for buttons and `grab`/`grabbing` for the drag handle.
- **Why:** Cursor affordance is how users discover that the panel is draggable and the thumbnail is clickable; right now both are invisible features.
- **Affected:** `src/content/overlay.css`.

#### U6. Esc to close + safer dismissal — **S**
- **What:** Esc closes only the lightbox, not the panel. Meanwhile the invisible full-page backdrop closes the panel on *any* outside click — easy to lose an answer thread accidentally, and the page underneath is un-interactable while the panel is open. Add an Esc handler for the panel; consider making the backdrop click-through (close via button/Esc only) or requiring confirmation when a follow-up thread exists.
- **Affected:** `src/content/result-panel.ts`.

#### U7. Panel accessibility — **S**
- **What:** The result panel lacks `role="dialog"`/`aria-modal`, focus is not moved into it on open, and there's no focus trap — the lightbox already implements one (`src/content/result-panel.ts:271–307`) that can be generalized. The follow-up textarea should get an `aria-label` (placeholder-only labeling isn't announced reliably).
- **Why:** Keyboard/screen-reader users can currently interact with the (visually blocked) page behind the panel.
- **Affected:** `src/content/result-panel.ts`.

#### U8. Selection size indicator during snip — **S**
- **What:** Show a live `W × H px` badge near the selection rectangle while dragging (`src/content/snip-overlay.ts`).
- **Why:** Standard affordance in every screenshot tool; helps users judge whether they've captured enough of the question, reducing failed "unreadable screenshot" round-trips (which cost an API call each).
- **Affected:** `src/content/snip-overlay.ts`, `src/content/overlay.css`.

#### U9. Re-snip from the panel — **S**
- **What:** A "New snip" button in the panel header that closes the panel and restarts the overlay, instead of requiring the toolbar icon or keyboard shortcut again.
- **Why:** Retaking a capture (wrong region, page scrolled) is the most common recovery flow.
- **Affected:** `src/content/result-panel.ts`, `src/content/index.ts`.

#### U10. Options page upgrades — **S–M**
- **What:**
  - Show/hide toggle on the API key field (it's `type="password"` with no reveal).
  - "Test key" button that fires a minimal API call and reports success/failure inline.
  - Surface the snip keyboard shortcut and link to `chrome://extensions/shortcuts` (Chrome blocks direct links, so display the URL as copyable text).
- **Why:** Key typos currently surface only later as an "Invalid API key" error mid-flow; the shortcut is undiscoverable after install.
- **Affected:** `src/options/options.html`, `src/options/options.ts`, `src/options/options.css`.

#### U11. Show the initial question in the thread — **XS**
- **What:** The first exchange renders only the assistant bubble (`displayMessages` starts empty and the default prompt is never displayed). Render the prompt that was used as the first user bubble.
- **Why:** Makes the thread read as a conversation and shows users what was actually asked — especially once custom default prompts are in play.
- **Affected:** `src/content/index.ts`.

#### U12. Better rate-limit feedback — **XS**
- **What:** On HTTP 429, read the `retry-after` header and include it in the message ("Rate limit reached — try again in ~20s") instead of the generic text.
- **Affected:** `src/lib/anthropic.ts`.

#### U13. (Optional, direction change) Render minimal markdown instead of stripping it — **M**
- **What:** `stripMarkdown` regex-strips formatting and can mangle legitimate content (backticks in code answers, `*` in math). The alternative: keep asking the model for plain text, but safely render a minimal subset (bold, inline code, lists) in assistant bubbles instead of destructive stripping.
- **Why:** Better readability for math working and code answers. This changes product direction (plain-text-only is a deliberate current choice), so decide explicitly.
- **Affected:** `src/lib/plain-text.ts`, `src/content/result-panel.ts`, `src/lib/screenshot-qa-prompt.ts`.

---

## 3. Prioritized Roadmap

### Phase 1 — Quick wins (each XS–S, do first)

| # | Item | Effort |
|---|------|--------|
| C1 | `git init` + first commit | XS |
| C2 | Typecheck script wired into build | XS |
| C4 | Delete dead assets / `.DS_Store` / empty dirs | XS |
| C5 | Remove dead history branch in `analyzeImage` | XS |
| C8 | Clamp crop bounds to bitmap | XS |
| C9 | Fetch timeout | XS |
| C10 | Drop duplicated `sendResponse` payloads | XS |
| C11 | Consolidate session-reset functions | XS |
| C13 | Sender validation | XS |
| C14 | README dark-mode correction | XS |
| U5 | Pointer cursors | XS |
| U11 | Show initial question in thread | XS |
| U12 | Rate-limit retry-after message | XS |
| U6 | Esc-to-close panel | S |

### Phase 2 — High impact, moderate effort

| # | Item | Effort |
|---|------|--------|
| C6 | Thinking/effort tuning (fixes latency + truncation) | XS |
| C7 | `stop_reason` handling with clear error messages | S |
| U2 | Stop / Retry controls | S |
| U3 | Copy-answer button | S |
| U7 | Panel accessibility (dialog role, focus trap) | S |
| U8 | Selection size indicator | S |
| U9 | Re-snip from panel | S |
| C12 | Keep API key out of content script + README privacy note | S |
| U10 | Options page: reveal toggle, Test key, shortcut info | S–M |
| C3 | Vitest + tests for the four pure-logic modules | S–M |

### Phase 3 — Larger initiatives

| # | Item | Effort |
|---|------|--------|
| U1 | Streaming responses (pairs with U2's Stop button) | M–L |
| U4 | Light theme for the panel | M |
| U13 | Markdown rendering decision (product call first) | M |

**Suggested sequencing rationale:** Phase 1 is almost all risk-free cleanup that makes every later change safer (version control, typechecking) or is trivially small. Phase 2 concentrates on the items users actually feel — C6/C7 fix real answer-quality failures, and U2/U3/U7 close the biggest interaction gaps. Phase 3's streaming work is the single largest UX improvement but touches the full message pipeline, so it benefits from the tests and version control landing first.
