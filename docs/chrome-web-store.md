# Chrome Web Store listing

Answers for the **Privacy practices** tab in the Chrome Web Store Developer Dashboard. Keep them
in sync with [PRIVACY.md](../PRIVACY.md), `src/manifest.json`, and `src/manifest-native.json` whenever permissions or data
handling change.

The package now includes an explicit, experimental macOS companion mode alongside the default
**In Chrome** interface. The declarations below cover its `nativeMessaging` permission and
local recipient. The companion has an unsigned local acceptance package and separate
install/upgrade/uninstall tooling. An actual signed/notarized release and final physical
interaction acceptance remain pending; see [Phase 4](native-phase4.md). The installer stores
only app/version/checksum and registration metadata locally, with no content or credentials.
This change does not mean a
store release has been submitted. The isolated
[Phase 1 prototype](../experiments/native-phase1/README.md) remains a separate unpacked test
extension and must not be submitted as the store package.

Decide before the next store submission whether the package ships native mode.
`nativeMessaging` adds the install warning "Communicate with cooperating native applications".
Chrome disables an installed extension when an update adds a warning, until the user accepts
it, so publishing this package would disable SnapScreen for existing users until they approve.
The permission stays required rather than optional because a running service worker's
`chrome.runtime.connectNative` did not update when the permission changed at runtime (tested in
Chromium 149). A grant from Settings might therefore not take effect until the worker restarts.
Alternatives are a separate native build or a reworked optional-permission flow.

## Native-only development variant

`npm run build:extension-native` builds `dist-native/` from `src/manifest-native.json`.
It requires the separately installed macOS companion and has no interface selector. It omits
`scripting`, content scripts, all web-accessible resources, the result frame, and the workspace.
The ordinary build and its `npm run package` archive remain separate.
`npm run package:extension-native` validates the native-only build and extracted assets, then
writes `release/snapscreen-native-only-<version>.zip` and prints its SHA-256 checksums. The
companion is a second archive, produced by `npm run package:native`; neither archive contains
or installs the other. The default companion package is unsigned and intended for local
acceptance. The tag release workflow still publishes only the ordinary extension ZIP.
Creating either native artifact does not submit a store listing, publish a native release,
sign/notarize the companion, or complete physical acceptance. See the
[candidate verification record](native-only-candidate-verification.md) for artifact identities
and automated results, separately from the pending physical trials.

For a future native-only listing, describe the single purpose as answering a user-selected
region of the current tab in the local macOS companion. Omit the `scripting` justification
below; describe `storage` as keeping only the API key and settings, with no workspace routing
metadata. `activeTab`, `nativeMessaging`, and Anthropic host access serve the same purposes.
Local-file capture requires file access enabled in Chrome's extension management page and
never opens an in-session permission request. First installation opens trusted Settings;
capture errors only report through the extension badge. The same screenshot/answer transfers
and credential protections apply. Each variant's native host registration must authorize its
exact extension ID. To switch variants in one browser user-data root, explicitly remove the
old ID's registration before installing the new one; see the
[variant-switch procedure](native-phase4.md#switch-extension-variants). Separate Chrome
profiles within the same root share that registration; separate browser roots can each
authorize their chosen variant.

## Single purpose

> SnapScreen answers questions about part of the current tab: the user snips a region of the
> page, and SnapScreen shows an answer from Anthropic's Claude in Chrome or the user's
> explicitly selected local macOS companion.

## Permission justifications

| Permission | Justification |
| --- | --- |
| `activeTab` | Captures the visible part of the current tab, only after the user clicks the toolbar icon or presses the SnapScreen shortcut. |
| `scripting` | Injects SnapScreen's snipping overlay and answer panel into the current tab when the user invokes the default In Chrome mode. Native mode does not inject page UI. |
| `storage` | Saves the user's Anthropic API key and settings on the device, and temporary data that reconnects SnapScreen's workspace tab. |
| `nativeMessaging` | Connects to the separately installed local macOS companion for a user-invoked native session or an explicit Settings availability check (version handshake only, with no capture or API data). Sends the captured screenshot, crop, and streamed answers and receives selection/follow-up actions. The host is restricted to the exact extension origin and receives no API key. |
| Host permission `https://api.anthropic.com/*` | Sends the selected region and the user's question to Anthropic's API, which writes the answer. |
| Optional host permission `file:///*` | Supports user-invoked capture of local `file://` pages. In Chrome mode, SnapScreen may request access during invocation. Native capture requires file access enabled in Chrome's extension management page first and reports missing access through the badge. |

## Remote code

No. Extension code ships in the extension package; the optional companion is a separately
installed local executable. Neither downloads or executes code from the API. API answers are
displayed as text.

## Data usage

Declare these data types:

- **Website content:** the region of the page the user snips, sent to Anthropic to generate the
  answer. In native mode the visible screenshot and selected crop also go to the local
  companion for selection and preview; answers and follow-ups pass through that local UI.
- **Authentication information:** the user's own Anthropic API key, stored on the device and
  sent only to Anthropic.

SnapScreen doesn't sell user data. Transfers to Anthropic and the explicitly selected local
companion serve only its single purpose; it doesn't use data for unrelated purposes or credit
decisions. Screenshots and conversations stay in memory and are discarded when sessions end
or disconnect. Accepted crops replace full screenshots. Clipboard writes require explicit
Copy. Native processes receive no API key, system prompt, or structured API history.

## Privacy policy URL

<https://github.com/thedanielyuan/SnapScreen/blob/main/PRIVACY.md>
