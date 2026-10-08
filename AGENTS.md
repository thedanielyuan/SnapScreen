# AGENTS.md

SnapScreen is a Chrome Manifest V3 extension (Chrome 116+): snip a region of the current tab,
then ask Claude (`claude-opus-5-5`, streamed SSE) about it. Strict TypeScript, built by
Vite 8 + `@crxjs/vite-plugin` from `src/manifest.json`. Shipped code is plain DOM + `fetch`:
keep `package.json` devDependencies-only, and don't add `@anthropic-ai/sdk` (the API client is
hand-written in `src/lib/anthropic.ts`).

## Commands

```bash
npm ci                               # npm only (package-lock.json); CI uses Node 22
npx playwright install chromium      # once, for test:browser
git config core.hooksPath .githooks  # once per clone: pre-push check for stale branches
npm run lint                         # ESLint (eslint.config.js); zero warnings allowed
npm run typecheck                    # tsc --noEmit
npm test                             # Vitest: every co-located *.test.ts
npx vitest run src/lib/crop.test.ts  # one file; add -t "<test name>" for one test
npm run build                        # tsc --noEmit && vite build → dist/ (never hand-edit)
npm run test:browser                 # Playwright smoke test of dist/; mocked API, no key needed
npm run build:extension-native       # separate native-only Chrome extension → dist-native/
npm run test:browser-native          # ZIP/package negative controls + browser lifecycle; both fresh builds
npm run test:extension-artifacts     # variant selection, runner CLI and release package regressions
npm run package                      # zip the built dist/ into release/ for the Chrome Web Store
npm run package:extension-native     # validated native-only ZIP from dist-native/ → release/
npm run build:native                 # macOS: build the companion app into native/macos/build/
npm run test:native                  # macOS: companion self-tests and installer/package tests
npm run test:native-live             # macOS: real Chrome-launched companion sessions; defaults to dist/
npm run package:native               # macOS: unsigned production app archive for local acceptance
npm run test:native-packaged         # macOS: extracted archive + installed host; defaults to dist/
```

Before finishing any change, run lint, typecheck, test, build, then test:browser (under 10 s in
total). The smoke test runs whatever is in `dist/`, so it needs a fresh build. If you touch the
native companion (`native/`, `src/lib/native-protocol.ts`, `src/background/native-*.ts`), also
run build:native, test:native, then test:native-live on macOS; the live test shows companion
windows for about 10 s. CI (`.github/workflows/ci.yml`) runs the same steps plus
`npm audit --audit-level=moderate`, which can turn red from a new upstream advisory with no code
change, and a macOS job runs the native checks. There is no formatter; match the
surrounding style (2-space indent, single quotes, semicolons, trailing commas).

For native-only build or shared background/Settings changes, also run build:extension-native
then test:browser-native after the ordinary build/browser checks. The native-only build has its
own manifest, worker, Settings bootstrap, and Vite config; never import the ordinary worker
into it or include the content script, result frame, workspace, or web-accessible resources.
Its worker ignores interfaceMode. Native live, packaged, and physical runners accept
`--extension-dir dist-native`; omission keeps the repository `dist/` default, while explicit
relative paths resolve from the current working directory. For native-only changes, run live
and packaged native tests against `dist-native/` explicitly as well as the ordinary variant.
Native-only browser tests use mocked capture/host/API transport.
The native-only gate inspects a temporary ZIP before adding its disposable browser shim, then
loads the extracted assets. Its CDP worker restart checks fresh state/no replay, not natural
suspension or physical focus. Keep package exclusions and runtime checks ahead of fixture
instrumentation; never ship the smoke or acceptance shims. `package:extension-native` validates and archives
`dist-native/` separately; the tag workflow continues to publish only the ordinary extension.

For native build, packaging, or installer changes, also run package:native then
test:native-packaged. The latter uses the shipped installer and production app in disposable
browser roots. Physical focus acceptance uses `experiment:native-packaged -- --app <path>`;
pass `--extension-dir dist-native` for the native-only candidate and read
`docs/native-phase4-acceptance.md` before collecting evidence. Runner evidence records the
selected variant/path and original/fixture file and aggregate hashes. Packaged and physical
runners reject native test hooks; only the live suite builds a disposable test-hook app. Signing/notarization is
explicit opt-in (`docs/native-phase4.md`); default packages are unsigned local acceptance builds.

