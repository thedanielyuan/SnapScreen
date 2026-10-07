# SnapScreen AI

**Clarity, without breaking your flow**

SnapScreen is a Chrome extension that lets you snip part of the current tab and ask Claude
about it, using your own Anthropic API key.

The default interface runs in Chrome. An optional **experimental macOS companion** now has a
native bridge, Phase 3 interface, and local development build. It requires separate installation
and an explicit selection in Settings. See [setup and current limitations](docs/native-phase2.md),
the [implementation plan](docs/native-companion-plan.md), and
[Phase 1 interaction results](docs/native-phase1-results.md). See
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
The existing installer rejects a conflicting registration. To migrate one browser root,
explicitly remove the old registration with the old extension ID before registering the new
ID; see the same setup instructions. Registration authorizes one exact extension origin.

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
Existing native live/packaged/physical runners still select `dist/`; variant selection and
native-only release archive packaging are subsequent work. Physical focus and input acceptance for
the native-only candidate remain pending. `npm run build:native` continues to build the Swift
companion, and `npm run package` continues to archive the ordinary extension.

## License

[MIT](LICENSE)
