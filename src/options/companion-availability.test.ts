import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { NATIVE_HOST_NAME, NATIVE_PROTOCOL_VERSION } from '../lib/native-protocol';
import { checkCompanionAvailability } from './companion-availability';

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

describe('Settings companion availability check', () => {
  let port: ReturnType<typeof createPort>;
  let getPlatformInfo: ReturnType<typeof vi.fn>;
  let connectNative: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    vi.useFakeTimers();
    port = createPort();
    getPlatformInfo = vi.fn().mockResolvedValue({ os: 'mac' });
    connectNative = vi.fn(() => port);
    vi.stubGlobal('chrome', { runtime: { getPlatformInfo, connectNative } });
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  async function beginCheck() {
    const result = checkCompanionAvailability();
    await Promise.resolve();
    const hello = port.postMessage.mock.calls[0][0] as { connectionId: string };
    return { result, ready: { version: NATIVE_PROTOCOL_VERSION, type: 'ready', connectionId: hello.connectionId } };
  }

  it('checks platform support before launching any host', async () => {
    getPlatformInfo.mockResolvedValue({ os: 'linux' });
    await expect(checkCompanionAvailability()).resolves.toBe('unsupported');
    expect(connectNative).not.toHaveBeenCalled();
  });

  it('does not connect when the platform query fails', async () => {
    getPlatformInfo.mockRejectedValue(new Error('unavailable'));
    await expect(checkCompanionAvailability()).resolves.toBe('unavailable');
    expect(connectNative).not.toHaveBeenCalled();
  });

  it('sends only hello, validates the matching ready, and disconnects immediately', async () => {
    port.postMessage.mockImplementation((message) => {
      expect(port.onMessage.listeners.size).toBe(1);
      expect(port.onDisconnect.listeners.size).toBe(1);
      port.onMessage.emit({ ...(message as object), type: 'ready' });
    });
    await expect(checkCompanionAvailability()).resolves.toBe('ready');
    expect(connectNative).toHaveBeenCalledExactlyOnceWith(NATIVE_HOST_NAME);
    expect(port.postMessage).toHaveBeenCalledExactlyOnceWith({
      version: NATIVE_PROTOCOL_VERSION,
      type: 'hello',
      connectionId: expect.any(String),
    });
    expect(port.disconnect).toHaveBeenCalledTimes(1);
    expect(port.onMessage.listeners.size).toBe(0);
    expect(port.onDisconnect.listeners.size).toBe(0);
    expect(vi.getTimerCount()).toBe(0);
  });

  it.each([
    { version: NATIVE_PROTOCOL_VERSION - 1 },
    { connectionId: 'another-check' },
    { type: 'close' },
    { extra: 'unexpected' },
  ])('rejects mismatched or invalid handshakes: %j', async (change) => {
    const { result, ready } = await beginCheck();
    port.onMessage.emit({ ...ready, ...change });
    await expect(result).resolves.toBe('incompatible');
    expect(port.postMessage).toHaveBeenCalledTimes(1);
    expect(port.disconnect).toHaveBeenCalledTimes(1);
    expect(vi.getTimerCount()).toBe(0);
  });

  it('closes a silent host after five seconds', async () => {
    const { result } = await beginCheck();
    await vi.advanceTimersByTimeAsync(4_999);
    expect(port.disconnect).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1);
    await expect(result).resolves.toBe('timed-out');
    expect(port.disconnect).toHaveBeenCalledTimes(1);
    expect(port.onMessage.listeners.size).toBe(0);
    expect(port.onDisconnect.listeners.size).toBe(0);
  });

  it.each([
    ['Specified native messaging host not found.', 'missing'],
    ['Native host has exited. sk-ant-do-not-render', 'disconnected'],
    [undefined, 'disconnected'],
  ])('acknowledges Chrome errors without exposing their text', async (message, outcome) => {
    const lastError = vi.fn(() => message ? { message } : undefined);
    Object.defineProperty(chrome.runtime, 'lastError', { get: lastError });
    const { result } = await beginCheck();
    port.onDisconnect.emit();
    await expect(result).resolves.toBe(outcome);
    expect(lastError).toHaveBeenCalledTimes(1);
    expect(port.disconnect).toHaveBeenCalledTimes(1);
  });

  it('returns a fixed outcome if Chrome cannot launch the host', async () => {
    connectNative.mockImplementation(() => { throw new Error('sk-ant-do-not-render'); });
    await expect(checkCompanionAvailability()).resolves.toBe('unavailable');
    expect(vi.getTimerCount()).toBe(0);
  });

  it('cleans up a port when sending hello throws', async () => {
    port.postMessage.mockImplementation(() => { throw new Error('sk-ant-do-not-render'); });
    await expect(checkCompanionAvailability()).resolves.toBe('unavailable');
    expect(port.disconnect).toHaveBeenCalledTimes(1);
    expect(port.onMessage.listeners.size).toBe(0);
    expect(port.onDisconnect.listeners.size).toBe(0);
    expect(vi.getTimerCount()).toBe(0);
  });

  it('ignores late messages and disconnects after a settled check', async () => {
    const { result, ready } = await beginCheck();
    const receive = [...port.onMessage.listeners][0];
    const disconnected = [...port.onDisconnect.listeners][0];
    port.onMessage.emit(ready);
    receive(null);
    disconnected();
    await expect(result).resolves.toBe('ready');
    expect(port.disconnect).toHaveBeenCalledTimes(1);
  });
});
