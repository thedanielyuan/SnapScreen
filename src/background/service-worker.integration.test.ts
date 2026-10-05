import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { CsToBgMessage } from '../lib/messages';
import {
  UI_CLAIM_CAPABILITY,
  UI_REGISTER_CAPABILITY,
  type UiAttestationMessage,
} from '../lib/ui-protocol';
import {
  WORKSPACE_PATH,
  WORKSPACE_PORT_NAME,
  type BackgroundToWorkspaceMessage,
  type WorkspaceToBackgroundMessage,
} from '../lib/workspace-protocol';

const dependencies = vi.hoisted(() => ({
  analyzeImage: vi.fn(),
  cropImage: vi.fn(),
  fitHistoryScreenshotsToLimits: vi.fn(),
  fitScreenshotToLimits: vi.fn(),
  followUp: vi.fn(),
  getSettings: vi.fn(),
  initializeStorageAccess: vi.fn(),
}));

const testLimits = {
  maxInputCharacters: 4_000,
  maxScreenshotBytes: 5_242_880,
  maxScreenshotDimension: 2_576,
  maxConversationTurns: 12,
};

vi.mock('../content/index.ts?script&iife', () => ({ default: 'content-script.js' }));
vi.mock('../content/overlay.css?inline', () => ({ default: '/* content styles */' }));
vi.mock('../lib/crop', () => ({
  cropImage: dependencies.cropImage,
  fitHistoryScreenshotsToLimits: dependencies.fitHistoryScreenshotsToLimits,
  fitScreenshotToLimits: dependencies.fitScreenshotToLimits,
}));
vi.mock('../lib/storage', () => ({
  getSettings: dependencies.getSettings,
  initializeStorageAccess: dependencies.initializeStorageAccess,
  normalizeLimits: (limits: unknown) => limits,
}));
vi.mock('../lib/anthropic', () => ({
  analyzeImage: dependencies.analyzeImage,
  followUp: dependencies.followUp,
  AnthropicError: class AnthropicError extends Error {
    constructor(
      public code: string,
      message: string,
    ) {
      super(message);
    }
  },
}));

class FakeEvent<TArgs extends unknown[]> {
  readonly listeners: Array<(...args: TArgs) => unknown> = [];

  addListener = (listener: (...args: TArgs) => unknown): void => {
    this.listeners.push(listener);
  };

  emit(...args: TArgs): unknown[] {
    return this.listeners.map((listener) => listener(...args));
  }
}

class FakePort {
  readonly disconnect: ReturnType<typeof vi.fn>;
  readonly onDisconnect = new FakeEvent<[chrome.runtime.Port]>();
  readonly onMessage = new FakeEvent<[unknown, chrome.runtime.Port]>();
  readonly port: chrome.runtime.Port;
  readonly postMessage = vi.fn();
  private disconnected = false;

  constructor(
    sender: chrome.runtime.MessageSender,
    name = WORKSPACE_PORT_NAME,
  ) {
    this.disconnect = vi.fn(() => {
      if (this.disconnected) return;
      this.disconnected = true;
      this.onDisconnect.emit(this.port);
    });
    this.port = {
      disconnect: this.disconnect,
      name,
      onDisconnect: this.onDisconnect,
      onMessage: this.onMessage,
      postMessage: this.postMessage,
      sender,
    } as unknown as chrome.runtime.Port;
  }

  send(message: WorkspaceToBackgroundMessage): void {
    this.onMessage.emit(message, this.port);
  }
}

interface WorkerHarness {
  actionClicked: FakeEvent<[chrome.tabs.Tab]>;
  command: FakeEvent<[string, chrome.tabs.Tab]>;
  installed: FakeEvent<[chrome.runtime.InstalledDetails]>;
  connect: FakeEvent<[chrome.runtime.Port]>;
  message: FakeEvent<[
    unknown,
    chrome.runtime.MessageSender,
    (response?: unknown) => void,
  ]>;
  removed: FakeEvent<[number, chrome.tabs.OnRemovedInfo]>;
  updated: FakeEvent<[number, chrome.tabs.OnUpdatedInfo, chrome.tabs.Tab]>;
  tabs: {
    captureVisibleTab: ReturnType<typeof vi.fn>;
    create: ReturnType<typeof vi.fn>;
    get: ReturnType<typeof vi.fn>;
    query: ReturnType<typeof vi.fn>;
    remove: ReturnType<typeof vi.fn>;
    sendMessage: ReturnType<typeof vi.fn>;
    update: ReturnType<typeof vi.fn>;
  };
  action: {
    setBadgeText: ReturnType<typeof vi.fn>;
    setTitle: ReturnType<typeof vi.fn>;
  };
  scripting: {
    executeScript: ReturnType<typeof vi.fn>;
    insertCSS: ReturnType<typeof vi.fn>;
  };
  extension: {
    isAllowedFileSchemeAccess: ReturnType<typeof vi.fn>;
  };
  permissions: {
    request: ReturnType<typeof vi.fn>;
  };
  storage: {
    get: ReturnType<typeof vi.fn>;
    remove: ReturnType<typeof vi.fn>;
    set: ReturnType<typeof vi.fn>;
  };
}

interface Deferred<T> {
  promise: Promise<T>;
  reject: (reason?: unknown) => void;
  resolve: (value: T) => void;
}

function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, reject, resolve };
}

function trustedSender(overrides: Partial<chrome.runtime.MessageSender> = {}): chrome.runtime.MessageSender {
  return {
    id: 'test-extension',
    documentId: 'document-1',
    frameId: 0,
    origin: 'https://example.test',
    url: 'https://example.test/question',
    tab: {
      id: 7,
      index: 0,
      pinned: false,
      highlighted: true,
      active: true,
      incognito: false,
      selected: true,
      discarded: false,
      frozen: false,
      autoDiscardable: true,
      groupId: -1,
      windowId: 2,
      url: 'https://example.test/question',
    },
    ...overrides,
  };
}

function trustedUiFrameSender(
  overrides: Partial<chrome.runtime.MessageSender> = {},
): chrome.runtime.MessageSender {
  return trustedSender({
    documentId: 'ui-document-1',
    frameId: 4,
    origin: 'chrome-extension://test-extension',
    url: 'chrome-extension://test-extension/src/ui/result-frame.html',
    ...overrides,
  });
}

function trustedWorkspaceSender(
  tabId = 70,
  url = `chrome-extension://test-extension/${WORKSPACE_PATH}`,
): chrome.runtime.MessageSender {
  return {
    id: 'test-extension',
    documentId: 'workspace-document-1',
    frameId: 0,
    origin: 'chrome-extension://test-extension',
    url,
    tab: {
      ...trustedSender().tab!,
      id: tabId,
      url,
    },
  };
}

