import {
  isNativeToExtensionMessage,
  NATIVE_HOST_NAME,
  NATIVE_PROTOCOL_VERSION,
} from '../lib/native-protocol';
import type { ExtensionToNativeMessage } from '../lib/native-protocol';

export type CompanionAvailability =
  | 'ready'
  | 'unsupported'
  | 'unavailable'
  | 'missing'
  | 'forbidden'
  | 'failed-to-start'
  | 'incompatible'
  | 'disconnected'
  | 'timed-out';

// Chrome's fixed connection errors for the common setup mistakes. Other text is never shown.
const CHROME_ERRORS = new Map<string, CompanionAvailability>([
  ['Specified native messaging host not found.', 'missing'],
  ['Access to the specified native messaging host is forbidden.', 'forbidden'],
  ['Failed to start native messaging host.', 'failed-to-start'],
]);

/** Explicit Settings diagnostic: no capture, session, credentials, or API request. */
export async function checkCompanionAvailability(): Promise<CompanionAvailability> {
  try {
    if ((await chrome.runtime.getPlatformInfo()).os !== 'mac') return 'unsupported';
  } catch {
    return 'unavailable';
  }

  return new Promise((resolve) => {
    const connectionId = crypto.randomUUID();
    let port: chrome.runtime.Port | undefined;
    let settled = false;
    const timeout = setTimeout(() => finish('timed-out'), 5_000);

    function finish(result: CompanionAvailability): void {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      if (port) {
        port.onMessage.removeListener(receive);
        port.onDisconnect.removeListener(disconnected);
        try {
          port.disconnect();
        } catch {
          // Chrome may have already closed the host's port.
        }
      }
      resolve(result);
    }

    function receive(value: unknown): void {
      finish(isNativeToExtensionMessage(value)
        && value.type === 'ready'
        && value.connectionId === connectionId ? 'ready' : 'incompatible');
    }

    function disconnected(): void {
      // Acknowledge Chrome's error, but never render host or transport error text.
      const error = chrome.runtime.lastError?.message;
      finish((error && CHROME_ERRORS.get(error)) || 'disconnected');
    }

    try {
      port = chrome.runtime.connectNative(NATIVE_HOST_NAME);
      port.onMessage.addListener(receive);
      port.onDisconnect.addListener(disconnected);
      port.postMessage({
        version: NATIVE_PROTOCOL_VERSION,
        type: 'hello',
        connectionId,
      } satisfies ExtensionToNativeMessage);
    } catch {
      finish('unavailable');
    }
  });
}
