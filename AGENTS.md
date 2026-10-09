# AGENTS.md

SnapScreen is a Chrome Manifest V3 extension (Chrome 116+): snip part of the current tab, then ask
Claude (`claude-opus-5-5`, streamed SSE) about it with the user's own API key. The main product
is the native-only extension (`dist-native/`), which always shows the snip and answers in a
macOS companion (`native/macos/`, Swift/AppKit) and injects nothing into the page. The original
In Chrome extension (`dist/`, the `ordinary` variant) renders them in the page and can
optionally use the companion; it stays as a fallback build. Strict TypeScript, built by Vite 8 +
`@crxjs/vite-plugin`. Shipped code is plain DOM + `fetch`: keep `package.json`
devDependencies-only, and don't add `@anthropic-ai/sdk` (the client is `src/lib/anthropic.ts`).

## Commands

```bash
npm ci                               # npm only (package-lock.json); CI uses Node 22
npx playwright install chromium      # once, for the browser tests
git config core.hooksPath .githooks  # once per clone: pre-push blocks branches behind main
npx vitest run src/lib/crop.test.ts  # one test file; add -t "<test name>" for one test
```

Before finishing any change, run CI's `verify` steps in this order (about 20 s). The smoke tests
load `dist/` and `dist-native/` (never hand-edit either), so rebuild before rerunning them. CI
also runs `npm audit --audit-level=moderate`, which can fail on a new advisory with no code change.

```bash
npm run lint && npm run typecheck && npm test && npm run test:extension-artifacts &&
  npm run build && npm run test:browser &&
  npm run build:extension-native && npm run test:browser-native && npm run package:extension-native
```

## Layout

- `src/background/` service worker, `src/options/` options page (Settings), `src/lib/` shared code
  and protocols, `scripts/` test and packaging runners
- `src/content/` — content script (`index.ts`, injected on demand). Its rendering code
  (`result-panel.ts`, `snip-overlay.ts`, `overlay.css`) runs only in the UI frame (`src/ui/`) and
  the workspace (`src/workspace/`, a tab used when a page rejects injection), never in the page;
  the content script reaches it through `ui-proxy.ts`.
- `native/macos/` — the companion, one host process per session;
  `src/background/native-session.ts` owns its session, crop, conversation, and API calls
- `experiments/native-phase1/` — finished prototype and evidence. Frozen: don't edit unless asked.

## Conventions

- Cross-context messages are discriminated unions in `src/lib/`: `messages.ts` (content ↔
  background), `ui-protocol.ts` (content ↔ UI frame), `workspace-protocol.ts` (workspace ↔
  background). Extend them; never send ad-hoc message objects.