Unit and smoke tests mock the API, so only `src/lib/anthropic.live.test.ts` catches the real API
rejecting a model, beta header, or request field. `npm test` skips it unless
`SNAPSCREEN_LIVE_API_KEY` is set; `.github/workflows/live-api.yml` runs it daily with that repo
secret. After changing any of those, ask the user before running the check on your pushed
branch (`gh workflow run live-api.yml --ref <branch>`), since it spends API credit. GitHub
disables scheduled workflows in a public repo after 60 days without activity; re-enable the
daily check from the repo's Actions tab.

## Layout

- `src/background/` — service worker: capture flow, UI/workspace session registries, API calls
- `src/content/` — content script (`index.ts`, injected on demand): snip flow, conversation
  state, UI-frame host. The rendering code (`result-panel.ts`, `snip-overlay.ts` and their
  helpers, `overlay.css`) runs in the UI frame and the workspace, never in the page; the content
  script reaches it through `ui-proxy.ts`.
- `src/ui/` — extension-origin iframe that renders all injected UI
- `src/workspace/` — extension tab that shows the capture when a page rejects injection; reuses
  the content script's capture controller and rendering code
- `src/options/` — options page: API key, default prompt, limits, interface choice
- `native/macos/` — Swift/AppKit companion for the experimental native interface. Chrome launches
  one host process per session over Native Messaging; `src/background/native-session.ts` owns
  the session, crop, conversation, and API calls
- `src/lib/` — shared: Anthropic client, system prompt, crop math, storage, limits, protocols

## Conventions

- Cross-context messages are discriminated unions in `src/lib/`: `messages.ts` (content ↔
  background), `ui-protocol.ts` (content ↔ UI frame), `workspace-protocol.ts` (workspace ↔
  background). Extend them; never send ad-hoc message objects.
- `ui-protocol.ts` and `workspace-protocol.ts` also hold hand-written `is…Message` validators.
  Their `switch` returns `false` by default, and receivers silently drop any message that fails.
  Add a validator case for every new variant, because tsc won't flag a missing one. The
  workspace relays `messages.ts` traffic, so new variants there also need a case in
  `workspace-protocol.ts`: `isControllerMessage` (`CsToBgMessage`) or `isControllerEvent`
  (`BgToCsMessage`).
- The native protocol is validated on both sides: `src/lib/native-protocol.ts` and
  `native/macos/Protocol.swift`, with the companion's state machine in `Session.swift`. Every
  variant has exact keys, so change both sides and their tests (`native-protocol.test.ts`,
  `SelfTests.swift`) together.
- Surface failures as `AnthropicError(code, friendlyMessage)`. Provider/API text must pass
  through `sanitizeProviderMessage` in `src/lib/anthropic.ts` (key redaction, control-char
  strip, length cap) before it can reach the UI.
- Tests sit beside their source (`foo.test.ts`). Vitest defaults to Node; DOM tests start with
  `// @vitest-environment happy-dom` on line 1. Stub `chrome` per file with
  `vi.stubGlobal('chrome', …)`.
