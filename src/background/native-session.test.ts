import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { NativeSessionController } from './native-session';
import { analyzeImage, followUp, AnthropicError } from '../lib/anthropic';
import { cropImage, fitScreenshotToLimits } from '../lib/crop';
import { DEFAULT_LIMITS, getSettings } from '../lib/storage';
import type { ExtensionToNativeMessage } from '../lib/native-protocol';

vi.mock('../lib/anthropic', async (actual) => ({
  ...await actual<typeof import('../lib/anthropic')>(), analyzeImage: vi.fn(), followUp: vi.fn(),
}));
vi.mock('../lib/crop', async (actual) => ({
  ...await actual<typeof import('../lib/crop')>(), cropImage: vi.fn(), fitScreenshotToLimits: vi.fn(),
}));
vi.mock('../lib/storage', async (actual) => ({
  ...await actual<typeof import('../lib/storage')>(), getSettings: vi.fn(),
}));

const IMAGE = 'data:image/png;base64,AAAA';
const CROP = 'data:image/png;base64,BBBB';
const source = { tabId: 1, windowId: 2, documentVersion: 0 };
class Event<T> {
  listeners = new Set<(value: T) => void>();
  addListener = (listener: (value: T) => void) => { this.listeners.add(listener); };
  removeListener = (listener: (value: T) => void) => { this.listeners.delete(listener); };
  emit(value: T) { for (const listener of [...this.listeners]) listener(value); }
}
class Port {
  onMessage = new Event<unknown>();
  onDisconnect = new Event<unknown>();
  sent: ExtensionToNativeMessage[] = [];
  disconnect = vi.fn();
  postMessage = (message: ExtensionToNativeMessage) => {
    this.sent.push(message);
    if (message.type === 'hello') this.onMessage.emit({ ...message, type: 'ready' });
  };
  latest(type?: string) {
    return [...this.sent].reverse().find(message => !type || message.type === type)!;
  }
  command(type: string, extra = {}, envelope = this.latest()) {
    if (!('sessionId' in envelope)) throw new Error('No session envelope');
    this.onMessage.emit({ version: 2, connectionId: envelope.connectionId,
      sessionId: envelope.sessionId, requestId: envelope.requestId, type, ...extra });
  }
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
async function flush() { for (let i = 0; i < 20; i++) await Promise.resolve(); }
function setup() {
  const ports: Port[] = [];
  vi.stubGlobal('chrome', { runtime: { connectNative: vi.fn(() => {
    const port = new Port(); ports.push(port); return port;
  }), getPlatformInfo: vi.fn(async () => ({})) } });
  const capture = vi.fn(async () => IMAGE);
  const isSourceCurrent = vi.fn(() => true);
  const report = vi.fn(async () => undefined);
  const controller = new NativeSessionController({ capture, isSourceCurrent, report });
  return { controller, ports, capture, isSourceCurrent, report };
}
async function accepted(harness: ReturnType<typeof setup>) {
  await harness.controller.start(source);
  const port = harness.ports.at(-1)!;
  port.command('selected', { rect: { x: 0, y: 0, width: 0.5, height: 0.5 } });
  await flush();
  return port;
}

beforeEach(() => {
  vi.useFakeTimers();
  vi.mocked(getSettings).mockResolvedValue({ apiKey: 'sk-ant-test-secret',
    defaultPrompt: 'Keep guidance.', limits: { ...DEFAULT_LIMITS } });
  vi.mocked(cropImage).mockResolvedValue(CROP);
  vi.mocked(fitScreenshotToLimits).mockImplementation(async image => image);
  vi.mocked(analyzeImage).mockResolvedValue({ text: 'First answer', history: [] });
  vi.mocked(followUp).mockResolvedValue({ text: 'Follow-up answer', history: [] });
});
afterEach(() => { vi.clearAllMocks(); vi.clearAllTimers(); vi.useRealTimers(); vi.unstubAllGlobals(); });

describe('background-owned native sessions', () => {
  it('handshakes before capture, accepts its own crop, and never transports credentials/history/guidance', async () => {
    const harness = setup();
    const port = await accepted(harness);
    expect(port.sent.map(message => message.type)).toEqual(['hello', 'capture', 'accepted', 'started', 'answer']);
    expect(cropImage).toHaveBeenCalledWith(IMAGE, { x: 0, y: 0, width: 0.5, height: 0.5 });
    expect(analyzeImage).toHaveBeenCalledWith('sk-ant-test-secret', CROP,
      expect.objectContaining({ hiddenInstruction: 'Keep guidance.', limits: DEFAULT_LIMITS }));
    const wire = JSON.stringify(port.sent);
    expect(wire).not.toContain('sk-ant');
    expect(wire).not.toContain('Keep guidance');
    expect(wire).not.toContain('history');
    port.command('close');
    expect(port.disconnect).toHaveBeenCalledOnce();
  });

  it('preserves accepted conversations through source navigation and closure', async () => {
    const harness = setup();
    const port = await accepted(harness);
    harness.isSourceCurrent.mockReturnValue(false);
    harness.controller.invalidateSource(source.tabId);
    port.command('followup', { text: 'Explain it' });
    await flush();
    expect(followUp).toHaveBeenCalledWith('sk-ant-test-secret', 'Explain it',
      expect.arrayContaining([expect.objectContaining({ role: 'assistant', content: 'First answer' })]),
      expect.objectContaining({ sessionInstruction: 'Keep guidance.' }));
    expect(harness.capture).toHaveBeenCalledOnce();
    expect(port.disconnect).not.toHaveBeenCalled();
  });

  it.each(['selection', 'crop'])('invalidates before acceptance during %s', async stage => {
    const harness = setup();
    const pending = deferred<string>();
    vi.mocked(cropImage).mockReturnValue(pending.promise);
    await harness.controller.start(source);
    const port = harness.ports[0];
    if (stage === 'crop') port.command('selected', { rect: { x: 0, y: 0, width: 1, height: 1 } });
    harness.controller.invalidateSource(source.tabId);
    pending.resolve(CROP);
    await flush();
    expect(port.disconnect).toHaveBeenCalledOnce();
    expect(analyzeImage).not.toHaveBeenCalled();
    expect(port.sent.some(message => message.type === 'accepted')).toBe(false);
  });

  it('rejects stale capture completion after a newer invocation', async () => {
    const harness = setup();
    const pending = deferred<string>();
    harness.capture.mockReturnValueOnce(pending.promise);
    const old = harness.controller.start(source);
    await flush();
    await harness.controller.start(source);
    pending.resolve(IMAGE);
    await old;
    expect(harness.ports[0].sent.some(message => message.type === 'capture')).toBe(false);
    expect(harness.ports[1].latest().type).toBe('capture');
  });

  it('cancels on disconnect and never replays a paid request or late answer', async () => {
    const harness = setup();
    const result = deferred<{ text: string; history: [] }>();
    vi.mocked(analyzeImage).mockReturnValueOnce(result.promise);
    const port = await accepted(harness);
    const options = vi.mocked(analyzeImage).mock.calls[0][2]!;
    port.onDisconnect.emit(undefined);
    expect(options.signal!.aborted).toBe(true);
    options.onDelta?.('Late secret');
    result.resolve({ text: 'Late answer', history: [] });
    await flush();
    expect(port.sent.some(message => message.type === 'answer')).toBe(false);
    await harness.controller.start(source);
    expect(analyzeImage).toHaveBeenCalledOnce();
    expect(harness.ports[1].latest().type).toBe('capture');
  });

  it('ignores stale, duplicate and cross-session requests', async () => {
    const harness = setup();
    const port = await accepted(harness);
    const old = port.latest();
    port.command('followup', { text: 'One' }, old);
    port.command('followup', { text: 'Duplicate' }, old);
    await flush();
    port.command('followup', { text: 'Stale' }, old);
    port.command('followup', { text: 'Wrong session', sessionId: 'another-session' });
    await flush();
    expect(followUp).toHaveBeenCalledOnce();
  });

  it('stops once, retains partial history, and retries from the original base', async () => {
    const harness = setup();
    const pending = deferred<{ text: string; history: [] }>();
    vi.mocked(analyzeImage).mockReturnValueOnce(pending.promise);
    const port = await accepted(harness);
    const options = vi.mocked(analyzeImage).mock.calls[0][2]!;
    options.onDelta?.('Partial answer');
    const generation = port.latest();
    port.command('stop');
    expect(options.signal!.aborted).toBe(true);
    expect(port.latest()).toMatchObject({ type: 'answer', text: 'Partial answer', status: 'stopped' });
    port.command('retry');
    await flush();
    expect(analyzeImage).toHaveBeenCalledTimes(2);
    pending.resolve({ text: 'Late result', history: [] });
    await flush();
    port.command('stop', {}, generation);
    expect(port.latest()).toMatchObject({ type: 'answer', text: 'First answer', status: 'done' });
  });

  it('keeps failed follow-up retries from duplicating the user turn', async () => {
    const harness = setup();
    const port = await accepted(harness);
    vi.mocked(followUp).mockRejectedValueOnce(new AnthropicError('network', 'Connection interrupted.'));
    port.command('followup', { text: 'Retry this' });
    await flush();
    expect(port.latest()).toMatchObject({ type: 'error', code: 'network' });
    port.command('retry');
    await flush();
    const calls = vi.mocked(followUp).mock.calls;
    expect(calls[0][1]).toBe(calls[1][1]);
    expect(calls[0][2]).toEqual(calls[1][2]);
  });

  it('returns generic errors for untrusted unexpected exceptions', async () => {
    const harness = setup();
    vi.mocked(analyzeImage).mockRejectedValueOnce(new Error('sk-ant-private provider\u0000details'));
    const port = await accepted(harness);
    expect(port.latest()).toMatchObject({ type: 'error', code: 'request_failed' });
    expect(JSON.stringify(port.sent)).not.toContain('private');
  });

  it('uses snapshotted preferences with the current key for follow-ups', async () => {
    const harness = setup();
    const port = await accepted(harness);
    vi.mocked(getSettings).mockResolvedValue({ apiKey: 'replacement-key',
      defaultPrompt: 'Changed preference', limits: { ...DEFAULT_LIMITS, maxInputCharacters: 100 } });
    port.command('followup', { text: 'Follow up' });
    await flush();
    expect(followUp).toHaveBeenCalledWith('replacement-key', 'Follow up', expect.any(Array),
      expect.objectContaining({ sessionInstruction: 'Keep guidance.', limits: DEFAULT_LIMITS }));
  });

  it('expires idle selections and refuses host-initiated recapture', async () => {
    const harness = setup();
    await harness.controller.start(source);
    const port = harness.ports[0];
    await vi.advanceTimersByTimeAsync(120_000);
    expect(port.disconnect).toHaveBeenCalledOnce();
    expect(harness.capture).toHaveBeenCalledOnce();
    expect(analyzeImage).not.toHaveBeenCalled();
  });

  it('binds independent sessions to their own port and caps retained sessions', async () => {
    const harness = setup();
    const first = await accepted(harness);
    const second = await accepted(harness);
    first.command('followup', { text: 'Wrong connection' }, second.latest());
    await flush();
    expect(followUp).not.toHaveBeenCalled();
    expect(first.disconnect).toHaveBeenCalledOnce();
    for (let i = 0; i < 3; i++) await accepted(harness);
    await harness.controller.start(source);
    expect(harness.report).toHaveBeenCalledWith(1, expect.stringContaining('Close a native'));
  });

  it('checks liveness after loading settings before issuing API requests', async () => {
    const harness = setup();
    await harness.controller.start(source);
    const settings = deferred<Awaited<ReturnType<typeof getSettings>>>();
    vi.mocked(getSettings).mockReturnValueOnce(settings.promise);
    const port = harness.ports[0];
    port.command('selected', { rect: { x: 0, y: 0, width: 1, height: 1 } });
    await flush();
    port.command('close');
    settings.resolve({ apiKey: 'secret', defaultPrompt: 'Guidance', limits: DEFAULT_LIMITS });
    await flush();
    expect(analyzeImage).not.toHaveBeenCalled();
  });

  it('handles missing keys without starting a request and allows explicit Retry', async () => {
    const harness = setup();
    vi.mocked(getSettings).mockResolvedValueOnce({ apiKey: '', defaultPrompt: 'Keep guidance.', limits: DEFAULT_LIMITS })
      .mockResolvedValueOnce({ apiKey: '', defaultPrompt: 'Keep guidance.', limits: DEFAULT_LIMITS });
    const port = await accepted(harness);
    expect(port.latest()).toMatchObject({ type: 'error', code: 'no_api_key' });
    expect(analyzeImage).not.toHaveBeenCalled();
    port.command('retry');
    await flush();
    expect(analyzeImage).toHaveBeenCalledOnce();
  });

  it.each(['stop', 'error'])('keeps history aligned after a first-question %s', async outcome => {
    const harness = setup();
    vi.mocked(analyzeImage).mockRejectedValueOnce(new AnthropicError('network', 'Try again.'));
    const port = await accepted(harness);
    const pending = deferred<{ text: string; history: [] }>();
    vi.mocked(analyzeImage).mockReturnValueOnce(pending.promise);
    port.command('followup', { text: 'Initial question after failure' });
    await flush();
    const options = vi.mocked(analyzeImage).mock.calls[1][2]!;
    options.onDelta?.('Partial');
    if (outcome === 'stop') port.command('stop');
    else pending.reject(new AnthropicError('network', 'Interrupted.'));
    await flush();
    port.command('followup', { text: 'Continue' });
    await flush();
    expect(followUp).toHaveBeenCalledOnce();
    expect(JSON.stringify(vi.mocked(followUp).mock.calls[0][2])).toContain('Initial question after failure');
    expect(port.latest()).toMatchObject({ type: 'answer', status: 'done' });
  });

  it('reports oversized transport payloads before making any API request', async () => {
    const harness = setup();
    harness.capture.mockResolvedValue(`data:image/png;base64,${'A'.repeat(24 * 1024 * 1024)}`);
    await harness.controller.start(source);
    expect(harness.report).toHaveBeenCalledWith(1, expect.stringContaining('could not be delivered'));
    expect(harness.ports[0].disconnect).toHaveBeenCalledOnce();
    expect(analyzeImage).not.toHaveBeenCalled();
  });

  it('batches stream snapshots and cancels pending batches on Close', async () => {
    const harness = setup();
    vi.mocked(analyzeImage).mockReturnValueOnce(new Promise(() => undefined));
    const port = await accepted(harness);
    const options = vi.mocked(analyzeImage).mock.calls[0][2]!;
    for (let i = 0; i < 100; i++) options.onDelta?.(`Text ${i}`);
    expect(port.sent.filter(message => message.type === 'answer')).toHaveLength(0);
    await vi.advanceTimersByTimeAsync(100);
    expect(port.sent.filter(message => message.type === 'answer')).toHaveLength(1);
    expect(port.latest()).toMatchObject({ type: 'answer', text: 'Text 99' });
    options.onDelta?.('Later text');
    port.command('close');
    await vi.advanceTimersByTimeAsync(100);
    expect(port.sent.filter(message => message.type === 'answer')).toHaveLength(1);
  });
});
