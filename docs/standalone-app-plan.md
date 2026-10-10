# Standalone macOS app plan

Proposal, 10 October 2026. Replace the native-only Chrome extension and its companion with one
macOS menu bar app that snips any part of the screen and answers in the companion's existing
windows. The extension stays your daily tool until the app passes acceptance (Phase 4).

## End state

- `SnapScreen.app`: a menu bar app with no Dock icon, running all the time. ⌥⇧S works from any
  app. The menu has Snip, Settings… and Quit.
- The shortcut freezes the display under the pointer, using ScreenCaptureKit. You drag a region
  on that frozen image, which covers the screen, and the answer opens in today's conversation
  window beside the region.
- The API key is stored in the Keychain, and the other settings in `UserDefaults`.
- There's no Chrome extension, no native messaging, no Node, and no TypeScript.

## What stays the same

- **The request.** `claude-opus-5-5`, adaptive thinking, effort `high`, `max_tokens: 32_000`,
  `fallbacks: 'default'` with the `server-side-fallback-2026-07-01` beta, and top-level
  `cache_control`. The key check sends no `thinking` field. History keeps answer text only.
- **The system prompt**, ported verbatim from `src/lib/screenshot-qa-prompt.ts`, including the
  plain-text and code-fence rules. `AnswerView.swift` already parses code fences.
- **Conversation behavior.** Follow-ups, Stop, Retry, trimming to `maxConversationTurns` with a
  notice, and clearing refused text are unchanged. The four limits keep their current defaults
  and bounds.
- **Windows.** The conversation window, composer, preview, Copy buttons, and panels that never
  activate the app are all kept, so the app you snip keeps focus.
- **Privacy rules.** Screenshots, answers and drafts are never written to disk or logs. A
  session's images and text are dropped when it closes. Provider error text still passes
  through `sanitizeProviderMessage`.

These differences are deliberate:

- The `anthropic-dangerous-direct-browser-access` header is dropped, because it only exists for
  browser CORS.
- The 240 s request cap becomes a 10-minute overall timeout plus a 60 s idle timeout. The 240 s
  cap only existed because of Chrome's 5-minute service-worker limit.
- The caps that only exist for the extension ↔ companion protocol go away: 24 MB screenshot
  transfers and 262,144-character answers.

## Decisions

You kept every default on 10 October 2026.

| Decision | Default | Alternative |
| --- | --- | --- |
| Chrome builds at the end | Remove both, including the In Chrome fallback | Keep In Chrome, which keeps the TS, Vite and Playwright toolchain |
| Selection | Freeze-frame overlay: what was on screen when you pressed the shortcut, like today | Live ⌘⇧4-style selection, captured on release |
| Displays | The display under the pointer | All displays |
| Toolchain at the end | A Swift package plus shell scripts, no Node | Keep the Node scripts |
| Old records | Delete `experiments/native-phase1/` and `docs/native-phase*.md` in Phase 5 | Keep them as history |

## Architecture

The repository moves to a Swift package (`Package.swift` at the root). The deployment target is
macOS 15; ScreenCaptureKit screenshots need macOS 14.

- `Sources/SnapScreenCore/`: Foundation, CoreGraphics and ImageIO only, with no AppKit. Built in
  Swift 6 language mode and unit-tested with Swift Testing in `Tests/SnapScreenCoreTests/`.
- `Sources/SnapScreen/`: the AppKit app. It starts in Swift 5 mode, which the companion uses
  today. Its view checks stay in the `--self-test` harness, because they need a real app process
  for window and key behavior.
- `scripts/build-app.sh`: runs `swift build`, writes `build/SnapScreen.app` (bundle ID
  `com.snapscreen.app`, `LSUIElement`), and signs it.