async function loadWorker(): Promise<WorkerHarness> {
  vi.resetModules();

  const installed = new FakeEvent<[chrome.runtime.InstalledDetails]>();
  const actionClicked = new FakeEvent<[chrome.tabs.Tab]>();
  const command = new FakeEvent<[string, chrome.tabs.Tab]>();
  const message = new FakeEvent<[
    unknown,
    chrome.runtime.MessageSender,
    (response?: unknown) => void,
  ]>();
  const connect = new FakeEvent<[chrome.runtime.Port]>();
  const removed = new FakeEvent<[number, chrome.tabs.OnRemovedInfo]>();
  const activated = new FakeEvent<[chrome.tabs.OnActivatedInfo]>();
  const updated = new FakeEvent<[number, chrome.tabs.OnUpdatedInfo, chrome.tabs.Tab]>();

  const tabs = {
    captureVisibleTab: vi.fn(async () => 'data:image/png;base64,FULL'),
    create: vi.fn(async () => ({ id: 70, windowId: 2 })),
    get: vi.fn(async (tabId: number) => ({
      ...trustedSender().tab!,
      id: tabId,
    })),
    query: vi.fn(async () => [{ id: 7, windowId: 2, active: true }]),
    remove: vi.fn(async () => undefined),
    sendMessage: vi.fn(async () => undefined),
    update: vi.fn(async (tabId: number) => ({ id: tabId, windowId: 2, active: true })),
  };
  const action = {
    setBadgeText: vi.fn(async () => undefined),
    setTitle: vi.fn(async () => undefined),
  };
  const scripting = {
    executeScript: vi.fn(async () => [{
      documentId: 'document-1',
      frameId: 0,
      result: undefined,
    }]),
    insertCSS: vi.fn(async () => undefined),
  };
  const extension = {
    isAllowedFileSchemeAccess: vi.fn(async () => true),
  };
  const permissions = {
    request: vi.fn(async () => true),
  };
  const storage = {
    get: vi.fn(async () => ({})),
    remove: vi.fn(async () => undefined),
    set: vi.fn(async () => undefined),
  };

  vi.stubGlobal('chrome', {
    runtime: {
      getURL: (path: string) => `chrome-extension://test-extension/${path}`,
      id: 'test-extension',
      onConnect: connect,
      onInstalled: installed,
      onMessage: message,
      openOptionsPage: vi.fn(async () => undefined),
    },
    extension,
    permissions,
    storage: {
      session: storage,
    },
    action: {
      onClicked: actionClicked,
      ...action,
    },
    commands: { onCommand: command },
    scripting,
    tabs: {
      ...tabs,
      onActivated: activated,
      onRemoved: removed,
      onUpdated: updated,
    },
  });

  await import('./service-worker');
  expect(message.listeners).toHaveLength(1);

  return {
    actionClicked,
    action,
    command,
    connect,
    extension,
    installed,
    message,
    permissions,
    removed,
    scripting,
    storage,
    updated,
    tabs,
  };
}

function dispatch(
  harness: WorkerHarness,
  request: CsToBgMessage | UiAttestationMessage,
  sender = trustedSender(),
): Promise<unknown> {
  const listener = harness.message.listeners[0];
  if (!listener) throw new Error('Background message listener was not registered.');

  return new Promise((resolve, reject) => {
    let responded = false;
    const timeout = setTimeout(
      () => reject(new Error(`Background did not respond to ${request.type}.`)),
      2_000,
    );
    const sendResponse = (response?: unknown): void => {
      if (responded) return;
      responded = true;
      clearTimeout(timeout);
      resolve(response);
    };

    const keepChannelOpen = listener(request, sender, sendResponse);
    if (keepChannelOpen !== true && !responded) {
      clearTimeout(timeout);
      resolve(undefined);
    }
  });
}

function captureRequest(
  captureId: string,
): Extract<CsToBgMessage, { type: 'CAPTURE_REGION' }> {
  return {
    type: 'CAPTURE_REGION',
    captureId,
    dataUrl: `data:image/png;base64,FULL_${captureId}`,
    selection: {
      viewportRect: { x: 10, y: 20, width: 100, height: 50 },
      normalizedRect: { x: 0.1, y: 0.2, width: 0.5, height: 0.25 },
    },
  };
}

function analyzeRequest(
  captureId: string,
  requestId: string,
  dataUrl = `data:image/png;base64,${requestId}`,
  sessionSettings = {
    defaultPrompt: 'Answer the question.',
    limits: testLimits,
  },
): CsToBgMessage {
  return {
    type: 'ANALYZE',
    captureId,
    dataUrl,
    requestId,
    screenshotId: `screenshot-${captureId}`,
    sessionSettings,
  };
}

function rejectWhenAborted(signal: AbortSignal): Promise<never> {
  return new Promise((_, reject) => {
    const abort = (): void => {
      reject(signal.reason ?? new DOMException('Aborted', 'AbortError'));
    };
    if (signal.aborted) {
      abort();
      return;
    }
    signal.addEventListener('abort', abort, { once: true });
  });
}

async function openRestrictedWorkspace(
  harness: WorkerHarness,
  sourceUrl = 'chrome://settings',
): Promise<{ nonce: string; sessionId: string; sourceTab: chrome.tabs.Tab }> {
  const sourceTab = { ...trustedSender().tab!, url: sourceUrl };
  harness.tabs.sendMessage.mockRejectedValue(new Error('No receiver'));
  harness.scripting.executeScript.mockRejectedValue(new Error('Cannot inject'));
  harness.tabs.get.mockImplementation(async (tabId: number) => (
    tabId === sourceTab.id
      ? sourceTab
      : { ...trustedWorkspaceSender(tabId).tab!, id: tabId }
  ));

  harness.actionClicked.emit(sourceTab);
  await vi.waitFor(() => expect(harness.tabs.create).toHaveBeenCalledTimes(1));
  await vi.waitFor(() => expect(harness.storage.set).toHaveBeenCalled());
  const createProperties = harness.tabs.create.mock.calls[0]?.[0] as {
    url?: string;
  };
  const workspaceUrl = new URL(createProperties.url!);
  const params = new URLSearchParams(workspaceUrl.hash.slice(1));
  const nonce = params.get('nonce');
  const sessionId = params.get('session');
  if (!nonce || !sessionId) throw new Error('Workspace capability was not created.');
  return { nonce, sessionId, sourceTab };
}

async function claimWorkspace(
  harness: WorkerHarness,
  sessionId: string,
  nonce: string,
): Promise<{ port: FakePort; ready: Extract<BackgroundToWorkspaceMessage, {
  type: 'SNAPSCREEN_WORKSPACE_READY';
}> }> {
  const port = new FakePort(trustedWorkspaceSender());
  harness.connect.emit(port.port);
  port.send({
    type: 'SNAPSCREEN_WORKSPACE_CLAIM',
    sessionId,
    nonce,
    needsInitialState: true,
  });
  await vi.waitFor(() => expect(port.postMessage).toHaveBeenCalled());
  const ready = port.postMessage.mock.calls
    .map(([message]) => message as BackgroundToWorkspaceMessage)
    .find((message) => message.type === 'SNAPSCREEN_WORKSPACE_READY');
  if (!ready || ready.type !== 'SNAPSCREEN_WORKSPACE_READY') {
    throw new Error('Workspace did not receive its ready envelope.');
  }
  return { port, ready };
}

beforeEach(() => {
  dependencies.analyzeImage.mockReset().mockResolvedValue({
    history: [],
    text: 'Answer',
  });
  dependencies.cropImage.mockReset().mockResolvedValue(
    'data:image/png;base64,CROPPED',
  );
  dependencies.fitHistoryScreenshotsToLimits.mockReset().mockImplementation(
    async (history: unknown) => history,
  );
  dependencies.fitScreenshotToLimits.mockReset().mockImplementation(
    async (dataUrl: string) => dataUrl,
  );
  dependencies.followUp.mockReset().mockResolvedValue({
    history: [],
    text: 'Follow-up answer',
  });
  dependencies.getSettings.mockReset().mockResolvedValue({
    apiKey: 'sk-ant-test-secret',
    defaultPrompt: 'Answer the question.',
    limits: testLimits,
  });
  dependencies.initializeStorageAccess.mockReset().mockResolvedValue(undefined);
});

afterEach(() => {
  vi.clearAllTimers();
  vi.unstubAllGlobals();
});

