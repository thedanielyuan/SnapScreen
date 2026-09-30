# AGENTS.md

SnapScreen is a Chrome extension (Manifest V3) that captures a selected region of the current
tab and answers questions about it via the Anthropic API (`claude-sonnet-5-5`, streamed SSE).
TypeScript (strict), built by Vite 8 + @crxjs/vite-plugin from `src/manifest.json`. No UI
framework and no runtime npm dependencies — shipped code is plain DOM + `fetch`; everything in
`package.json` is a devDependency.

## Setup

```bash
npm install                      # npm is the package manager (package-lock.json)
npx playwright install chromium  # one-time, only needed for `npm run test:browser`
```

CI uses Node 22; Node 24 verified locally. No `.nvmrc` or `engines` field.

## Commands

All verified; timings from a warm local run.

```bash
npm run lint          # ESLint flat config, zero warnings tolerated   (~1 s)
npm run typecheck     # tsc --noEmit                                  (~1 s)
npm test              # Vitest, full co-located suite                 (~2 s)
npx vitest run src/lib/crop.test.ts    # one test file
npm run build         # tsc --noEmit && vite build → dist/            (~1 s)
npm run test:browser  # Playwright smoke test; run `npm run build` first
npm run dev           # watch build; load dist/ unpacked, reload extension after changes
```

The whole battery (lint, typecheck, test, build, test:browser) takes under 10 s — run all of
it before finishing any change. CI (`.github/workflows/ci.yml`) runs exactly that plus
`npm audit --audit-level=moderate`.

## Layout

- `src/manifest.json` — source MV3 manifest; the crx plugin generates `dist/manifest.json` from it
- `src/background/` — service worker: capture flow, generation + UI-capability registries, API dispatch
- `src/content/` — isolated-world content script: snip overlay, conversation state, UI-frame host
- `src/ui/` — `result-frame.html`/`.ts`/`.css`: extension-origin iframe that renders all injected UI
- `src/workspace/` — extension-tab fallback that shows the capture when a page rejects injection
- `src/options/` — options page: API key, default prompt, request limits
- `src/lib/` — shared logic: Anthropic client, crop math, storage, request limits, typed protocols
- `scripts/extension-smoke.mjs` — the `test:browser` script
- `docs/archive/` — historical audit notes; explicitly not current
- `dist/` — generated output (gitignored); never hand-edit

## Conventions

- No formatter is configured. Match surrounding style by hand: 2-space indent, single quotes,
  semicolons, trailing commas.
- Tests are co-located (`foo.test.ts` beside `foo.ts`). Vitest runs with no config file; the
  default environment is Node, and DOM tests declare `// @vitest-environment happy-dom` on line 1.
- Cross-context messages are discriminated unions: `src/lib/messages.ts` (content ↔ background)
  and `src/lib/ui-protocol.ts` (content ↔ UI frame). Extend those types; no ad-hoc message objects.
- User-facing failures are `AnthropicError(code, message)` with friendly text; provider/API text
  is sanitized (key redaction, control-char strip, length cap) before it can reach the UI.

## Security invariants — do not regress

- Content scripts never receive or read the API key. Only the background worker and the options
  page call the API; `chrome.storage.local` is set to `TRUSTED_CONTEXTS` access level.
- All injected UI renders inside the extension-origin iframe in a closed shadow host. Content ↔
  frame traffic goes over a capability-attested `MessageChannel` — never plain
  `window.postMessage`, DOM events, or attributes.
- `npm run test:browser` enforces parts of this (a hostile-page probe checks that answer/composer
  text and key events never reach the host DOM). `docs/security.md` documents the full contract.

## Gotchas

- `src/ui/result-frame.html` must stay an explicit `rolldownOptions.input` in `vite.config.ts`;
  being a web_accessible_resource alone would not get its TS/CSS bundled.
- Model settings in `src/lib/anthropic.ts` (thinking off, effort high, `max_tokens: 4096`)
  are a deliberate product choice; don't change them casually.
  Sonnet 5.5 returns 400 for `thinking: {type: 'disabled'}`, so "off" is
  `{type: 'between_tools'}`. It must be the only field in `thinking`, and effort must stay
  `high` or lower.
- Answer requests send `fallbacks: 'default'` with the `server-side-fallback-2026-07-01` beta
  header. A refusal from the cyber or frontier-LLM classifier then continues on Anthropic's
  fallback model in the same SSE stream. The switch is marked by a `fallback` content block,
  which the stream reader ignores. Other refusal categories still end in the `refusal` error.
- Answer requests use automatic prompt caching (top-level `cache_control`). First answers and
  follow-ups must send the same `system` prompt and resend earlier messages unchanged, or
  follow-ups silently miss the cache and pay full input price. That is why the follow-up rules
  live in the shared system prompt, not in a separate prompt or a mid-conversation `system`
  message (Sonnet 5, the fallback model, isn't documented to accept those).
- CI's `npm audit --audit-level=moderate` gate can turn red from a new upstream advisory with no
  code change in the PR.
- The smoke test reads `dist/` — a stale build tests stale code. Build first, always.
- Manual run: build, then chrome://extensions → Developer mode → Load unpacked → `dist/`. The
  options page auto-opens on first install; real analysis needs an Anthropic API key.
