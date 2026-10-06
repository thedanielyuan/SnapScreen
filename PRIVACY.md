# SnapScreen privacy policy

Last updated: October 6, 2026

SnapScreen is a Chrome extension that answers questions about part of a web page. This policy
explains what it handles, where that data goes, and what stays on your device.

## Summary

- SnapScreen has no servers. It sends your snips and questions to Anthropic, the AI provider
  that writes the answers. Optional native mode also gives screenshot and conversation data
  to the separately installed SnapScreen companion on your Mac.
- It doesn't collect analytics, show ads, or sell or share your data with anyone else.
- Your API key and settings stay in Chrome on your device.

## What SnapScreen handles

| Data | When | Where it goes | How long it's kept |
| --- | --- | --- | --- |
| A screenshot of the visible part of the tab | When you click the SnapScreen icon or press its shortcut | In memory on your device; also sent to the local companion in native mode | Until the crop is accepted or you cancel |
| The region you select | When you finish a snip | Sent to Anthropic to get the answer; also shown by the local companion in native mode | In memory until you close or lose the session |
| Questions you type, and your default prompt | When you ask | Sent to Anthropic with the region; native follow-ups are typed in the local companion | In memory until you close or lose the session |
| Answer text | When Anthropic responds | Displayed in the extension or local companion | In memory until you close or lose the session; explicit Copy puts text on your clipboard |
| Your Anthropic API key | When you save it in Settings | Stored in Chrome on your device, and sent to Anthropic with each request | Until you remove it or uninstall SnapScreen |
| Settings (default prompt, limits, and interface choice) | When you save them | Stored in Chrome on your device | Until you change them or uninstall SnapScreen |
| The address of the page you snipped | Only when a page needs SnapScreen's separate workspace tab | Chrome's temporary session storage on your device, to reconnect that tab | Until the workspace tab closes or Chrome quits |

SnapScreen never writes screenshots or conversations to disk.

### Optional macOS companion

The **In Chrome** interface is the default. To use native mode, install the companion and
explicitly select it in Settings. Chrome starts a separate local process for each native
session. It receives the screenshot, crop, streamed answers, and follow-ups; it never receives
your API key, the system prompt, or the structured history used for Anthropic requests. The
extension still sends every API request directly to Anthropic. No local web server or shared
app relay is involved. The optional **Check companion** button in Settings briefly starts a
local host for a version handshake, then disconnects. It opens no native window and transfers
no screenshots, questions, answers, or API credentials.

The separate companion installer stores the app and a receipt containing its version,
checksum, and chosen browser registration paths under your user account. It registers the
exact extension ID in each browser root you choose. This installation metadata contains no
screenshots, questions, answers, or API key. The companion has no automatic update service.
Remove it separately using the [uninstall instructions](docs/native-phase4.md#install-upgrade-and-remove);
uninstalling the Chrome extension does not remove the companion app or its registration.

Both processes release the full screenshot when the crop is accepted. The selected region and
conversation stay in memory until the session closes or disconnects. Follow-ups can continue
after the source page navigates or closes. Lost sessions are not restored or replayed. Copy
writes only the text you explicitly choose to your system clipboard, which can retain it after
the window closes. Missing or incompatible companions report an extension badge error without
opening another interface. Modifier keys may still reach the page.

If you allow the extension in incognito, each incognito native session also gets its own
companion process, as every session does. Chrome's local extension storage shares the API key
and saved settings between regular and incognito use within that Chrome profile.
[Chrome incognito behavior](https://developer.chrome.com/docs/extensions/reference/manifest/incognito)

### Optional local development experiment

The separate Phase 1 native prototype in this repository is not part of the packaged Chrome
extension. If you build and run it, its `nativeMessaging` permission sends the captured image
and typed follow-up to a local macOS process. It uses only mocked answers and sends nothing to
Anthropic. Image and question data remain in memory until the session is replaced, closed, or
disconnected. Copy writes the mock answer to your clipboard. The instrumented test page can
save event and focus metadata locally, including native window positions/sizes, answer
scroll offsets, keyboard input-source identifiers, and modifier-key names, without screenshots,
typed text, or clipboard contents. To check Copy, the local process compares pasted follow-up
text with the copied mock answer in memory and logs only whether they match. Reports also identify
the tested executable and extension files by their SHA-256 hashes.
The runner registers the host only in a temporary test browser profile and removes that
profile when it exits normally.

The Phase 4 packaged acceptance runner similarly uses an isolated browser profile, the
production companion, and a disposable copy of the extension with canned answers. Its reports
save page-event metadata, message types/IDs/timing, versions, and artifact hashes, without
screenshots, question/answer text, or API credentials. It does not contact Anthropic. These
diagnostic reports are local files retained until you remove them; they are not generated
during ordinary use.

## Anthropic

SnapScreen sends requests straight from your browser to Anthropic's API (`api.anthropic.com`),
using your own API key. Anthropic keeps API inputs and outputs under its own
[data-retention policy](https://privacy.claude.com/en/articles/7996866-how-long-do-you-store-my-organization-s-data).
To make follow-up questions cheaper, Anthropic may also keep a conversation, including the snip,
cached for about 5 minutes after its last use.

## Permissions

- **activeTab and scripting:** capture the current tab and show SnapScreen on it, only after
  you click the icon or press the shortcut. SnapScreen can't read or change any other page.
- **storage:** saves your API key and settings on your device.
- **nativeMessaging:** connects to the separately installed local macOS companion when you
  explicitly choose native mode and invoke SnapScreen, or choose **Check companion** in
  Settings for a data-free version handshake. Native sessions transfer screenshots and answer
  data to that process and receives selection and follow-up actions; it never transfers keys.
- **Access to `api.anthropic.com`:** sends your snip and question to Anthropic.
- **Access to local files (optional):** requested only when you use SnapScreen on a `file://`
  page.

## Security

Your API key is stored unencrypted in Chrome's extension storage. Only SnapScreen's own pages and
background service can read it; websites can't. Anyone with access to your Chrome profile could
still find it, so use a dedicated key with a spend limit. [docs/security.md](docs/security.md)
has the details.

## Your choices

- Remove your API key at any time on SnapScreen's Settings page.
- Choose **In Chrome** in Settings to use the extension without the native companion.
- Uninstalling SnapScreen deletes its stored key and settings from Chrome.

## Changes

If this policy changes, the new version will be posted here with a new date.

## Contact

Questions about this policy: open an issue at
<https://github.com/thedanielyuan/SnapScreen/issues>.
