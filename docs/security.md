# Security and privacy

How SnapScreen handles your API key and screenshots, and how its UI is isolated from the pages
it runs on. The [privacy policy](../PRIVACY.md) is the short version.

## API key

Your API key is stored unencrypted in `chrome.storage.local` on your device and is sent
directly to Anthropic's API only from trusted extension contexts: the background service for
screenshot analysis, and the options page when you choose **Test key**. It never passes
through a third-party server. SnapScreen restricts local extension storage to trusted
extension contexts, and its content scripts (the code injected into web pages) neither read
nor receive the key.

This is defense in depth, not credential encryption: anyone who can access or copy your
Chrome profile may still be able to extract the key. Use a dedicated Anthropic key with an
appropriate spend limit, revoke it if the profile is lost or compromised, and remove it from
SnapScreen when it is no longer needed.

## Screenshots

Screenshots are sent directly to Anthropic for analysis and are not persisted by SnapScreen.
Anthropic retains API inputs and outputs under its own
[data-retention policy](https://privacy.claude.com/en/articles/7996866-how-long-do-you-store-my-organization-s-data).
Answer requests use Anthropic's prompt caching, so Anthropic keeps the conversation, including
the screenshot, cached for about 5 minutes after its last use; this makes follow-up questions
cheaper. A fallback screenshot remains only in memory: the background holds it until the exact
workspace claims its one-time capability, after which the workspace page owns it. Only small
source/workspace routing metadata is kept in `chrome.storage.session` so a service-worker
restart can reconnect the workspace.

## Injected UI isolation

SnapScreen renders every injected interactive surface—the crop selector, result panel,
screenshot lightbox, composer, and toast—inside a full-viewport extension-origin iframe. The
iframe is mounted inside a closed-shadow outer `#snapscreen-ui-host`, so page CSS cannot
restyle the UI and ordinary page DOM APIs cannot locate the iframe or query its screenshot,
answer, composer value, lightbox, or controls. The host is removed when the UI is dismissed
so it does not affect page layout or captured pixels. The extension frame also remains
loadable on pages with a strict host Content Security Policy.

The isolated content script keeps capture and conversation state. It creates a fresh 32-byte
capability for each UI session, registers it with the background for its tab and top-level
document, places it in the hidden iframe URL fragment, and transfers one end of a
`MessageChannel` directly to that child with an exact extension `targetOrigin`. The exact
packaged child frame must claim that capability once before it acknowledges the channel;
claims expire and cannot be replayed or moved across tabs. Screenshot data, streamed answers,
composer submissions, and actions then travel only over the private port, never through
ordinary `window.postMessage`, page DOM events, or DOM attributes. Commands are validated and
buffered until attestation completes. Privileged actions such as opening Settings are sent
back to the trusted content controller rather than executed by the web-accessible frame, and
normal background commands reject extension-frame senders.

## Fallback workspace

Pages that reject injection use a packaged workspace that is deliberately absent from
`web_accessible_resources`. Its exact top-level extension URL and tab must claim a one-time
session ID/nonce pair over a long-lived runtime port. Reconnects use a separate credential;
requests and streamed events are correlated and targeted to that authenticated workspace.
Workspace messages never supply the source tab ID, and the API key and Anthropic network
requests remain in the background worker.

## Limits of the isolation boundary

This boundary protects confidentiality and prevents page capture listeners from cancelling
the frame's keyboard/input handling, but it is not a tamper-proof browser surface. Chrome
exposes coarse pointer activity retargeted to the outer host (not the internal target or
text); tests confirm that parent `preventDefault()` and `stopImmediatePropagation()` do not
block the child click. A hostile page can still remove, move, cover, or navigate the outer
host and cause denial of service or attempt clickjacking. The packaged frame is
web-accessible, but a page-created copy remains inert because it cannot register or claim a
legitimate session capability. A page can still imitate the extension visually with its own
HTML, so treat unexpected or context-sensitive prompts as untrusted, just as with any UI
rendered inside a web page.
