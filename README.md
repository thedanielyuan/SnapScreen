# SnapScreen

**Turn any on-screen question into an instant answer.**

Press a shortcut, drag a box around a quiz question, an error message, or a chart, and an AI
answer appears in a panel right beside it.

## Features

- **Snip with mouse or keyboard** — drag a box, or place and adjust one with the arrow keys
- **Streaming answers** — watch the reply as it's written, then ask follow-up questions
- **Answer controls** — stop, retry, copy, view the full-size capture, or start a new snip
- **Works almost everywhere** — including browser pages, the Chrome Web Store, PDFs, and local
  files
- **Light and dark themes** — follows your system setting

## How to use

1. Click the SnapScreen icon or press `Alt+Shift+S` (`Option+Shift+S` on Mac).
2. Drag a box around what you want to ask about. The answer appears right next to it.
3. Ask a follow-up question, or close the panel with **Esc** or a click outside it.

**Keyboard selection:** press **Enter** to place a box, move it with the **arrow keys**, resize
it with **Shift + arrow keys**, and press **Enter** again to confirm.

On protected pages, such as the Chrome Web Store, your capture opens in a separate SnapScreen
tab.

## Settings

Right-click the SnapScreen icon and choose **Options** to:

- Manage your API key
- Change the default prompt that's sent with each new capture
- Set limits on question length, conversation length, and screenshot size
- Change the keyboard shortcut, for example if another extension already uses it

## Limitations

- Captures only the visible part of the tab, not the full scrolling page.
- Chrome may blank out browser menus, permission prompts, system dialogs, and DRM-protected
  video.
- Local `file://` pages also need **Allow access to file URLs**, which you can turn on in
  SnapScreen's details at `chrome://extensions`.

## Privacy

- **No SnapScreen servers.** SnapScreen sends your screenshots and questions straight from your
  browser to its AI provider to generate answers, and never saves them. The provider keeps them
  under its own data-retention policy, and may also cache a conversation for about 5 minutes to
  speed up follow-up questions.
- **Your API key stays on your device.** It's sent only to that provider, and websites can't
  read it. It isn't encrypted, though, so anyone with access to your Chrome profile could
  find it.
- **Websites can't see your conversation.** Pages can't read what's in SnapScreen's panel. A
  malicious page could still hide the panel or show a fake one, so be careful with unexpected
  SnapScreen-looking prompts.

## License

[MIT](LICENSE)