- `ui-protocol.ts` and `workspace-protocol.ts` validate with hand-written `is…Message` functions
  whose `switch` defaults to `false`, and receivers silently drop failures, so add a case for
  every new variant (tsc won't flag a missing one). The workspace relays `messages.ts` traffic,
  so new variants there also need a case in `isControllerMessage` (`CsToBgMessage`) or
  `isControllerEvent` (`BgToCsMessage`) in `workspace-protocol.ts`.
- Surface failures as `AnthropicError(code, friendlyMessage)`. Provider/API text must pass
  through `sanitizeProviderMessage` (`src/lib/anthropic.ts`) before it can reach the UI.
- Vitest tests sit beside their source and default to Node; DOM tests start with
  `// @vitest-environment happy-dom` on line 1. Stub `chrome` per file with `vi.stubGlobal`.
- Script tests are `scripts/*.node-test.mjs`, which Vitest skips. `node --test` runs only those
  listed in a `package.json` script or `scripts/native-companion-test.mjs`; add new ones there.
- No formatter: match the surrounding style (2-space indent, single quotes, semicolons, commas).
- Update dependencies and workflow actions by hand; never add or suggest Dependabot or Renovate.
- Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`, `test:`). Land on `main` via PR from
  a `<type>/<topic>` branch cut from the remote tip, never local `main` (it falls behind):
  `git fetch origin && git switch --no-track -c <type>/<topic> origin/main`. `main` merges only
  up-to-date PRs; if it moves first, run `git fetch origin && git merge origin/main` and recheck.

## Security and privacy — do not regress

- Only the background worker and the options page read the API key or call the API. Content
  scripts, the UI frame, and the workspace never receive it; `chrome.storage.local` is
  restricted to `TRUSTED_CONTEXTS`.
- All injected UI renders in the extension-origin iframe inside a closed shadow host. Content ↔
  frame traffic uses the capability-attested `MessageChannel`, never `window.postMessage`, DOM
  events, or attributes.
- `src/ui/result-frame.html` is the only web-accessible resource. `src/workspace/workspace.html`
  must never be; it claims its capture as a one-time capability over a runtime port.
- The companion gets screenshots, crops, answers, and follow-ups, never the API key, system
  prompt, or API history. Its test hooks (`SNAPSCREEN_TEST_HOOKS`) compile only into the live
  suite's disposable app.
- `npm run test:browser` enforces parts of this; `docs/security.md` is the full contract. Update
  it when you change a boundary.
- When permissions or data handling change, also update `PRIVACY.md` and
  `docs/chrome-web-store.md` (the user pastes its answers into the store dashboard). Never add a
  privacy section or a `PRIVACY.md` link to `README.md`.

## Anthropic API (`src/lib/anthropic.ts`)

- Adaptive thinking, effort `high`, and `max_tokens: 32_000` are deliberate for answer quality;
  don't change them casually. Keep effort explicit: Opus 5.5 defaults to `medium`.
- Opus 5.5 always thinks: any `thinking.type` other than `'adaptive'`, even `'between_tools'`,
  returns 400, so `verifyApiKey`'s one-token key check sends no `thinking` field. Keep history to
  answer text: replayed thinking would trip its history-editing check when old turns are pruned.
- Answer requests send `fallbacks: 'default'` with the `server-side-fallback-2026-07-01` beta, so a
  refused answer continues in the same SSE stream on a model Anthropic picks, after a `fallback`
  content block the reader ignores. Categories without a fallback, such as
  `reasoning_extraction`, still end in the `refusal` error.
- Prompt caching is automatic (top-level `cache_control`): first answers and follow-ups must send
  the same `system` prompt and resend earlier messages unchanged, or follow-ups silently miss the
  cache. So follow-up rules live in the shared `src/lib/screenshot-qa-prompt.ts`, never in a
  separate prompt or a mid-conversation `system` message (not every fallback model accepts one).
- Answers are plain text except fenced code blocks, which `src/lib/code-blocks.ts` and
  `native/macos/AnswerView.swift` parse for per-block Copy buttons. Change the prompt's formatting
  rules and both parsers together.
- Thinking can stream no text for over 30 s, and Chrome may stop an idle worker even mid-fetch, so
  requests run inside `keepAliveUntilSettled`. Keep `API_REQUEST_TIMEOUT_MS` (240 s) under
  Chrome's 5-minute cap on one service-worker event.
- Other tests mock the API: only `src/lib/anthropic.live.test.ts` catches the real API rejecting a
  model, beta header, or request field. `npm test` skips it without `SNAPSCREEN_LIVE_API_KEY`;
  `.github/workflows/live-api.yml` runs it daily. After changing any of those, ask the user before
  running `gh workflow run live-api.yml --ref <branch>`, since it spends API credit.

## Native companion (macOS)

```bash
npm run build:native          # companion app → native/macos/build/
npm run test:native           # the built app's self-tests, then installer/package/runner tests
npm run test:native-live      # real Chrome-launched sessions, mocked answers; windows show ~10 s
npm run package:native        # unsigned app archive (signing is opt-in: docs/native-phase4.md)
npm run test:native-packaged  # extracted archive + shipped installer in disposable browser roots
```

- After touching `native/`, `src/lib/native-protocol.ts`, or `src/background/native-*.ts`, run
  the first three; build, packaging, or installer changes need all five. The live, packaged, and
  physical runners load `dist/` unless passed `-- --extension-dir dist-native`; for native-only
  changes, run the live and packaged tests against both builds, as CI does.
- The native protocol is validated on both sides with exact keys: `src/lib/native-protocol.ts` and
  `native/macos/Protocol.swift` (state machine in `Session.swift`). Change both sides and their
  tests (`native-protocol.test.ts`, `SelfTests.swift`) together.
- `scripts/native-companion-build.mjs` compiles an explicit list of Swift files; add new ones.
- Panels never activate the app, so Chrome stays active: close windows on key release
  (`CompanionPanel`) and give tracking areas `.activeAlways`. Match the In Chrome interface's
  wording and conversation behavior.
- The badge title is native mode's only lasting failure signal (Chrome ends a host about 2 s after
  its port closes; badges clear after 5 s), so keep `native-session.ts` messages accurate.
- `nativeMessaging` stays a required permission: a running worker's `chrome.runtime.connectNative`
  doesn't pick up one granted at runtime (`docs/chrome-web-store.md`).
- Leave `npm run install:native` to the user; it registers the host for a real browser.
- Physical acceptance (`npm run experiment:native-packaged -- --app <path>`) needs a human
  operator; read `docs/native-phase4-acceptance.md` first. Keep rounds to 5–7 numbered steps the
  product needs, and set window state yourself with the runner's `fullscreen`, `normal`, and
  `move` commands instead of asking the operator.
- The native-only extension has its own manifest, worker, and options page (`src/**/*-native.*`)
  and `vite.native.config.ts`; its worker ignores `interfaceMode`. Never import the ordinary
  worker into it or add the content script, result frame, workspace, or web-accessible resources.
  `test:browser-native` checks a temporary ZIP before adding its browser shim: keep package
  exclusions and runtime checks ahead of fixture instrumentation, and never ship test shims.

## Build and release gotchas

- The content script isn't in the manifest: `service-worker.ts` imports
  `../content/index.ts?script&iife` and injects it with `chrome.scripting.executeScript`. It must
  build to a synchronous IIFE, so nothing it imports may use dynamic `import()` (the smoke test
  checks). CRX makes that import web-accessible too, so `vite.config.ts` ships only the
  web-accessible resources `src/manifest.json` declares.
- `src/ui/result-frame.html`, `src/workspace/workspace.html`, and any new extension page must be
  in `rolldownOptions.input` in `vite.config.ts`. Without an entry the build still passes, but the
  frame ships unbundled and the workspace isn't emitted.
- `npm run dev` doesn't work (the strict CSP blocks the crxjs dev server) and leaves a dev build in
  `dist/` that fails `test:browser` until you rebuild. To try a change, build, load `dist-native/`
  (or `dist/` for In Chrome) unpacked at chrome://extensions, and reload it after each rebuild.
  Real answers need an API key; the native-only build also needs a registered companion.
- The version lives only in `package.json`; bump it with `npm version <x.y.z> --no-git-tag-version`.
  A matching `v<x.y.z>` tag runs `.github/workflows/release.yml`, which publishes only the
  native-only extension's ZIP (`npm run package:extension-native`), not the companion.
