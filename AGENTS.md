# AGENTS.md

SnapScreen is a Chrome Manifest V3 extension: snip a region of the current tab, then ask Claude
(`claude-sonnet-5-5`, streamed SSE) about it. Strict TypeScript, built by Vite 8 +
`@crxjs/vite-plugin` from `src/manifest.json`. Shipped code is plain DOM + `fetch`: keep
`package.json` devDependencies-only, and don't add `@anthropic-ai/sdk` (the API client is
hand-written in `src/lib/anthropic.ts`).

## Commands

```bash
npm install                          # npm only (package-lock.json); CI uses Node 22
npx playwright install chromium      # once, for test:browser
npm run lint                         # ESLint (eslint.config.js); zero warnings allowed
npm run typecheck                    # tsc --noEmit
npm test                             # Vitest: every co-located *.test.ts
npx vitest run src/lib/crop.test.ts  # one file; add -t "<test name>" for one test
npm run build                        # tsc --noEmit && vite build → dist/ (never hand-edit)
npm run test:browser                 # Playwright smoke test of dist/; mocked API, no key needed
npm run package                      # zip the built dist/ into release/ for the Chrome Web Store
```

Before finishing any change, run lint, typecheck, test, build, then test:browser (under 10 s in
total). The smoke test runs whatever is in `dist/`, so it needs a fresh build. CI
(`.github/workflows/ci.yml`) runs the same steps plus `npm audit --audit-level=moderate`. There
is no formatter; match the surrounding style (2-space indent, single quotes, semicolons,
trailing commas).

Pushing a `v*` tag runs `.github/workflows/release.yml`: the same checks, then `npm run package`,
then a GitHub release with the zip. The tag must match the `package.json` version.
`.github/workflows/live-api.yml` runs `src/lib/anthropic.live.test.ts` against the real API
daily with the `SNAPSCREEN_LIVE_API_KEY` secret; without that variable the test is skipped.

## Layout

- `src/background/` — service worker: capture flow, UI/workspace session registries, API calls
- `src/content/` — content script, injected on demand: snip flow, conversation state, UI-frame host
- `src/ui/` — extension-origin iframe that renders all injected UI
- `src/workspace/` — extension tab that shows the capture when a page rejects injection
- `src/lib/` — shared: Anthropic client, system prompt, crop math, storage, limits, protocols

## Conventions

- Cross-context messages are discriminated unions in `src/lib/`: `messages.ts` (content ↔
  background), `ui-protocol.ts` (content ↔ UI frame), `workspace-protocol.ts` (workspace ↔
  background). Extend them; never send ad-hoc message objects.
- `ui-protocol.ts` and `workspace-protocol.ts` also hold hand-written `is…Message` validators.
  Their `switch` returns `false` by default, and receivers silently drop any message that fails.
  Add a validator case for every new variant, because tsc won't flag a missing one.
  `workspace-protocol.ts` also re-validates the `messages.ts` types that the workspace relays,
  so new `messages.ts` variants need a case there too.
- Surface failures as `AnthropicError(code, friendlyMessage)`. Provider/API text must pass
  through the sanitizer in `src/lib/anthropic.ts` (key redaction, control-char strip, length
  cap) before it can reach the UI.
- Tests sit beside their source (`foo.test.ts`). Vitest defaults to Node; DOM tests start with
  `// @vitest-environment happy-dom` on line 1. Stub `chrome` per file with
  `vi.stubGlobal('chrome', …)`.
