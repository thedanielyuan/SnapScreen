# AGENTS.md

SnapScreen is a macOS menu bar app (macOS 15+): press ⌥⇧S, select part of the display under the
pointer, and ask Claude (`claude-opus-5-5`, streamed SSE) about it with the user's own API key.
It's a Swift package with no dependencies: keep it that way, and don't add the Anthropic Swift
SDK (the client is `Sources/SnapScreenCore/AnthropicClient.swift`). It replaced a Chrome
extension and its macOS companion, which `docs/standalone-app-plan.md` records.

## Commands

```bash
git config core.hooksPath .githooks                          # once per clone: pre-push blocks branches behind main
swift test                                                   # the core's tests and fixture replays
swift test --filter AnthropicClientTests                     # one suite
scripts/build-app.sh                                         # → build/SnapScreen.app, signed
build/SnapScreen.app/Contents/MacOS/SnapScreen --self-test   # the views' and app shell's checks
scripts/test-app-live.sh                                     # a test-hooks build snips through real windows
open build/SnapScreen.app                                    # the menu bar app
```

Before finishing any change, run CI's steps in this order: `swift build`, `swift test`,
`scripts/build-app.sh`, the app's `--self-test`, then `scripts/test-app-live.sh`, whose windows
show for a few seconds. After changing activation, panels, notices, the menu or Settings, also run
`scripts/test-app-live.sh --focus` and `--focus --fullscreen`: each posts real input for about
20 seconds, so ask the user first, and quit the running app (`pkill -x SnapScreen`) beforehand.

## Layout

- `Sources/SnapScreenCore/`: the API client (`AnthropicClient`, `SSEParser`, `HTTPTransport`),
  `SessionController`, which runs snips and their answers and reports to the app through a
  delegate, and the rules they share: `RequestLimits`, `ImageFitting`, `SystemPrompt`, `CodeFence`
  and `Settings`.
- `Sources/SnapScreen/`: the AppKit app. `AppDelegate`, `Hotkey` and `StatusMenu` are the shell,
  `ScreenCapturer`, `SelectionOverlay` and `SessionWindows` the snip, and `SettingsWindow`,
  `KeychainStore` and `NoticePanel` the rest. `UI/` holds the conversation, preview and selection
  views.
- `Tests/SnapScreenCoreTests/`: Swift Testing. `Fixtures/` holds golden requests and streams
  recorded from the extension's TypeScript before it was removed.
- `scripts/build-app.sh` bundles and signs the app, and `scripts/test-app-live.sh` runs the live
  test. `docs/security.md` is the security and privacy contract.

## Conventions

- `SnapScreenCore` uses only Foundation, CoreGraphics and ImageIO, in Swift 6 language mode. The
  app is in Swift 5 mode.
- The app's checks need a real app process for windows and keys, so they aren't Swift Testing
  tests: each `Sources/SnapScreen/**/*Tests.swift` has a `run…Tests()` that `main.swift` adds to
  `--self-test`. Add new ones there.
- Surface failures as `AnthropicError(code, message)`. Provider/API text must pass through
  `sanitizeProviderMessage` before it can reach a window.
