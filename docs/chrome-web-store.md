# Chrome Web Store listing

Answers for the **Privacy practices** tab in the Chrome Web Store Developer Dashboard. Keep them
in sync with [PRIVACY.md](../PRIVACY.md) and `src/manifest.json` whenever permissions or data
handling change.

The package now includes an explicit, experimental macOS companion mode alongside the default
**In Chrome** interface. The declarations below cover its `nativeMessaging` permission and
local recipient. The companion is a separate development installation; signing, distribution,
and final physical interaction acceptance remain future work. This change does not mean a
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
| Optional host permission `file:///*` | Requested only when the user invokes SnapScreen on a local `file://` page, so it can capture that page. |

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
