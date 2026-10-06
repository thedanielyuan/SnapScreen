import assert from 'node:assert/strict';
import test from 'node:test';

function event() {
  const listeners = [];
  return { addListener(listener) { listeners.push(listener); }, emit(...args) { for (const listener of listeners) listener(...args); } };
}

async function flush() {
  for (let index = 0; index < 20; index += 1) await Promise.resolve();
}

async function harness(options = {}) {
  const tab = { id: 42, windowId: 7, url: 'http://127.0.0.1/fixture' };
  const outgoing = [];
  const badgeTexts = [];
  const openedSurfaces = [];
  let connections = 0;
  let captures = 0;
  let currentNativePort;
  const createPort = () => {
    const nativePort = {
      onMessage: event(),
      onDisconnect: event(),
      disconnect() { /* The mock port has no external resources. */ },
      postMessage(message) {
        outgoing.push(message);
        if (message.type === 'hello') queueMicrotask(() => {
          if (options.missingHost) {
            chrome.runtime.lastError = { message: 'host not installed' };
            nativePort.onDisconnect.emit();
            delete chrome.runtime.lastError;
          } else nativePort.onMessage.emit({ version: 1, type: 'hello', pid: 123 });
        });
        if (message.type === 'shutdown') queueMicrotask(() => nativePort.onDisconnect.emit());
      },
    };
    return nativePort;
  };
  globalThis.chrome = {
    runtime: {
      connectNative() { connections += 1; currentNativePort = createPort(); return currentNativePort; },
      openOptionsPage() { openedSurfaces.push('options'); },
    },
    scripting: { executeScript() { openedSurfaces.push('injection'); } },
    action: {
      onClicked: event(),
      async setBadgeText({ text }) { badgeTexts.push(text); },
      async setBadgeBackgroundColor() { /* Only the error badge text is relevant to these tests. */ },
      async setTitle() { /* Title changes do not open an extension surface. */ },
    },
    commands: { onCommand: event() },
    tabs: {
      async query() { return [tab]; },
      async get() { return tab; },
      async captureVisibleTab() { captures += 1; return options.capture ? options.capture() : 'data:image/png;base64,aW1hZ2U='; },
      create() { openedSurfaces.push('tab'); },
      onUpdated: event(), onRemoved: event(), onActivated: event(),
    },
    windows: { onFocusChanged: event(), WINDOW_ID_NONE: -1, create() { openedSurfaces.push('window'); } },
  };
  await import(`./background.mjs?trial=${crypto.randomUUID()}`);
  return {
    tab, outgoing, badgeTexts, openedSurfaces,
    get nativePort() { return currentNativePort; },
    observation: globalThis.phase1,
    control: globalThis.phase1Control,
    connections: () => connections,
    captures: () => captures,
    async action() { chrome.action.onClicked.emit(tab); await flush(); },
    async baseline() { chrome.commands.onCommand.emit('capture-baseline', tab); await flush(); },
  };
}

test('real action callback handshakes, captures, validates selection, and keeps the warm port', async () => {
  const h = await harness();
  try {
    await h.action();
    assert.equal(h.observation.status.state, 'selecting');
    assert.deepEqual(h.outgoing.map(message => message.type), ['hello', 'capture']);
    const oldSession = h.observation.status.sessionId;
    h.nativePort.onMessage.emit({ version: 1, type: 'selected', sessionId: oldSession, rect: { x: 0, y: 0, width: 1, height: 1 } });
    assert.equal(h.observation.status.state, 'streaming');
    // After acceptance the captured session survives source navigation and tab closure.
    chrome.tabs.onUpdated.emit(h.tab.id, { status: 'loading' });
    chrome.tabs.onRemoved.emit(h.tab.id);
    assert.equal(h.observation.status.sessionId, oldSession);
    assert.ok(h.outgoing.some(message => message.type === 'answer'));
    h.nativePort.onMessage.emit({ version: 1, type: 'closed', sessionId: oldSession });
    assert.equal(h.observation.status.state, 'idle');
    await h.action();
    assert.equal(h.connections(), 1);
    assert.notEqual(h.observation.status.sessionId, oldSession);
    h.nativePort.onMessage.emit({ version: 1, type: 'selected', sessionId: oldSession, rect: { x: 0, y: 0, width: 1, height: 1 } });
    assert.equal(h.observation.status.state, 'selecting');
    assert.ok(h.observation.logs.some(entry => entry.event === 'stale_native_message'));
    const diagnostic = JSON.stringify(h.observation);
    assert.equal(diagnostic.includes('data:image'), false);
    assert.equal(diagnostic.includes(h.tab.url), false);
    assert.equal(diagnostic.includes('mocked answer'), false);
    assert.deepEqual(h.openedSurfaces, []);
  } finally { h.control.shutdown(); await flush(); }
});

