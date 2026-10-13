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
window ever gets it. Answers read it with Keychain prompts turned off, through the legacy
`SecKeychainSetUserInteractionAllowed`, since the login keychain ignores
`kSecUseAuthenticationUIFail` and `LAContext` there: if macOS would ask for your password, because
the key doesn't trust this build yet or the keychain is locked, the answer fails and sends you to
Settings, where reading it may ask. Checking whether a key exists reads only the item's attributes, never the
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
fitted to the limits in Settings, goes to Anthropic. A session's images and answer stay in memory
too, and are released when its conversation closes. Nothing is written to disk or
logged. Copy writes text to the clipboard only when you choose it, and the clipboard can keep it
after the conversation closes.

Anthropic keeps API inputs and outputs under its own
[data-retention policy](https://privacy.claude.com/en/articles/7996866-how-long-do-you-store-my-organization-s-data).
Answer requests don't ask Anthropic to cache them: a snip sends one request, and only Retry sends
it again. Provider error text passes through `sanitizeProviderMessage` before a window shows it.

## Permissions

The shortcut is registered with Carbon's `RegisterEventHotKey`, which needs no Accessibility or
Input Monitoring permission: the app receives that one combination and no other keystrokes, except
those you type into its own windows. Watching for a click in another app, which closes a finished
conversation (below), needs no permission either. Settings checks Screen Recording with
`CGPreflightScreenCaptureAccess`, which never prompts. Its **Open System Settings** button requests
access, so macOS lists the app, and then opens that list. Snip checks access the same way first,
and without it shows a notice with the same button. **Open at login** registers the app with
`SMAppService` only when you turn it on.

## Staying out of the way

The bundle sets `LSUIElement` and launch sets the accessory activation policy before constructing
any windows, so SnapScreen has no Dock or App Switcher entry. The selection overlay, conversation,
preview, notice and resize-shield panels share `PassivePanel`, an `NSPanel` subclass that installs
`.nonactivatingPanel` at construction and cannot become key or main. Each is explicitly a floating
panel, becomes key only if needed (and never qualifies), stays visible on deactivation, joins all
Spaces, supports fullscreen apps and is excluded from window cycling. Selection uses the screen
saver level; the other panels use the floating level. They appear through `orderFront(nil)`;
the resize shield is ordered directly below its conversation.
The capture and answer flow never activates SnapScreen or requests keyboard focus. Select a
region by dragging, cancel by clicking, and use panel close buttons or **Close All Conversations**
to dismiss it. A snip gets one answer, with no follow-ups or other text input, and Stop, Retry and
Copy are pointer actions. Keyboard selection, Escape and Command-W are unavailable in these passive
panels.
Keyboard input continues to go to the foreground app.

Settings is a separate foreground setup flow and activates SnapScreen only when explicitly
opened, including reopening the running app. If no API key exists at launch, a passive notice
offers **Open Settings** rather than automatically opening Settings.
After Settings closes, only another visible keyboard-eligible window can keep SnapScreen active.
Otherwise AppKit's `hide` hands activation back to the previous app; passive panels set `canHide`
to false, so an open snip does not disappear during that handoff. If another app already has focus,
closing Settings leaves that choice alone.

Launching SnapScreen through LaunchServices, as Finder, Spotlight, `open` and login items do, leaves
it in the background on macOS 27. Another app can still activate it, as `osascript`'s `activate`,
launchers and the system's own handoffs do. With Settings closed, SnapScreen then hands activation
back the same way after 150 ms, the time it waits for the reopen event that follows LaunchServices
activating it when you open the running app again: that event opens Settings, which keeps it.
During those 150 ms a page sees its window blur and refocus, and keys typed reach no app.

The overlay is non-opaque, because an opaque window covering the display could make Chrome mark
its page as hidden. macOS shows only the frontmost app's cursor changes, so while the overlay is
up, SnapScreen sets the window server's private `SetsCursorInBackground` property, which lets its
crosshair show without activating the app, and turns it off when the overlay closes.

Once an answer has finished, a click in another app closes its conversation and screenshot
preview the way their close button does, which ends the session and releases its images and text.
SnapScreen sees that click through an AppKit global monitor for mouse presses. The monitor gets a
copy of each press that goes to another app and can't change or stop it, so the click still lands
where you clicked. SnapScreen reads only where the press was, never watches keys, and keeps and
logs nothing. It watches only while a finished conversation is open: not while an answer or a
Retry runs, or after one fails or stops. Clicks in SnapScreen's own windows, such as the
conversation, the preview or a new snip's overlay, never reach the monitor. A click within
8 points of either panel, where it may have been meant to resize one, or while a panel is pressed
or resized, leaves them open. Closing them activates no app, and no snip panel can take the
keyboard during the close.

Selecting a region in a new snip closes the previous snip's conversation and preview the same
way, whatever state they're in, so only one conversation is open at a time. Cancelling the new
snip leaves them open. They close only after the new conversation is shown, and nothing is
activated or refocused.

On 12 October 2026, a manual check of the passive panels on macOS 27.0.1 with Chrome 154.0.8037.98
used the real global shortcut and ScreenCaptureKit capture, then synthetic streamed answers through
the production windows, including preview and dismissal. During the 21-second interval, all 211
page samples retained focus and visibility, no browser blur occurred, Chrome stayed frontmost, and
SnapScreen never became active or key. A deliberate app switch before the snip produced blur and
focus events, validating that observer. This is evidence for that run, not a guarantee across
browser versions, display modes or system alerts. The Phase 4 acceptance round
([plan](standalone-app-plan.md)) and 11 October checks cover the earlier keyboard-interactive panels.

On 13 October 2026, the same Chrome 154 page kept focus at every 100 ms sample while SnapScreen's
menu bar menu or a right-click menu in a conversation was open and while answer text was selected:
macOS takes key-window status from the browser during any menu, but the page saw no blur.

Two limitations are known and accepted. The shortcut's modifier keys reach the app beneath,
because they're pressed before the S that macOS hands to SnapScreen. And macOS periodically shows
its own alert for apps that capture the screen without the system picker; while it's up, it has
focus. SnapScreen makes no promise to be undetectable, and nothing here hides it from screen
sharing, other apps, or the OS.

## Other processes

The app takes no commands from other processes: it has no URL scheme, socket or XPC service, and
the only Apple events it acts on are the standard ones, where reopening the app shows Settings. A
second copy exits when it finds one running. It refuses a quit event from a command-line tool or
script, such as `osascript`, so a script or test can't quit the copy you're using: it quits when you
choose Quit SnapScreen, when you log out, restart or shut down, and when macOS or an app, such as
Activity Monitor, quits it. This isn't a security boundary: Force Quit and signals still end it. Notices about failures before a conversation exists
use a panel that never activates the app or takes the keyboard.

## Tests

The app's `--self-test` adds and removes a throwaway Keychain item under its own service,
`com.snapscreen.app.self-test`, and never reads the real key. Its snips use a scripted client and
a made-up capture, so they need neither the network nor Screen Recording, and its copy checks
write to a private pasteboard, never your clipboard. The live test,
`scripts/test-app-live.sh`, runs a separate test-hooks build in `build/test-hooks/`. That build
has its own bundle ID and an ad hoc signature, replaces the capture and the API with scripted
ones, and reads no key. `build-app.sh` refuses to make a production app that contains its code.
`LiveAPITests` calls the real API only when `SNAPSCREEN_LIVE_API_KEY` is set.

For WindowServer focus checks, quit the production app to free its global shortcut and run
`scripts/test-app-live.sh --focus`, then `scripts/test-app-live.sh --focus --fullscreen`.
These optional modes require existing event-posting and Accessibility approval for the launching
terminal; they never request or change either. They open an isolated helper app with a local WebKit
textarea, use the actual registered shortcut and pointer events to select, copy, preview and
dismiss, and check native focus, webpage blur, visibility, active element and keyboard input.
A deliberate focus loss validates the observer before measuring. The test also explicitly opens
a synthetic Settings window, then verifies that closing it returns focus with an answer open.
Then the helper launches a copy of the real app shell through LaunchServices, with its own bundle
ID, a key kept in memory and the same fixtures, and the test uses its missing-key notice and
Settings, has the helper activate it, and reopens it; in a normal Space it also uses the menu bar
item's Snip, Close All Conversations, Settings… and Quit, found through Accessibility. Only
Settings may take the helper's place in front, and SnapScreen must hand an activation back within
half a second. The fullscreen
mode uses a native macOS fullscreen Space and checks panel ordering above the target window.
The helper reports only its synthetic webpage state through private pipes. All of this code is
test-hooks-only. These checks still use fixture captures and API answers; they do not certify
ScreenCaptureKit permission alerts, Canvas deployments or every browser's focus behavior.

On 13 October 2026, both optional modes passed on macOS 27.0.1, the normal run with 285 checks and
the fullscreen run with 223 (the counts include polling). The local webpage retained focus,
visibility and typed input throughout each capture, answer and pointer interaction, the app shell's
launch and its menus; Settings returned focus while a passive answer stayed visible; and the app
shell handed back an activation it didn't ask for. With that handback removed, the normal run
failed there. The signed app, checked by hand the same way, handed one back after 167 ms. The
standard live window test also passed, along with the core suite and the app's self-test.
