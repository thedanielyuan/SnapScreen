# Packaged native interaction acceptance

Status: runner prepared; physical acceptance of the Phase 3 interface is pending. A successful
build, package, or automated transport test does not establish focus preservation, keyboard
privacy, accessibility, or support for an untested OS/browser/display combination.

Use the actual extracted or installed app you intend to distribute. The runner never builds
the app, modifies its bundle, or compiles `SNAPSCREEN_TEST_HOOKS`. It runs the app's production
self-tests first and rejects a test-hooks build. All native selection, editing, Copy, preview,
Stop, Retry, and Close actions must use the shipping AppKit controls.

```bash
npm run build
npx playwright install --no-shell chromium
npm run experiment:native-packaged -- --app "/absolute/path/SnapScreenCompanion.app"
```

To collect evidence for the native-only extension, build and select it explicitly:

```bash
npm run build:extension-native
npm run experiment:native-packaged -- --extension-dir dist-native \
  --app "/absolute/path/SnapScreenCompanion.app"
```

`--extension-dir` defaults to the repository `dist/`; explicit relative paths resolve from the
current working directory. A missing or invalid selected build fails before the browser starts.
The runner validates the built variant and records its absolute source path, original per-file
and aggregate SHA-256 hashes, and the fixture's hashes. Use the same candidate and companion
artifacts as the automated packaged tests; a report for one variant does not establish the other.

The default browser is Playwright's installed Chromium binary, launched directly with a fresh
profile. `--browser /absolute/path/to/browser` selects another Chromium-based executable, such
as installed Google Chrome:
`--browser "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"`. Google Chrome 137
and later ignores `--load-extension`, so the runner loads the fixture with the DevTools
`Extensions.loadUnpacked` command over `--remote-debugging-pipe`. The report records the
browser version and the shortcut Chrome assigned; do not infer Chrome 116 support from a newer
version.
`--output /absolute/path/to/results` selects a results directory (default:
`native/macos/build/acceptance-results`). `--trial-seconds 90` extends the default 45-second
action window; values from 10 to 300 seconds are accepted.

The temporary extension copies the selected fresh build, adds a stable public fixture key and
display name, and wraps the production worker with a mock-only fetch and metadata observer.
It keeps the real action/shortcut callbacks, `activeTab` authorization, capture, crop, native
bridge, conversation controller, and API stream parser. The shim seeds a dummy key and native
mode only in that disposable profile. Every worker `fetch` is either the locally generated
Anthropic-shaped response or a blocked request; it never falls through to the network. A
successful capture therefore requires a real toolbar or keyboard invocation. These fixture
changes are named and separately hashed in every report, alongside all packaged app files and
the original selected extension files. Source validation precedes fixture instrumentation.
The live functional suite uses its own disposable test-hook app; that app is not accepted here.

Only this browser profile registers `com.snapscreen.companion`, with the absolute executable
path and one exact fixture extension origin. `quit`, Ctrl+C, and normal error cleanup close
the browser and remove its temporary profile/registration. Existing browser profiles and host
registrations are untouched. Results contain metadata and must use dummy fixture content only.
The observer never writes screenshot bytes, answers, follow-up text, clipboard contents, or
printable key values. URLs, artifact paths, display geometry, and OS/browser versions are saved.

## Recording an interaction

The runner reuses the Phase 1 page probe with a raw Chrome DevTools Protocol pipe. It never
attaches Playwright, enables focus emulation, synthesizes page input, or changes the page's
focus/visibility APIs. Its profile uses a mock keychain, so no keychain prompt can interrupt a
trial. Use a physical keyboard and pointer. Automation of native controls can
help debug functionality, but its reports cannot replace physical acceptance.

1. Pin the fixture extension in Chrome's toolbar during setup. Close any setup dialogs and
   focus the page's text field. Keep all content synthetic.
2. First run positive controls: an ordinary page click and typing, an actual application
   switch, and an actual Chrome tab switch. Their reports must show the expected input,
   blur/focus and visibility signals. If they do not, stop and fix the observer setup.
