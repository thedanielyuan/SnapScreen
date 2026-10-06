# Native verification and distribution (Phase 4)

Phase 4 is in progress. The repository now builds a versioned production companion archive,
installs and upgrades it at a stable user-local path, and tests the extracted archive through
Chrome. Physical interaction acceptance and an actual Developer ID/notarized release are
still required. The default package is an **unsigned local acceptance build**.

## Build and check a package

On macOS with Xcode command-line tools and Node.js 22 or later:

```bash
npm ci
npx playwright install --no-shell chromium
npm run lint
npm run typecheck
npm test
npm run build
npm run test:browser
npm run build:native
npm run test:native
npm run test:native-live
npm run package:native
npm run test:native-packaged
```

The package command prints the archive, staged app, metadata, and SHA-256 checksum paths.
Outputs live under `native/macos/build/package/` and are ignored by Git. Each archive contains
`SnapScreenCompanion.app`, a standalone Node installer, `README.txt`, and `release.json`.
The app version comes from `package.json`; the build checks that Swift and TypeScript agree
on the native protocol version. Both sides require that exact version in the handshake, so an
app works with any extension build that uses the same protocol; package and release them from
the same commit. Its metadata records the build target, architectures, and absence of native
test hooks. Packaging runs the production app's self-tests before archiving.

`--arch arm64`, `--arch x86_64`, and `--arch universal` select explicit targets; the default is
the build machine's architecture. The compiler targets macOS 13.0 or later. **A deployment
target is not a tested support claim.** Running the x86_64 slice under Rosetta 2 on Apple
silicon does not establish behavior on Intel hardware. The extension still declares Chrome 116
as its minimum; the native workflow needs separate evidence for every advertised
OS/browser/architecture combination.

```bash
npm run package:native -- --arch universal
npm run test:native-packaged -- --archive /absolute/path/to/package.zip
```

## Install, upgrade, and remove

Extract the ZIP. Get the exact extension ID from `chrome://extensions` and the browser's
user-data root from `chrome://version` (the parent of **Profile Path**, not its `Default` or
`Profile 1` directory). Chrome, Chrome for Testing, and Chromium may use different roots; the
installer rejects a profile folder. Run from the extracted release folder, replacing the
extension ID. This example uses Google Chrome's usual root:

```bash
node native-companion-install.mjs --app "$PWD/SnapScreenCompanion.app" \
  --extension-id YOUR_EXTENSION_ID --user-data-dir "$HOME/Library/Application Support/Google/Chrome"
```

The installer copies the app to `~/Library/Application Support/SnapScreen`, then writes an
absolute executable path and exactly one allowed extension origin to that browser root's
`NativeMessagingHosts/com.snapscreen.companion.json`. A local receipt tracks the installed app
and its registrations. It stores installation metadata only, not screenshots or conversations.
Use **Check companion** in SnapScreen Settings after selecting the experimental native mode.

For an upgrade, close companion windows and rerun the same command with the new extracted app.
The installer validates bundle identity, version metadata, executable self-tests, and the copy;
rejects downgrades and conflicting registrations; and rolls back failed replacements. A shared
app can have registrations in multiple explicitly chosen browser roots. Register each root
separately. A root that already has a development registration must have it removed first
(`npm run install:native -- --remove` with that root and ID); development and managed
registrations can coexist in different roots.

```bash
node native-companion-install.mjs --remove \
  --extension-id YOUR_EXTENSION_ID --user-data-dir "$HOME/Library/Application Support/Google/Chrome"
```

Removal only touches a registration naming the managed app and that exact extension origin.
Removing the last recorded registration also removes the managed app, its receipt, and the
default folder when nothing else is inside. Unrelated files are retained. If the app was deleted
outside the installer, install and remove still work; if it was modified, both stop until it is
moved aside. Uninstalling the Chrome extension does not remove the separate companion;
uninstalling the companion does not remove Chrome's API key or settings. There is no automatic
update service. Node.js 22+ remains an installation prerequisite for this developer/acceptance
distribution.

## Signing and notarization preparation

The local unsigned workflow needs no Apple credentials. When preparing an actual release,
use a Developer ID Application certificate and an existing `notarytool` keychain profile:

