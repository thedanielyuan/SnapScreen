# Native-only candidate verification

Milestone 4 completed on 7 October 2026. All 20 preparation, verification, and packaging
commands passed. Both extension variants were checked, and the production companion was
tested with the ordinary build, native-only build, and a retained extraction of the final
native-only ZIP. Physical acceptance and trace review remain milestones 5 and 6.

## Source and environment

The reviewed implementation is commit `f120ea5fef71ecda7295d8d6ee783d059fb03b37`
(tree `7b13584e2e85c709a8755c81ab426e4959a6fe25`). The checkout was clean when verification
started. All extension, companion, installer, test, dependency, and build inputs remained
unchanged from that commit throughout packaging and verification. This milestone adds
documentation and the verification record; it changes no runtime code. Both candidate
archives therefore come from the same reviewed implementation. After verification,
`eslint.config.js` also ignores `release/`, so the retained extracted bundles below do not fail
`npm run lint`; this changes neither artifact.

| Item | Recorded value |
| --- | --- |
| Local run | 7 October 2026, 11:38–11:40 BST (Europe/London) |
| Extension / companion version | 1.1.0 / 1.1.0 |
| Native protocol | 3 |
| macOS / architecture | 27.0 (26A428) / arm64 |
| Node.js / npm | 24.15.0 / 11.12.1 |
| Xcode / Swift | 27.0 (27A266a) / Apple Swift 6.4 |
| Automated browser | Playwright Chromium 149.0.7827.55 |
| Companion status | Unsigned local acceptance build; no Developer ID signing or notarization |

The macOS 13 deployment target and Chrome 116 manifest minimum are build requirements, not
evidence of testing those versions. These results cover the environment above. Remote CI,
Google Chrome physical trials, Intel/universal builds, and signed distribution were not run
as part of this milestone.

`SNAPSCREEN_LIVE_API_KEY` was removed from the environment of every verification command.
The two paid live API tests were skipped. Browser/native checks used synthetic content and
mocked or blocked API transport; no paid API workflow was dispatched. Installer and native
runner tests used disposable browser roots, leaving everyday registrations untouched.

## Retained artifacts

All files below are local to `release/native-only-candidate-2026-10-07/`, which is ignored by
Git. They have not been published. Retain this directory for milestone 5; the usual `dist/`,
`dist-native/`, and top-level release ZIPs can be overwritten by later builds. Links to local
evidence will be unavailable in a fresh clone unless that directory is copied alongside it.

| Artifact | Retained path relative to the candidate directory |
| --- | --- |
| Native-only extension ZIP | [snapscreen-native-only-1.1.0.zip](../release/native-only-candidate-2026-10-07/snapscreen-native-only-1.1.0.zip) |
| Unsigned production companion ZIP | [companion/SnapScreenCompanion-1.1.0-macos-arm64-unsigned.zip](../release/native-only-candidate-2026-10-07/companion/SnapScreenCompanion-1.1.0-macos-arm64-unsigned.zip) |
| Ordinary extension control ZIP | [snapscreen-1.1.0.zip](../release/native-only-candidate-2026-10-07/snapscreen-1.1.0.zip) |
| Extracted native-only extension | `extension-native/` |
| Extracted ordinary extension | `extension-ordinary/` |
| Extracted production app | `extracted-companion/SnapScreenCompanion-1.1.0-macos-arm64-unsigned/SnapScreenCompanion.app` |

Archive SHA-256 checksums, also saved in [SHA256SUMS](../release/native-only-candidate-2026-10-07/SHA256SUMS):

```text
ec5d119a6545d134a2bdd45a9946913359a0adfd46e9e1e4a1f66c62895fd2bc  snapscreen-native-only-1.1.0.zip
3d4297f854eaf41b8ddb043a03a3fb5f22bc204002fc6aba5b1ca0ca68cf3edf  companion/SnapScreenCompanion-1.1.0-macos-arm64-unsigned.zip
735b97329a49fac10e9ebc8eb019411b4510184bcb6bde6d8372c218f9a91e03  snapscreen-1.1.0.zip
```

Content identities use `hashSummary` from `scripts/native-extension-artifact.mjs`: SHA-256
of the JSON-encoded, sorted relative-path-to-file-SHA-256 map. They differ from ZIP checksums.

| Content | SHA-256 |
| --- | --- |
| Native-only extension, all 12 files | `6e0180d96e2af8bc9b7468e5207174aacbb5d0dcac60353aa5a17a65413338f7` |
| Ordinary extension, all 30 files | `a8d49f1d27d050a783dc7d7e7426bd4219583d77e9b3ee440cc7888298599674` |
| Extracted production app, all bundle files | `d7f7a690ac52fc9ba87c9f6ee7f6c94aed5599f1879ffa1ad367af0757abd5e5` |
| Production executable | `55654155a0e3d9e6eb81db1e91f99e1d363aa610dea2529deb9b63dd8fe2b391` |
| Shipped installer | `964c2a0f2bea8137142d3bdb98776569a7a10af3c01aa7eb9ac5e31e0c029764` |

[artifacts.json](../release/native-only-candidate-2026-10-07/artifacts.json) preserves the full
source paths, manifests, original/extracted file hashes, app/package metadata, and environment.
The companion archive's extracted executable and installer match `release.json`. Its metadata
records `testHooks: false`, `signing: unsigned`, `notarization: null`, and
`physicalInteractionAcceptance: pending`. Both extracted extension trees match their builds
file for file. Source validation took place before each runner added its disposable fixture.