test('missing native host reports a badge and never captures or opens another surface', async () => {
  const h = await harness({ missingHost: true });
  await h.action();
  assert.equal(h.captures(), 0);
  assert.equal(h.observation.status.state, 'idle');
  assert.equal(h.observation.status.connection, 'disconnected');
  assert.equal(h.observation.status.error, 'host_unavailable');
  assert.ok(h.badgeTexts.includes('ERR'));
  assert.deepEqual(h.outgoing.map(message => message.type), ['hello']);
  assert.deepEqual(h.openedSurfaces, []);
});

test('worker forwards validated geometry metadata and never logs rejected payload fields', async () => {
  const h = await harness();
  try {
    await h.action();
    const frame = { x: -100, y: 20, width: 640, height: 520 };
    const scroll = { x: 0, y: 120, width: 600, height: 350 };
    const message = {
      version: 1, type: 'telemetry', event: 'answer.shown', at: 100,
      sessionId: h.observation.status.sessionId, appActive: false, keyWindow: true,
      frame, scroll, geometrySource: 'baseline',
    };
    h.nativePort.onMessage.emit(message);
    const logged = h.observation.logs.at(-1);
    assert.equal(logged.event, 'native_telemetry');
    assert.equal(logged.nativeEvent, 'answer.shown');
    assert.deepEqual(logged.frame, frame);
    assert.deepEqual(logged.scroll, scroll);
    assert.equal(logged.geometrySource, 'baseline');
    assert.notEqual(logged.frame, frame);
    assert.notEqual(logged.scroll, scroll);
    h.nativePort.onMessage.emit({ ...message, inputSource: 'com.apple.keylayout.US' });
    assert.equal(h.observation.logs.at(-1).inputSource, 'com.apple.keylayout.US');
    h.nativePort.onMessage.emit({ ...message, frame: { ...frame, title: 'private-window-title' } });
    assert.equal(h.observation.status.error, 'invalid_native_message');
    assert.equal(JSON.stringify(h.observation).includes('private-window-title'), false);
  } finally { h.control.shutdown(); await flush(); }
});

test('clearing logs starts a new observation window without changing the session', async () => {
  const h = await harness();
  try {
    await h.action();
    const id = h.observation.status.sessionId;
    assert.equal(h.observation.capacity, 20_000);
    h.observation.droppedEntries = 3;
    h.control.clearLogs();
    assert.deepEqual(h.observation.logs.map(entry => entry.event), ['logs_cleared']);
    assert.equal(h.observation.droppedEntries, 0);
    assert.equal(h.observation.status.sessionId, id);
    assert.equal(h.observation.status.state, 'selecting');
  } finally { h.control.shutdown(); await flush(); }
});