```bash
npm run package:native -- --arch universal --release \
  --sign-identity 'Developer ID Application: YOUR NAME (TEAMID1234)' \
  --notary-profile YOUR_KEYCHAIN_PROFILE
```

Supplying `--notary-profile` uploads the signed app to Apple's notary service. The release path
requires both options, signs with hardened runtime and a secure timestamp, checks the expected
team and timestamp, waits for Apple's **Accepted** result, staples and validates the ticket,
requires a `Notarized Developer ID` Gatekeeper assessment, and reruns the production self-tests
before producing the final archive. Signing alone is labeled `signed`, never `notarized`. A
rejected submission's error names its ID for `xcrun notarytool log`. Failed gates do not produce
a new release archive. Keep credentials in the macOS keychain; do not put passwords or
certificates in the repository.
The workflow follows Apple's [notarization guidance](https://developer.apple.com/documentation/Security/customizing-the-notarization-workflow)
and [Developer ID guidance](https://developer.apple.com/developer-id/).

The existing tag workflow still publishes only the extension ZIP. Native packages are not
automatically uploaded or released. Signing/notarization tooling has local gate tests; a real
credentialed run and Gatekeeper installation on a clean Mac remain release gates. Signing does
not establish interaction acceptance, which stays explicitly pending in the package metadata.

## Evidence and remaining gates

Local verification on 7 October 2026 used macOS 27.0 on arm64. Automated suites used
Chromium 149.0.7827.55; the acceptance runner was also started with Google Chrome 154.0.8037.98:

| Check | Result |
| --- | --- |
| Lint, typecheck, extension build and browser smoke | Passed |
| Vitest | 419 passed; 2 paid live API tests skipped |
| Production companion self-tests | 318 checks passed |
| Installer, packaging gates, and acceptance fixture tests | 22 passed |
| Real Chrome-launched mocked exchange | Passed |
| Extracted arm64 package, managed install at the default path, Chrome lifecycle | Passed |
| x86_64 and universal packages | Self-tests and packaged Chrome test passed; x86_64 ran under Rosetta 2, not on Intel hardware |
| Hardened runtime with an ad hoc signature | Packaged Chrome test passed |
| Signature and Gatekeeper gates | Accept existing notarized Developer ID apps on this Mac |
| Unsigned archive reproducibility | Two package runs produced identical archives |
| Physical collector startup, setup commands, and cleanup | Passed in both browsers with no focus emulation or native test hooks |
| Physical interactions, Developer ID signing, notarization | Not performed |

The final tested arm64 archive SHA-256 was
`ec02b61f6f7f84812787db8a7330b95b034d79ae432b01a6be4a2f2a88f14c60`.
This identifies the unsigned local artifact, not a published release.

The macOS CI job runs both native suites. The test-hook suite uses the built extension with
mocked API answers for selection, streaming, follow-ups, navigation expiry, and error routing.
The packaged suite extracts the production ZIP, runs its shipped installer at the default
`Application Support` path under a temporary home directory, and checks real Chrome launches,
exact version handshakes, independent processes across two browser roots,
malformed/version/oversized rejection, capture disconnection, worker restart without replay,
and uninstall. Neither suite spends API credit or installs in everyday browser
profiles. The browser suite continues to enforce native-mode non-injection and retained
In Chrome confidentiality boundaries.

Use the [packaged physical acceptance runner](native-phase4-acceptance.md) to collect the
remaining interaction matrix. It uses the production app with no native test hooks, a disposable
copy of the built extension, canned answers, the Phase 1 page probe, and raw CDP without focus
emulation. Its fixture-specific extension edits and artifact hashes are recorded explicitly.
Actual shortcut/toolbar use, controls, application/tab-switch positive controls, and environment
details must be recorded; a successful runner setup is not an accepted interaction trial.

Pending release evidence includes VoiceOver and keyboard traversal; selection, preview, Copy,
Stop, Retry, text editing, input methods and close; fullscreen, display/scale/zoom changes;
supported incognito configurations; real installation/upgrades under Gatekeeper; and the
supported OS/browser/architecture matrix. The accepted Phase 1 modifier-key limitation still
applies. Do not inherit Phase 1 physical results for the completed packaged UI.