| Today | In the app |
| --- | --- |
| `src/lib/anthropic.ts` | `AnthropicClient.swift`, `SSEParser.swift`, `HTTPTransport.swift` (core) |
| `src/lib/screenshot-qa-prompt.ts` | `SystemPrompt.swift` (core) |
| `src/lib/messages.ts` (API types), `session-history.ts` | `Messages.swift` (core) |
| `src/lib/request-limits.ts` | `RequestLimits.swift` (core) |
| `src/lib/conversation-state.ts` | `ConversationState.swift` (core) |
| `src/lib/crop.ts` | `ImageFitting.swift` (core) |
| `src/lib/storage.ts` | `Settings.swift` (core), `KeychainStore.swift` (app) |
| `closeOpenCodeFence` in `src/lib/code-blocks.ts` | `CodeFence.swift` (core) |
| `src/lib/plain-text.ts` and JavaScript string behavior | `JavaScriptStrings.swift` (core) |
| `src/background/native-session.ts`, `native/macos/Session.swift` | `SessionController.swift` (core, reports to the app through a delegate) |
| `src/background/capture-source.ts`, `capture-session.ts` | `ScreenCapturer.swift` |
| `service-worker-native.ts` (toolbar button and command) | `AppDelegate.swift`, `Hotkey.swift`, `StatusMenu.swift` |
| `src/options/` | `SettingsWindow.swift` |
| `action-feedback.ts` (badge) | `NoticePanel.swift` |
| `native-bridge.ts`, `native-protocol.ts`, `worker-keepalive.ts`, `Protocol.swift` | Deleted |

These files are reused as they are: `AnswerView`, `ConversationView`, `Composer`, `Controls`
(`Theme`, `CompanionPanel`, buttons), `Geometry`, and `PreviewView`. `SelectionView` gains a
fill-bounds mode for the overlay.

The app runs as one long-lived `.accessory` process. As today, up to four sessions can run at
once.

## Phases

Each phase leaves CI green.

### Phase 0: Package and shared UI (small, done)

- Add `Package.swift`, with a stub `main.swift` for the app target that only runs
  `--self-test`, and add `.build/`, `.swiftpm/` and `build/` to `.gitignore`.
- `git mv` the shared views and their checks (`AnswerViewTests`, `SelectionViewTests`,
  `ConversationViewTests`) to `Sources/SnapScreen/UI/`.
- Move what those views need out of the companion:
  - `NormalizedRect` into `Geometry.swift`; its wire format stays in `Protocol.swift`
  - `AnswerStatus` into `ConversationView.swift`
  - the whitespace and input-limit helpers into `TextLimits.swift`
- Split `SelfTests.swift`: the geometry checks move to `GeometryTests.swift`, and the protocol
  and session checks stay with the companion. The companion still runs all 318 checks.
- Point `scripts/native-companion-build.mjs` at the new paths. The companion behaves exactly as
  before.
- Add `scripts/build-app.sh`. It signs with an Apple Development certificate when one exists,
  and otherwise signs ad hoc and prints a warning. (Until Phase 2 it used a self-signed
  `SnapScreen Local` certificate.)
- In the CI `native` job, add `scripts/build-app.sh` and the app's `--self-test`. `swift test`
  arrives with the core target in Phase 1.
- **You, once:** create an Apple Development certificate, which is free with an Apple ID: Xcode →
  Settings → Accounts → your Apple ID → Manage Certificates → + → Apple Development. macOS ties
  Screen Recording and Keychain approvals to the app's signature, and an ad hoc build loses both
  on every rebuild. The Keychain also checks the signature's Apple team. A self-signed
  certificate has no team, so the Keychain treats each rebuild as a new app and asks for your
  login password. The `SnapScreen Local` certificate made on 10 October 2026 had that problem,
  so Phase 2 replaced it. This is local only. Done on 10 October 2026.

  If `codesign` can't build a chain for the certificate, the Keychain is missing Apple's
  intermediate certificate. Xcode includes the G3 one that personal teams' certificates use:

  ```bash
  security add-certificates -k ~/Library/Keychains/login.keychain-db /Applications/Xcode.app/Contents/SharedFrameworks/DVTFoundation.framework/Versions/A/Resources/AppleWWDRCA-2030.cer
  ```

Done when: CI builds the package and the companion's tests pass unchanged.

### Phase 1: Port the core (large, done)

