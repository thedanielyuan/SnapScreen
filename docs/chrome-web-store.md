# Chrome Web Store listing

Answers for the **Privacy practices** tab in the Chrome Web Store Developer Dashboard. Keep them
in sync with [PRIVACY.md](../PRIVACY.md) and `src/manifest.json` whenever permissions or data
handling change.

## Single purpose

> SnapScreen answers questions about part of the current tab: the user snips a region of the
> page, and SnapScreen shows an answer from Anthropic's Claude next to it.

## Permission justifications

| Permission | Justification |
| --- | --- |
| `activeTab` | Captures the visible part of the current tab, only after the user clicks the toolbar icon or presses the SnapScreen shortcut. |
| `scripting` | Injects SnapScreen's snipping overlay and answer panel into the current tab when the user invokes it. |
| `storage` | Saves the user's Anthropic API key and settings on the device, and temporary data that reconnects SnapScreen's workspace tab. |
| Host permission `https://api.anthropic.com/*` | Sends the selected region and the user's question to Anthropic's API, which writes the answer. |
| Optional host permission `file:///*` | Requested only when the user invokes SnapScreen on a local `file://` page, so it can capture that page. |

## Remote code

No. All code ships in the package; the API returns plain text, which SnapScreen displays as text.

## Data usage

Declare these data types:

- **Website content:** the region of the page the user snips, sent to Anthropic to generate the
  answer.
- **Authentication information:** the user's own Anthropic API key, stored on the device and
  sent only to Anthropic.

All three data-use certifications are true: SnapScreen doesn't sell user data or transfer it
except to Anthropic to provide its single purpose, doesn't use it for anything unrelated, and
doesn't use it for credit decisions.

## Privacy policy URL

<https://github.com/thedanielyuan/SnapScreen/blob/main/PRIVACY.md>