## Automated results

[checks.json](../release/native-only-candidate-2026-10-07/checks.json) records every exact
command, start/end time, exit code, and log path. All 20 commands exited zero. The table below
groups related commands; logs are retained under `logs/` in the candidate directory.

| Commands | Result | Log files |
| --- | --- | --- |
| `npm ci`; `npx playwright install --no-shell chromium` | Dependencies and browser ready | `01-install.log`, `02-browser-install.log` |
| `npm audit --audit-level=moderate` | Zero vulnerabilities | `03-audit.log` |
| `npm run lint`; `npm run typecheck` | Passed; zero lint warnings | `04-lint.log`, `05-typecheck.log` |
| `env -u SNAPSCREEN_LIVE_API_KEY npm test` | 448 passed; 2 paid live tests skipped; 35 files passed, 1 skipped | `06-unit.log` |
| `npm run build`; `npm run test:browser` | Fresh ordinary build and browser smoke passed | `07-build-ordinary.log`, `08-browser-ordinary.log` |
| `npm run build:native`; `npm run test:native` | Production build; 318 Swift checks and 50 Node tests passed, including extension-artifact regressions | `09-build-companion.log`, `10-native.log` |
| `npm run test:native-live` | Ordinary extension: live host/capture/conversation/cleanup checks passed | `11-live-ordinary.log` |
| `npm run package:native -- --output-dir <candidate>/companion` | Unsigned arm64 production archive created and self-tested | `12-package-companion.log` |
| `npm run test:native-packaged -- --archive <emitted companion ZIP>` | Ordinary extension with extracted, installed production app passed | `13-packaged-ordinary.log` |
| `npm run build:extension-native`; `npm run test:browser-native` | Native-only build, 31 package tests, and extracted-ZIP browser lifecycle checks passed | `14-build-native-extension.log`, `15-browser-native.log` |
| `npm run test:native-live -- --extension-dir dist-native` | Native-only live host/capture/conversation/cleanup checks passed | `16-live-native.log` |
| `npm run test:native-packaged -- --extension-dir dist-native --archive <emitted companion ZIP>` | Native-only build with extracted, installed production app passed | `17-packaged-native.log` |
| `npm run package:extension-native`; `npm run package` | Separate native-only and ordinary archives verified and retained | `18-package-native-extension.log`, `19-package-ordinary-extension.log` |
| `npm run test:native-packaged -- --extension-dir <candidate>/extension-native --archive <emitted companion ZIP>` | Final native-only ZIP extraction with the same production archive passed | `20-packaged-extracted-native.log` |

Each packaged run used the exact companion archive path printed by the packaging command.
Each live/packaged runner log records the selected extension variant/path, original file and
aggregate hashes, fixture hashes, and modifications. The final packaged run explicitly selected
the retained native-only ZIP extraction. The live suite alone compiled a disposable test-hook
app; packaged tests used the unmodified production app and its shipped installer.

[evidence-integrity.json](../release/native-only-candidate-2026-10-07/evidence-integrity.json)
records a final cross-check of all five runner identities, their fixture modifications, archive
checksums, retained extractions, and unchanged build inputs, plus SHA-256 hashes of every log.

The native-only browser gate checked the absence of scripting permission, content scripts,
web-accessible resources, injected UI, result frame, workspace, and test shims. It also checked
Settings/CSP, resource probes with controls, streaming/follow-ups/Stop/Retry, cancellation and
host failures, source invalidation, concurrency, and worker restart without replay.

Packaged companion checks covered production self-tests, installation at the user-local default
path in a disposable home, exact-origin registration in two browser roots, real browser-launched
handshakes, malformed/version/oversized request rejection, capture disconnect, host exit after
worker termination, restart without replay, and removal. These tests use mocked capture or
invocation and debugger-driven worker stops. They do not establish physical input isolation,
real toolbar/shortcut authorization, or natural worker suspension behavior.

## Milestone 5 handoff

Security, privacy, store-listing, and setup documentation now describe the independent archives,
native-only permissions/data boundaries, unsigned acceptance status, and explicit exact-origin
registration switching. No store listing, GitHub release, signing, or notarization was performed.

Use the retained extraction and production app for the human-operated
[physical acceptance procedure](native-phase4-acceptance.md). From the repository root:

```bash
candidate="$PWD/release/native-only-candidate-2026-10-07"
(cd "$candidate" && shasum -a 256 -c SHA256SUMS)
npm run experiment:native-packaged -- \
  --extension-dir "$candidate/extension-native" \
  --app "$candidate/extracted-companion/SnapScreenCompanion-1.1.0-macos-arm64-unsigned/SnapScreenCompanion.app" \
  --trial-seconds 90 \
  --output "$candidate/physical-acceptance"
```

At the milestone 4 handoff, this collector command had not been run for this candidate.
Subsequent collector preparation and physical work are tracked in the
[physical acceptance record](native-only-physical-acceptance.md). The command defaults to installed Playwright
Chromium; select another browser explicitly and record its version when assessing that browser.
Begin with physical page-input, application-switch, and tab-switch positive controls. Focus,
visibility, keyboard/pointer leakage, resizing, accessibility, and the environment matrix remain
unmeasured. Known modifier-key leakage and the prototype's unexplained focus/visibility loss
remain relevant limitations to investigate; automated passes do not resolve them or support an
undetectability claim.
