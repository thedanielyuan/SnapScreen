import {
  isExtensionToNativeMessage,
  isNativeToExtensionMessage,
  NATIVE_HOST_NAME,
  NATIVE_PROTOCOL_VERSION,
} from '../lib/native-protocol';
import type { ExtensionToNativeMessage, NativeToExtensionMessage } from '../lib/native-protocol';

const HANDSHAKE_TIMEOUT_MS = 5_000;
const CONNECTION_ERROR = 'The SnapScreen companion is unavailable. Start a new snip after checking its installation.';

/** One Chrome-owned native host, with no replay or reconnection after disconnect. */
export class NativeBridge {
  readonly #connectionId: string;
  readonly #onMessage: (message: NativeToExtensionMessage) => void;
  readonly #onDisconnect: () => void;
  #state: 'idle' | 'connecting' | 'ready' | 'closed' = 'idle';
  #port: chrome.runtime.Port | undefined;
  #connection: Promise<void> | undefined;
  #resolve: (() => void) | undefined;
  #reject: ((error: Error) => void) | undefined;
  #timer: ReturnType<typeof setTimeout> | undefined;

  constructor(
    connectionId: string,
    onMessage: (message: NativeToExtensionMessage) => void,
    onDisconnect: () => void,
  ) {
    if (!isExtensionToNativeMessage({ version: NATIVE_PROTOCOL_VERSION, type: 'hello', connectionId })) {
      throw new Error('Invalid companion connection identity.');
    }
    this.#connectionId = connectionId;
    this.#onMessage = onMessage;
    this.#onDisconnect = onDisconnect;
  }

  connect(): Promise<void> {
    if (this.#state === 'closed') return Promise.reject(new Error(CONNECTION_ERROR));
    if (this.#connection) return this.#connection;
    this.#state = 'connecting';
    this.#connection = new Promise<void>((resolve, reject) => {
      this.#resolve = resolve;
      this.#reject = reject;
    });
    try {
      this.#port = chrome.runtime.connectNative(NATIVE_HOST_NAME);
      this.#port.onMessage.addListener(this.#receive);
      this.#port.onDisconnect.addListener(this.#disconnected);
      this.#timer = setTimeout(() => this.#end(true), HANDSHAKE_TIMEOUT_MS);
      this.#port.postMessage({
        version: NATIVE_PROTOCOL_VERSION,
        type: 'hello',
        connectionId: this.#connectionId,
      } satisfies ExtensionToNativeMessage);
    } catch {
      this.#end(true);
    }
    return this.#connection;
  }

  send(message: ExtensionToNativeMessage): void {
    if (this.#state !== 'ready' || !this.#port
      || !isExtensionToNativeMessage(message)
      || message.connectionId !== this.#connectionId
      || message.type === 'hello') {
      throw new Error('The companion message could not be sent.');
    }
    try {
      this.#port.postMessage(message);
    } catch {
      this.#end(true);
      throw new Error(CONNECTION_ERROR);
    }
  }

  disconnect(): void {
    this.#end(false);
  }

  readonly #receive = (value: unknown): void => {
    if (this.#state === 'closed') return;
    if (!isNativeToExtensionMessage(value) || value.connectionId !== this.#connectionId) {
      this.#end(true);
      return;
    }
    if (this.#state === 'connecting' && value.type === 'ready') {
      this.#state = 'ready';
      clearTimeout(this.#timer);
      this.#timer = undefined;
      this.#resolve?.();
      this.#resolve = undefined;
      this.#reject = undefined;
      return;
    }
    if (this.#state !== 'ready' || value.type === 'ready') {
      this.#end(true);
      return;
    }
    this.#onMessage(value);
  };

  readonly #disconnected = (): void => {
    // Reading lastError acknowledges Chrome's error without exposing host/provider text.
    void chrome.runtime.lastError;
    this.#end(true);
  };

  #end(notify: boolean): void {
    if (this.#state === 'closed') return;
    this.#state = 'closed';
    clearTimeout(this.#timer);
    this.#timer = undefined;
    const port = this.#port;
    this.#port = undefined;
    if (port) {
      port.onMessage.removeListener(this.#receive);
      port.onDisconnect.removeListener(this.#disconnected);
      try {
        port.disconnect();
      } catch {
        // Chrome may have already closed the port.
      }
    }
    this.#reject?.(new Error(CONNECTION_ERROR));
    this.#resolve = undefined;
    this.#reject = undefined;
    if (notify) this.#onDisconnect();
  }
}
