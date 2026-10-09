# Chrome Web Store listing

Answers for the **Privacy practices** tab in the Chrome Web Store Developer Dashboard. Keep them
in sync with [PRIVACY.md](../PRIVACY.md), `src/manifest-native.json`, and `src/manifest.json`
whenever permissions or data handling change.

These answers cover the native-only extension (`src/manifest-native.json`), the main product:
`npm run package:extension-native` writes its ZIP and the tag release workflow publishes it.
It always uses the separately installed macOS companion and has no interface selector. It omits
`scripting`, content scripts, all web-accessible resources, the result frame, and the workspace.
[In Chrome build](#in-chrome-build) lists what differs for the original extension. The isolated
[Phase 1 prototype](../experiments/native-phase1/README.md) remains a separate unpacked test
extension and must not be submitted as the store package.

`nativeMessaging` adds the install warning "Communicate with cooperating native applications".
Chrome disables an installed extension when an update adds a warning, until the user accepts
it. The permission stays required rather than optional because a running service worker's
`chrome.runtime.connectNative` did not update when the permission changed at runtime (tested in
Chromium 149). A grant from Settings might therefore not take effect until the worker restarts.

The companion is a second archive, produced by `npm run package:native`; neither archive
contains or installs the other, and releases don't include the companion. Its default package
is unsigned. Its installer stores only app/version/checksum and registration metadata locally,
with no content or credentials. Each extension's native host registration must authorize its
exact extension ID. To switch variants in one browser user-data root, explicitly remove the old
ID's registration before installing the new one; see the
[variant-switch procedure](native-phase4.md#switch-extension-variants). Separate Chrome
profiles within the same root share that registration; separate browser roots can each
authorize their chosen variant. See the
[candidate verification record](native-only-candidate-verification.md) for artifact identities
and automated results.

## Single purpose

> SnapScreen answers questions about part of the current tab: the user snips a region of the
> page in the local SnapScreen macOS companion, which shows an answer from Anthropic's Claude.

## Permission justifications

| Permission | Justification |
| --- | --- |
| `activeTab` | Captures the visible part of the current tab, only after the user clicks the toolbar icon or presses the SnapScreen shortcut. |
| `storage` | Saves the user's Anthropic API key and settings on the device. |
| `nativeMessaging` | Connects to the separately installed local macOS companion for a user-invoked session or an explicit Settings availability check (version handshake only, with no capture or API data). Sends the captured screenshot, crop, and streamed answers and receives selection/follow-up actions. The host is restricted to the exact extension origin and receives no API key. |
| Host permission `https://api.anthropic.com/*` | Sends the selected region and the user's question to Anthropic's API, which writes the answer. |
| Optional host permission `file:///*` | Supports user-invoked capture of local `file://` pages. Capture requires file access enabled in Chrome's extension management page first, reports missing access through the badge, and never opens a permission request. |

## Remote code

No. Extension code ships in the extension package; the companion is a separately installed
local executable. Neither downloads or executes code from the API. API answers are displayed
as text.

## Data usage

Declare these data types:

- **Website content:** the region of the page the user snips, sent to Anthropic to generate the
  answer. The visible screenshot and selected crop also go to the local companion for selection
  and preview; answers and follow-ups pass through that local UI.
- **Authentication information:** the user's own Anthropic API key, stored on the device and
  sent only to Anthropic.

SnapScreen doesn't sell user data. Transfers to Anthropic and the local companion serve only
its single purpose; it doesn't use data for unrelated purposes or credit decisions. Screenshots
and conversations stay in memory and are discarded when sessions end or disconnect. Accepted
crops replace full screenshots. Clipboard writes require explicit Copy. Native processes receive
no API key, system prompt, or structured API history.

## In Chrome build

The original extension (`src/manifest.json`, archived by `npm run package`) shows its UI in the
page by default and uses the companion only when the user selects it in Settings. Its answers
differ as follows; the rest are the same.

- **Single purpose:**

  > SnapScreen answers questions about part of the current tab: the user snips a region of the
  > page, and SnapScreen shows an answer from Anthropic's Claude in Chrome or the user's
  > explicitly selected local macOS companion.

- **`scripting`:** Injects SnapScreen's snipping overlay and answer panel into the current tab
  when the user invokes the default In Chrome mode. Native mode does not inject page UI.
- **`storage`:** Saves the user's Anthropic API key and settings on the device, and temporary
  data that reconnects SnapScreen's workspace tab.
- **Optional host permission `file:///*`:** Supports user-invoked capture of local `file://`
  pages. In Chrome mode, SnapScreen may request access during invocation. Native capture
  requires file access enabled in Chrome's extension management page first and reports missing
  access through the badge.
- **Data usage:** the screenshot, crop, answers, and follow-ups reach the local companion only
  in the explicitly selected native mode.

## Privacy policy URL

<https://github.com/thedanielyuan/SnapScreen/blob/main/PRIVACY.md>
