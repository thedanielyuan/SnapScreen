import {
  UI_REGISTER_CAPABILITY,
  UI_REVOKE_CAPABILITY,
  UI_CONNECT_MESSAGE,
  UI_FRAME_PATH,
  UI_READY_MESSAGE,
  UiCommandBuffer,
  isFrameToControllerMessage,
  isUiAttestationSuccess,
  type ControllerToFrameMessage,
  type FrameToControllerMessage,
} from '../lib/ui-protocol';

const HOST_ID = 'snapscreen-ui-host';
const OWNERSHIP_MARKER = 'data-snapscreen-owned';
const HANDSHAKE_TIMEOUT_MS = 5_000;

export interface ResultFrameHostOptions {
  onMessage: (message: Exclude<FrameToControllerMessage, {
    type: typeof UI_READY_MESSAGE;
  }>) => void;
  onUnexpectedDispose?: () => void;
  onUnavailable?: () => void;
  /** Avoids unsupported chrome-extension navigation in DOM-only tests. */
  skipFrameNavigationForTesting?: boolean;
}

type ControllerCommand = ControllerToFrameMessage extends infer Message
  ? Message extends ControllerToFrameMessage
    ? Omit<Message, 'sessionId'>
    : never
  : never;

export function createUiNonce(
  fillRandomValues: (bytes: Uint8Array<ArrayBuffer>) => void = (bytes) => {
    crypto.getRandomValues(bytes);
  },
): string {
  const bytes = new Uint8Array(new ArrayBuffer(32));
  fillRandomValues(bytes);
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replace(/=+$/u, '');
}

export class ResultFrameHost {
  readonly #host: HTMLDivElement;
  readonly #frame: HTMLIFrameElement;
  readonly #sessionId: string;
  readonly #nonce: string;
  readonly #targetOrigin: string;
  readonly #options: ResultFrameHostOptions;
  readonly #buffer: UiCommandBuffer;
  readonly #returnFocusElement: HTMLElement | null;
  #port: MessagePort | null = null;
  #handshakeTimeout: ReturnType<typeof setTimeout> | null = null;
  #observer: MutationObserver | null = null;
  #disposed = false;
  #loadCount = 0;