- Add the `SnapScreenCore` target and `Tests/SnapScreenCoreTests/`, and add `swift test` to the
  CI `native` job.
- **Record golden fixtures from the TypeScript before porting.** `src/lib/core-fixtures.test.ts`,
  deleted in Phase 5, runs `analyzeImage` and `followUp` against a scripted `fetch`, and drives
  multi-turn sessions through the conversation-state functions as `native-session.ts` does. It
  saves each request body, stream, result and state change as a file snapshot in
  `Tests/SnapScreenCoreTests/Fixtures/`, so `npm test` also fails if the TypeScript drifts from
  them; `npx vitest run src/lib/core-fixtures.test.ts -u` rewrites them. The cases:
  - first answers with and without a question and a Default Prompt
  - follow-ups, including trimming at the turn limit
  - stopped and failed answers, and Retry
  - 401, 403, 429 with `retry-after`, 5xx, and 4xx with a provider message
  - malformed and interrupted streams
  - a refusal
  - a `max_tokens` cut-off inside a code fence
- **Port these into `SnapScreenCore`:**
  - The API client streams with `URLSession.bytes(for:)` through an injectable transport and
    sends the same request body. Stop uses `Task` cancellation, and the timeouts are URLSession's
    request (idle) and resource (overall) timeouts.
  - The SSE parser keeps today's line-ending handling, including a CR split across chunks. It
    signals thinking once.
  - Error mapping and `sanitizeProviderMessage` keep their limits: provider error bodies of at
    most 16 KB, and messages of at most 240 characters.
  - Input limits count Unicode scalars (`unicodeScalars.count`), because the TypeScript counts
    code points. Swift's `String.count` counts characters, which gives a different number.
  - Cropping and fitting use `CGImage` and ImageIO PNG encoding, with the same rounding, up to
    four passes, and the same `0.9 × √(limit / size)` byte scaling.
- **Tests.** Port the cases in `anthropic`, `request-limits`, `conversation-state`, `crop`,
  `storage` and `screenshot-qa-prompt` (about 1,900 lines of TypeScript tests). Compare the
  Swift output with the golden fixtures. A prompt check compares the Swift prompt with the
  TypeScript one until Phase 5.
- Add a Swift live API test that only runs when `SNAPSCREEN_LIVE_API_KEY` is set. Ask before
  running it in CI, as today, because it spends API credit.

Done when: Swift request bodies equal the fixtures as JSON, and every ported case passes.
Done on 10 October 2026: 18 fixture files replay, and 80 Swift tests pass.

### Phase 2: App shell (medium, done)

- `AppDelegate` with the `.accessory` policy, a single-instance guard, and the menu bar menu.
  A second copy exits, and opening the app again while it runs shows Settings. Settings also
  opens at launch while no key is saved, as the extension's does on install.
- Register the global shortcut with Carbon `RegisterEventHotKey`, which needs no Accessibility
  permission. Until Phase 5 it registers ⌃⌥⇧S, so ⌥⇧S still reaches the extension. The
  registration is exclusive: if another app has the shortcut, a notice and Settings say so, and
  the menu stops showing it.
- Settings live in `UserDefaults` and are checked with `normalizeLimits`. The key is stored in
  the Keychain as a generic password (service `com.snapscreen.app`, account
  `anthropic-api-key`).
- Until Phase 3, Snip checks Screen Recording and then shows a notice that snipping isn't built
  yet.
- The Settings window has the options page's fields:
  - the key, with show/hide, Save, Test key and Remove key
  - the Default Prompt
  - the advanced limits

  It also shows Screen Recording status with an Open System Settings button, and an Open at
  login switch (`SMAppService`). The companion check goes away.
- Move the Edit menu from the companion's `main.swift` into a shared file. Without it, ⌘C and ⌘V
  don't work in the Settings fields.
- `NoticePanel` replaces the toolbar badge. It's a small panel that never activates the app,
  used for failures before a conversation window exists.
- Add a standalone app section to `docs/security.md`.

