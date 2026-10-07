import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { DEFAULT_LIMITS } from '../lib/storage';
import { NATIVE_PROTOCOL_VERSION, type ExtensionToNativeMessage } from '../lib/native-protocol';

const dependencies = vi.hoisted(() => ({
  analyzeImage: vi.fn(),
  followUp: vi.fn(),
  cropImage: vi.fn(),
  fitScreenshotToLimits: vi.fn(),
}));

vi.mock('../lib/anthropic', async (actual) => ({
  ...await actual<typeof import('../lib/anthropic')>(),
  analyzeImage: dependencies.analyzeImage,
  followUp: dependencies.followUp,
}));
vi.mock('../lib/crop', async (actual) => ({
  ...await actual<typeof import('../lib/crop')>(),
  cropImage: dependencies.cropImage,
  fitScreenshotToLimits: dependencies.fitScreenshotToLimits,
}));

const IMAGE = 'data:image/png;base64,AAAA';
const CROP = 'data:image/png;base64,BBBB';
const RAW_ERROR = 'Host rejected sk-ant-test-secret\u0000private host details';
const sourceTab = { id: 7, windowId: 2, active: true, url: 'https://example.test/question' } as chrome.tabs.Tab;

class Event<T extends unknown[]> {
  listeners = new Set<(...args: T) => unknown>();
  addListener = (listener: (...args: T) => unknown) => { this.listeners.add(listener); };
  removeListener = (listener: (...args: T) => unknown) => { this.listeners.delete(listener); };
  emit(...args: T) { for (const listener of [...this.listeners]) listener(...args); }
}

class Port {
  onMessage = new Event<[unknown]>();
  onDisconnect = new Event<[]>();
  sent: ExtensionToNativeMessage[] = [];
  disconnect = vi.fn();
  handshake: 'ready' | 'malformed' | 'incompatible' | 'waiting' = 'ready';
  postMessage = (message: ExtensionToNativeMessage) => {
    this.sent.push(message);
    if (message.type !== 'hello' || this.handshake === 'waiting') return;
    this.onMessage.emit({ ...message, type: 'ready',
      ...(this.handshake === 'malformed' ? { error: RAW_ERROR } : {}),
      ...(this.handshake === 'incompatible' ? { version: NATIVE_PROTOCOL_VERSION + 1 } : {}),
    });
  };

  latest(type?: ExtensionToNativeMessage['type']) {
    return [...this.sent].reverse().find(message => !type || message.type === type)!;
  }

  command(type: string, extra = {}, envelope = this.latest()) {
    if (!envelope || !('sessionId' in envelope)) throw new Error('No capture envelope');
    this.onMessage.emit({ type, version: NATIVE_PROTOCOL_VERSION,
      connectionId: envelope.connectionId, sessionId: envelope.sessionId,
      requestId: envelope.requestId, ...extra });
  }
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(yes => { resolve = yes; });
  return { promise, resolve };
}

async function flush() { for (let i = 0; i < 40; i++) await Promise.resolve(); }

async function setup() {
  vi.resetModules();
  const port = new Port();
  const ports: Port[] = [];
  const clicked = new Event<[chrome.tabs.Tab]>();
  const command = new Event<[string, chrome.tabs.Tab?]>();
  const installed = new Event<[chrome.runtime.InstalledDetails]>();
  const activated = new Event<[chrome.tabs.OnActivatedInfo]>();
  const updated = new Event<[number, chrome.tabs.OnUpdatedInfo, chrome.tabs.Tab]>();
  const removed = new Event<[number]>();
  const message = new Event<[unknown, chrome.runtime.MessageSender, (response?: unknown) => void]>();
  const connect = new Event<[chrome.runtime.Port]>();
  const runtime = {
    connectNative: vi.fn(() => {
      const next = ports.length ? new Port() : port;
      ports.push(next);
      return next;
    }),
    openOptionsPage: vi.fn(async () => undefined),
    getPlatformInfo: vi.fn(async () => ({ os: 'mac' })),
    onInstalled: installed,
    onMessage: message,
    onConnect: connect,
    lastError: { message: RAW_ERROR },
  };
  const local = {
    setAccessLevel: vi.fn(async () => undefined),
    get: vi.fn(async () => ({ apiKey: 'sk-ant-test-secret', defaultPrompt: 'Private guidance.',
      limits: DEFAULT_LIMITS, interfaceMode: 'extension' })),
  };
  const action = {
    onClicked: clicked,
    setBadgeText: vi.fn(async () => undefined),
    setTitle: vi.fn(async () => undefined),
  };
  const tabs = {
    onActivated: activated, onUpdated: updated, onRemoved: removed,
    query: vi.fn(async () => [sourceTab]),
    captureVisibleTab: vi.fn(async () => IMAGE),
    create: vi.fn(), update: vi.fn(), sendMessage: vi.fn(),
  };
  const scripting = { executeScript: vi.fn(), insertCSS: vi.fn() };
  const permissions = { request: vi.fn() };
  const extension = { isAllowedFileSchemeAccess: vi.fn(async () => true) };
  vi.stubGlobal('chrome', { runtime, storage: { local }, action, tabs, scripting, permissions,
    extension, commands: { onCommand: command } });
  await import('./service-worker-native');
  return { port, ports, clicked, command, installed, activated, updated, removed, runtime, local,
    action, tabs, scripting, permissions, extension, message, connect };
}