  constructor(options: ResultFrameHostOptions) {
    this.#options = options;
    this.#sessionId = crypto.randomUUID();
    this.#nonce = createUiNonce();
    this.#returnFocusElement = document.activeElement instanceof HTMLElement
      ? document.activeElement
      : null;

    const frameUrl = new URL(chrome.runtime.getURL(UI_FRAME_PATH));
    frameUrl.hash = new URLSearchParams({
      session: this.#sessionId,
      nonce: this.#nonce,
    }).toString();
    this.#targetOrigin = frameUrl.origin;

    const existingHost = document.getElementById(HOST_ID);
    if (existingHost?.hasAttribute(OWNERSHIP_MARKER)) existingHost.remove();

    const host = document.createElement('div');
    host.id = existingHost && !existingHost.hasAttribute(OWNERSHIP_MARKER)
      ? `${HOST_ID}-${crypto.randomUUID()}`
      : HOST_ID;
    host.setAttribute(OWNERSHIP_MARKER, '');
    setImportantStyles(host, {
      all: 'initial',
      display: 'block',
      height: 'auto',
      inset: '0',
      pointerEvents: 'none',
      position: 'fixed',
      width: 'auto',
      zIndex: '2147483647',
    });

    const root = host.attachShadow({ mode: 'closed' });
    const frame = document.createElement('iframe');
    if (!options.skipFrameNavigationForTesting) frame.src = frameUrl.href;
    frame.title = 'SnapScreen';
    frame.referrerPolicy = 'no-referrer';
    frame.setAttribute('aria-label', 'SnapScreen');
    setImportantStyles(frame, {
      all: 'initial',
      background: 'transparent',
      border: '0',
      display: 'block',
      height: '100vh',
      inset: '0',
      margin: '0',
      maxHeight: 'none',
      maxWidth: 'none',
      padding: '0',
      pointerEvents: 'auto',
      position: 'fixed',
      width: '100vw',
      zIndex: '2147483647',
    });

    this.#host = host;
    this.#frame = frame;
    this.#buffer = new UiCommandBuffer((message) => {
      this.#port?.postMessage(message);
    });

    frame.addEventListener('load', () => this.#handleLoad());
    document.documentElement.append(host);

    const observer = new MutationObserver((records) => {
      const hostWasRemoved = records.some(
        (record) => record.type === 'childList'
          && Array.from(record.removedNodes).includes(host),
      );
      const hostWasMutated = records.some(
        (record) => record.type === 'attributes' && record.target === host,
      );
      if (
        !this.#disposed
        && (
          hostWasRemoved
          || hostWasMutated
          || !host.isConnected
          || host.parentNode !== document.documentElement
        )
      ) {
        this.#dispose('unexpected');
      }
    });
    observer.observe(document.documentElement, { childList: true });
    observer.observe(host, { attributes: true });
    this.#observer = observer;

    if (options.skipFrameNavigationForTesting) {
      root.append(frame);
      this.#startHandshakeTimeout();
    } else {
      void this.#registerAndMount(root);
    }
  }

  send(message: ControllerCommand): boolean {
    if (this.#disposed) return false;
    return this.#buffer.enqueue({ ...message, sessionId: this.#sessionId } as
      ControllerToFrameMessage);
  }

  setInteractive(interactive: boolean): void {
    if (this.#disposed) return;
    this.#frame.style.setProperty(
      'pointer-events',
      interactive ? 'auto' : 'none',
      'important',
    );
  }

  dispose(): void {
    this.#dispose('normal');
  }

  get isDisposed(): boolean {
    return this.#disposed;
  }

  /** Internal test seam; production code never exposes the closed root. */
  getFrameForTesting(): HTMLIFrameElement {
    return this.#frame;
  }

  #handleLoad(): void {
    if (this.#disposed) return;
    this.#loadCount += 1;
    if (this.#loadCount !== 1) {
      // A host page can navigate a child frame even though it cannot read it.
      // Never authenticate a replacement document into an existing session.
      this.#dispose('unexpected');
      return;
    }

    const channel = new MessageChannel();
    this.#port = channel.port1;
    channel.port1.addEventListener('message', (event: MessageEvent<unknown>) => {
      this.#handlePortMessage(event.data);
    });
    channel.port1.addEventListener('messageerror', () => {
      this.#dispose('unavailable');
    }, { once: true });
    channel.port1.start();

    const target = this.#frame.contentWindow;
    if (!target) {
      channel.port1.close();
      channel.port2.close();
      this.#dispose('unavailable');
      return;
    }

    try {
      target.postMessage(
        {
          type: UI_CONNECT_MESSAGE,
          sessionId: this.#sessionId,
          nonce: this.#nonce,
        },
        this.#targetOrigin,
        [channel.port2],
      );
    } catch {
      channel.port1.close();
      channel.port2.close();
      this.#dispose('unavailable');
      return;
    }

  }

  async #registerAndMount(root: ShadowRoot): Promise<void> {
    let response: unknown;
    try {
      response = await chrome.runtime.sendMessage({
        type: UI_REGISTER_CAPABILITY,
        sessionId: this.#sessionId,
        nonce: this.#nonce,
      });
    } catch {
      this.#dispose('unavailable');
      return;
    }

    if (this.#disposed) {
      this.#revokeCapability();
      return;
    }
    if (!isUiAttestationSuccess(response)) {
      this.#dispose('unavailable');
      return;
    }
    root.append(this.#frame);
    this.#startHandshakeTimeout();
  }

  #startHandshakeTimeout(): void {
    if (this.#disposed || this.#buffer.isReady || this.#handshakeTimeout !== null) return;
    this.#handshakeTimeout = setTimeout(() => {
      this.#handshakeTimeout = null;
      if (!this.#buffer.isReady) this.#dispose('unavailable');
    }, HANDSHAKE_TIMEOUT_MS);
  }

  #handlePortMessage(value: unknown): void {
    if (this.#disposed || !isFrameToControllerMessage(value, this.#sessionId)) return;
    if (value.type === UI_READY_MESSAGE) {
      if (this.#buffer.isReady) return;
      if (this.#handshakeTimeout !== null) {
        clearTimeout(this.#handshakeTimeout);
        this.#handshakeTimeout = null;
      }
      this.#buffer.markReady();
      return;
    }
    if (!this.#buffer.isReady) return;
    this.#options.onMessage(value);
  }

  #dispose(reason: 'normal' | 'unexpected' | 'unavailable'): void {
    if (this.#disposed) return;
    this.#disposed = true;
    this.#buffer.dispose();
    if (this.#handshakeTimeout !== null) {
      clearTimeout(this.#handshakeTimeout);
      this.#handshakeTimeout = null;
    }
    this.#observer?.disconnect();
    this.#observer = null;
    this.#port?.close();
    this.#port = null;
    this.#frame.remove();
    this.#host.remove();
    this.#revokeCapability();

    if (this.#returnFocusElement?.isConnected) {
      try {
        this.#returnFocusElement.focus({ preventScroll: true });
      } catch {
        // The page may have changed the previous focus target meanwhile.
      }
    }
    if (reason === 'unexpected') this.#options.onUnexpectedDispose?.();
    if (reason === 'unavailable') this.#options.onUnavailable?.();
  }

  #revokeCapability(): void {
    void chrome.runtime.sendMessage({
      type: UI_REVOKE_CAPABILITY,
      sessionId: this.#sessionId,
    }).catch(() => undefined);
  }
}

function setImportantStyles(
  element: HTMLElement,
  styles: Record<string, string>,
): void {
  for (const [property, value] of Object.entries(styles)) {
    const cssProperty = property.replace(/[A-Z]/gu, (letter) => `-${letter.toLowerCase()}`);
    element.style.setProperty(cssProperty, value, 'important');
  }
}