3. Enter `trial shortcut-selection` in the runner. It waits five seconds so you can return to
   Chrome and focus the field. After recording starts, use the real shortcut, select, and
   interact with the native window during the action window. The report saves automatically;
   do not return to the terminal until the recording window ends.
4. Use one clear action or workflow per label, including cold launch and a second session
   while a previous answer window remains open. Record the action performed and visible native
   outcome separately; the shipping app intentionally exposes no test telemetry.
5. Inspect the JSON after the trial. `trial.startValid` must be true, both observation buffers
   must have zero dropped entries, and the timestamps must cover the intended action. Reports
   are marked `pending-physical-review`, never automatically passed.

`state` reads a compact state, `status` reads a full snapshot, and `save label.json` saves an
ad-hoc snapshot. `reset` clears metadata only and is blocked during a timed trial. `mark label`
adds a fixed action label; never include typed content. Returning to the terminal to issue
commands during a timed trial introduces a real application switch and must be recorded as
such, so set up scenarios before each trial.

`scenario slow` delays the mocked stream for Stop and waiting-state checks. `scenario error`
makes the next request fail once; Retry then receives the ordinary answer. `scenario answer`
restores ordinary streaming. Follow-up answers are synthetic and deliberately do not echo the
question. `disconnect` closes fixture native ports, and `restart-worker` requests worker
termination. These are diagnostic operations, not user interaction passes. They cannot establish
natural service-worker suspension behavior while a debugger is attached.

`window`, `move <left> <top>`, `fullscreen`, and `normal` inspect or set up browser geometry.
Change geometry before a trial, then physically move/resize the companion during it. The probe
belongs to one fixture document; navigation/reload resets it and closing it prevents collection.
Use automated lifecycle coverage for those cases and separate before/after snapshots for
physical navigation diagnostics. Do not count an incomplete document trace as acceptance.

## Required review matrix

Record the exact macOS build, browser version, processor architecture, keyboard layout/input
method, display/scaling arrangement, Chrome zoom, and Full Keyboard Access/VoiceOver settings.
The runner captures OS/browser versions and initial viewport automatically; add the remaining
conditions and the operator's actions to the reviewed results without recording personal text.

| Interaction | Evidence required |
| --- | --- |
| Ordinary page input, application and tab switching | Positive controls expose expected input/focus/visibility transitions |
| Pinned toolbar and shortcut, cold and concurrent launch | Route and actual capture appear in extension metadata; record activation signals separately |
| Drag selection, click cancellation, Return/arrows/Shift/Option selection, Escape | Correct crop; native-directed keys/pointer actions do not reach page; no transient focus/visibility changes |
| Streaming, waiting, Stop, Retry, errors | Expected UI and request transitions, no replay, no page UI/workspace/Settings fallback |
| Move, native edge resize, scroll, code Copy, answer Copy and selection | Correct native behavior and clipboard result; no page event leakage |
| Preview open, move, resize, independent close | Correct crop and return to composer; no stray close-key release |
| Follow-up typing, selection, cut/copy/paste, multiline, character limit, IME | Native text outcome verified; no page input/clipboard/composition events |
| Tab/Shift-Tab, Full Keyboard Access, VoiceOver | Controls reachable, labelled and usable; any conflict with focus claims stated |
| Escape/Command-W, held close keys, close during streaming, connection loss | Correct cleanup, no stale commands or request replay, no leaked nonmodifier keys |
| Fullscreen, multiple windows/displays, mixed scale, zoom, keyboard layouts | Repeat the relevant actions for each claimed supported configuration |

Any transient focus or visibility change counts, even if the final state recovers. Keep the
previously accepted modifier-key limitation explicit: the shortcut's Option/Shift and Command
used by native shortcuts may reach page handlers. Never discard those events from evidence or
describe the workflow as universally undetectable. Absence of a page event alone does not prove
that a native action succeeded; pair the trace with the observed control result.

Publishing a reviewed matrix, testing installation/upgrade/uninstall of the final signed and
notarized artifact, and evaluating supported incognito/profile combinations remain release work.
