# Phase 1: native interaction experiment

This macOS prototype tests the native companion's interaction model.
It is a separate unpacked extension with mocked answers, not a native mode in the shipping
extension. Do not proceed with the full companion based only on a successful build or bridge
handshake. The [results](../../docs/native-phase1-results.md) distinguish measured behavior
from untested workflows.

## Process arrangement

Chrome launches the Swift executable via `chrome.runtime.connectNative()`. That same process
owns the AppKit nonactivating panels. There is no shared desktop service, socket, or second IPC
boundary. Each Chrome connection has its own process and one current capture. The port stays
open after Close to permit a warm-process experiment; quitting the disposable browser closes
stdin and terminates the host. A cold run requires a new connection/process. If this arrangement
changes, repeat the measurements.

The selection surface displays a **fitted frozen image**, not an overlay aligned to Chrome's
viewport. Coordinates are normalized within the image, excluding letterboxing. The panel is
nonactivating but can become key to accept keyboard input. Whether that steals observable
focus from Chrome is an experimental question, not a guarantee supplied by the window flag.

## Build and run

Requirements: macOS, Xcode Command Line Tools (`xcrun swiftc`), Node 22+, npm dependencies,
and Playwright's Chromium (`npx playwright install chromium`).

```bash
npm ci
npm run build:native-prototype
npm run test:native-prototype
npm run experiment:native
```

The runner starts the instrumented page on loopback, opens a visible Chrome for Testing window,
and registers the host only inside a fresh temporary user-data directory. The allowed origin
is the stable experiment extension ID, `cdkiemiejgdholedacflfdkgmkfiaaoo`. It does not register
the host in your ordinary Chrome profile. On `quit`, Ctrl+C, or normal failure it removes the
profile and host manifest. A forced process kill may leave the temporary directory; the
startup path is not used by your everyday browser.

Use real browser controls during the experiment:

- **Alt+Shift+S:** the extension action's real shortcut, which grants `activeTab`.
- **Toolbar:** open Chrome's Extensions menu and click **Native Phase 1: capture and select**. Record menu and
  invocation signals as part of this route; do not omit activation-induced blur.
- **Alt+Shift+B:** capture-only baseline, with no native panel.
- Drag a rectangle and release it; the answer opens at once. A click without a drag cancels.
- Observe the mocked stream; exercise Copy, preview, scrolling, movement, edge resizing, and
  follow-up.
- Close or Escape; invoke again on the same connection for the warm-process case.

The terminal accepts observation commands while the UI remains active:

```text
mark cold-shortcut
state
save run-01.json
reset
quit
```

`state` prints compact page and connection state; `status` prints the full report. `reset`
clears both the page probe and the extension log without touching the page, connection, or
session. Setup-only commands change the test window before a recorded action: `window` prints
its state, `move <left> <top>` moves it (for example onto another display), and `fullscreen` /
`normal` set macOS fullscreen or a normal window. `kill-host` sends SIGKILL to the connected
host, after checking that the PID belongs to this experiment's executable, to observe crash
handling. Typing into the terminal changes the front application, so feed commands without
focusing it, for example:

```bash
tail -f commands.txt | npm run experiment:native
```

Append each command to `commands.txt` from another shell. For per-session results, run
`node experiments/native-phase1/fixture/sessions.mjs <report.json>`; `--evidence <file>
--method "<how actions were performed>"` also writes a metadata-only extract for `results/`.

For physical tests, use `trial <label>` instead of changing focus to enter markers during an
action. It gives you five seconds to return to Chrome and focus the page field, then records
for 25 seconds and automatically saves `<label>.json`. It reports invalid starting focus and
refuses overlapping trials. Begin with actual application-switch and tab-switch controls.

`mark` does not focus or modify the page. `save` writes metadata-only observations under
`experiments/native-phase1/build/results/` (ignored by Git). It records page, extension, and
native timestamps in one file, with SHA-256 hashes of the built native executable and
extension files to identify the tested build. `reset` clears page observations, so save before using it.
The extension exposes metadata-only diagnostics through its worker's `phase1` object. Do not
use synthetic callback invocation as evidence for real shortcut/toolbar behavior.

For a cold restart inside a run, the worker's diagnostic shutdown function may close its native
connection; the next **real invocation** creates a fresh process. Mark this explicitly.
Process disconnection must never replay a capture or switch tabs.

## Observation method and acceptance

Use the fixture's initially focused text field. Keep the ordinary browser window foreground
before marking the baseline. Record each action separately, including pointer movement onto
the native surface, and save before returning focus to the developer tools or terminal.
Automation that activates the target application can itself change focus; label these runs
as contaminated and repeat manually before accepting a focus-preservation claim.

The probe records DOM mutation metadata, iframe count, focus/blur/focusin/focusout,
`document.hasFocus()`, active element identity, visibility, viewport state, and pointer,
keyboard, clipboard, and composition event metadata. It never patches page APIs or prevents
page events. It does not retain typed characters, clipboard contents, screenshot pixels, or
DOM text. See [fixture instructions](fixture/README.md).

Any transient focus or visibility change fails the strict requirement. Any native-directed
input reaching a page handler also fails, even if focus remains true. Pointer exits and
activation shortcut modifier events are still observations and must be reported separately.
A one-display run establishes nothing about fullscreen, multiple Chrome windows, multiple
monitors, different display scales, browser zoom, keyboard layouts, or input methods.

## Privacy and limits

The experiment requests only `activeTab` and `nativeMessaging`. It has no content scripts,
web-accessible resources, API access, settings page, or access to the shipping extension's key.
The local native process receives the captured image and follow-up text in memory. All answers
are canned. Copy intentionally writes the sample answer to the macOS clipboard. Observations
contain metadata only; raw screenshots and conversation contents are not written by this
experiment. Browser/OS internals may have their own retention behavior.

Transport is versioned and bounded on both ends. Only session-bound selections and follow-ups
are accepted. On missing host, invalid messages, navigation during selection, or disconnection,
the experiment cancels and uses a badge/status log; it never opens an injected UI or workspace.
There is no production installer, signing, notarization, release packaging, paid API request,
or Phase 2 conversation migration in this prototype.