function expectDisconnected(port: Port) {
  expect(port.disconnect).toHaveBeenCalledOnce();
  expect(port.onMessage.listeners.size).toBe(0);
  expect(port.onDisconnect.listeners.size).toBe(0);
}

async function acceptCapture(harness: Awaited<ReturnType<typeof setup>>) {
  harness.clicked.emit(sourceTab);
  await flush();
  const port = harness.ports.at(-1)!;
  port.command('selected', { rect: { x: 0, y: 0, width: 0.5, height: 0.5 } });
  await flush();
  return port;
}

function expectNoPageFallback(harness: Awaited<ReturnType<typeof setup>>) {
  expect(harness.scripting.executeScript).not.toHaveBeenCalled();
  expect(harness.scripting.insertCSS).not.toHaveBeenCalled();
  expect(harness.tabs.sendMessage).not.toHaveBeenCalled();
  expect(harness.tabs.create).not.toHaveBeenCalled();
  expect(harness.tabs.update).not.toHaveBeenCalled();
  expect(harness.runtime.openOptionsPage).not.toHaveBeenCalled();
  expect(harness.permissions.request).not.toHaveBeenCalled();
}

beforeEach(() => {
  vi.useFakeTimers();
  dependencies.cropImage.mockResolvedValue(CROP);
  dependencies.fitScreenshotToLimits.mockImplementation(async image => image);
  dependencies.analyzeImage.mockResolvedValue({ text: 'First answer', history: [] });
  dependencies.followUp.mockResolvedValue({ text: 'Follow-up answer', history: [] });
});
afterEach(() => { vi.clearAllMocks(); vi.clearAllTimers(); vi.useRealTimers(); vi.unstubAllGlobals(); });

