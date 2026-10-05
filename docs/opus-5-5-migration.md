# Switch SnapScreen to Claude Opus 5.5

This change moves SnapScreen's answers from `claude-sonnet-5-5` to `claude-opus-5-5`. Every other
answer setting stays: adaptive thinking, effort `high`, `max_tokens: 32_000`, SSE streaming,
automatic prompt caching, and the server-side refusal fallback. Besides the model ID, the only
request that has to change is the API-key check on the options page.

**Verified** on `origin/main` at `85908ea` (2026-10-05, Node 24) with the [patch](#patch)
applied: lint, typecheck, unit tests (327 pass; the 2 live tests skip without a key), build, and
the browser smoke test all pass. The [live API check](#4-run-the-live-api-check) still has to
run, because it needs an API key and spends a little credit.

## Why the key check changes

`verifyApiKey` in [src/lib/anthropic.ts](../src/lib/anthropic.ts) sends
`thinking: {type: 'between_tools'}` so its one-token request skips thinking. Only Claude Sonnet
5.5 accepts that value. Opus 5.5 always thinks, and any `thinking.type` other than `adaptive`
returns a 400. Left in place, the **Test** button on the options page would show this for every
working key:

```text
API error (400): "thinking.type.between_tools" is not supported for this model.
```

The patch drops the `thinking` field. `max_tokens` caps thinking and answer text together, so
`max_tokens: 1` still ends the check after one token.

The unit and smoke tests mock the API. The updated unit test fails if the key check sends any
`thinking` field (confirmed by putting `between_tools` back), but only the live check proves the
API accepts the new request.

## What stays the same

| Setting | On Opus 5.5 |
| --- | --- |
| `thinking: {type: 'adaptive'}` | Accepted; thinking is always on |
| `output_config: {effort: 'high'}` | Accepted. Keep it explicit: Opus 5.5 defaults to `medium` |
| `max_tokens: 32_000` | Under the 128K output limit |
| SSE stream reader | Unchanged; it skips thinking blocks and keeps only answer text |
| "Thinking…" status | Unchanged; Opus 5.5 streams the same `thinking` block starts |
| Top-level `cache_control` | Unchanged |
| `fallbacks: 'default'` with `server-side-fallback-2026-07-01` | Supported |
| 2,576 px screenshot default | Same high-resolution tier: 2,576 px long edge, 4,784 visual tokens |
| History-editing check on replayed thinking | Still can't trigger: history never holds thinking blocks |
| System prompt | No model-specific rules, and it doesn't ask for written-out reasoning, which Opus 5.5 can decline as `reasoning_extraction` |

Permissions and data handling don't change, and neither [PRIVACY.md](../PRIVACY.md) nor
[chrome-web-store.md](chrome-web-store.md) names the model, so both stay as they are.

## What users will notice

**Answers cost about twice as much.** Prices per million tokens:

| | Sonnet 5.5 | Opus 5.5 |
| --- | --- | --- |
| Input | $2 | $4 |
| 5-minute cache write | $2.50 | $5 |
| Cache read | $0.20 | $0.20 |
| Output, including thinking | $10 | $20 |

An answer that uses all 32,000 output tokens now costs about $0.67, up from about $0.33.
Follow-ups within 5 minutes re-read the screenshot and earlier turns at the cache-read rate,
which is the same on both models, so most of the increase is in output and first answers.

**Answers can take longer.** Anthropic lists Opus 5.5's latency as "Moderate" and Sonnet 5.5's as
"Fast", and an effort level doesn't mean the same amount of thinking on different models. The
240 s request timeout (`API_REQUEST_TIMEOUT_MS`) can't grow, because it has to stay under
Chrome's 5-minute limit on one service-worker event. If answers start timing out or ending in
"Answer was cut off", lower the effort; for cut-offs alone, raising `max_tokens` also works.

**Refused answers fall back to different models.** With `fallbacks: 'default'`, a declined answer
continues in the same stream on the model Anthropic recommends for the refusal's category. From
Sonnet 5.5, `cyber` and `frontier_llm` refusals went to Claude Sonnet 5. From Opus 5.5, Anthropic
chooses the fallback server-side, so it isn't fixed in the code. Categories with no recommended
fallback, such as `reasoning_extraction`, still end in "Claude declined to answer this question."

**Retirement:** Opus 5.5 stays available until at least September 22, 2027.

## Files

| File | Change |
| --- | --- |
| [src/lib/anthropic.ts](../src/lib/anthropic.ts) | `MODEL` is `claude-opus-5-5`; the key check sends no `thinking`; the fallback comment no longer names Sonnet categories |
| [src/lib/anthropic.test.ts](../src/lib/anthropic.test.ts) | Expects the new model and no `thinking` on the key check; the fallback fixture uses Opus models |
| [scripts/extension-smoke.mjs](../scripts/extension-smoke.mjs) | Mocked responses report `claude-opus-5-5` |
| [src/lib/storage.ts](../src/lib/storage.ts) | The screenshot-limit comment names Opus 5.5 |
| [AGENTS.md](../AGENTS.md) | Model ID, the thinking and key-check note, the fallback and caching notes |
| [REMEDIATION_PLAN.md](../REMEDIATION_PLAN.md) | Model ID in 1.3, the maximum answer cost in 2.3 |

## Steps

### 1. Branch from the remote tip

```bash
git fetch origin && git switch --no-track -c feat/opus-5-5 origin/main
```

### 2. Apply the patch

Run this from the repository root. It pulls the [patch](#patch) out of this file:

```bash
awk '/^````diff$/{p=1; next} /^````$/{p=0} p' docs/opus-5-5-migration.md | git apply
```

If `main` has moved and the patch no longer applies, add `--3way` to `git apply` and resolve the
conflicts, or make the edits by hand from the patch.

### 3. Run the checks

```bash
npm run lint && npm run typecheck && npm test && npm run build && npm run test:browser
```

Expect no lint warnings and every unit test passing, with the two live tests skipped.

### 4. Run the live API check

This is the only check that sends the new requests to Anthropic, so it's what proves the key
check works without `thinking`. Both tests must pass: "accepts the options page key check" and
"answers a screenshot question with the production request". Together they cost a few cents at
most.

On GitHub, push the branch and run the workflow on it. This needs the `SNAPSCREEN_LIVE_API_KEY`
repository secret (item 1.3 in REMEDIATION_PLAN.md); without it, the run fails straight away.

```bash
git push -u origin feat/opus-5-5
```

```bash
gh workflow run live-api.yml --ref feat/opus-5-5
```

Or run the same tests locally. Paste a key at the prompt; it isn't shown, saved in shell history,
or left in your shell afterwards:

```bash
(printf 'API key: ' && read -rs SNAPSCREEN_LIVE_API_KEY && echo && export SNAPSCREEN_LIVE_API_KEY && npx vitest run src/lib/anthropic.live.test.ts)
```

### 5. Try it in Chrome

Load `dist/` (chrome://extensions → Developer mode → Load unpacked), or reload the extension if
it's already loaded. Then:

1. On the options page, enter a key and click **Test**. Expect "API key works."
2. Snip a question on any page. The answer streams in, and a follow-up question works.

### 6. Open the PR

Commit as `feat: switch answers to Claude Opus 5.5` and open a PR to `main`. Say in the
description that answers now cost about twice as much.

### 7. Release

Ship it in the next release ([AGENTS.md → Releases](../AGENTS.md#releases)) and call out the
higher cost in the release notes.

## Rollback

Revert the PR's merge commit. The change is self-contained: reverting restores `claude-sonnet-5-5`
and the `between_tools` key check together.

## Sources

Anthropic documentation, checked 2026-10-05:

- [Models overview](https://platform.claude.com/docs/en/models/overview): model IDs, thinking
  always on, default effort, latency, retirement dates
- [Pricing](https://platform.claude.com/docs/en/about-claude/pricing): input, output, and cache
  prices for both models
- [Refusals and fallback](https://platform.claude.com/docs/en/build-with-claude/refusals-and-fallback):
  `fallbacks: 'default'` routing, and that only Sonnet 5.5 accepts `between_tools`
- [Steering thinking](https://platform.claude.com/docs/en/build-with-claude/thinking-steering-and-cost):
  `max_tokens` caps thinking and answer text together
- [Vision](https://platform.claude.com/docs/en/build-with-claude/vision): image resolution tiers
  and size limits

## Patch

Base: `origin/main` at `85908ea`.

````diff
diff --git a/AGENTS.md b/AGENTS.md
index d346be2..1c9791f 100644
--- a/AGENTS.md
+++ b/AGENTS.md
@@ -1,7 +1,7 @@
 # AGENTS.md
 
 SnapScreen is a Chrome Manifest V3 extension (Chrome 116+): snip a region of the current tab,
-then ask Claude (`claude-sonnet-5-5`, streamed SSE) about it. Strict TypeScript, built by
+then ask Claude (`claude-opus-5-5`, streamed SSE) about it. Strict TypeScript, built by
 Vite 8 + `@crxjs/vite-plugin` from `src/manifest.json`. Shipped code is plain DOM + `fetch`:
 keep `package.json` devDependencies-only, and don't add `@anthropic-ai/sdk` (the API client is
 hand-written in `src/lib/anthropic.ts`).
@@ -101,24 +101,27 @@ daily check from the repo's Actions tab.
   isn't emitted at all.
 - Model settings in `src/lib/anthropic.ts` (adaptive thinking, effort `high`,
   `max_tokens: 32_000`) are a deliberate choice for answer quality; don't change them casually.
-  The stream reader skips thinking blocks and history stores only answer text, so thinking is
-  never sent back and turn pruning can't trip Sonnet 5.5's history-editing check on replayed
-  thinking. Sonnet 5.5 returns 400 for `thinking: {type: 'disabled'}`; to turn thinking off,
-  send `{type: 'between_tools'}` with no other `thinking` field at effort `high` or lower, as
-  `verifyApiKey`'s one-token key check does.
+  Keep effort explicit, because Opus 5.5 defaults to `medium`. The stream reader skips thinking
+  blocks and history stores only answer text, so thinking is never sent back and turn pruning
+  can't trip Opus 5.5's history-editing check on replayed thinking. Opus 5.5 always thinks:
+  any `thinking.type` other than `'adaptive'` returns 400, including `'between_tools'`, so
+  `verifyApiKey`'s one-token key check sends no `thinking` field (`max_tokens: 1` caps
+  thinking and text together).
 - A thinking answer can stream no text for over 30 s, and Chrome may stop an idle service
   worker even mid-fetch. `keepAliveUntilSettled` (`src/background/worker-keepalive.ts`) calls
   an extension API every 25 s while a request runs. The 240 s request timeout
   (`API_REQUEST_TIMEOUT_MS`) stays under Chrome's 5-minute cap on one service-worker event.
 - Answer requests send `fallbacks: 'default'` with the `server-side-fallback-2026-07-01` beta
-  header. A `cyber` or `frontier_llm` refusal then continues on Claude Sonnet 5 in the same SSE
-  stream. The switch is marked by a `fallback` content block, which the stream reader ignores.
-  Other refusal categories still end in the `refusal` error.
+  header. A refused answer then continues in the same SSE stream on the model Anthropic
+  recommends for the refusal's category, which Anthropic chooses server-side. The switch is
+  marked by a `fallback` content block, which the stream reader ignores. Categories with no
+  recommended fallback, such as `reasoning_extraction`, still end in the `refusal` error.
 - Answer requests use automatic prompt caching (top-level `cache_control`). First answers and
   follow-ups must send the same `system` prompt and resend earlier messages unchanged, or
   follow-ups silently miss the cache. That's why follow-up rules live in the shared prompt in
   `src/lib/screenshot-qa-prompt.ts`. Don't move them to a separate prompt or a mid-conversation
-  `system` message, which Sonnet 5 (the fallback model) rejects.
+  `system` message: the refusal fallback reruns the request on a model Anthropic picks, and not
+  every model accepts one.
 - Answers are plain text except fenced code blocks: the prompt asks for fences,
   `src/lib/code-blocks.ts` parses them, and the result panel gives each block its own Copy
   button. Change the prompt's formatting rules and the parser together.
diff --git a/REMEDIATION_PLAN.md b/REMEDIATION_PLAN.md
index b6c53c4..4b10fb6 100644
--- a/REMEDIATION_PLAN.md
+++ b/REMEDIATION_PLAN.md
@@ -64,7 +64,7 @@ store.
 ### 1.3 Daily check against the real Anthropic API
 
 [src/lib/anthropic.ts](src/lib/anthropic.ts#L175-L195) hard-codes the model
-(`claude-sonnet-5-5`), a dated beta header (`server-side-fallback-2026-07-01`),
+(`claude-opus-5-5`), a dated beta header (`server-side-fallback-2026-07-01`),
 `fallbacks: 'default'`, adaptive thinking and effort. The smoke test fakes the API. If Anthropic
 retires the model or beta, or changes a parameter, every answer fails for every user while CI
 stays green, and the fix waits on store review.
@@ -145,8 +145,8 @@ page.
 
 ### 2.3 Cost guidance for users
 
-Users pay for every answer: usually cents, at most about $0.33 (32,000 output tokens at Claude
-Sonnet 5.5's $10 per million). The README doesn't mention cost, and the spend-limit advice is
+Users pay for every answer: usually cents, at most about $0.67 (32,000 output tokens at Claude
+Opus 5.5's $20 per million). The README doesn't mention cost, and the spend-limit advice is
 only in [docs/security.md](docs/security.md).
 
 - [ ] Add a short cost note to the README and the options page: typical cost per answer, and a
diff --git a/scripts/extension-smoke.mjs b/scripts/extension-smoke.mjs
index d417a13..b296e77 100644
--- a/scripts/extension-smoke.mjs
+++ b/scripts/extension-smoke.mjs
@@ -373,7 +373,7 @@ function answerSse(answer, { interrupted = false } = {}) {
           id: 'msg_snapscreen_smoke',
           type: 'message',
           role: 'assistant',
-          model: 'claude-sonnet-5-5',
+          model: 'claude-opus-5-5',
           content: [],
           stop_reason: null,
           stop_sequence: null,
@@ -513,7 +513,7 @@ async function installStalledThinkingStream(worker) {
             id: 'msg_snapscreen_smoke_thinking',
             type: 'message',
             role: 'assistant',
-            model: 'claude-sonnet-5-5',
+            model: 'claude-opus-5-5',
             content: [],
             stop_reason: null,
             stop_sequence: null,
diff --git a/src/lib/anthropic.test.ts b/src/lib/anthropic.test.ts
index 56cf9b4..b8a7d5b 100644
--- a/src/lib/anthropic.test.ts
+++ b/src/lib/anthropic.test.ts
@@ -140,7 +140,7 @@ describe('analyzeImage', () => {
     expect(JSON.stringify(body.messages)).toContain(hiddenInstruction);
     expect(body.system).toContain(SCREENSHOT_QA_SYSTEM_PROMPT);
     expect(body.system).not.toContain(hiddenInstruction);
-    expect(body.model).toBe('claude-sonnet-5-5');
+    expect(body.model).toBe('claude-opus-5-5');
     expect(body.max_tokens).toBe(32_000);
     expect(body.thinking).toEqual({ type: 'adaptive' });
     expect(body.output_config).toEqual({ effort: 'high' });
@@ -284,8 +284,8 @@ describe('analyzeImage', () => {
         index: 1,
         content_block: {
           type: 'fallback',
-          from: { model: 'claude-sonnet-5-5' },
-          to: { model: 'claude-sonnet-5' },
+          from: { model: 'claude-opus-5-5' },
+          to: { model: 'claude-opus-4-8' },
         },
       },
       { type: 'content_block_stop', index: 1 },
@@ -697,9 +697,9 @@ describe('verifyApiKey', () => {
     const mock = stubFetch({ content: [{ type: 'text', text: 'Hi' }] });
     await expect(verifyApiKey('key')).resolves.toBeUndefined();
     const body = lastRequestBody(mock);
-    expect(body.model).toBe('claude-sonnet-5-5');
+    expect(body.model).toBe('claude-opus-5-5');
     expect(body.max_tokens).toBe(1);
-    expect(body.thinking).toEqual({ type: 'between_tools' });
+    expect(body.thinking).toBeUndefined();
     expect(body.stream).toBeUndefined();
     expect(lastRequestHeaders(mock)['anthropic-beta']).toBeUndefined();
     const response = await mock.mock.results[0].value as Response;
diff --git a/src/lib/anthropic.ts b/src/lib/anthropic.ts
index 1487666..5307f6b 100644
--- a/src/lib/anthropic.ts
+++ b/src/lib/anthropic.ts
@@ -21,10 +21,10 @@ import {
 } from './session-history';
 
 const API_URL = 'https://api.anthropic.com/v1/messages';
-const MODEL = 'claude-sonnet-5-5';
-// Server-side refusal fallback: when a safety classifier declines (on Sonnet
-// 5.5, the cyber and frontier_llm categories), the API reruns the request on
-// Anthropic's recommended fallback model within the same stream.
+const MODEL = 'claude-opus-5-5';
+// Server-side refusal fallback: when a safety classifier declines, the API
+// reruns the request on the model Anthropic recommends for that refusal
+// category, within the same stream.
 const REFUSAL_FALLBACK_BETA = 'server-side-fallback-2026-07-01';
 const MAX_PROVIDER_ERROR_BYTES = 16_384;
 const MAX_PROVIDER_ERROR_CHARACTERS = 240;
@@ -155,9 +155,9 @@ export async function verifyApiKey(apiKey: string, signal?: AbortSignal): Promis
       apiKey,
       {
         model: MODEL,
+        // Key check only, so it stops after one token. Opus 5.5 can't turn
+        // thinking off, and max_tokens caps thinking and text together.
         max_tokens: 1,
-        // Key check only, so it skips thinking and stops after one token.
-        thinking: { type: 'between_tools' },
         messages: [{ role: 'user', content: 'Hi' }],
       },
       requestSignal,
diff --git a/src/lib/storage.ts b/src/lib/storage.ts
index 749130c..63c615e 100644
--- a/src/lib/storage.ts
+++ b/src/lib/storage.ts
@@ -17,7 +17,7 @@ export const LIMIT_CONSTRAINTS = {
   maxInputCharacters: { min: 100, max: 50_000, default: 4_000 },
   // Anthropic's direct API accepts at most 10 MB per base64 image.
   maxScreenshotBytes: { min: 1_000_000, max: 10_000_000, default: 5_000_000 },
-  // 2,576 px is Sonnet 5.5's native long edge; 8,000 px is the API ceiling.
+  // 2,576 px is Opus 5.5's native long edge; 8,000 px is the API ceiling.
   maxScreenshotDimension: { min: 512, max: 8_000, default: 2_576 },
   maxConversationTurns: { min: 2, max: 50, default: 12 },
 } as const;
````
