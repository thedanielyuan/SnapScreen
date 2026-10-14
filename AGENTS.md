# AGENTS.md

SnapScreen is a macOS 15+ menu bar app: press ⌥⇧S, select part of the display under the pointer,
and Claude (`claude-opus-5-5`, streamed SSE) answers it with the user's own API key. It's a Swift
package with no dependencies: keep it that way, and don't add the Anthropic Swift SDK. It replaced
a Chrome extension; `docs/standalone-app-plan.md` records the move, including the phases that
code comments cite.

## Commands

```bash
git config core.hooksPath .githooks                          # once per clone: refuse stale pushes
swift build
swift test                                                   # core tests and fixture replays
scripts/build-app.sh                                         # → build/SnapScreen.app, signed
build/SnapScreen.app/Contents/MacOS/SnapScreen --self-test   # the app's own checks
scripts/test-app-live.sh                                     # snips through real windows
swift test --filter AnthropicClientTests                     # one suite
open build/SnapScreen.app                                    # run the menu bar app
```

Before finishing any change, run `swift build` through `scripts/test-app-live.sh` in order, as
CI's `verify` job does; the live test's windows show for a few seconds. After changing activation,
panels, notices, the menu or Settings, also run `scripts/test-app-live.sh --focus` and
`--focus --fullscreen`: each posts real input throughout the run, so ask the user first, and quit
the running app (`pkill -x SnapScreen`) beforehand.

## Conventions

- `SnapScreenCore` imports only Foundation, CoreGraphics and ImageIO, in Swift 6 language mode;
  the app is in Swift 5 mode.
- The app's checks need a real app process, so they aren't Swift Testing tests: each
  `Sources/SnapScreen/**/*Tests.swift` has a `run…Tests()` that `main.swift` adds to
  `--self-test`. Add new ones there.
- Surface failures as `AnthropicError(code, message)`, and pass provider/API text through
  `sanitizeProviderMessage` before it can reach a window.