describe('native-only background entry', () => {
  it('uses the real native capture flow despite a stale extension preference', async () => {
    const harness = await setup();
    harness.clicked.emit(sourceTab);
    await flush();
    expect(harness.local.setAccessLevel).toHaveBeenCalledWith({ accessLevel: 'TRUSTED_CONTEXTS' });
    expect(harness.local.get.mock.calls).toEqual([[['apiKey', 'defaultPrompt', 'limits']]]);
    expect(harness.tabs.captureVisibleTab).toHaveBeenCalledWith(2, { format: 'png' });
    expect(harness.port.sent.map(value => value.type)).toEqual(['hello', 'capture']);
    expect(harness.port.sent[1]).toMatchObject({ imageDataUrl: IMAGE });
    expectNoPageFallback(harness);
  });

  it('runs the shortcut using its source tab, or resolves the active tab when none is supplied', async () => {
    const harness = await setup();
    harness.command.emit('unrelated', sourceTab);
    await flush();
    expect(harness.runtime.connectNative).not.toHaveBeenCalled();
    harness.command.emit('snip');
    await flush();
    expect(harness.tabs.query).toHaveBeenCalledWith({ active: true, currentWindow: true });
    expect(harness.port.sent.at(-1)).toMatchObject({ type: 'capture' });
    harness.port.command('cancelled');
    expect(harness.port.disconnect).toHaveBeenCalledOnce();
    expectNoPageFallback(harness);
  });

  it('opens first-install Settings separately and never reopens it for updates or capture failures', async () => {
    const harness = await setup();
    harness.installed.emit({ reason: 'update' } as chrome.runtime.InstalledDetails);
    expect(harness.runtime.openOptionsPage).not.toHaveBeenCalled();
    harness.installed.emit({ reason: 'install' } as chrome.runtime.InstalledDetails);
    expect(harness.runtime.openOptionsPage).toHaveBeenCalledOnce();
    harness.runtime.openOptionsPage.mockClear();
    harness.runtime.connectNative.mockImplementation(() => { throw new Error(RAW_ERROR); });
    harness.clicked.emit(sourceTab);
    await flush();
    expectNoPageFallback(harness);
  });

  it('exposes no message or port handler to former injected UI or other extension pages', async () => {
    const harness = await setup();
    expect(harness.message.listeners.size).toBe(0);
    expect(harness.connect.listeners.size).toBe(0);
    expectNoPageFallback(harness);
  });

  it.each(['missing', 'malformed', 'incompatible', 'disconnected', 'timeout'] as const)(
    'reports a %s companion with sanitized browser feedback and no capture fallback', async failure => {
      const harness = await setup();
      if (failure === 'missing') {
        harness.runtime.connectNative.mockImplementation(() => { throw new Error(RAW_ERROR); });
      } else {
        harness.port.handshake = failure === 'disconnected' || failure === 'timeout' ? 'waiting' : failure;
      }
      harness.clicked.emit(sourceTab);
      await flush();
      if (failure === 'disconnected') harness.port.onDisconnect.emit();
      if (failure === 'timeout') await vi.advanceTimersByTimeAsync(5_000);
      await flush();
      expect(harness.action.setBadgeText).toHaveBeenCalledWith({ tabId: 7, text: '!' });
      expect(harness.action.setTitle).toHaveBeenCalledWith({ tabId: 7,
        title: 'The SnapScreen companion could not start. Check its installation, then invoke SnapScreen again.' });
      expect(JSON.stringify(harness.action.setTitle.mock.calls)).not.toContain('sk-ant');
      expect(harness.tabs.captureVisibleTab).not.toHaveBeenCalled();
      expect(harness.runtime.connectNative).toHaveBeenCalledOnce();
      if (failure !== 'missing') expectDisconnected(harness.port);
      expectNoPageFallback(harness);
    },
  );

  it('requires existing file access without requesting permission', async () => {
    const harness = await setup();
    harness.extension.isAllowedFileSchemeAccess.mockResolvedValue(false);
    harness.clicked.emit({ ...sourceTab, url: 'file:///private/question.html' });
    await flush();
    expect(harness.runtime.connectNative).not.toHaveBeenCalled();
    expect(harness.action.setTitle).toHaveBeenCalledWith({ tabId: 7,
      title: expect.stringContaining('Allow access to file URLs') });
    harness.extension.isAllowedFileSchemeAccess.mockResolvedValue(true);
    harness.clicked.emit({ ...sourceTab, url: 'file:///private/question.html' });
    await flush();
    expect(harness.tabs.captureVisibleTab).toHaveBeenCalledOnce();
    expectNoPageFallback(harness);
  });

  it('does not capture when the initiating tab is no longer active', async () => {
    const harness = await setup();
    harness.tabs.query.mockResolvedValue([{ ...sourceTab, id: 8 }]);
    harness.clicked.emit(sourceTab);
    await flush();
    expect(harness.tabs.captureVisibleTab).not.toHaveBeenCalled();
    expect(harness.port.disconnect).toHaveBeenCalledOnce();
    expect(harness.action.setTitle).toHaveBeenCalledWith({ tabId: 7,
      title: expect.stringContaining('active tab changed') });
    expectNoPageFallback(harness);
  });

  it('rejects a screenshot if activation changes away and back while Chrome captures it', async () => {
    const harness = await setup();
    const capture = deferred<string>();
    harness.tabs.captureVisibleTab.mockReturnValue(capture.promise);
    harness.clicked.emit(sourceTab);
    await flush();
    harness.activated.emit({ tabId: 8, windowId: 2 });
    harness.activated.emit({ tabId: 7, windowId: 2 });
    capture.resolve(IMAGE);
    await flush();
    expect(harness.port.sent.map(value => value.type)).toEqual(['hello']);
    expect(harness.action.setTitle).toHaveBeenCalledWith({ tabId: 7,
      title: expect.stringContaining('active tab changed') });
    expectNoPageFallback(harness);
  });

  it('keeps Chrome capture denials outside the page without exposing the raw error', async () => {
    const harness = await setup();
    harness.tabs.captureVisibleTab.mockRejectedValue(new Error(RAW_ERROR));
    harness.clicked.emit(sourceTab);
    await flush();
    expect(harness.port.sent.map(value => value.type)).toEqual(['hello']);
    expect(harness.action.setTitle).toHaveBeenCalledWith({ tabId: 7,
      title: 'Native capture could not start. Invoke SnapScreen again on the page you want to snip.' });
    expectNoPageFallback(harness);
  });

  it.each(['navigation', 'closure'] as const)('invalidates an unfinished capture on source %s', async change => {
    const harness = await setup();
    const capture = deferred<string>();
    harness.tabs.captureVisibleTab.mockReturnValue(capture.promise);
    harness.clicked.emit(sourceTab);
    await flush();
    if (change === 'navigation') harness.updated.emit(7, { status: 'loading' }, sourceTab);
    else harness.removed.emit(7);
    capture.resolve(IMAGE);
    await flush();
    expect(harness.port.sent.map(value => value.type)).toEqual(['hello']);
    expect(harness.port.disconnect).toHaveBeenCalledOnce();
    expect(harness.action.setBadgeText).not.toHaveBeenCalled();
    expectNoPageFallback(harness);
  });

  it('preserves same-document selection and accepted conversations after navigation or closure', async () => {
    const harness = await setup();
    harness.clicked.emit(sourceTab);
    await flush();
    harness.updated.emit(7, { url: `${sourceTab.url}#section` }, sourceTab);
    expect(harness.port.disconnect).not.toHaveBeenCalled();
    harness.port.command('selected', { rect: { x: 0, y: 0, width: 0.5, height: 0.5 } });
    await flush();
    expect(dependencies.analyzeImage).toHaveBeenCalledWith('sk-ant-test-secret', CROP,
      expect.objectContaining({ hiddenInstruction: 'Private guidance.' }));
    harness.updated.emit(7, { status: 'loading' }, sourceTab);
    harness.removed.emit(7);
    harness.port.command('followup', { text: 'Explain it' });
    await flush();
    expect(dependencies.followUp).toHaveBeenCalledWith('sk-ant-test-secret', 'Explain it',
      expect.arrayContaining([expect.objectContaining({ role: 'assistant', content: 'First answer' })]),
      expect.objectContaining({ sessionInstruction: 'Private guidance.' }));
    expect(harness.port.disconnect).not.toHaveBeenCalled();
    expect(JSON.stringify(harness.port.sent)).not.toMatch(/sk-ant|Private guidance|history/);
    expectNoPageFallback(harness);
  });

  it.each([
    ['selection', 'navigation'], ['selection', 'closure'],
    ['crop', 'navigation'], ['crop', 'closure'],
    ['fit', 'navigation'], ['fit', 'closure'],
  ] as const)(
    'invalidates work during %s on source %s and ignores its late completion', async (stage, change) => {
      const harness = await setup();
      const pending = deferred<string>();
      if (stage === 'crop') dependencies.cropImage.mockReturnValueOnce(pending.promise);
      if (stage === 'fit') dependencies.fitScreenshotToLimits.mockReturnValueOnce(pending.promise);
      harness.clicked.emit(sourceTab);
      await flush();
      if (stage !== 'selection') {
        harness.port.command('selected', { rect: { x: 0, y: 0, width: 1, height: 1 } });
        await flush();
      }
      if (change === 'navigation') harness.updated.emit(7, { status: 'loading' }, sourceTab);
      else harness.removed.emit(7);
      pending.resolve(CROP);
      await flush();
      expect(harness.port.sent.map(message => message.type)).toEqual(['hello', 'capture', 'expired']);
      expectDisconnected(harness.port);
      expect(dependencies.analyzeImage).not.toHaveBeenCalled();
      expect(harness.action.setBadgeText).not.toHaveBeenCalled();
      expectNoPageFallback(harness);
    },
  );

  it.each(['disconnected', 'malformed', 'incompatible', 'duplicate ready'] as const)(
    'aborts a running request after a %s host and removes listeners without replay', async failure => {
      const harness = await setup();
      const pending = deferred<{ text: string; history: [] }>();
      dependencies.analyzeImage.mockReturnValueOnce(pending.promise);
      const port = await acceptCapture(harness);
      const handlers = dependencies.analyzeImage.mock.calls[0][2];
      handlers.onDelta('Pending answer');
      const sent = [...port.sent];
      if (failure === 'disconnected') port.onDisconnect.emit();
      else if (failure === 'duplicate ready') port.onMessage.emit({ ...port.sent[0], type: 'ready' });
      else port.command('stop', failure === 'malformed'
        ? { unexpected: RAW_ERROR } : { version: NATIVE_PROTOCOL_VERSION + 1 });
      expect(handlers.signal.aborted).toBe(true);
      expectDisconnected(port);
      handlers.onThinking();
      handlers.onDelta('Late answer');
      pending.resolve({ text: 'Late answer', history: [] });
      await vi.advanceTimersByTimeAsync(100);
      await flush();
      expect(port.sent).toEqual(sent);
      expect(harness.runtime.connectNative).toHaveBeenCalledOnce();
      expect(dependencies.analyzeImage).toHaveBeenCalledOnce();
      expect(harness.action.setTitle).toHaveBeenCalledWith({ tabId: 7,
        title: 'The native session ended. Invoke SnapScreen in Chrome to start a new capture.' });
      expect(JSON.stringify(harness.action.setTitle.mock.calls)).not.toContain('sk-ant');
      expectNoPageFallback(harness);
    },
  );

  it('streams answers, stops the active request, and retries without accepting stale events', async () => {
    const harness = await setup();
    const pending = deferred<{ text: string; history: [] }>();
    dependencies.analyzeImage.mockReturnValueOnce(pending.promise);
    const port = await acceptCapture(harness);
    const handlers = dependencies.analyzeImage.mock.calls[0][2];
    handlers.onThinking();
    expect(port.latest()).toMatchObject({ type: 'thinking' });
    handlers.onDelta('Partial answer');
    await vi.advanceTimersByTimeAsync(100);
    expect(port.latest()).toMatchObject({ type: 'answer', status: 'streaming', text: 'Partial answer' });
    const stoppedRequest = port.latest();
    port.command('stop');
    expect(handlers.signal.aborted).toBe(true);
    expect(port.latest()).toMatchObject({ type: 'answer', status: 'stopped', text: 'Partial answer' });
    port.command('retry');
    await flush();
    expect(dependencies.analyzeImage).toHaveBeenCalledTimes(2);
    const retryAnswer = port.latest();
    expect(retryAnswer).toMatchObject({ type: 'answer', status: 'done', text: 'First answer' });
    if (!('requestId' in retryAnswer) || !('requestId' in stoppedRequest)) throw new Error('No answer envelope');
    expect(retryAnswer.requestId).not.toBe(stoppedRequest.requestId);
    port.command('stop', {}, stoppedRequest);
    handlers.onThinking();
    handlers.onDelta('Stale answer');
    pending.resolve({ text: 'Stale answer', history: [] });
    await flush();
    expect(port.latest()).toBe(retryAnswer);
    port.command('close');
    expectDisconnected(port);
    expect(vi.getTimerCount()).toBe(0);
    expect(JSON.stringify(port.sent)).not.toMatch(/sk-ant|Private guidance|history/);
    expectNoPageFallback(harness);
  });

  it('isolates concurrent conversations, rejects cross-session commands, and releases the session cap', async () => {
    const harness = await setup();
    dependencies.analyzeImage.mockResolvedValueOnce({ text: 'First session answer', history: [] })
      .mockResolvedValueOnce({ text: 'Second session answer', history: [] });
    const first = await acceptCapture(harness);
    const second = await acceptCapture(harness);
    await acceptCapture(harness);
    const fourth = await acceptCapture(harness);
    harness.clicked.emit(sourceTab);
    await flush();
    expect(harness.runtime.connectNative).toHaveBeenCalledTimes(4);
    expect(harness.tabs.captureVisibleTab).toHaveBeenCalledTimes(4);
    expect(harness.action.setTitle).toHaveBeenCalledWith({ tabId: 7,
      title: 'Close a native SnapScreen window before starting another capture.' });
    const foreign = second.latest();
    if (!('sessionId' in foreign)) throw new Error('No second session');
    first.command('followup', { text: 'Cross-session question', sessionId: foreign.sessionId,
      requestId: foreign.requestId });
    await flush();
    expect(dependencies.followUp).not.toHaveBeenCalled();
    const pending = deferred<{ text: string; history: [] }>();
    dependencies.followUp.mockReturnValueOnce(pending.promise);
    first.command('followup', { text: 'First question' });
    second.command('followup', { text: 'Second question' });
    await flush();
    expect(dependencies.followUp).toHaveBeenCalledTimes(2);
    const firstHistory = JSON.stringify(dependencies.followUp.mock.calls[0][2]);
    const secondHistory = JSON.stringify(dependencies.followUp.mock.calls[1][2]);
    expect(firstHistory).toContain('First session answer');
    expect(firstHistory).not.toContain('Second session answer');
    expect(secondHistory).toContain('Second session answer');
    expect(secondHistory).not.toContain('First session answer');
    first.command('stop');
    expect(dependencies.followUp.mock.calls[0][3].signal.aborted).toBe(true);
    expect(dependencies.followUp.mock.calls[1][3].signal.aborted).toBe(false);
    expect(second.latest()).toMatchObject({ type: 'answer', status: 'done' });
    pending.resolve({ text: 'Late first follow-up', history: [] });
    await flush();
    fourth.command('close');
    expectDisconnected(fourth);
    const replacement = await acceptCapture(harness);
    expect(harness.runtime.connectNative).toHaveBeenCalledTimes(5);
    expect(replacement.latest()).toMatchObject({ type: 'answer', status: 'done' });
    expect(first.disconnect).not.toHaveBeenCalled();
    expect(second.disconnect).not.toHaveBeenCalled();
    expectNoPageFallback(harness);
  });

  it('supersedes only unfinished selections and retains accepted conversations on the same tab', async () => {
    const harness = await setup();
    const accepted = await acceptCapture(harness);
    harness.clicked.emit(sourceTab);
    await flush();
    const superseded = harness.ports[1];
    const oldSelection = superseded.latest();
    harness.clicked.emit(sourceTab);
    await flush();
    const current = harness.ports[2];
    expectDisconnected(superseded);
    expect(superseded.latest()).toMatchObject({ type: 'expired' });
    expect(accepted.disconnect).not.toHaveBeenCalled();
    superseded.command('selected', { rect: { x: 0, y: 0, width: 1, height: 1 } }, oldSelection);
    accepted.command('followup', { text: 'Continue the accepted capture' });
    await flush();
    expect(dependencies.analyzeImage).toHaveBeenCalledOnce();
    expect(dependencies.followUp).toHaveBeenCalledOnce();
    expect(current.latest()).toMatchObject({ type: 'capture' });
    current.command('cancelled');
    expectDisconnected(current);
    expect(harness.action.setBadgeText).not.toHaveBeenCalled();
    expectNoPageFallback(harness);
  });

  it('expires idle selections and cancels their timers and callbacks without reconnecting', async () => {
    const harness = await setup();
    harness.clicked.emit(sourceTab);
    await flush();
    const capture = harness.port.latest();
    await vi.advanceTimersByTimeAsync(120_000);
    expect(harness.port.latest()).toMatchObject({ type: 'expired' });
    expectDisconnected(harness.port);
    harness.port.command('selected', { rect: { x: 0, y: 0, width: 1, height: 1 } }, capture);
    await vi.advanceTimersByTimeAsync(120_000);
    expect(dependencies.analyzeImage).not.toHaveBeenCalled();
    expect(harness.runtime.connectNative).toHaveBeenCalledOnce();
    expect(harness.action.setBadgeText).not.toHaveBeenCalled();
    expect(vi.getTimerCount()).toBe(0);
    expectNoPageFallback(harness);
  });
});
