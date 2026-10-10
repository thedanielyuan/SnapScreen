# Security and privacy

How SnapScreen handles your API key and screen captures, and how it keeps out of the way of the
app you snip. The [privacy policy](../PRIVACY.md) is the short version.

## API key

The key is a generic password in your login keychain (service `com.snapscreen.app`, account
`anthropic-api-key`), never in a file or `UserDefaults`, which holds only the Default Prompt and
limits. The item trusts the app that created it. macOS lets a rebuilt app read it without your
login password only when it's signed by the same Apple team, which is why `scripts/build-app.sh`
signs with an Apple Development certificate. Other apps, and builds signed any other way, must
ask for that password.

The app reads the key when Settings opens, and closing Settings clears it from the window. Each
answer reads it again, so a key saved in Settings applies to open conversations, and no other
window ever gets it. Checking whether a key exists reads only the item's attributes, never the
key. The key is sent only to Anthropic's API (`api.anthropic.com`), to answer a snip or when you
choose **Test key**, and never through another server.

This protects the key from other apps, not from someone who can unlock your keychain. Use a
dedicated Anthropic key with a spend limit, revoke it if your Mac or keychain is compromised, and
remove it in Settings when you no longer need it.

## Captures

The app captures only when you press ⌥⇧S or choose **Snip**, and only the display under the
pointer, with ScreenCaptureKit at full resolution. The capture leaves out the cursor and
SnapScreen's own windows, such as open conversations, notices and Settings. The frozen display
stays in memory while you select a region. It's released once the region is cropped, or when
the selection is cancelled, replaced by a new snip, or left for two minutes. Only the crop,
fitted to the limits in Settings, goes to Anthropic. A session's images, answers and drafts stay
in memory too, and are released when its conversation closes. Nothing is written to disk or
logged. Copy writes text to the clipboard only when you choose it, and the clipboard can keep it
after the conversation closes.

Anthropic keeps API inputs and outputs under its own
[data-retention policy](https://privacy.claude.com/en/articles/7996866-how-long-do-you-store-my-organization-s-data).
Answer requests use prompt caching, so Anthropic keeps the conversation, including the crop,
cached for about 5 minutes after its last use, which makes follow-up questions cheaper. Provider
error text passes through `sanitizeProviderMessage` before a window shows it.

## Permissions

The shortcut is registered with Carbon's `RegisterEventHotKey`, which needs no Accessibility or
Input Monitoring permission: the app receives that one combination and no other keystrokes, except
those you type into its own windows. Settings checks Screen Recording with
`CGPreflightScreenCaptureAccess`, which never prompts. Its **Open System Settings** button requests
access, so macOS lists the app, and then opens that list. Snip checks access the same way first,
and without it shows a notice with the same button. **Open at login** registers the app with
`SMAppService` only when you turn it on.

## Staying out of the way

The selection overlay and the conversation panels never activate the app, so the app you snip
keeps focus, and Escape and Command-W close them on key release, so the release doesn't reach
the app beneath. The overlay is non-opaque, because an opaque window covering the display could
make Chrome mark its page as hidden. Phase 4's acceptance round
([plan](standalone-app-plan.md)) measured this over Chrome in a normal window and in fullscreen:
SnapScreen never became the frontmost app, the page kept focus and visibility, and no keys, text
or clicks reached it.

Two limitations are known and accepted. The shortcut's modifier keys reach the app beneath,
because they're pressed before the S that macOS hands to SnapScreen. And macOS periodically shows
its own alert for apps that capture the screen without the system picker; while it's up, it has
focus. SnapScreen makes no promise to be undetectable, and nothing here hides it from screen
sharing, other apps, or the OS.

## Other processes

The app takes no commands from other processes: it has no URL scheme, socket or XPC service, and
the only Apple events it acts on are the standard ones, where reopening the app shows Settings. A
second copy exits when it finds one running. Notices about failures before a conversation exists
use a panel that never activates the app or takes the keyboard.

## Tests

The app's `--self-test` adds and removes a throwaway Keychain item under its own service,
`com.snapscreen.app.self-test`, and never reads the real key. Its snips use a scripted client and
a made-up capture, so they need neither the network nor Screen Recording. The live test,
`scripts/test-app-live.sh`, runs a separate test-hooks build in `build/test-hooks/`. That build
has its own bundle ID and an ad hoc signature, replaces the capture and the API with scripted
ones, and reads no key. `build-app.sh` refuses to make a production app that contains its code.
`LiveAPITests` calls the real API only when `SNAPSCREEN_LIVE_API_KEY` is set.