Done when: the menu, shortcut and Settings work, and the key survives a rebuild with no Keychain
prompt. Done on 10 October 2026: 63 new self-test checks pass, and a rebuild signed with your
Apple Development certificate reads the previous build's Keychain item without a prompt.

### Phase 3: Snip to answer (large, done)

It lands in three pull requests: the session controller, then capture, selection and the
windows, then the test-hooks build.

- **`SessionController` (done).** Port `native-session.ts` into the core without the bridge.
  The app calls a session's methods (`select`, `ask`, `retry`, `stop` and `close`) where the
  companion sent commands, and one delegate method receives its events: captured, accepted,
  started, thinking, notice, answer, failed and ended. It covers:
  - crop and fit, the first answer, follow-ups, Stop, Retry, trimming notices, and refusal
    clearing
  - answer updates throttled to 10 per second
  - at most four sessions, with a new snip replacing a selection that hasn't been accepted
  - a selection ending after two minutes, as today
  - every image and all text released when a session closes

  The cases from `native-session.test.ts` are ported, except those about the native messaging
  protocol, and the `session-*` fixtures replay through it with the real client. Done on
  10 October 2026: 107 Swift tests pass.
- **Capture, selection and windows (done).** Done on 10 October 2026. The app's self-test runs
  snips through the real controller with a scripted client and a made-up capture: 266 checks
  pass. A real snip still needs Screen Recording granted to the build.
  - **`ScreenCapturer`.** Uses `SCShareableContent` to find the display under the pointer,
    leaves out SnapScreen's own windows, and captures with `SCScreenshotManager` at full pixel
    resolution, without the cursor. Snip checks permission first, as Phase 2's did, and shows
    `NoticePanel` with Open System Settings when it's denied. It returns a `FrozenScreen`, the
    capture as a `CGImage` with its display.
  - **`SelectionOverlay`.** A borderless, non-opaque panel that never activates the app. It
    covers that display above the menu bar (`canJoinAllSpaces`, `fullScreenAuxiliary`) and
    draws the frozen capture 1:1 with a dim. It must stay non-opaque. The earlier native
    prototype found that a screen-sized non-opaque panel caused no visibility change in Chrome
    (`docs/native-phase1-results.md`), and an opaque full-screen window could make Chrome mark
    the page as hidden.
  - `SelectionView` gains a fill-bounds mode for the overlay, and keeps release-to-ask, click
    or Escape to cancel, and Return for a keyboard selection. It now dims a copy of the image
    once, because blending the dim over a 5K display took about 18 ms on every redraw.
    Pressing the shortcut again replaces an unfinished selection, as today.
  - `performClose` never reaches the delegate of a window without a close button, so
    `CompanionPanel` gains a `closeAction` that the overlay uses for Escape.
  - **Windows.** `SnipWindows` is `SessionController`'s delegate and gives each session a
    `SessionWindows`: the overlay, then the companion's conversation and preview panels, with
    the conversation beside the selection. The panel factory, `PointerShield` with its press
    tracking, and `SessionEndedView` moved into `Sources/SnapScreen/UI/Panels.swift`, which
    the companion shares.
  - The app's messages don't mention Chrome. `SessionEndedView` takes its message, so the
    companion keeps "Invoke SnapScreen in Chrome…", and the app says to snip again.
- **Test-hooks build (done).** `scripts/build-app.sh --test-hooks` compiles with
  `-D SNAPSCREEN_TEST_HOOKS` into `build/test-hooks/`, with its own bundle ID
  (`com.snapscreen.app.test-hooks`), build folder and an ad hoc signature.
  - A made-up capture replaces ScreenCaptureKit, because CI can't grant Screen Recording.
  - A scripted event stream replaces the API, so the real client reads it.
  - The build selects a region with the keyboard, reads the streamed answer, asks one
    follow-up, and closes, checking the windows and requests along the way.

  `scripts/test-app-live.sh` runs it in CI's GUI session. `build-app.sh` fails the production
  build if its binary contains the hooks' marker. A key panel that doesn't activate the app
  still makes `NSApp.isActive` true, so the test checks that SnapScreen never becomes the
  frontmost app instead.

