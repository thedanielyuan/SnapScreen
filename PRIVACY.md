# SnapScreen privacy policy

Last updated: October 10, 2026

SnapScreen is a macOS menu bar app that answers questions about part of your screen. This policy
explains what it handles, where that data goes, and what stays on your Mac.

## Summary

- SnapScreen has no servers. It sends the region you select and your questions to Anthropic, the
  AI provider that writes the answers, using your own API key.
- It doesn't collect analytics, show ads, or sell or share your data with anyone else.
- Your API key stays in your login keychain, and your settings in SnapScreen's preferences on your
  Mac.

## What SnapScreen handles

| Data | When | Where it goes | How long it's kept |
| --- | --- | --- | --- |
| A capture of the display under the pointer | When you press ⌥⇧S or choose Snip | In memory on your Mac | Until you select a region or cancel, start another snip, or two minutes pass |
| The region you select | When you release the selection | Sent to Anthropic to get the answer, and shown in the conversation window | In memory until you close the conversation |
| Questions you type | When you ask | Sent to Anthropic with the region | In memory until you close the conversation |
| Answer text | When Anthropic responds | Shown in the conversation window | In memory until you close the conversation; Copy puts text on your clipboard |
| Your Anthropic API key | When you save it in Settings | Your login keychain, and sent to Anthropic with each request | Until you remove it in Settings |
| Settings: the Default Prompt, limits and Open at login | When you change them | SnapScreen's preferences on your Mac; the Default Prompt is sent with first answers | Until you change them |

SnapScreen never writes captures, regions, questions or answers to disk, and never logs them. The
capture leaves out the pointer and SnapScreen's own windows.

## Anthropic

SnapScreen sends requests straight from your Mac to Anthropic's API (`api.anthropic.com`), using
your own API key, and connects to nothing else. Anthropic keeps API inputs and outputs under its
own
[data-retention policy](https://privacy.claude.com/en/articles/7996866-how-long-do-you-store-my-organization-s-data).
To make follow-up questions cheaper, Anthropic may also keep a conversation, including the
region, cached for about 5 minutes after its last use.

## Permissions

- **Screen Recording:** captures the display under the pointer, only when you press ⌥⇧S or choose
  Snip. macOS also shows its own reminder from time to time for apps that capture the screen.
- **Keychain:** stores your API key as a password item in your login keychain.
- **Open at login (optional):** starts SnapScreen when you log in, only if you turn it on in
  Settings.

SnapScreen doesn't need Accessibility or Input Monitoring permission: macOS sends it the ⌥⇧S
shortcut, and it sees other keystrokes only when you type in its own windows.

## Security

Only SnapScreen can read its keychain item without asking for your login password, and only
builds signed by the same Apple team. Anyone who can unlock your Mac's keychain could still read
the key, so use a dedicated key with a spend limit. [docs/security.md](docs/security.md) has the
details.

## Your choices

- Remove your API key at any time in SnapScreen's Settings.
- Turn off Screen Recording or Open at login for SnapScreen in System Settings.
- Deleting the app leaves its keychain item and preferences behind, so remove your key in
  Settings first.

## Changes

If this policy changes, the new version will be posted here with a new date.

## Contact

Questions about this policy: open an issue at
<https://github.com/thedanielyuan/SnapScreen/issues>.
