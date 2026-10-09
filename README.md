# SnapScreen AI

**Clarity, without breaking your flow**

SnapScreen is a Chrome extension that lets you snip part of the current tab and ask Claude
about it, using your own Anthropic API key.

The default interface runs in Chrome. An optional **experimental macOS companion** now has a
native bridge, Phase 3 interface, and local development build. It requires separate installation
and an explicit selection in Settings. See [setup and current limitations](docs/native-phase2.md)
and [Phase 1 interaction results](docs/native-phase1-results.md). See
[Phase 3 controls](docs/native-phase3.md) and [Phase 4 packaging and acceptance](docs/native-phase4.md).
Unsigned local packages and install/upgrade/uninstall tooling are available. Physical acceptance
and a signed, notarized release remain pending; modifier keys may still reach the page.

## Native-only development build

The separate **SnapScreen Native** extension always uses the macOS companion. It includes
trusted Settings but no injected UI, workspace, `scripting` permission, or web-accessible
resources. Build it independently of the ordinary `dist/` extension:

```bash
npm run build:extension-native
npm run build:native
```

Load `dist-native/` through **chrome://extensions → Developer mode → Load unpacked**.
Use a separate browser user-data root when trying both variants: a profile folder inside the
same root does not isolate host registration. Copy the native-only extension's ID and follow
the [host registration instructions](docs/native-phase2.md#local-setup) for that browser root.
The installer rejects a conflicting registration. To migrate one browser root, follow the
[explicit variant-switch procedure](docs/native-phase4.md#switch-extension-variants), removing
the old registration with the old extension ID before registering the new ID. Registration
authorizes one exact extension origin.

Configure your key, prompt, and limits in Settings and use **Check companion** to verify the
installation. There is no interface selector. First installation opens Settings; later toolbar
and shortcut invocations start capture, with badge feedback for failures. For local files,
enable **Allow access to file URLs** in Chrome's extension management page first.

After a fresh ordinary `npm run build` and `npm run test:browser`, run
`npm run build:extension-native` and `npm run test:browser-native`. The latter uses both build
outputs for resource-probe controls, verifies a temporary ZIP and its extracted asset graph,
and runs the extracted extension with mocked capture, native host, and API responses. It covers
streaming, follow-ups, Stop/Retry, failures, source invalidation, concurrent sessions, connection
cleanup, and an actual worker stop/restart without replay. The restart is a debugger-driven
diagnostic; it does not establish natural suspension or physical focus behavior.
Native live, packaged, and physical runners accept `--extension-dir dist-native` to select
this variant explicitly. Without the flag they keep the repository `dist/` default; explicit
relative paths resolve from the current working directory. The selected build is validated
before fixture changes, with its variant, absolute path, and original/fixture hashes recorded.
After building and packaging the companion, run:

```bash
npm run test:native-live -- --extension-dir dist-native
npm run test:native-packaged -- --extension-dir dist-native
npm run package:extension-native
```

The final command validates the built and extracted assets and writes the distinct
`release/snapscreen-native-only-<version>.zip`, then prints archive and extension SHA-256
checksums. The companion is a separate archive produced by `npm run package:native` under
`native/macos/build/package/`; the command prints its exact path and checksum. Neither archive
contains or installs the other. The default companion package is unsigned and intended for
local acceptance. The tag release workflow continues to publish only the ordinary extension.
`npm run build:native` still builds the Swift companion, and `npm run package` still archives
the ordinary extension. The live suite uses a disposable test-hook app; packaged and physical
runners require the production app.

See the [candidate verification record](docs/native-only-candidate-verification.md) for the
reviewed source, automated results, and checksums identifying both candidate artifacts.
Physical focus and input acceptance for the native-only candidate was partially completed; the
[physical acceptance record](docs/native-only-physical-acceptance.md) lists the tested workflows
and documented limitations. To resume, use the
[physical acceptance procedure](docs/native-phase4-acceptance.md) with `--extension-dir dist-native`
and the extracted production companion to collect evidence with a human operator.

## License

[MIT](LICENSE)