- Commits use Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`). Branch as
  `<type>/<topic>` and land on `main` via PR.

## Security invariants — do not regress

- Only the background worker and the options page read the API key or call the API. Content
  scripts, the UI frame, and the workspace never receive it. `chrome.storage.local` is
  restricted to `TRUSTED_CONTEXTS`.
- All injected UI renders inside the extension-origin iframe in a closed shadow host. Content ↔
  frame traffic uses the capability-attested `MessageChannel`, never `window.postMessage`, DOM
  events, or attributes.
- `src/workspace/workspace.html` must never be web-accessible. It gets its capture by claiming
  a one-time capability over a runtime port.
- `npm run test:browser` enforces parts of this (hostile-page probe, closed shadow root,
  non-web-accessible workspace). `docs/security.md` is the full contract; update it when you
  change a boundary.

## Gotchas

- The content script isn't declared in the manifest. `service-worker.ts` imports
  `../content/index.ts?script&iife` and injects it with `chrome.scripting.executeScript`. It
  must build to a synchronous IIFE, so nothing it imports may use dynamic `import()`; the smoke
  test fails otherwise.
- `src/ui/result-frame.html` and `src/workspace/workspace.html` must stay in
  `rolldownOptions.input` in `vite.config.ts`, and any new extension page belongs there too.
  Without that entry the build still passes, but the frame ships unbundled and the workspace
  isn't emitted at all.
- Model settings in `src/lib/anthropic.ts` (adaptive thinking, effort `high`,
  `max_tokens: 32_000`) are a deliberate choice for answer quality; don't change them casually.
  Thinking counts toward `max_tokens`. The stream reader skips thinking blocks and history
  stores only answer text, so thinking is never sent back and turn pruning can't trip Sonnet
  5.5's history-editing check on replayed thinking. Sonnet 5.5 returns 400 for
  `thinking: {type: 'disabled'}`; "off" is `{type: 'between_tools'}` (the only `thinking` field
  allowed, effort `high` or lower), which `verifyApiKey`'s one-token key check still uses.
- A thinking answer can stream no text for over 30 s, and Chrome may stop an idle service
  worker even mid-fetch. `keepAliveUntilSettled` (`src/background/worker-keepalive.ts`) calls
  an extension API every 25 s while a request runs. The 240 s request timeout
  (`API_REQUEST_TIMEOUT_MS`) stays under Chrome's 5-minute cap on one service-worker event.
- Answer requests send `fallbacks: 'default'` with the `server-side-fallback-2026-07-01` beta
  header. A `cyber` or `frontier_llm` refusal then continues on Claude Sonnet 5 in the same SSE
  stream. The switch is marked by a `fallback` content block, which the stream reader ignores.
  Other refusal categories still end in the `refusal` error.
- Answer requests use automatic prompt caching (top-level `cache_control`). First answers and
  follow-ups must send the same `system` prompt and resend earlier messages unchanged, or
  follow-ups silently miss the cache. That's why follow-up rules live in the shared prompt in
  `src/lib/screenshot-qa-prompt.ts`. Don't move them to a separate prompt or a mid-conversation
  `system` message, which Sonnet 5 (the fallback model) rejects.
- Answers are plain text except fenced code blocks: the prompt asks for fences,
  `src/lib/code-blocks.ts` parses them, and the result panel gives each block its own Copy
  button. Change the prompt's formatting rules and the parser together.
- In the injected frame, the host page's permissions policy blocks `navigator.clipboard`, so
  Copy buttons work through the `execCommand('copy')` fallback, which needs a real click.
- The smoke test's hostile-page probe must stay limited to the top frame: init scripts also run
  in the extension frame, where the probe would cancel the frame's own clicks. In headless
  Chromium, clicks in the bottom ~90 px of the viewport never reach the extension frame, so
  the composer-focus check passes through auto-focus, not the click.
- `npm run dev` doesn't work. The manifest's strict CSP blocks the crxjs dev server, so
  extension pages hang on its loading screen. It also leaves a dev build in `dist/` that makes
  `test:browser` time out after 30 s.
- The extension version lives only in `package.json`; `vite.config.ts` writes it into the built
  manifest, so `src/manifest.json` has no `version`. Bump it with
  `npm version <x.y.z> --no-git-tag-version`.
- GitHub turns off scheduled workflows in a public repo after 60 days without activity, which
  stops the daily live API check. Re-enable it from the repo's Actions tab.
- CI's `npm audit` gate can turn red from a new upstream advisory with no code change.
- Manual run: `npm run build`, then chrome://extensions → Developer mode → Load unpacked →
  `dist/`. Reload the extension after each rebuild. Real answers need an Anthropic API key,
  which you enter on the options page.
