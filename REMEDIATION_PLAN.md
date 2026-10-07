# Production remediation plan

From a production-readiness audit of `main` at `dcd04a6` on 2026-10-01, assuming the goal is a
public Chrome Web Store listing. Line numbers in file links are from that commit.

**Verdict: not ready to publish yet, but close.** The code passes every check (lint, typecheck,
285 unit tests, build, smoke test, `npm audit`), git history has no real API keys, and the
security design is solid. The gaps are in shipping and running it in public. The before-launch
work is about 2–3 days; the first-month items add about a day.

**Status (2026-10-07):** the code and docs for 1.1–1.4 merged in
[PR #15](https://github.com/thedanielyuan/SnapScreen/pull/15), `main` is protected, and the daily
live API check is green. The unchecked items below need you: store dashboard, the first tagged
release, failure alerts, and testing on real hardware.

| #   | Item                                          | When          | Effort  | Status            |
| --- | --------------------------------------------- | ------------- | ------- | ----------------- |
| 1.1 | Privacy policy and store disclosures          | Before launch | ½ day   | Dashboard left    |
| 1.2 | Versioned, CI-built releases                  | Before launch | ½–1 day | Release left      |
| 1.3 | Daily check against the real Anthropic API    | Before launch | 2–4 h   | Alerts left       |
| 1.4 | Shrink large snips instead of rejecting them  | Before launch | 2–4 h   | Done              |
| 1.5 | Manual test pass                              | Before launch | ½ day   | To do             |
| 2.1 | Diagnostics and a support channel             | First month   | ½ day   | To do             |
| 2.2 | Keep working after extension updates          | First month   | 2–4 h   | To do             |
| 2.3 | Cost guidance for users                       | First month   | 1 h     | To do             |

## 1. Before launch

### 1.1 Privacy policy and store disclosures

SnapScreen sends page screenshots to Anthropic and stores the user's API key. The Chrome Web
Store requires you to declare that and link a privacy policy, or the listing is rejected.

- [x] Write a privacy policy: [PRIVACY.md](PRIVACY.md). Its GitHub URL works once it's merged
      to `main`.
- [x] Draft the store answers (single purpose, permission justifications, data usage, privacy
      policy URL): [docs/chrome-web-store.md](docs/chrome-web-store.md).
- [ ] Paste those answers into the dashboard's Privacy practices tab.
- [x] Add `homepage_url` to [src/manifest.json](src/manifest.json), and an install section to the
      README.
- [ ] Once the listing is live, add the store link to the README.

**Done when:** the listing passes review.

### 1.2 Versioned, CI-built releases

[src/manifest.json](src/manifest.json#L5) and `package.json` still say `1.0.0`, and the `v1.0.0`
tag is 31 commits behind `main`. There's no packaging script, release workflow, changelog or
archived build, and `main` isn't protected. So you can't tell which build a user has, rebuild a
known-good one. Rolling back is built into the store: the Developer Dashboard re-publishes the
previous version in one click, without review.

- [x] Bump the version to `1.1.0`. The version now lives only in `package.json`, and the build
      writes it into the manifest, so the two can't drift.
- [x] Add `npm run package`, which zips the built `dist/` into `release/`.
- [x] Add [.github/workflows/release.yml](.github/workflows/release.yml): on a `v*` tag it checks
      the tag matches `package.json`, runs the CI `verify` checks, and attaches the zip to a
      GitHub release with generated notes (instead of a `CHANGELOG.md`).
- [ ] Only upload zips from that workflow to the store, never local builds.
- [x] Protect `main` so the CI `verify` job must pass before merging.

**Done when:** pushing a tag produces a zip on a GitHub release, and that zip is what's in the
store.

### 1.3 Daily check against the real Anthropic API

[src/lib/anthropic.ts](src/lib/anthropic.ts#L175-L195) hard-codes the model
(`claude-opus-5-5`), a dated beta header (`server-side-fallback-2026-07-01`),
`fallbacks: 'default'`, adaptive thinking and effort. The smoke test fakes the API. If Anthropic
retires the model or beta, or changes a parameter, every answer fails for every user while CI
stays green, and the fix waits on store review.

- [x] Create a dedicated Anthropic API key with a low spend limit and save it as the
      `SNAPSCREEN_LIVE_API_KEY` repository secret.
- [x] Add [.github/workflows/live-api.yml](.github/workflows/live-api.yml) (daily, plus manual
      runs) and [src/lib/anthropic.live.test.ts](src/lib/anthropic.live.test.ts), which sends the
      real key-check and answer requests. It fails if the secret is missing.
- [ ] Run it once by hand from the Actions tab, and check that failed runs notify you.
- [ ] Watch Anthropic's model deprecation notices.

**Done when:** the scheduled run is green, and a deliberately wrong model ID turns it red.

### 1.4 Shrink large snips instead of rejecting them

[`cropImage`](src/lib/crop.ts#L38-L45) keeps the full device resolution, then
[`assertScreenshotWithinLimits`](src/lib/request-limits.ts#L123-L129) rejects anything longer
than the 2,576 px default ([src/lib/storage.ts](src/lib/storage.ts#L21)). On a 2× (Retina)
screen, any snip wider than about 1,288 page pixels fails, for example a full-width snip on a 13"
MacBook. Large photo-heavy snips also hit the 5 MB limit. The smoke test runs at 1×, so CI never
sees it.

- [x] Before each answer request, scale the screenshot so its longest edge fits
      `maxScreenshotDimension` (`fitScreenshotToLimits` in `src/lib/crop.ts`).
- [x] If it's still over `maxScreenshotBytes`, scale it down further instead of failing.
- [x] Keep the existing limit checks as a backstop.
- [x] Add unit tests for 2× captures, and a 3,000 px capture to the smoke test. Without the fix,
      the smoke test fails with the "edge limit" error.

**Done when:** a full-width snip on a Retina screen gets an answer with default settings.

### 1.5 Manual test pass

- [ ] macOS Retina and Windows at 150% scaling: small, full-width and full-viewport snips.
- [ ] A PDF in Chrome's viewer, a local `file://` page, and a protected page such as the Chrome
      Web Store (should open the workspace tab).
- [ ] Chrome 116, the oldest version `minimum_chrome_version` allows.
- [ ] A few hard multi-part questions: check they finish within the 240-second request timeout.
- [ ] Snip on a tab, reload the extension at `chrome://extensions`, then snip again on the same
      tab without reloading it (see 2.2).

## 2. First month

### 2.1 Diagnostics and a support channel

There are no `console.*` calls in `src/`. Unexpected errors become "SnapScreen could not complete
this request" with no error code
([src/background/service-worker.ts](src/background/service-worker.ts#L120-L125)), and the
extension never shows its version or where to get help. When something breaks, users can't send
you anything you can act on.

- [ ] Log unexpected errors with `console.error` in the service worker. Never log the API key,
      screenshots or answer text.
- [ ] Show the error code in error messages. The codes already exist on `AnthropicError`.
- [ ] Show the extension version on the options page (`chrome.runtime.getManifest().version`).
- [ ] Add a "Report a problem" link that opens a prefilled GitHub issue with the version,
      browser, OS and last error code, but no screenshot, key or answer.
- [ ] Keep all of it local, so the privacy policy's "SnapScreen has no servers" promise stays
      true.

**Done when:** a user's bug report includes the version and an error code.

### 2.2 Keep working after extension updates

[src/content/index.ts](src/content/index.ts#L30) registers its message listener only if
`window.__snapscreenListenerReady` isn't set. After an update, the old content script stops
working but its flag probably stays set, so the newly injected script skips registering. Snips on
that tab would then open the workspace tab instead of the in-page panel until the page is
reloaded. Store updates trigger this; normal development doesn't.

- [ ] Reproduce it with the last step of 1.5.
- [ ] If confirmed, tie the guard to the live extension instance (for example, re-register when
      the previous instance's `chrome.runtime.id` is gone) and add the reproduction to the smoke
      test.

**Done when:** snipping after an extension reload shows the in-page panel without reloading the
page.

### 2.3 Cost guidance for users

Users pay for every answer: usually cents, at most about $0.67 (32,000 output tokens at Claude
Opus 5.5's $20 per million). The README doesn't mention cost, and the spend-limit advice is
only in [docs/security.md](docs/security.md).

- [ ] Add a short cost note to the README and the options page: typical cost per answer, and a
      tip to set a spend limit on the key.

## 3. Ongoing

- [ ] Plan model and beta upgrades well before Anthropic's retirement dates, leaving time for
      store review.
- [ ] Keep every release zip on GitHub releases, so you always know what each version shipped.
- [ ] Repeat the manual test pass (1.5) before each release.
- [ ] Keep Dependabot and the `npm audit` gate.
- [x] Add `github-actions` to [.github/dependabot.yml](.github/dependabot.yml) so workflow
      actions stay current.
- [ ] Update the privacy policy and `docs/security.md` whenever data handling changes.