describe('service worker message integration', () => {
  it('uses the initiating session settings for analysis and follow-ups', async () => {
    const harness = await loadWorker();
    const sessionSettings = {
      defaultPrompt: 'Keep the original session guidance.',
      limits: {
        ...testLimits,
        maxInputCharacters: 1_500,
        maxConversationTurns: 4,
      },
    };
    dependencies.getSettings.mockResolvedValue({
      apiKey: 'sk-ant-current-secret',
      defaultPrompt: 'Changed after the snip started.',
      limits: {
        ...testLimits,
        maxInputCharacters: 100,
        maxConversationTurns: 2,
      },
    });

    await dispatch(harness, analyzeRequest(
      'capture-session',
      'request-analyze-session',
      'data:image/png;base64,SESSION',
      sessionSettings,
    ));

    expect(dependencies.analyzeImage).toHaveBeenCalledWith(
      'sk-ant-current-secret',
      'data:image/png;base64,SESSION',
      expect.objectContaining({
        hiddenInstruction: sessionSettings.defaultPrompt,
        limits: sessionSettings.limits,
      }),
    );

    const history = [
      { role: 'user' as const, content: 'Initial question' },
      { role: 'assistant' as const, content: 'Initial answer' },
    ];
    await dispatch(harness, {
      type: 'FOLLOW_UP',
      captureId: 'capture-session',
      history,
      requestId: 'request-follow-up-session',
      screenshotId: 'screenshot-capture-session',
      sessionSettings,
      text: 'Why?',
    });

    expect(dependencies.followUp).toHaveBeenCalledWith(
      'sk-ant-current-secret',
      'Why?',
      history,
      expect.objectContaining({
        sessionInstruction: sessionSettings.defaultPrompt,
        limits: sessionSettings.limits,
      }),
    );
    expect(JSON.stringify(sessionSettings)).not.toContain('sk-ant-current-secret');
  });

  it('sends the screenshot fitted to the session limits', async () => {
    const harness = await loadWorker();
    dependencies.fitScreenshotToLimits.mockResolvedValueOnce('data:image/png;base64,FITTED');

    await dispatch(harness, analyzeRequest(
      'capture-fit',
      'request-fit',
      'data:image/png;base64,LARGE',
    ));

    expect(dependencies.fitScreenshotToLimits).toHaveBeenCalledWith(
      'data:image/png;base64,LARGE',
      testLimits,
    );
    expect(dependencies.analyzeImage).toHaveBeenCalledWith(
      'sk-ant-test-secret',
      'data:image/png;base64,FITTED',
      expect.objectContaining({ limits: testLimits }),
    );
  });

  it('sends follow-up history with its screenshots fitted to the session limits', async () => {
    const harness = await loadWorker();
    const history = [
      { role: 'user' as const, content: 'Full-size screenshot turn' },
      { role: 'assistant' as const, content: 'Interrupted answer' },
    ];
    const fitted = [
      { role: 'user' as const, content: 'Fitted screenshot turn' },
      { role: 'assistant' as const, content: 'Interrupted answer' },
    ];
    dependencies.fitHistoryScreenshotsToLimits.mockResolvedValueOnce(fitted);

    await dispatch(harness, {
      type: 'FOLLOW_UP',
      captureId: 'capture-fit',
      history,
      requestId: 'request-fit-follow-up',
      screenshotId: 'screenshot-capture-fit',
      sessionSettings: { defaultPrompt: 'Answer the question.', limits: testLimits },
      text: 'Go on.',
    });

    expect(dependencies.fitHistoryScreenshotsToLimits).toHaveBeenCalledWith(
      history,
      testLimits,
    );
    expect(dependencies.followUp).toHaveBeenCalledWith(
      'sk-ant-test-secret',
      'Go on.',
      fitted,
      expect.objectContaining({ limits: testLimits }),
    );
  });

  it('correlates capture delivery to the initiating document', async () => {
    const harness = await loadWorker();

    await expect(dispatch(harness, captureRequest('capture-1'))).resolves.toEqual({
      ok: true,
    });

    expect(harness.tabs.captureVisibleTab).not.toHaveBeenCalled();
    expect(dependencies.cropImage).toHaveBeenCalledWith(
      'data:image/png;base64,FULL_capture-1',
      { x: 0.1, y: 0.2, width: 0.5, height: 0.25 },
    );
    expect(harness.tabs.sendMessage).toHaveBeenCalledWith(
      7,
      {
        type: 'CROPPED_IMAGE',
        captureId: 'capture-1',
        dataUrl: 'data:image/png;base64,CROPPED',
      },
      { documentId: 'document-1' },
    );
  });

  it('accepts controller messages from an opted-in top-level file document', async () => {
    const harness = await loadWorker();
    const fileUrl = 'file:///tmp/question.html';
    const sender = trustedSender({
      origin: 'file://',
      url: fileUrl,
      tab: { ...trustedSender().tab!, url: fileUrl },
    });

    await expect(dispatch(
      harness,
      captureRequest('file-capture'),
      sender,
    )).resolves.toEqual({ ok: true });
    expect(harness.tabs.sendMessage).toHaveBeenCalledWith(
      7,
      expect.objectContaining({
        type: 'CROPPED_IMAGE',
        captureId: 'file-capture',
      }),
      { documentId: 'document-1' },
    );
  });

  it('drops an in-flight capture when the tab starts navigating', async () => {
    const crop = deferred<string>();
    const harness = await loadWorker();
    dependencies.cropImage.mockReturnValueOnce(crop.promise);

    const response = dispatch(harness, captureRequest('capture-before-navigation'));
    await vi.waitFor(() => expect(dependencies.cropImage).toHaveBeenCalledOnce());

    harness.updated.emit(
      7,
      { status: 'loading' },
      trustedSender().tab!,
    );
    crop.resolve('data:image/png;base64,OLD_PAGE');

    await expect(response).resolves.toEqual({ ok: false, stale: true });
    expect(harness.tabs.sendMessage).not.toHaveBeenCalled();
  });

  it('delivers only the newest overlapping capture', async () => {
    const firstCrop = deferred<string>();
    const harness = await loadWorker();
    dependencies.cropImage
      .mockReturnValueOnce(firstCrop.promise)
      .mockResolvedValueOnce('data:image/png;base64,CROP_SECOND');

    const firstResponse = dispatch(harness, captureRequest('capture-1'));
    await vi.waitFor(() => expect(dependencies.cropImage).toHaveBeenCalledOnce());
    const secondResponse = dispatch(harness, captureRequest('capture-2'));

    await expect(secondResponse).resolves.toEqual({ ok: true });
    firstCrop.resolve('data:image/png;base64,CROP_FIRST');
    await expect(firstResponse).resolves.toEqual({ ok: false, stale: true });

    expect(harness.tabs.sendMessage).toHaveBeenCalledTimes(1);
    expect(harness.tabs.sendMessage).toHaveBeenCalledWith(
      7,
      expect.objectContaining({
        type: 'CROPPED_IMAGE',
        captureId: 'capture-2',
        dataUrl: 'data:image/png;base64,CROP_SECOND',
      }),
      { documentId: 'document-1' },
    );
  });

  it('cancels the matching generation on request and acknowledges the abort', async () => {
    const harness = await loadWorker();
    dependencies.analyzeImage.mockImplementation(
      async (_apiKey: string, _dataUrl: string, options: { signal: AbortSignal }) =>
        rejectWhenAborted(options.signal),
    );

    const analysis = dispatch(
      harness,
      analyzeRequest('capture-1', 'request-1'),
    );
    await vi.waitFor(() => expect(dependencies.analyzeImage).toHaveBeenCalledOnce());

    await expect(dispatch(harness, {
      type: 'CANCEL_GENERATION',
      captureId: 'capture-1',
      requestId: 'request-1',
    })).resolves.toEqual({ ok: true });
    await expect(analysis).resolves.toEqual({ ok: false, aborted: true });
    expect(harness.tabs.sendMessage).not.toHaveBeenCalled();
  });

  it('aborts active generation work when its tab closes', async () => {
    const harness = await loadWorker();
    dependencies.analyzeImage.mockImplementation(
      async (_apiKey: string, _dataUrl: string, options: { signal: AbortSignal }) =>
        rejectWhenAborted(options.signal),
    );

    const analysis = dispatch(
      harness,
      analyzeRequest('capture-1', 'request-tab-close'),
    );
    await vi.waitFor(() => expect(dependencies.analyzeImage).toHaveBeenCalledOnce());

    harness.removed.emit(7, { isWindowClosing: false, windowId: 2 });

    await expect(analysis).resolves.toEqual({ ok: false, aborted: true });
    expect(harness.tabs.sendMessage).not.toHaveBeenCalled();
  });

  it('acknowledges a generation abort when its document starts navigating', async () => {
    const harness = await loadWorker();
    dependencies.analyzeImage.mockImplementation(
      async (_apiKey: string, _dataUrl: string, options: { signal: AbortSignal }) =>
        rejectWhenAborted(options.signal),
    );

    const analysis = dispatch(
      harness,
      analyzeRequest('capture-1', 'request-navigation'),
    );
    await vi.waitFor(() => expect(dependencies.analyzeImage).toHaveBeenCalledOnce());

    harness.updated.emit(
      7,
      { status: 'loading', url: 'https://example.test/next-question' },
      trustedSender().tab!,
    );

    await expect(analysis).resolves.toEqual({ ok: false, aborted: true });
    expect(harness.tabs.sendMessage).not.toHaveBeenCalled();
  });

  it('keeps generation alive across same-document URL updates', async () => {
    const result = deferred<{ text: string; history: [] }>();
    const harness = await loadWorker();
    dependencies.analyzeImage.mockReturnValueOnce(result.promise);

    const analysis = dispatch(
      harness,
      analyzeRequest('capture-1', 'request-same-document'),
    );
    await vi.waitFor(() => expect(dependencies.analyzeImage).toHaveBeenCalledOnce());

    harness.updated.emit(
      7,
      { url: 'https://example.test/question#solution' },
      trustedSender().tab!,
    );
    result.resolve({ text: 'Still valid', history: [] });

    await expect(analysis).resolves.toEqual({ ok: true });
    expect(harness.tabs.sendMessage).toHaveBeenCalledWith(
      7,
      expect.objectContaining({
        type: 'ANALYZE_RESULT',
        text: 'Still valid',
      }),
      { documentId: 'document-1' },
    );
  });

  it('tells the originating document when the model starts thinking', async () => {
    const harness = await loadWorker();
    dependencies.analyzeImage.mockImplementationOnce(
      async (_apiKey: string, _dataUrl: string, options: { onThinking?: () => void }) => {
        options.onThinking?.();
        return { history: [], text: 'Answer' };
      },
    );

    await dispatch(harness, analyzeRequest('capture-1', 'request-thinking'));

    expect(harness.tabs.sendMessage).toHaveBeenCalledWith(
      7,
      {
        type: 'ANALYZE_THINKING',
        captureId: 'capture-1',
        requestId: 'request-thinking',
        screenshotId: 'screenshot-capture-1',
      },
      { documentId: 'document-1' },
    );
  });

  it('stops generation when delivery to the originating document fails', async () => {
    const harness = await loadWorker();
    harness.tabs.sendMessage.mockRejectedValueOnce(new Error('Document is gone'));
    dependencies.analyzeImage.mockImplementation(
      async (
        _apiKey: string,
        _dataUrl: string,
        options: { signal: AbortSignal; onDelta?: (text: string) => void },
      ) => {
        options.onDelta?.('Partial answer');
        return rejectWhenAborted(options.signal);
      },
    );

    const analysis = dispatch(
      harness,
      analyzeRequest('capture-1', 'request-delivery-failure'),
    );

    await expect(analysis).resolves.toEqual({ ok: false, aborted: true });
    expect(harness.tabs.sendMessage).toHaveBeenCalledWith(
      7,
      expect.objectContaining({
        type: 'ANALYZE_CHUNK',
        captureId: 'capture-1',
        requestId: 'request-delivery-failure',
      }),
      { documentId: 'document-1' },
    );
  });

  it('does not let a stale snip cancellation abort a newer capture generation', async () => {
    const result = deferred<{ history: []; text: string }>();
    const harness = await loadWorker();
    dependencies.analyzeImage.mockReturnValueOnce(result.promise);

    const analysis = dispatch(
      harness,
      analyzeRequest('capture-new', 'request-new'),
    );
    await vi.waitFor(() => expect(dependencies.analyzeImage).toHaveBeenCalledOnce());

    await expect(dispatch(harness, {
      type: 'SNIP_CANCELLED',
      captureId: 'capture-old',
    })).resolves.toEqual({ ok: true });
    result.resolve({ history: [], text: 'New answer' });

    await expect(analysis).resolves.toEqual({ ok: true });
    expect(harness.tabs.sendMessage).toHaveBeenCalledWith(
      7,
      expect.objectContaining({
        type: 'ANALYZE_RESULT',
        captureId: 'capture-new',
        requestId: 'request-new',
        text: 'New answer',
      }),
      { documentId: 'document-1' },
    );
  });

  it('aborts an older overlapping generation and delivers only the newer result', async () => {
    const harness = await loadWorker();
    dependencies.analyzeImage.mockImplementation(
      async (
        _apiKey: string,
        dataUrl: string,
        options: { signal: AbortSignal },
      ) => {
        if (dataUrl.includes('request-old')) {
          return rejectWhenAborted(options.signal);
        }
        return { history: [], text: 'Newest answer' };
      },
    );

    const older = dispatch(
      harness,
      analyzeRequest('capture-1', 'request-old'),
    );
    await vi.waitFor(() => expect(dependencies.analyzeImage).toHaveBeenCalledOnce());
    const newer = dispatch(
      harness,
      analyzeRequest('capture-1', 'request-new'),
    );

    await expect(older).resolves.toEqual({ ok: false, aborted: true });
    await expect(newer).resolves.toEqual({ ok: true });
    const resultMessages = harness.tabs.sendMessage.mock.calls
      .map((call) => call[1] as { type?: string; requestId?: string })
      .filter((message) => message.type === 'ANALYZE_RESULT');
    expect(resultMessages).toEqual([
      expect.objectContaining({ requestId: 'request-new' }),
    ]);
  });

  it('ignores messages that do not originate from this extension', async () => {
    const harness = await loadWorker();
    const sender = trustedSender({ id: 'untrusted-extension' });

    await expect(
      dispatch(harness, captureRequest('capture-untrusted'), sender),
    ).resolves.toBeUndefined();
    expect(harness.tabs.captureVisibleTab).not.toHaveBeenCalled();
    expect(dependencies.analyzeImage).not.toHaveBeenCalled();
  });

  it('rejects normal worker commands from a web-accessible extension frame', async () => {
    const harness = await loadWorker();

    await expect(dispatch(
      harness,
      captureRequest('capture-from-war-frame'),
      trustedUiFrameSender(),
    )).resolves.toBeUndefined();

    expect(harness.tabs.captureVisibleTab).not.toHaveBeenCalled();
    expect(dependencies.cropImage).not.toHaveBeenCalled();
  });

  it('attests a registered UI capability once in the same tab', async () => {
    const harness = await loadWorker();
    const nonce = 'a'.repeat(43);
    const register: UiAttestationMessage = {
      type: UI_REGISTER_CAPABILITY,
      sessionId: 'session-attested',
      nonce,
    };
    const claim: UiAttestationMessage = {
      type: UI_CLAIM_CAPABILITY,
      sessionId: 'session-attested',
      nonce,
    };

    await expect(dispatch(harness, register)).resolves.toEqual({ ok: true });
    await expect(dispatch(
      harness,
      claim,
      trustedUiFrameSender(),
    )).resolves.toEqual({ ok: true });
    await expect(dispatch(
      harness,
      claim,
      trustedUiFrameSender({ documentId: 'ui-replay-document' }),
    )).resolves.toEqual({ ok: false, error: 'ui_auth_failed' });
  });

  it('rejects unregistered, cross-tab, and wrong-context UI claims generically', async () => {
    const harness = await loadWorker();
    const nonce = 'b'.repeat(43);
    const claim: UiAttestationMessage = {
      type: UI_CLAIM_CAPABILITY,
      sessionId: 'session-isolated',
      nonce,
    };

    await expect(dispatch(
      harness,
      claim,
      trustedUiFrameSender(),
    )).resolves.toEqual({ ok: false, error: 'ui_auth_failed' });

    await expect(dispatch(harness, {
      type: UI_REGISTER_CAPABILITY,
      sessionId: 'session-isolated',
      nonce,
    })).resolves.toEqual({ ok: true });

    const otherTab = {
      ...trustedSender().tab!,
      id: 8,
    };
    await expect(dispatch(
      harness,
      claim,
      trustedUiFrameSender({ tab: otherTab }),
    )).resolves.toEqual({ ok: false, error: 'ui_auth_failed' });
    await expect(dispatch(
      harness,
      claim,
      trustedSender(),
    )).resolves.toEqual({ ok: false, error: 'ui_auth_failed' });
    await expect(dispatch(
      harness,
      {
        type: UI_REGISTER_CAPABILITY,
        sessionId: 'frame-cannot-register',
        nonce,
      },
      trustedUiFrameSender(),
    )).resolves.toEqual({ ok: false, error: 'ui_auth_failed' });

    // Failed claims do not consume the valid capability.
    await expect(dispatch(
      harness,
      claim,
      trustedUiFrameSender(),
    )).resolves.toEqual({ ok: true });
  });

  it('starts snipping from one cold toolbar invocation', async () => {
    const harness = await loadWorker();
    const tab = trustedSender().tab!;

    harness.actionClicked.emit(tab);
    await vi.waitFor(() => {
      expect(harness.tabs.sendMessage).toHaveBeenCalledWith(
        7,
        expect.objectContaining({
          type: 'START_SNIP',
          dataUrl: 'data:image/png;base64,FULL',
          defaultPrompt: 'Answer the question.',
          limits: testLimits,
        }),
        { documentId: 'document-1' },
      );
    });

    expect(harness.tabs.sendMessage).toHaveBeenNthCalledWith(
      1,
      7,
      { type: 'PREPARE_SNIP_CAPTURE' },
      { frameId: 0 },
    );
    expect(harness.tabs.captureVisibleTab).toHaveBeenCalledWith(2, { format: 'png' });
    const prepareOrder = harness.tabs.sendMessage.mock.invocationCallOrder[0];
    const captureOrder = harness.tabs.captureVisibleTab.mock.invocationCallOrder[0];
    const startOrder = harness.tabs.sendMessage.mock.invocationCallOrder[1];
    expect(prepareOrder).toBeLessThan(captureOrder);
    expect(captureOrder).toBeLessThan(startOrder);
    expect(harness.scripting.executeScript).toHaveBeenCalledWith({
      target: { tabId: 7 },
      files: ['content-script.js'],
    });
    expect(harness.scripting.insertCSS).not.toHaveBeenCalled();
    expect(JSON.stringify(harness.tabs.sendMessage.mock.calls)).not.toContain(
      'sk-ant-test-secret',
    );

    const startMessage = harness.tabs.sendMessage.mock.calls
      .map(([, message]) => message as { type?: string; captureId?: string })
      .find((message) => message.type === 'START_SNIP');
    const captureId = startMessage?.captureId;
    expect(captureId).toBeTypeOf('string');
    await expect(dispatch(harness, {
      ...captureRequest(captureId!),
      dataUrl: 'data:image/png;base64,CONTENT_FALLBACK',
    })).resolves.toEqual({ ok: true });
    expect(dependencies.cropImage).toHaveBeenLastCalledWith(
      'data:image/png;base64,FULL',
      { x: 0.1, y: 0.2, width: 0.5, height: 0.25 },
    );
  });

  it('starts snipping from one cold shortcut invocation', async () => {
    const harness = await loadWorker();

    harness.command.emit('snip', trustedSender().tab!);

    await vi.waitFor(() => {
      expect(harness.tabs.sendMessage).toHaveBeenCalledWith(
        7,
        expect.objectContaining({ type: 'START_SNIP' }),
        { documentId: 'document-1' },
      );
    });
    expect(harness.scripting.executeScript).toHaveBeenCalledTimes(1);
  });

  it('uses the active session settings when requesting a new snip', async () => {
    const harness = await loadWorker();
    const sessionSettings = {
      defaultPrompt: 'Keep this session prompt.',
      limits: { ...testLimits, maxConversationTurns: 4 },
    };

    await expect(dispatch(harness, {
      type: 'REQUEST_SNIP',
      sessionSettings,
    })).resolves.toEqual({ ok: true });

    expect(harness.tabs.sendMessage).toHaveBeenCalledWith(
      7,
      expect.objectContaining({
        type: 'START_SNIP',
        dataUrl: 'data:image/png;base64,FULL',
        defaultPrompt: sessionSettings.defaultPrompt,
        limits: sessionSettings.limits,
      }),
      { documentId: 'document-1' },
    );
  });

  it('waits for slow content initialization before sending START_SNIP', async () => {
    const harness = await loadWorker();
    const initialization = deferred<chrome.scripting.InjectionResult<unknown>[]>();
    harness.scripting.executeScript.mockReturnValueOnce(initialization.promise);

    harness.command.emit('snip', trustedSender().tab!);
    await vi.waitFor(() => {
      expect(harness.scripting.executeScript).toHaveBeenCalledTimes(1);
    });
    expect(harness.tabs.sendMessage).toHaveBeenCalledExactlyOnceWith(
      7,
      { type: 'PREPARE_SNIP_CAPTURE' },
      { frameId: 0 },
    );

    initialization.resolve([{
      documentId: 'document-1',
      frameId: 0,
      result: undefined,
    }]);

    await vi.waitFor(() => {
      expect(harness.tabs.sendMessage).toHaveBeenCalledWith(
        7,
        expect.objectContaining({ type: 'START_SNIP' }),
        { documentId: 'document-1' },
      );
    });
    expect(harness.tabs.sendMessage).toHaveBeenCalledTimes(2);
  });

  it('activates an already-loaded content script exactly once per invocation', async () => {
    const harness = await loadWorker();
    const tab = trustedSender().tab!;

    harness.actionClicked.emit(tab);
    await vi.waitFor(() => {
      expect(harness.tabs.sendMessage).toHaveBeenCalledTimes(2);
    });

    harness.actionClicked.emit(tab);
    await vi.waitFor(() => {
      expect(harness.tabs.sendMessage).toHaveBeenCalledTimes(4);
    });

    expect(harness.scripting.executeScript).toHaveBeenCalledTimes(2);
    expect(harness.tabs.sendMessage.mock.calls.filter(([, message]) => (
      message as { type?: string }
    ).type === 'START_SNIP')).toHaveLength(2);
  });

  it('bounds stalled initialization and falls back to a trusted workspace', async () => {
    vi.useFakeTimers();
    const harness = await loadWorker();
    harness.scripting.executeScript.mockReturnValueOnce(new Promise(() => undefined));
    harness.tabs.sendMessage.mockRejectedValue(new Error('No receiver'));

    harness.actionClicked.emit(trustedSender().tab!);
    await vi.advanceTimersByTimeAsync(0);
    expect(harness.scripting.executeScript).toHaveBeenCalledTimes(1);

    await vi.advanceTimersByTimeAsync(5_000);

    expect(harness.tabs.sendMessage).not.toHaveBeenCalledWith(
      7,
      expect.objectContaining({ type: 'START_SNIP' }),
      expect.anything(),
    );
    expect(harness.tabs.captureVisibleTab).toHaveBeenCalledWith(2, { format: 'png' });
    expect(harness.tabs.create).toHaveBeenCalledWith(expect.objectContaining({
      active: true,
      url: expect.stringContaining('chrome-extension://test-extension/src/workspace/workspace.html#'),
      windowId: 2,
    }));
    expect(harness.action.setBadgeText).not.toHaveBeenCalledWith({ tabId: 7, text: '!' });
  });

  it('does not activate a replacement document after navigation during initialization', async () => {
    const harness = await loadWorker();
    const initialization = deferred<chrome.scripting.InjectionResult<unknown>[]>();
    harness.scripting.executeScript.mockReturnValueOnce(initialization.promise);
    const tab = trustedSender().tab!;

    harness.actionClicked.emit(tab);
    await vi.waitFor(() => {
      expect(harness.scripting.executeScript).toHaveBeenCalledTimes(1);
    });
    harness.updated.emit(7, { status: 'loading' }, {
      ...tab,
      url: 'https://example.test/replacement',
    });
    initialization.resolve([{
      documentId: 'document-2',
      frameId: 0,
      result: undefined,
    }]);

    await vi.waitFor(() => {
      expect(harness.action.setTitle).toHaveBeenCalledWith({
        tabId: 7,
        title: 'SnapScreen did not start because the page changed. Try again on the current page.',
      });
    });
    expect(harness.tabs.sendMessage).not.toHaveBeenCalledWith(
      7,
      expect.objectContaining({ type: 'START_SNIP' }),
      expect.anything(),
    );
  });

  it('uses a trusted workspace for chrome pages that reject content injection', async () => {
    const harness = await loadWorker();
    harness.tabs.sendMessage.mockRejectedValue(new Error('No receiver'));
    harness.scripting.executeScript.mockRejectedValue(new Error('Cannot access chrome://'));
    const restrictedTab = {
      ...trustedSender().tab!,
      url: 'chrome://settings',
    };

    harness.actionClicked.emit(restrictedTab);
    await vi.waitFor(() => {
      expect(harness.tabs.create).toHaveBeenCalledTimes(1);
    });

    expect(harness.tabs.captureVisibleTab).toHaveBeenCalledWith(2, { format: 'png' });
    expect(harness.scripting.executeScript).toHaveBeenCalledTimes(1);
    expect(harness.action.setBadgeText).not.toHaveBeenCalledWith({ tabId: 7, text: '!' });
  });

  it('surfaces isolated-frame startup failures in browser chrome', async () => {
    const harness = await loadWorker();

    await expect(dispatch(harness, { type: 'UI_UNAVAILABLE' })).resolves.toEqual({
      ok: true,
    });

    expect(harness.action.setBadgeText).toHaveBeenCalledWith({
      tabId: 7,
      text: '!',
    });
    expect(harness.action.setTitle).toHaveBeenCalledWith({
      tabId: 7,
      title: 'SnapScreen could not open its isolated UI on this page. Please try again.',
    });
    expect(harness.tabs.sendMessage).not.toHaveBeenCalled();
  });

  it('opens Settings for the content script, which cannot open it itself', async () => {
    const harness = await loadWorker();

    await expect(dispatch(harness, { type: 'OPEN_SETTINGS' })).resolves.toEqual({
      ok: true,
    });

    expect(chrome.runtime.openOptionsPage).toHaveBeenCalledTimes(1);
  });

  it('captures the Chrome Web Store into a trusted workspace', async () => {
    const harness = await loadWorker();
    harness.tabs.sendMessage.mockRejectedValue(new Error('No receiver'));
    harness.scripting.executeScript.mockRejectedValue(new Error('Cannot access Web Store'));

    harness.actionClicked.emit({
      ...trustedSender().tab!,
      url: 'https://chromewebstore.google.com/detail/example/abcdefghijklmnop',
    });
    await vi.waitFor(() => {
      expect(harness.tabs.create).toHaveBeenCalledTimes(1);
    });

    expect(harness.tabs.captureVisibleTab).toHaveBeenCalledTimes(1);
    expect(harness.scripting.executeScript).toHaveBeenCalledTimes(1);
  });

  it.each([
    ['a data URL', 'data:text/html,<h1>Question</h1>'],
    [
      'the built-in PDF viewer',
      'chrome-extension://mhjfbmdgcfjbbpaeojofohoefgiehjai/index.html?file=https://example.test/test.pdf',
    ],
    ['another extension page', 'chrome-extension://abcdefghijklmnop/page.html'],
    ['an unknown injection failure', 'https://example.test/unexpected-policy'],
  ])('falls back to a workspace for %s', async (_label, url) => {
    const harness = await loadWorker();
    harness.tabs.sendMessage.mockRejectedValue(new Error('No receiver'));
    harness.scripting.executeScript.mockRejectedValue(new Error('Injection denied'));

    harness.actionClicked.emit({ ...trustedSender().tab!, url });
    await vi.waitFor(() => expect(harness.tabs.create).toHaveBeenCalledTimes(1));

    expect(harness.tabs.captureVisibleTab).toHaveBeenCalledWith(2, { format: 'png' });
    expect(harness.scripting.executeScript).toHaveBeenCalledTimes(1);
  });

  it('shows a friendly error when Chrome genuinely denies screenshot capture', async () => {
    const harness = await loadWorker();
    harness.tabs.sendMessage.mockRejectedValue(new Error('No receiver'));
    harness.tabs.captureVisibleTab.mockRejectedValue(
      new Error('Cannot capture a chrome:// page'),
    );

    harness.actionClicked.emit({
      ...trustedSender().tab!,
      url: 'chrome://certificate-viewer',
    });
    await vi.waitFor(() => {
      expect(harness.action.setTitle).toHaveBeenCalledWith({
        tabId: 7,
        title: expect.stringContaining('Chrome did not allow SnapScreen to capture'),
      });
    });

    expect(harness.scripting.executeScript).not.toHaveBeenCalled();
    expect(harness.tabs.create).not.toHaveBeenCalled();
  });

  it('requests file access and captures an opted-in file page', async () => {
    const harness = await loadWorker();
    harness.tabs.sendMessage.mockRejectedValue(new Error('No receiver'));
    harness.scripting.executeScript.mockRejectedValue(new Error('No receiver'));

    harness.actionClicked.emit({
      ...trustedSender().tab!,
      url: 'file:///tmp/question.html',
    });
    await vi.waitFor(() => {
      expect(harness.tabs.create).toHaveBeenCalledTimes(1);
    });

    expect(harness.permissions.request).toHaveBeenCalledWith({ origins: ['file:///*'] });
    expect(harness.extension.isAllowedFileSchemeAccess).toHaveBeenCalledTimes(1);
    expect(harness.tabs.captureVisibleTab).toHaveBeenCalledTimes(1);
  });

  it('opens an actionable workspace error when file access is disabled', async () => {
    const harness = await loadWorker();
    harness.extension.isAllowedFileSchemeAccess.mockResolvedValue(false);

    harness.actionClicked.emit({
      ...trustedSender().tab!,
      url: 'file:///tmp/question.html',
    });
    await vi.waitFor(() => {
      expect(harness.tabs.create).toHaveBeenCalledTimes(1);
    });
    await vi.waitFor(() => expect(harness.storage.set).toHaveBeenCalled());

    const workspaceUrl = new URL(
      (harness.tabs.create.mock.calls[0]?.[0] as { url: string }).url,
    );
    const params = new URLSearchParams(workspaceUrl.hash.slice(1));
    const sessionId = params.get('session')!;
    const nonce = params.get('nonce')!;
    const { ready } = await claimWorkspace(harness, sessionId, nonce);

    expect(harness.permissions.request).toHaveBeenCalledWith({ origins: ['file:///*'] });
    expect(harness.tabs.captureVisibleTab).not.toHaveBeenCalled();
    expect(harness.scripting.executeScript).not.toHaveBeenCalled();
    expect(ready.error).toEqual({
      code: 'file_access_disabled',
      message: expect.stringContaining('Allow access to file URLs'),
    });
  });

  it('does not capture when the optional file permission is denied', async () => {
    const harness = await loadWorker();
    harness.permissions.request.mockResolvedValue(false);

    harness.actionClicked.emit({
      ...trustedSender().tab!,
      url: 'file:///tmp/question.html',
    });
    await vi.waitFor(() => expect(harness.tabs.create).toHaveBeenCalledTimes(1));

    expect(harness.extension.isAllowedFileSchemeAccess).not.toHaveBeenCalled();
    expect(harness.tabs.captureVisibleTab).not.toHaveBeenCalled();
    expect(harness.scripting.executeScript).not.toHaveBeenCalled();
  });

  it('authenticates an exact workspace tab once and correlates crop responses', async () => {
    const harness = await loadWorker();
    const { nonce, sessionId } = await openRestrictedWorkspace(harness);
    const { port, ready } = await claimWorkspace(harness, sessionId, nonce);

    expect(ready.initialMessage).toEqual(expect.objectContaining({
      type: 'START_SNIP',
      dataUrl: 'data:image/png;base64,FULL',
    }));
    expect(ready.reconnectToken).toMatch(/^[A-Za-z0-9_-]{43}$/u);
    expect(JSON.stringify(ready)).not.toContain('sk-ant-test-secret');

    const replay = new FakePort(trustedWorkspaceSender());
    harness.connect.emit(replay.port);
    replay.send({
      type: 'SNAPSCREEN_WORKSPACE_CLAIM',
      sessionId,
      nonce,
      needsInitialState: true,
    });
    await vi.waitFor(() => expect(replay.disconnect).toHaveBeenCalledTimes(1));
    expect(port.disconnect).not.toHaveBeenCalled();

    port.send({
      type: 'SNAPSCREEN_WORKSPACE_REQUEST',
      sessionId,
      requestId: 'crop-rpc-1',
      message: {
        ...captureRequest(ready.initialMessage!.captureId),
        dataUrl: 'data:image/png;base64,WORKSPACE_OWNED',
      },
    });
    await vi.waitFor(() => {
      expect(port.postMessage).toHaveBeenCalledWith({
        type: 'SNAPSCREEN_WORKSPACE_RESPONSE',
        sessionId,
        requestId: 'crop-rpc-1',
        response: { ok: true },
      });
    });
    expect(dependencies.cropImage).toHaveBeenLastCalledWith(
      'data:image/png;base64,WORKSPACE_OWNED',
      { x: 0.1, y: 0.2, width: 0.5, height: 0.25 },
    );
    expect(port.postMessage).toHaveBeenCalledWith({
      type: 'SNAPSCREEN_WORKSPACE_EVENT',
      sessionId,
      message: expect.objectContaining({
        type: 'CROPPED_IMAGE',
        captureId: ready.initialMessage!.captureId,
      }),
    });
  });

  it('expires unclaimed frozen screenshot bytes', async () => {
    vi.useFakeTimers();
    const harness = await loadWorker();
    const { nonce, sessionId } = await openRestrictedWorkspace(harness);

    await vi.advanceTimersByTimeAsync(30_000);
    const { ready } = await claimWorkspace(harness, sessionId, nonce);

    expect(ready.initialMessage).toBeUndefined();
    expect(ready.error).toEqual({
      code: 'capture_expired',
      message: expect.stringContaining('frozen screenshot expired'),
    });
  });

  it('rejects workspace claims from the wrong path or tab', async () => {
    const harness = await loadWorker();
    const { nonce, sessionId } = await openRestrictedWorkspace(harness);
    const wrongPath = new FakePort(trustedWorkspaceSender(
      70,
      'chrome-extension://test-extension/src/options/options.html',
    ));

    harness.connect.emit(wrongPath.port);
    expect(wrongPath.disconnect).toHaveBeenCalledTimes(1);

    const wrongTab = new FakePort(trustedWorkspaceSender(71));
    harness.connect.emit(wrongTab.port);
    wrongTab.send({
      type: 'SNAPSCREEN_WORKSPACE_CLAIM',
      sessionId,
      nonce,
      needsInitialState: true,
    });
    await vi.waitFor(() => expect(wrongTab.disconnect).toHaveBeenCalledTimes(1));
  });

  it('reconnects an authenticated workspace without replaying frozen bytes', async () => {
    const harness = await loadWorker();
    const { nonce, sessionId } = await openRestrictedWorkspace(harness);
    const { port, ready } = await claimWorkspace(harness, sessionId, nonce);
    port.port.disconnect();

    const reconnected = new FakePort(trustedWorkspaceSender());
    harness.connect.emit(reconnected.port);
    reconnected.send({
      type: 'SNAPSCREEN_WORKSPACE_CLAIM',
      sessionId,
      reconnectToken: ready.reconnectToken,
      needsInitialState: false,
    });
    await vi.waitFor(() => {
      expect(reconnected.postMessage).toHaveBeenCalledWith({
        type: 'SNAPSCREEN_WORKSPACE_READY',
        sessionId,
        reconnectToken: ready.reconnectToken,
        initialMessage: undefined,
        error: undefined,
      });
    });
    expect(reconnected.disconnect).not.toHaveBeenCalled();
  });

  it('cancels workspace generation work after a disconnected port does not reconnect', async () => {
    vi.useFakeTimers();
    const harness = await loadWorker();
    const { nonce, sessionId } = await openRestrictedWorkspace(harness);
    const { port, ready } = await claimWorkspace(harness, sessionId, nonce);
    let generationSignal: AbortSignal | undefined;
    dependencies.analyzeImage.mockImplementationOnce((
      _apiKey,
      _dataUrl,
      options: { signal: AbortSignal },
    ) => {
      generationSignal = options.signal;
      return rejectWhenAborted(options.signal);
    });

    port.send({
      type: 'SNAPSCREEN_WORKSPACE_REQUEST',
      sessionId,
      requestId: 'disconnect-generation-rpc',
      message: {
        type: 'ANALYZE',
        captureId: ready.initialMessage!.captureId,
        dataUrl: 'data:image/png;base64,CROPPED',
        requestId: 'disconnect-generation',
        screenshotId: 'disconnect-screenshot',
        sessionSettings: {
          defaultPrompt: 'Answer the question.',
          limits: testLimits,
        },
      },
    });
    await vi.waitFor(() => expect(generationSignal).toBeDefined());

    port.port.disconnect();
    await vi.advanceTimersByTimeAsync(4_999);
    expect(generationSignal?.aborted).toBe(false);
    await vi.advanceTimersByTimeAsync(1);
    expect(generationSignal?.aborted).toBe(true);
  });

  it('cleans workspace routing metadata when its tab navigates away', async () => {
    const harness = await loadWorker();
    const { nonce, sessionId } = await openRestrictedWorkspace(harness);
    await claimWorkspace(harness, sessionId, nonce);
    harness.storage.remove.mockClear();

    const optionsUrl = 'chrome-extension://test-extension/src/options/options.html';
    harness.updated.emit(
      70,
      { status: 'loading', url: optionsUrl },
      { ...trustedWorkspaceSender().tab!, url: optionsUrl },
    );

    await vi.waitFor(() => {
      expect(harness.storage.remove).toHaveBeenCalledWith(
        `snapscreenWorkspace:${sessionId}`,
      );
    });
  });

  it('reactivates the source and reuses the workspace for a new snip', async () => {
    const harness = await loadWorker();
    const { nonce, sessionId } = await openRestrictedWorkspace(harness);
    const { port } = await claimWorkspace(harness, sessionId, nonce);
    harness.tabs.captureVisibleTab.mockClear();
    port.postMessage.mockClear();

    port.send({
      type: 'SNAPSCREEN_WORKSPACE_REQUEST',
      sessionId,
      requestId: 'resnip-rpc-1',
      message: {
        type: 'REQUEST_SNIP',
        sessionSettings: {
          defaultPrompt: 'Keep this workspace prompt.',
          limits: testLimits,
        },
      },
    });

    await vi.waitFor(() => {
      expect(port.postMessage).toHaveBeenCalledWith({
        type: 'SNAPSCREEN_WORKSPACE_RESPONSE',
        sessionId,
        requestId: 'resnip-rpc-1',
        response: { ok: true },
      });
    });
    expect(harness.tabs.update).toHaveBeenNthCalledWith(1, 7, { active: true });
    expect(harness.tabs.captureVisibleTab).toHaveBeenCalledWith(2, { format: 'png' });
    expect(harness.tabs.update).toHaveBeenNthCalledWith(2, 70, { active: true });
    expect(harness.tabs.create).toHaveBeenCalledTimes(1);
    expect(port.postMessage).toHaveBeenCalledWith({
      type: 'SNAPSCREEN_WORKSPACE_EVENT',
      sessionId,
      message: expect.objectContaining({
        type: 'START_SNIP',
        defaultPrompt: 'Keep this workspace prompt.',
      }),
    });
  });

  it('preserves workspace follow-ups but disables recapture after source closure', async () => {
    const harness = await loadWorker();
    const { nonce, sessionId } = await openRestrictedWorkspace(harness);
    const { port, ready } = await claimWorkspace(harness, sessionId, nonce);
    port.postMessage.mockClear();

    harness.removed.emit(7, { isWindowClosing: false, windowId: 2 });
    await vi.waitFor(() => {
      expect(port.postMessage).toHaveBeenCalledWith({
        type: 'SNAPSCREEN_WORKSPACE_EVENT',
        sessionId,
        message: expect.objectContaining({
          type: 'RESNIP_UNAVAILABLE',
        }),
      });
    });

    const history = [
      { role: 'user' as const, content: 'What is shown?' },
      { role: 'assistant' as const, content: 'A settings page.' },
    ];
    port.send({
      type: 'SNAPSCREEN_WORKSPACE_REQUEST',
      sessionId,
      requestId: 'follow-up-after-close',
      message: {
        type: 'FOLLOW_UP',
        captureId: ready.initialMessage!.captureId,
        requestId: 'generation-after-close',
        screenshotId: 'screenshot-after-close',
        sessionSettings: {
          defaultPrompt: 'Answer the question.',
          limits: testLimits,
        },
        history,
        text: 'What section?',
      },
    });
    await vi.waitFor(() => {
      expect(port.postMessage).toHaveBeenCalledWith({
        type: 'SNAPSCREEN_WORKSPACE_RESPONSE',
        sessionId,
        requestId: 'follow-up-after-close',
        response: { ok: true },
      });
    });
    expect(dependencies.followUp).toHaveBeenCalledOnce();
  });

  it('rejects stale workspace recapture after source navigation', async () => {
    const harness = await loadWorker();
    const { nonce, sessionId, sourceTab } = await openRestrictedWorkspace(harness);
    const { port } = await claimWorkspace(harness, sessionId, nonce);
    port.postMessage.mockClear();
    harness.tabs.captureVisibleTab.mockClear();

    harness.updated.emit(7, { status: 'loading' }, {
      ...sourceTab,
      url: 'chrome://settings/privacy',
    });
    await vi.waitFor(() => {
      expect(port.postMessage).toHaveBeenCalledWith({
        type: 'SNAPSCREEN_WORKSPACE_EVENT',
        sessionId,
        message: expect.objectContaining({ type: 'RESNIP_UNAVAILABLE' }),
      });
    });

    port.send({
      type: 'SNAPSCREEN_WORKSPACE_REQUEST',
      sessionId,
      requestId: 'stale-resnip-rpc',
      message: {
        type: 'REQUEST_SNIP',
        sessionSettings: {
          defaultPrompt: 'Keep prior context.',
          limits: testLimits,
        },
      },
    });
    await vi.waitFor(() => {
      expect(port.postMessage).toHaveBeenCalledWith(expect.objectContaining({
        type: 'SNAPSCREEN_WORKSPACE_RESPONSE',
        sessionId,
        requestId: 'stale-resnip-rpc',
        response: expect.objectContaining({
          error: expect.stringContaining('source page changed'),
        }),
      }));
    });
    expect(harness.tabs.captureVisibleTab).not.toHaveBeenCalled();
  });

  it('closes the workspace after returning to its source tab', async () => {
    const harness = await loadWorker();
    const { nonce, sessionId } = await openRestrictedWorkspace(harness);
    const { port } = await claimWorkspace(harness, sessionId, nonce);

    port.send({ type: 'SNAPSCREEN_WORKSPACE_CLOSE', sessionId });
    await vi.waitFor(() => expect(harness.tabs.remove).toHaveBeenCalledWith(70));
    expect(harness.tabs.update).toHaveBeenCalledWith(7, { active: true });
    expect(harness.storage.remove).toHaveBeenCalledWith(
      `snapscreenWorkspace:${sessionId}`,
    );
  });

  it('does not let an older badge timer clear a newer error', async () => {
    vi.useFakeTimers();
    const harness = await loadWorker();

    void dispatch(harness, { type: 'UI_UNAVAILABLE' });
    await vi.waitFor(() => expect(harness.action.setBadgeText).toHaveBeenCalledTimes(1));
    await vi.advanceTimersByTimeAsync(4_000);
    void dispatch(harness, { type: 'UI_UNAVAILABLE' });
    await vi.waitFor(() => expect(harness.action.setBadgeText).toHaveBeenCalledTimes(2));
    await vi.advanceTimersByTimeAsync(1_000);

    expect(harness.action.setBadgeText).not.toHaveBeenCalledWith({
      tabId: 7,
      text: '',
    });

    await vi.advanceTimersByTimeAsync(4_000);
    expect(harness.action.setBadgeText).toHaveBeenCalledWith({
      tabId: 7,
      text: '',
    });
  });

  it('does not let a slower older badge update postpone newer cleanup', async () => {
    vi.useFakeTimers();
    const olderTitle = deferred<void>();
    const harness = await loadWorker();
    harness.action.setTitle
      .mockReturnValueOnce(olderTitle.promise)
      .mockResolvedValueOnce(undefined);

    const older = dispatch(harness, { type: 'UI_UNAVAILABLE' });
    const olderResponse = expect(older).resolves.toEqual({ ok: true });
    await Promise.resolve();
    const newer = dispatch(harness, { type: 'UI_UNAVAILABLE' });
    await expect(newer).resolves.toEqual({ ok: true });

    await vi.advanceTimersByTimeAsync(1_500);
    olderTitle.resolve();
    await olderResponse;
    await vi.advanceTimersByTimeAsync(3_500);

    expect(harness.action.setBadgeText).toHaveBeenCalledWith({
      tabId: 7,
      text: '',
    });
  });

  it('clears active badge feedback when the tab navigates', async () => {
    const harness = await loadWorker();

    await expect(dispatch(harness, { type: 'UI_UNAVAILABLE' })).resolves.toEqual({
      ok: true,
    });
    harness.updated.emit(7, { status: 'loading' }, trustedSender().tab!);

    await vi.waitFor(() => {
      expect(harness.action.setBadgeText).toHaveBeenCalledWith({
        tabId: 7,
        text: '',
      });
      expect(harness.action.setTitle).toHaveBeenCalledWith({
        tabId: 7,
        title: 'SnapScreen – Snip and analyze',
      });
    });
  });

  it('clears partial badge feedback when one action API call fails', async () => {
    vi.useFakeTimers();
    const harness = await loadWorker();
    harness.action.setTitle.mockRejectedValueOnce(new Error('Title unavailable'));

    const response = dispatch(harness, { type: 'UI_UNAVAILABLE' });
    await vi.runAllTimersAsync();
    await expect(response).resolves.toEqual({ ok: true });

    expect(harness.action.setBadgeText).toHaveBeenCalledWith({
      tabId: 7,
      text: '',
    });
  });

  it('does not relay secrets from unexpected generation errors', async () => {
    const harness = await loadWorker();
    dependencies.analyzeImage.mockRejectedValueOnce(
      new Error('request failed with sk-ant-should-not-leak'),
    );

    const response = await dispatch(
      harness,
      analyzeRequest('capture-1', 'request-secret-error'),
    );

    expect(response).toEqual({
      error: 'SnapScreen could not complete this request. Please try again.',
    });
    expect(JSON.stringify(harness.tabs.sendMessage.mock.calls)).not.toContain(
      'sk-ant-should-not-leak',
    );
  });
});