Done when: CI runs a full mocked exchange through real windows. Done on 10 October 2026: CI runs
the live test, which passes 13 checks.

### Phase 4: Acceptance and switch-over (small)

- **The round (done).** One physical round of five steps, which `npm run experiment:app`
  (`scripts/app-acceptance.mjs`) runs:
  - Press the shortcut over Chrome on a page that logs `focus`, `blur`, `visibilitychange`, keys
    and pointer events, first in a normal window and then in fullscreen.
  - Select a region, read the answer, ask a follow-up, and copy a code block.
  - Snip a PDF in Preview.
  - Rebuild, and check that Screen Recording and the Keychain work without prompts.

  The runner builds and restarts the app, opens the page in a fresh Chrome profile, and sets up
  each step itself when the previous snip's windows close. `scripts/app-acceptance-observer.swift`
  records SnapScreen's windows, the frontmost app, prompts and pasteboard changes, never titles
  or contents. Unchanged sources build an identical signature, so the rebuild sets
  `SNAPSCREEN_BUILD_NUMBER`, which changes it as a code change would. The report and its summary
  go to `build/acceptance/`.
- It passes when the page keeps focus and visibility during selection and answering, and the
  app never takes focus. Modifier keys reaching the page remains the accepted known limitation.
- Done on 10 October 2026, on macOS 27.0.1 and Chrome 154, with a 2× and a 1× display.
  SnapScreen never became the frontmost app, the page kept focus and visibility, and no keys,
  text or clicks reached it. After the rebuild, the app snipped and answered with no Screen
  Recording or Keychain prompt. You accepted one finding as a second known limitation: macOS's
  periodic alert for apps that capture the screen without the system picker appeared on the
  first snip and had focus for the 2 s until you dismissed it. SnapScreen can't suppress it.
- **You:** remove the native host registration and uninstall the extension before Phase 5
  deletes the installer:

  ```bash
  npm run install:native -- --extension-id <id> --user-data-dir <root> --remove
  ```

### Phase 5: Remove the extension (medium, mostly deletion)

- Delete:
  - `src/`, `scripts/*.mjs` and `scripts/app-acceptance-observer.swift`
  - `vite.config.ts`, `vite.native.config.ts`, `tsconfig.json` and `eslint.config.js`
  - `package.json` and `package-lock.json`
  - `native/macos/` and `experiments/native-phase1/`
  - `docs/chrome-web-store.md` and `docs/native-phase*.md`
  - `.github/workflows/release.yml`, which only publishes the extension ZIP
- Switch the shortcut to ⌥⇧S. Move the version from `package.json` to a `VERSION` file that
  `build-app.sh` reads.
- CI becomes one macOS job: `swift build`, `swift test`, `build-app.sh` and `test-app-live.sh`.
  `live-api.yml` runs the Swift live test on `macos-latest`. The repo is public, so macOS
  minutes are free.
- Rewrite these docs:
  - `AGENTS.md`: commands, layout and conventions, carrying the Anthropic API rules over
    unchanged.
  - `README.md`: still no privacy section or link.
  - `docs/security.md`: there's no web content, and the key is in the Keychain. The app only
    captures when you press the shortcut, captures only the display under the pointer, and
    leaves out its own windows. Images stay in memory only, and test hooks exist only in the
    test build.
  - `PRIVACY.md`: what is captured, where the key is stored, and what goes to Anthropic.
- Keep `.githooks/pre-push`, which is shell only.

Done when: the repo contains only the app and CI is green.

## Risks

- **Chrome page visibility under the overlay.** Phase 4 measured it: the page stayed visible in
  a normal window and in fullscreen, so the freeze-frame overlay stays.
- **Approvals reset on rebuild** if the app isn't signed with an Apple Development certificate
  (Phase 0).
- **Shortcut conflict** while both the app and the extension exist. Handled by using ⌃⌥⇧S until
  Phase 5.
- **Swift 6 strict concurrency.** It adds early friction, but only in the core target.

## Not planned

A UI for customizing the shortcut, multi-display capture, and saved history.
