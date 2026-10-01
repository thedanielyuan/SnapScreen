# SnapScreen privacy policy

Last updated: October 1, 2026

SnapScreen is a Chrome extension that answers questions about part of a web page. This policy
explains what it handles, where that data goes, and what stays on your device.

## Summary

- SnapScreen has no servers. It sends your snips and questions only to Anthropic, the AI
  provider that writes the answers.
- It doesn't collect analytics, show ads, or sell or share your data with anyone else.
- Your API key and settings stay in Chrome on your device.

## What SnapScreen handles

| Data | When | Where it goes | How long it's kept |
| --- | --- | --- | --- |
| A screenshot of the visible part of the tab | When you click the SnapScreen icon or press its shortcut | Stays in memory on your device while you choose a region | Until the snip finishes or you cancel |
| The region you select | When you finish a snip | Sent to Anthropic to get the answer | In memory until you close the answer |
| Questions you type, and your default prompt | When you ask | Sent to Anthropic with the region | In memory until you close the answer |
| Your Anthropic API key | When you save it in Settings | Stored in Chrome on your device, and sent to Anthropic with each request | Until you remove it or uninstall SnapScreen |
| Settings (default prompt and limits) | When you save them | Stored in Chrome on your device | Until you change them or uninstall SnapScreen |
| The address of the page you snipped | Only when a page needs SnapScreen's separate workspace tab | Chrome's temporary session storage on your device, to reconnect that tab | Until the workspace tab closes or Chrome quits |

SnapScreen never writes screenshots or conversations to disk.

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
- Uninstalling SnapScreen deletes its stored key and settings from Chrome.

## Changes

If this policy changes, the new version will be posted here with a new date.

## Contact

Questions about this policy: open an issue at
<https://github.com/thedanielyuan/SnapScreen/issues>.
