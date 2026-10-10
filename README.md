# SnapScreen AI

**Clarity, without breaking your flow**

SnapScreen is a macOS menu bar app. Press ⌥⇧S, drag over part of your screen, and ask Claude
about it with your own Anthropic API key. The answer opens beside your selection, and the app you
snipped keeps focus: SnapScreen's windows never activate it.

## Build and run

Requirements: macOS 15 or later and Xcode 16 or later.

```bash
scripts/build-app.sh
open build/SnapScreen.app
```

Settings opens the first time, so you can add your API key. Your first snip asks you to allow
Screen Recording in System Settings. Sign builds with an Apple Development certificate, which is free with an
Apple ID, so that the Keychain and Screen Recording keep trusting the app after a rebuild; see
Phase 0 of the [plan](docs/standalone-app-plan.md). Without one, `build-app.sh` signs ad hoc and
macOS asks again after every rebuild.

## Using it

- Press ⌥⇧S, or choose **Snip** from the menu bar icon, to freeze the display under the pointer.
- Drag over a region and release to ask. Click or press Escape to cancel; Return selects with the
  keyboard.
- Ask follow-ups in the conversation window. You can Stop or Retry an answer, open the
  screenshot, and copy a code block or the answer.
- Settings holds your API key, a Default Prompt for first answers, the advanced limits, and Open
  at login.

## Development

[AGENTS.md](AGENTS.md) lists the checks CI runs and how the package is laid out.
[docs/standalone-app-plan.md](docs/standalone-app-plan.md) records how the app replaced the
Chrome extension and its companion.

## License

[MIT](LICENSE)