- No formatter: match the surrounding style (2-space indent, comments wrapped at 100 columns).
- Update workflow actions by hand; never add or suggest Dependabot or Renovate.
- Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`, `test:`). Land on `main` via PR from
  a `<type>/<topic>` branch cut from the remote tip, never local `main`, which falls behind:
  `git fetch origin && git switch --no-track -c <type>/<topic> origin/main`. `main` merges only
  up-to-date PRs that pass CI's `verify` job; if it moves first, run
  `git fetch origin && git merge origin/main` and recheck.

## Security and privacy — do not regress

This section is the whole security and privacy contract: update it when you change a boundary or
how data is handled. Never add a privacy section to `README.md`.

- The API key lives only in the Keychain (service `com.snapscreen.app`, account
  `anthropic-api-key`), never in files, `UserDefaults` or logs, and goes only to
  `api.anthropic.com`. Each request reads it with `readWithoutPrompt`, and no window keeps it;
  only Settings may let macOS ask for the login password. If Keychain prompts cannot be disabled,
  fail the read without accessing the key, rather than risk a dialog taking focus.
- Capture only on the shortcut or Snip, only the display under the pointer, without SnapScreen's
  own windows. Captures, crops and answers stay in memory, are never written to disk or logged,
  and are released when their session closes. Only Copy changes the clipboard; tests use private
  pasteboards.
- Screen Recording is the only permission: the shortcut is a Carbon hot key (`Hotkey`), which
  needs no Accessibility or Input Monitoring. Check access with `CGPreflightScreenCaptureAccess`,
  which never prompts; only the Open System Settings button requests it.
- The capture-flow windows (overlay, conversation, preview, notice, pointer shield), status menu
  and read-only text context menus all use `PassivePanel` (`UI/Panels.swift`): non-activating,
  shown with `orderFront(nil)`, and never key or main, even while closing. Never activate the app
  or request keyboard focus in this flow.
  Selection and dismissal use the pointer, with no keyboard selection or Escape/Command-W, and a
  snip gets one answer, with no follow-ups or other text input. Keep Stop, Retry, Copy and close
  usable without focus.
- Menus use `PassiveMenu`, not native `NSMenu` tracking, which can take the foreground window's
  key status and typed input. Their global and local mouse monitors run only while a menu is
  visible, read only the pointer event needed to dismiss it, and never consume an outside click.
  Menus take no keyboard input; typing stays in the foreground app. Answer and error text context
  menus offer only Copy and Select All, and only Copy writes the clipboard.
- Only Settings, opened explicitly, keeps the app active: `applicationDidBecomeActive` hands any
  other activation back after `AppDelegate.handbackDelay`, and closing Settings hands focus back
  (`ForegroundFocus`). A missing key shows a passive notice instead of opening Settings.
- Give tracking areas `.activeAlways`. macOS ignores cursor changes from an app that isn't
  frontmost, so the overlay's crosshair needs `BackgroundCursor`, enabled only while it's up.
- A finished conversation closes on a click in another app, seen by a global mouse-down monitor
  (`SessionWindows.watchOutsideClicks`) that runs only while the answer is complete, reads only
  where the press was, and can't consume it, so the click still lands. Don't replace it with an
  event tap, key monitoring, or app deactivation or key-window loss.
- Selecting a region in a new snip closes the earlier snips' windows (`SnipWindows.closeEarlier`)
  through `closeConversation()`, only after the new conversation is shown. Keep that order, and
  don't make the close activate or refocus anything.
- The app takes no commands from other processes (no URL scheme, socket or XPC service) and
  refuses quit events from command-line tools and scripts (`QuitRequest`), so a test can't quit
  the user's copy. Don't widen what it accepts.
- Test hooks (`SNAPSCREEN_TEST_HOOKS`) compile only into `build/test-hooks/`, which has its own
  bundle ID, and `build-app.sh` refuses a production binary that contains them.

## Anthropic API (`Sources/SnapScreenCore/AnthropicClient.swift`)

- Answers use adaptive thinking, explicit effort `high` (Opus 5.5 defaults to `medium`) and
  `max_tokens: 32_000`, and no prompt caching, since only Retry could read the cache: a cheaper
  Retry isn't worth the write cost or the 5 minutes the cache keeps the screenshot at Anthropic.
  Don't change these casually.
- Opus 5.5 rejects any `thinking.type` but `'adaptive'`, so `verifyAPIKey`'s one-token key check
  sends no `thinking` field.
- Answers send `fallbacks: 'default'` with the `server-side-fallback-2026-07-01` beta, so a refused
  answer continues in the same stream on a model Anthropic picks. Categories without a fallback,
  such as `reasoning_extraction`, still end in the `refusal` error.
- Set answer length and style in `SystemPrompt.swift`, not with effort, which mostly changes how
  much the model thinks. The user can't reply, so answers state assumptions instead of asking.
- Answers are plain text except fenced code blocks, which `CodeFence.swift` and
  `UI/AnswerView.swift` each parse for Copy buttons: change the prompt's formatting rules and both
  parsers together.
- Thinking can stream no text for over 30 s, so keep `URLSessionTransport.idleTimeout` (60 s)
  above that; `overallTimeout` (10 minutes) bounds the whole answer.
- The golden fixtures, recorded from the extension's TypeScript, pin request bodies, streams and
  the prompt, and nothing regenerates them: after an intended change to the client, limits or
  prompt, edit them by hand in the same change. `JavaScriptStrings` keeps the string behavior
  they pin.
- Only `LiveAPITests` calls the real API, so only it catches a rejected model, beta header or
  request field. `swift test` skips it without `SNAPSCREEN_LIVE_API_KEY`, and `live-api.yml` runs
  it daily. After changing any of those, ask the user before running
  `gh workflow run live-api.yml --ref <branch>`, which spends API credit.

## Building and running

- `build-app.sh` signs with the user's Apple Development certificate (ad hoc in CI). Keep the
  bundle ID and that certificate: Screen Recording approval and password-free Keychain reads
  survive a rebuild only with the same Apple team, which ad hoc and self-signed builds lack.
- Unchanged sources build an identical signature; to check that approvals survive a new one, set
  `SNAPSCREEN_BUILD_NUMBER`, which joins `CFBundleVersion`. The version lives only in `VERSION`.
- Opening the app while a copy runs only shows that copy's Settings, and it refuses `osascript`'s
  quit, so stop it with `pkill -x SnapScreen` before opening a rebuild. Leave the user's copy as
  you found it: if it was running, `open build/SnapScreen.app` before you finish, including after
  a test or audit that stopped it. Give test apps their own bundle ID.
- If `test-app-live.sh` prints `SnapScreen is already running.`, a test-hooks copy is still open
  and the duplicate test launch fails with a nonzero exit: stop that copy, not the user's, and
  rerun. The runner requires exit 0 and the exact requested completion marker,
  `SnapScreen test completed: live`, `SnapScreen test completed: focus`, or
  `SnapScreen test completed: focus fullscreen`; a generic `passed` line does not verify a run.
  Its false-success regression checks run on each invocation.
- `--self-test` uses its own Keychain service, `com.snapscreen.app.self-test`, never the real
  key's.
- Known limitations, accepted in Phase 4: the shortcut's modifier keys reach the app beneath, and
  macOS's periodic alert for apps that capture the screen without the system picker can take
  focus for one snip.