- No formatter: match the surrounding style (2-space indent, comments wrapped at 100 columns).
- Update workflow actions by hand; never add or suggest Dependabot or Renovate.
- Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`, `test:`). Land on `main` via PR from
  a `<type>/<topic>` branch cut from the remote tip, never local `main` (it falls behind):
  `git fetch origin && git switch --no-track -c <type>/<topic> origin/main`. `main` merges only
  up-to-date PRs that pass CI's `verify` job; if it moves first, run
  `git fetch origin && git merge origin/main` and recheck.

## Security and privacy — do not regress

- The API key lives only in the Keychain (service `com.snapscreen.app`, account
  `anthropic-api-key`), never in files, `UserDefaults` or logs. It's read for each request, with
  Keychain prompts turned off (`readWithoutPrompt`), and no window keeps it. Only Settings may let
  macOS ask for the login password.
- The app captures only when you press the shortcut or choose Snip, only the display under the
  pointer, and leaves out its own windows. Captures, crops and answers stay in memory, are never
  written to disk or logged, and are released when their session closes.
- Capture, conversation, preview and notice panels use `.nonactivatingPanel` and `orderFront(nil)`
  and can never become key or main. Never activate the app or request keyboard focus in this flow.
  Selection and dismissal use the pointer; keyboard selection and Escape/Command-W are
  unavailable, and a snip gets one answer, with no follow-ups or other text input. Keep Stop,
  Retry, Copy and close buttons usable without focus.
  Settings is a separate foreground flow opened explicitly; a missing key shows a passive notice.
  Only Settings keeps the app active: `applicationDidBecomeActive` hands any other activation back
  after `AppDelegate.handbackDelay`, which lets a reopen claim it for Settings, and closing Settings
  hands focus back too (`ForegroundFocus`).
  Give tracking areas `.activeAlways`. macOS ignores cursor changes from an app that isn't
  frontmost, so the overlay's crosshair needs `BackgroundCursor`, enabled only while it's up.
- A finished conversation closes on a click in another app, which a global mouse-down monitor
  sees (`SessionWindows.watchOutsideClicks`). It runs only while the answer has finished, reads
  only where the press was, and can't consume it, so the click still lands. Don't replace it with
  an event tap, key monitoring, or app deactivation or key-window loss. All snip panels remain
  ineligible for the keyboard while closing, including when another snip is open.
- Selecting a region in a new snip closes the earlier snips' windows (`SnipWindows.closeEarlier`)
  through `closeConversation()`, only after the new conversation is shown. Keep that order, and
  don't make the close activate or refocus anything.
- The app takes no commands from other processes: no URL scheme, socket or XPC service. It refuses
  quit events from command-line tools and scripts (`QuitRequest`), so a test can't quit the copy
  the user is running; keep that, and don't widen what it accepts.
- Test hooks (`SNAPSCREEN_TEST_HOOKS`) compile only into `build/test-hooks/`, which has its own
  bundle ID, and `build-app.sh` refuses a production binary that contains them.
- `docs/security.md` is the full contract: update it when you change a boundary, and update
  `PRIVACY.md` when data handling changes. Never add a privacy section or a `PRIVACY.md` link to
  `README.md`.

## Anthropic API (`Sources/SnapScreenCore/AnthropicClient.swift`)

- Adaptive thinking, effort `high`, and `max_tokens: 32_000` are deliberate for answer quality;
  don't change them casually. Keep effort explicit: Opus 5.5 defaults to `medium`.
- Opus 5.5 always thinks: any `thinking.type` other than `'adaptive'`, even `'between_tools'`,
  returns 400, so `verifyAPIKey`'s one-token key check sends no `thinking` field.
- Answer requests send `fallbacks: 'default'` with the `server-side-fallback-2026-07-01` beta, so a
  refused answer continues in the same SSE stream on a model Anthropic picks, after a `fallback`
  content block the parser ignores. Categories without a fallback, such as
  `reasoning_extraction`, still end in the `refusal` error.
- A snip sends one request, which only Retry resends, so answers don't use prompt caching: its
  write cost and the 5 minutes it keeps the screenshot at Anthropic aren't worth a cheaper Retry.
  The user can't reply, so `SystemPrompt.swift` has the model state its assumptions, such as Python
  when no language is given, rather than ask questions.
- Answers are plain text except fenced code blocks, which `CodeFence.swift` and
  `UI/AnswerView.swift` parse for per-block Copy buttons. Change the prompt's formatting rules and
  both parsers together.
- Thinking can stream no text for over 30 s, so `HTTPTransport`'s 60 s idle timeout must stay above
  that; its 10-minute overall timeout bounds the whole answer.
- The golden fixtures pin request bodies and streams, and nothing regenerates them now. After an
  intended change to the client, limits or prompt, edit the affected fixtures by hand in the same
  change.
- Other tests mock the API: only `LiveAPITests` catches the real API rejecting a model, beta
  header, or request field. `swift test` skips it without `SNAPSCREEN_LIVE_API_KEY`;
  `.github/workflows/live-api.yml` runs it daily. After changing any of those, ask the user before
  running `gh workflow run live-api.yml --ref <branch>`, since it spends API credit.

## Building and running

- `build-app.sh` signs with the user's Apple Development certificate (ad hoc in CI). Keep the
  bundle ID and that certificate: macOS ties Screen Recording approval to the signature, and the
  Keychain lets a rebuilt app read the key without a password prompt only when it has the same
  Apple team, which a self-signed certificate lacks.
- Unchanged sources build an identical signature. To check that approvals survive a new one, set
  `SNAPSCREEN_BUILD_NUMBER`, which `build-app.sh` adds to `CFBundleVersion`.
- The version lives only in `VERSION`, which `build-app.sh` writes into the bundle.
- Stop a running copy with `pkill -x SnapScreen` before opening a rebuild, since opening the app
  while one runs only shows that copy's Settings, and it refuses `osascript`'s quit. Leave the
  user's copy as you found it: if it was running, `open build/SnapScreen.app` before you finish,
  including after a test or audit that stopped it, and give test apps their own bundle ID.
  `--self-test` adds and removes a Keychain item under its own service,
  `com.snapscreen.app.self-test`, never the real key's.
- Known limitations, accepted in Phase 4: the shortcut's modifier keys reach the app beneath, and
  macOS's periodic alert for apps that capture the screen without the system picker can take focus
  for one snip.
