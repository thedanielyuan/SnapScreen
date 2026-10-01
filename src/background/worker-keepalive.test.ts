import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { KEEPALIVE_INTERVAL_MS, keepAliveUntilSettled } from './worker-keepalive';

describe('keepAliveUntilSettled', () => {
  let getPlatformInfo: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    vi.useFakeTimers();
    getPlatformInfo = vi.fn(async () => ({}));
    vi.stubGlobal('chrome', { runtime: { getPlatformInfo } });
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it('calls an extension API on an interval until the operation resolves', async () => {
    let resolve!: (value: string) => void;
    const result = keepAliveUntilSettled(new Promise<string>((done) => { resolve = done; }));

    await vi.advanceTimersByTimeAsync(KEEPALIVE_INTERVAL_MS * 3);
    expect(getPlatformInfo).toHaveBeenCalledTimes(3);

    resolve('answer');
    await expect(result).resolves.toBe('answer');
    await vi.advanceTimersByTimeAsync(KEEPALIVE_INTERVAL_MS * 3);
    expect(getPlatformInfo).toHaveBeenCalledTimes(3);
  });

  it('stops pinging and rethrows when the operation rejects', async () => {
    let reject!: (error: Error) => void;
    const result = keepAliveUntilSettled(new Promise<never>((_, fail) => { reject = fail; }));
    const settled = expect(result).rejects.toThrow('stream failed');

    await vi.advanceTimersByTimeAsync(KEEPALIVE_INTERVAL_MS);
    reject(new Error('stream failed'));
    await settled;
    await vi.advanceTimersByTimeAsync(KEEPALIVE_INTERVAL_MS * 2);
    expect(getPlatformInfo).toHaveBeenCalledTimes(1);
  });

  it('ignores a failed keepalive call', async () => {
    getPlatformInfo.mockRejectedValue(new Error('Extension context invalidated.'));
    let resolve!: (value: string) => void;
    const result = keepAliveUntilSettled(new Promise<string>((done) => { resolve = done; }));

    await vi.advanceTimersByTimeAsync(KEEPALIVE_INTERVAL_MS);
    resolve('answer');
    await expect(result).resolves.toBe('answer');
  });
});
