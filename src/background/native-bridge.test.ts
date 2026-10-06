import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { ExtensionToNativeMessage, NativeToExtensionMessage } from '../lib/native-protocol';
import { MAX_NATIVE_ANSWER_LENGTH, NATIVE_HOST_NAME } from '../lib/native-protocol';
import { NativeBridge } from './native-bridge';

const connectionId = 'connection-1';
const base = { version: 2, connectionId } as const;
const session = { ...base, sessionId: 'session-1', requestId: 'request-1' };
const ready = { ...base, type: 'ready' };

function createEvent<T>() {
  const listeners = new Set<(value: T) => void>();
  return {
    listeners,
    addListener: vi.fn((listener: (value: T) => void) => { listeners.add(listener); }),
    removeListener: vi.fn((listener: (value: T) => void) => { listeners.delete(listener); }),
    emit: (value: T) => { for (const listener of listeners) listener(value); },
  };
}

function createPort() {
  const onMessage = createEvent<unknown>();
  const onDisconnect = createEvent<void>();
  return {
    onMessage,
    onDisconnect,
    postMessage: vi.fn((_message: unknown) => undefined),
    disconnect: vi.fn(() => { onDisconnect.emit(); }),
  };
}

describe('NativeBridge', () => {
  let port: ReturnType<typeof createPort>;
  let connectNative: ReturnType<typeof vi.fn>;
  let onMessage: ReturnType<typeof vi.fn<(message: NativeToExtensionMessage) => void>>;
  let onDisconnect: ReturnType<typeof vi.fn<() => void>>;
  let bridge: NativeBridge;

  beforeEach(() => {
    vi.useFakeTimers();
    port = createPort();
    connectNative = vi.fn(() => port);
    vi.stubGlobal('chrome', { runtime: { connectNative } });
    onMessage = vi.fn();
    onDisconnect = vi.fn();
    bridge = new NativeBridge(connectionId, onMessage, onDisconnect);
  });

  afterEach(() => {
    bridge.disconnect();
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  async function connect() {
    const connecting = bridge.connect();
    port.onMessage.emit(ready);
    await connecting;
  }

  it('installs both listeners before hello and waits for a matching ready', async () => {
    port.postMessage.mockImplementation(() => {
      expect(port.onMessage.listeners.size).toBe(1);
      expect(port.onDisconnect.listeners.size).toBe(1);
      port.onMessage.emit(ready);
      return undefined;
    });
    await expect(bridge.connect()).resolves.toBeUndefined();
    expect(connectNative).toHaveBeenCalledWith(NATIVE_HOST_NAME);
    expect(port.postMessage).toHaveBeenCalledWith({ ...base, type: 'hello' });
    expect(onMessage).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(5_000);
    expect(onDisconnect).not.toHaveBeenCalled();
  });

  it('shares one handshake and host for repeated connects', async () => {
    const first = bridge.connect();
    expect(bridge.connect()).toBe(first);
    port.onMessage.emit(ready);
    await first;
    await bridge.connect();
    expect(connectNative).toHaveBeenCalledTimes(1);
  });

  it('forwards validated session messages only after the handshake', async () => {
    await connect();
    const message = { ...session, type: 'followup', text: 'Why?' };
    port.onMessage.emit(message);
    expect(onMessage).toHaveBeenCalledExactlyOnceWith(message);
  });

  it.each([
    { ...ready, version: 1 },
    { ...ready, connectionId: 'another-connection' },
    { ...ready, apiKey: 'unexpected' },
    { ...session, type: 'stop' },
    null,
  ])('closes on malformed or out-of-order handshake messages: %j', async (message) => {
    const connecting = bridge.connect();
    const rejected = expect(connecting).rejects.toThrow('companion is unavailable');
    port.onMessage.emit(message);
    await rejected;
    expect(port.disconnect).toHaveBeenCalledTimes(1);
    expect(onDisconnect).toHaveBeenCalledTimes(1);
    expect(onMessage).not.toHaveBeenCalled();
    expect(port.onMessage.listeners.size).toBe(0);
    expect(port.onDisconnect.listeners.size).toBe(0);
  });

  it.each([
    ready,
    { ...session, type: 'stop', connectionId: 'another-connection' },
    { ...session, type: 'followup', text: 'Why?', tabId: 7 },
    { ...session, type: 'selected', rect: { x: 0, y: 0, width: 2, height: 1 } },
  ])('closes on invalid traffic after ready: %j', async (message) => {
    await connect();
    port.onMessage.emit(message);
    expect(onDisconnect).toHaveBeenCalledTimes(1);
    expect(onMessage).not.toHaveBeenCalled();
    expect(port.disconnect).toHaveBeenCalledTimes(1);
  });

  it('times out the handshake after five seconds and cannot reconnect', async () => {
    const connecting = bridge.connect();
    const rejected = expect(connecting).rejects.toThrow('companion is unavailable');
    await vi.advanceTimersByTimeAsync(4_999);
    expect(onDisconnect).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1);
    await rejected;
    await expect(bridge.connect()).rejects.toThrow('companion is unavailable');
    expect(connectNative).toHaveBeenCalledTimes(1);
    expect(onDisconnect).toHaveBeenCalledTimes(1);
  });

  it('acknowledges Chrome disconnect errors without exposing their text', async () => {
    const getLastError = vi.fn(() => ({ message: 'sensitive host error sk-ant-secret' }));
    Object.defineProperty(chrome.runtime, 'lastError', { configurable: true, get: getLastError });
    const connecting = bridge.connect();
    const rejected = expect(connecting).rejects.toThrow(/^The SnapScreen companion is unavailable\./);
    port.onDisconnect.emit();
    await rejected;
    expect(getLastError).toHaveBeenCalledTimes(1);
    expect(onDisconnect).toHaveBeenCalledExactlyOnceWith();
    expect(onMessage).not.toHaveBeenCalled();
  });

  it('reports thrown connect errors generically', async () => {
    connectNative.mockImplementation(() => { throw new Error('sensitive host error'); });
    await expect(bridge.connect()).rejects.toThrow(/^The SnapScreen companion is unavailable\./);
    expect(onDisconnect).toHaveBeenCalledExactlyOnceWith();
  });

  it('notifies only once on disconnection and ignores late messages', async () => {
    await connect();
    const receive = [...port.onMessage.listeners][0];
    const disconnected = [...port.onDisconnect.listeners][0];
    port.onDisconnect.emit();
    disconnected();
    receive({ ...session, type: 'close' });
    bridge.disconnect();
    await vi.advanceTimersByTimeAsync(5_000);
    expect(onDisconnect).toHaveBeenCalledTimes(1);
    expect(onMessage).not.toHaveBeenCalled();
    expect(port.disconnect).toHaveBeenCalledTimes(1);
  });

  it('manual disconnect rejects an unfinished handshake without notifying', async () => {
    const connecting = bridge.connect();
    const rejected = expect(connecting).rejects.toThrow('companion is unavailable');
    bridge.disconnect();
    await rejected;
    await vi.advanceTimersByTimeAsync(5_000);
    expect(onDisconnect).not.toHaveBeenCalled();
    expect(port.disconnect).toHaveBeenCalledTimes(1);
  });

  it('manual disconnect after ready prevents sends and never reconnects', async () => {
    await connect();
    bridge.disconnect();
    expect(() => bridge.send({ ...session, type: 'thinking' })).toThrow('could not be sent');
    await expect(bridge.connect()).rejects.toThrow('companion is unavailable');
    expect(onDisconnect).not.toHaveBeenCalled();
    expect(connectNative).toHaveBeenCalledTimes(1);
  });

  it('sends validated messages and rejects extra data, overlong answers, and crossed identities', async () => {
    expect(() => bridge.send({ ...session, type: 'thinking' })).toThrow('could not be sent');
    await connect();
    port.postMessage.mockClear();
    const thinking = { ...session, type: 'thinking' } as const;
    bridge.send(thinking);
    expect(port.postMessage).toHaveBeenCalledExactlyOnceWith(thinking);
    for (const message of [
      { ...thinking, connectionId: 'other' },
      { ...thinking, apiKey: 'secret' },
      { ...base, type: 'hello' },
      { ...session, type: 'answer', text: 'a'.repeat(MAX_NATIVE_ANSWER_LENGTH + 1), status: 'done' },
    ]) {
      expect(() => bridge.send(message as ExtensionToNativeMessage)).toThrow('could not be sent');
    }
    expect(port.postMessage).toHaveBeenCalledTimes(1);
  });

  it('closes if sending fails and exposes only a generic transport error', async () => {
    await connect();
    port.postMessage.mockImplementation(() => { throw new Error('sensitive host error'); });
    expect(() => bridge.send({ ...session, type: 'thinking' })).toThrow(/^The SnapScreen companion is unavailable\./);
    expect(onDisconnect).toHaveBeenCalledTimes(1);
    expect(port.disconnect).toHaveBeenCalledTimes(1);
  });

  it('rejects invalid connection identities before launching a host', () => {
    expect(() => new NativeBridge('bad/id', onMessage, onDisconnect)).toThrow('identity');
    expect(connectNative).not.toHaveBeenCalled();
  });
});
