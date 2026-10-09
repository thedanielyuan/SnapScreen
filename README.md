# SnapScreen AI

**Clarity, without breaking your flow**

SnapScreen lets you snip part of the current Chrome tab and ask Claude about it, using your own
Anthropic API key. The snip and answers appear in the SnapScreen companion, a separate macOS
app, so SnapScreen adds no UI or web-accessible resources to the page. Modifier keys from its
shortcut can still reach the page.

## Setup

Requirements: macOS, Xcode command-line tools with `swiftc`, Node 22, and Chrome 116 or later.
Releases include only the Chrome extension, so build both parts from this repository:

```bash
npm ci
npm run build:extension-native
npm run build:native
```

1. Load `dist-native/` at **chrome://extensions → Developer mode → Load unpacked**, and copy its
   extension ID. SnapScreen's Settings page opens on first installation.
2. Register the companion for that exact ID in your browser's user-data root: the parent of the
   **Profile Path** shown at `chrome://version`, not the `Default` or `Profile 1` folder itself.
   For Google Chrome this is usually `~/Library/Application Support/Google/Chrome`; pass its
   expanded absolute path.

   ```bash
   npm run install:native -- --extension-id <extension-id> --user-data-dir <absolute-user-data-root>
   ```

3. In Settings, add your API key, then choose **Check companion**.

Click the toolbar icon or press Option-Shift-S to snip. If the companion can't start, the
toolbar badge and the icon's tooltip say why for five seconds. For local files, first enable
**Allow access to file URLs** for SnapScreen in Chrome's extension management page.

The registration points at this checkout's build, so rerun it after moving the checkout. To
install a packaged copy of the companion instead, or to upgrade or remove it, see
[Phase 4 packaging](docs/native-phase4.md#install-upgrade-and-remove). See
[Phase 3](docs/native-phase3.md) for how the companion's windows and controls work and
[Phase 1 interaction results](docs/native-phase1-results.md) for the prototype's findings.

## In Chrome build

The original extension shows the snip overlay and answers inside the page instead, so it also
works without the companion and outside macOS. Its Settings can switch it to the companion
(experimental); see [native mode setup](docs/native-phase2.md#local-setup). Build it with
`npm run build` and load `dist/`; scripts call it the `ordinary` variant.

Each browser user-data root registers the companion for one extension ID, shared by all of its
Chrome profiles, and the installer rejects a conflicting registration. To use both builds with
the companion, load them in separate user-data roots, or follow the
[variant-switch procedure](docs/native-phase4.md#switch-extension-variants) to remove the old
ID's registration before registering the new one.

## Development

[AGENTS.md](AGENTS.md) lists the full check sequence that CI runs. `npm run test:browser-native`
needs fresh `npm run build` and `npm run build:extension-native` outputs: it uses both for
resource-probe controls, verifies a temporary ZIP and its extracted asset graph, and runs the
extracted extension with mocked capture, native host, and API responses. It covers streaming,
follow-ups, Stop/Retry, failures, source invalidation, concurrent sessions, connection cleanup,
and an actual worker stop/restart without replay. The restart is a debugger-driven diagnostic;
it does not establish natural suspension or physical focus behavior.

The native live, packaged, and physical runners test `dist/` unless passed
`--extension-dir dist-native`; explicit relative paths resolve from the current working
directory. The selected build is validated before fixture changes, with its variant, absolute
path, and original/fixture hashes recorded. After building and packaging the companion, run:

```bash
npm run test:native-live -- --extension-dir dist-native
npm run test:native-packaged -- --extension-dir dist-native
npm run package:extension-native
```

The final command validates the built and extracted assets, writes
`release/snapscreen-native-only-<version>.zip`, and prints its archive and extension SHA-256
checksums. A matching `v<version>` tag publishes that ZIP as a GitHub release. `npm run package`
archives the In Chrome build, and `npm run package:native` writes the companion archive under
`native/macos/build/package/`, printing its exact path and checksum; releases include neither.
Neither archive contains or installs the other. The default companion package is unsigned and
intended for local acceptance. The live suite uses a disposable test-hook app; packaged and
physical runners require the production app.

Physical focus and input acceptance for the native-only extension was only partially completed.
To resume, use the [physical acceptance procedure](docs/native-phase4-acceptance.md) with
`--extension-dir dist-native` and the extracted production companion to collect evidence with a
human operator.

## License

[MIT](LICENSE)