- Commits use Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`). Branch as
  `<type>/<topic>` and land on `main` via PR.
- Branch from the remote tip, never from local `main`, which falls behind because PRs merge on
  GitHub: `git fetch origin && git switch --no-track -c <type>/<topic> origin/main`. `main`
  only merges up-to-date PRs, so if it moves before yours merges, `git fetch origin && git
  merge origin/main` and rerun the checks. `.githooks/pre-push` blocks pushing a branch that's
  behind.

## Security and privacy — do not regress

- Only the background worker and the options page read the API key or call the API. Content
  scripts, the UI frame, and the workspace never receive it. `chrome.storage.local` is
  restricted to `TRUSTED_CONTEXTS`.
- All injected UI renders inside the extension-origin iframe in a closed shadow host. Content ↔
  frame traffic uses the capability-attested `MessageChannel`, never `window.postMessage`, DOM
  events, or attributes.
- `src/ui/result-frame.html` is the only web-accessible resource. `src/workspace/workspace.html`
  must never be web-accessible. It gets its capture by claiming a one-time capability over a
  runtime port.
- The native companion receives screenshots, crops, answers, and follow-ups, never the API key,
  system prompt, or API history. Its test hooks (`SNAPSCREEN_TEST_HOOKS`) compile only into the
  live test's build; `test:native` fails if the default build has them.
- `npm run test:browser` enforces parts of this (hostile-page probe, closed shadow root,
  webpage probes of private resources). `docs/security.md` is the full contract; update it when
  you change a boundary.
- When permissions or data handling change, also update `PRIVACY.md` and
  `docs/chrome-web-store.md`, whose answers the user pastes into the store dashboard.

## Gotchas

- The content script isn't declared in the manifest. `service-worker.ts` imports
  `../content/index.ts?script&iife` and injects it with `chrome.scripting.executeScript`. It
  must build to a synchronous IIFE, so nothing it imports may use dynamic `import()`; the smoke
  test fails otherwise. CRX also makes that import web-accessible, so `vite.config.ts` ships
  only the web-accessible resources that `src/manifest.json` declares.
- `src/ui/result-frame.html` and `src/workspace/workspace.html` must stay in
  `rolldownOptions.input` in `vite.config.ts`, and any new extension page belongs there too.
  Without that entry the build still passes, but the frame ships unbundled and the workspace
  isn't emitted at all.
- Model settings in `src/lib/anthropic.ts` (adaptive thinking, effort `high`,
  `max_tokens: 32_000`) are a deliberate choice for answer quality; don't change them casually.
  Keep effort explicit, because Opus 5.5 defaults to `medium`. The stream reader skips thinking
  blocks and history stores only answer text, so thinking is never sent back and turn pruning
  can't trip Opus 5.5's history-editing check on replayed thinking. Opus 5.5 always thinks:
  any `thinking.type` other than `'adaptive'` returns 400, including `'between_tools'`, so
  `verifyApiKey`'s one-token key check sends no `thinking` field (`max_tokens: 1` caps
  thinking and text together).
- A thinking answer can stream no text for over 30 s, and Chrome may stop an idle service
  worker even mid-fetch. `keepAliveUntilSettled` (`src/background/worker-keepalive.ts`) calls
  an extension API every 25 s while a request runs. The 240 s request timeout
  (`API_REQUEST_TIMEOUT_MS`) stays under Chrome's 5-minute cap on one service-worker event.
- Answer requests send `fallbacks: 'default'` with the `server-side-fallback-2026-07-01` beta
  header. A refused answer then continues in the same SSE stream on the model Anthropic
  recommends for the refusal's category, which Anthropic chooses server-side. The switch is
  marked by a `fallback` content block, which the stream reader ignores. Categories with no
  recommended fallback, such as `reasoning_extraction`, still end in the `refusal` error.
- Answer requests use automatic prompt caching (top-level `cache_control`). First answers and
  follow-ups must send the same `system` prompt and resend earlier messages unchanged, or
  follow-ups silently miss the cache. That's why follow-up rules live in the shared prompt in
  `src/lib/screenshot-qa-prompt.ts`. Don't move them to a separate prompt or a mid-conversation
  `system` message: the refusal fallback reruns the request on a model Anthropic picks, and not
  every model accepts one.
- Answers are plain text except fenced code blocks: the prompt asks for fences,
  `src/lib/code-blocks.ts` parses them, and the result panel gives each block its own Copy
  button. The native equivalent is `native/macos/AnswerView.swift`. Change the prompt's formatting
  rules and both parsers together.
- In native mode the badge title is the only lasting failure signal: Chrome ends a host about
  2 s after its port closes, and badges clear after 5 s. Keep `native-session.ts` messages
  accurate. `nativeMessaging` stays required because a running worker's
  `chrome.runtime.connectNative` doesn't update when the permission changes at runtime; read
  `docs/chrome-web-store.md` before releasing.
- `scripts/native-companion-build.mjs` compiles an explicit list of Swift files, so add new
  companion sources there. Its panels never activate the app, so Chrome stays the active app:
  close windows on key release (`CompanionPanel`), and give tracking areas `.activeAlways`.
  The companion mirrors the In Chrome interface's wording and conversation behavior.
- `npm run dev` doesn't work. The manifest's strict CSP blocks the crxjs dev server, so
  extension pages hang on its loading screen. It also overwrites `dist/` with a dev build that
  fails `test:browser` until you run `npm run build` again.
- Manual run: `npm run build`, then chrome://extensions → Developer mode → Load unpacked →
  `dist/`. Reload the extension after each rebuild. Real answers need an Anthropic API key,
  which you enter on the options page.

## Releases

The version lives only in `package.json`; `vite.config.ts` writes it into the built manifest,
so `src/manifest.json` has no `version`. Bump it with `npm version <x.y.z> --no-git-tag-version`.
Pushing a `v<x.y.z>` tag runs `.github/workflows/release.yml`: the `verify` CI checks, then
`npm run package`, then a GitHub release with the zip. The tag must match `package.json`.