test('capture-only command releases its image without connecting or displaying native UI', async () => {
  const h = await harness();
  await h.baseline();
  assert.equal(h.captures(), 1);
  assert.equal(h.connections(), 0);
  assert.equal(h.observation.status.sessionId, null);
  assert.equal(h.observation.status.state, 'idle');
  assert.ok(h.observation.logs.some(entry => entry.event === 'baseline_finished'));
  assert.equal(JSON.stringify(h.observation).includes('data:image'), false);
  assert.deepEqual(h.openedSurfaces, []);
});

test('source navigation or activation before selection resets the pending native session', async () => {
  const h = await harness();
  try {
    await h.action();
    const firstId = h.observation.status.sessionId;
    chrome.tabs.onUpdated.emit(h.tab.id, { status: 'loading' });
    assert.equal(h.observation.status.sessionId, null);
    assert.ok(h.outgoing.some(message => message.type === 'reset' && message.sessionId === firstId));
    await h.action();
    chrome.tabs.onActivated.emit({ tabId: 43, windowId: 7 });
    assert.equal(h.observation.status.sessionId, null);
    await h.action();
    chrome.windows.onFocusChanged.emit(8);
    assert.equal(h.observation.status.sessionId, null);
  } finally { h.control.shutdown(); await flush(); }
});

test('navigation during asynchronous screenshot capture prevents sending the image', async () => {
  let finishCapture;
  const h = await harness({ capture: () => new Promise(resolve => { finishCapture = resolve; }) });
  try {
    await h.action();
    assert.equal(h.observation.status.state, 'capturing');
    chrome.tabs.onUpdated.emit(h.tab.id, { url: 'http://127.0.0.1/other' });
    finishCapture('data:image/png;base64,aW1hZ2U=');
    await flush();
    assert.equal(h.outgoing.some(message => message.type === 'capture'), false);
    assert.equal(h.observation.status.sessionId, null);
  } finally { h.control.shutdown(); await flush(); }
});

test('invalid or oversized native messages expire the connection and session', async () => {
  const h = await harness();
  await h.action();
  h.nativePort.onMessage.emit({ version: 2, type: 'closed', sessionId: h.observation.status.sessionId });
  assert.equal(h.observation.status.sessionId, null);
  assert.equal(h.observation.status.connection, 'disconnected');
  assert.equal(h.observation.status.error, 'invalid_native_message');
});

test('a later action supersedes in-flight capture and the earlier image is never sent', async () => {
  let finishFirst;
  let captures = 0;
  const h = await harness({ capture: () => {
    captures += 1;
    return captures === 1 ? new Promise(resolve => { finishFirst = resolve; }) : 'data:image/png;base64,bmV3';
  } });
  try {
    await h.action();
    const firstId = h.observation.status.sessionId;
    await h.action();
    const secondId = h.observation.status.sessionId;
    assert.notEqual(firstId, secondId);
    finishFirst('data:image/png;base64,b2xk');
    await flush();
    const sent = h.outgoing.filter(message => message.type === 'capture');
    assert.equal(sent.length, 1);
    assert.equal(sent[0].sessionId, secondId);
    assert.equal(sent[0].imageDataUrl, 'data:image/png;base64,bmV3');
  } finally { h.control.shutdown(); await flush(); }
});

test('baseline closes a pending native session and shutdown permits a cold connection', async () => {
  const h = await harness();
  await h.action();
  const id = h.observation.status.sessionId;
  await h.baseline();
  assert.equal(h.observation.status.sessionId, null);
  assert.equal(h.observation.status.state, 'idle');
  assert.equal(h.connections(), 1);
  assert.equal(h.captures(), 2);
  assert.ok(h.outgoing.some(message => message.type === 'reset' && message.sessionId === id));
  assert.equal(h.outgoing.filter(message => message.type === 'capture').length, 1);
  h.control.shutdown();
  await flush();
  assert.equal(h.observation.status.connection, 'disconnected');
  assert.equal(h.observation.status.error, null);
  await h.action();
  assert.equal(h.connections(), 2);
  assert.equal(h.observation.status.state, 'selecting');
  h.control.shutdown();
  await flush();
});
