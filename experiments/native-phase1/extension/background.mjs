import { NATIVE_HOST } from './config.mjs';
import {
  MAX_FRAME_BYTES,
  MAX_NATIVE_FRAME_BYTES,
  isExtensionMessage,
  isNativeMessage,
  serializedBytes,
} from './protocol.mjs';

// No screenshots or entered text are stored in this diagnostic object.
const MAX_LOG_ENTRIES = 20_000;
const observation = {
  capacity: MAX_LOG_ENTRIES,
  logs: [],
  droppedEntries: 0,
  status: { connection: 'disconnected', pid: null, sessionId: null, state: 'idle', error: null },
};
globalThis.phase1 = observation;
let port = null;
let handshake = null;
let handshakeTimer = null;
let activeSession = null;
let generation = 0;
let shuttingDown = false;

function log(event, details = {}) {
  observation.logs.push({ at: Date.now(), event, ...details });
  if (observation.logs.length > MAX_LOG_ENTRIES) {
    observation.droppedEntries += observation.logs.length - MAX_LOG_ENTRIES;
    observation.logs.splice(0, observation.logs.length - MAX_LOG_ENTRIES);
  }
}

function badge(error = null) {
  observation.status.error = error;
  void chrome.action.setBadgeText({ text: error ? 'ERR' : '' });
  void chrome.action.setBadgeBackgroundColor({ color: '#b42318' });
  void chrome.action.setTitle({ title: error
    ? `Native Phase 1: ${error}. Inspect the experimental worker log.`
    : 'Native Phase 1: capture and select' });
}

function send(message) {
  if (!port || !isExtensionMessage(message) || serializedBytes(message) > MAX_FRAME_BYTES) {
    throw new Error('native_send_rejected');
  }
  port.postMessage(message);
}

function expireSession(event, notify = true) {
  generation += 1;
  const oldSession = activeSession;
  activeSession = null;
  observation.status.sessionId = null;
  observation.status.state = 'idle';
  if (!oldSession) return;
  log(event, { sessionId: oldSession.id });
  if (notify && port && observation.status.connection === 'ready' && oldSession.kind === 'native') {
    try { send({ version: 1, type: 'reset', sessionId: oldSession.id }); } catch { /* Disconnect cleanup owns the error. */ }
  }
}

function disconnect(reason, showError = true) {
  const oldPort = port;
  port = null;
  clearTimeout(handshakeTimer);
  handshakeTimer = null;
  if (handshake) {
    handshake.reject(new Error(reason));
    handshake = null;
  }
  observation.status.connection = 'disconnected';
  observation.status.pid = null;
  expireSession('session_expired', false);
  if (oldPort) oldPort.disconnect();
  log(reason);
  if (showError) badge(reason);
}

function connect() {
  if (observation.status.connection === 'ready' && port) return Promise.resolve();
  if (handshake) return handshake.promise;
  shuttingDown = false;
  const newPort = chrome.runtime.connectNative(NATIVE_HOST);
  port = newPort;
  observation.status.connection = 'connecting';
  const promise = new Promise((resolve, reject) => {
    handshake = { resolve, reject, promise: null };
  });
  handshake.promise = promise;
  newPort.onMessage.addListener(message => {
    if (newPort === port) receive(message);
  });
  newPort.onDisconnect.addListener(() => {
    // Read lastError to acknowledge it, but never persist raw transport text.
    const failed = Boolean(chrome.runtime.lastError);
    if (newPort === port) disconnect(shuttingDown ? 'host_shutdown' : failed ? 'host_unavailable' : 'host_disconnected', !shuttingDown);
  });
  handshakeTimer = setTimeout(() => disconnect('handshake_timeout'), 5000);
  log('host_connect');
  try { send({ version: 1, type: 'hello' }); } catch { disconnect('host_unavailable'); }
  return promise;
}

function receive(message) {
  if (!isNativeMessage(message) || serializedBytes(message) > MAX_NATIVE_FRAME_BYTES) {
    disconnect('invalid_native_message');
    return;
  }
  if (message.type === 'telemetry') {
    log('native_telemetry', {
      nativeEvent: message.event,
      nativeAt: message.at,
      ...(message.sessionId ? { sessionId: message.sessionId } : {}),
      appActive: message.appActive,
      keyWindow: message.keyWindow,
      ...(message.frame ? { frame: { ...message.frame } } : {}),
      ...(message.scroll ? { scroll: { ...message.scroll } } : {}),
      ...(message.geometrySource ? { geometrySource: message.geometrySource } : {}),
      ...(message.inputSource ? { inputSource: message.inputSource } : {}),
    });
    return;
  }
  if (message.type === 'hello') {
    if (!handshake) {
      disconnect('unexpected_handshake');
      return;
    }
    clearTimeout(handshakeTimer);
    handshakeTimer = null;
    observation.status.connection = 'ready';
    observation.status.pid = message.pid;
    const pending = handshake;
    handshake = null;
    log('host_ready', { pid: message.pid });
    pending.resolve();
    return;
  }
  if (!activeSession || message.sessionId !== activeSession.id) {
    log('stale_native_message', { type: message.type });
    return;
  }
  switch (message.type) {
    case 'selected':
      if (activeSession.state !== 'selecting') {
        log('unexpected_selection', { sessionId: activeSession.id });
        return;
      }
      activeSession.state = 'accepted';
      log('selection_accepted', { sessionId: activeSession.id, rect: message.rect });
      void streamSample(activeSession, false);
      break;
    case 'followup':
      if (activeSession.state !== 'ready') {
        log('unexpected_followup', { sessionId: activeSession.id });
        return;
      }
      log('followup_received', { sessionId: activeSession.id, characters: message.text.length });
      void streamSample(activeSession, true);
      break;
    case 'closed':
    case 'cancelled':
      expireSession(`native_${message.type}`, false);
      break;
  }
}

const SAMPLE_ANSWER = [
  'This is a mocked answer for the native interaction experiment. No API request was made.\n\n',
  'The selected screenshot is held in memory by this native process. Use the preview control to inspect the selected region. ',
  'While this answer arrives, observe the test page’s focus, visibility, DOM, pointer, and keyboard records.\n\n',
  'Try moving and resizing this window, scrolling through the answer, selecting answer text, and using Copy. ',
  'Record each action separately so a focus transition can be attributed to its actual cause.\n\n',
  'The follow-up field accepts input for this experiment. Typing, selecting, pasting, and input-method composition need individual observations. ',
  'A non-activating panel can still receive keyboard focus; the instrumented page determines whether the proposed interaction requirement passes.\n\n',
  'This long sample also makes scrolling measurable. Repeat each action with a focused page text field, then compare it with ordinary page use and the capture-only baseline. ',
  'A page staying visible does not establish that it kept focus. Any transient transition must remain in the recorded results.\n\n',
  'Close releases the native session. The host remains connected so the next real extension invocation measures a warm capture. ',
  'Use the diagnostic shutdown control between trials that require a cold process launch. No real provider response, credential, or conversation is used.\n\n',
  'End of the sample answer. The complete companion should be built only after the measured interaction results are reviewed.',
].join('');

async function streamSample(session, followup) {
  const currentGeneration = ++generation;
  session.state = 'streaming';
  observation.status.state = session.state;
  log('answer_started', { sessionId: session.id, followup });
  const sample = followup ? `This is a mocked follow-up response. Your question was not sent to any API.\n\n${SAMPLE_ANSWER}` : SAMPLE_ANSWER;
  for (let offset = 0; offset < sample.length; offset += 100) {
    if (activeSession !== session || currentGeneration !== generation || !port) return;
    const done = offset + 100 >= sample.length;
    try {
      send({ version: 1, type: 'answer', sessionId: session.id, text: sample.slice(offset, offset + 100), done });
    } catch {
      disconnect('answer_delivery_failed');
      return;
    }
    log('answer_chunk', { sessionId: session.id, characters: Math.min(100, sample.length - offset), done });
    if (!done) await new Promise(resolve => setTimeout(resolve, 100));
  }
  if (activeSession !== session || currentGeneration !== generation) return;
  session.state = 'ready';
  observation.status.state = session.state;
  log('answer_finished', { sessionId: session.id });
}

async function sourceStillActive(session) {
  if (activeSession !== session) return false;
  const [current] = await chrome.tabs.query({ active: true, windowId: session.windowId });
  const source = await chrome.tabs.get(session.tabId);
  return activeSession === session && current?.id === session.tabId
    && source.windowId === session.windowId && source.url === session.url;
}

async function capture(tab, kind) {
  expireSession('new_invocation');
  badge();
  log('invocation', { kind });
  if (!tab || !Number.isInteger(tab.id) || !Number.isInteger(tab.windowId)) {
    badge('no_source_tab');
    log('no_source_tab');
    return;
  }
  const session = {
    id: crypto.randomUUID(),
    tabId: tab.id,
    windowId: tab.windowId,
    url: tab.url,
    state: 'capturing',
    kind,
  };
  activeSession = session;
  observation.status.sessionId = session.id;
  observation.status.state = session.state;
  try {
    if (kind === 'native') await connect();
    if (!await sourceStillActive(session)) {
      if (activeSession === session) expireSession('source_changed');
      return;
    }
    log('capture_started', { sessionId: session.id, tabId: tab.id, windowId: tab.windowId });
    // This local is released when capture returns; the extension never stores image data in its session or logs.
    const imageDataUrl = await chrome.tabs.captureVisibleTab(tab.windowId, { format: 'png' });
    if (!await sourceStillActive(session)) {
      if (activeSession === session) expireSession('source_changed');
      return;
    }
    log('capture_finished', { sessionId: session.id, imageDataUrlBytes: imageDataUrl.length, kind });
    if (kind === 'baseline') {
      expireSession('baseline_finished', false);
      return;
    }
    const message = { version: 1, type: 'capture', sessionId: session.id, imageDataUrl };
    if (!isExtensionMessage(message)) {
      expireSession('capture_too_large');
      badge('capture_too_large');
      return;
    }
    session.state = 'selecting';
    observation.status.state = session.state;
    send(message);
    log('capture_sent', { sessionId: session.id });
  } catch {
    if (activeSession === session) {
      expireSession('capture_failed');
      badge('capture_failed');
    }
  }
}

function invalidatePending(reason, predicate) {
  if (activeSession && ['capturing', 'selecting'].includes(activeSession.state) && predicate(activeSession)) {
    log('source_invalidated', { reason, sessionId: activeSession.id });
    expireSession('source_changed');
  }
}

chrome.action.onClicked.addListener(tab => { void capture(tab, 'native'); });
chrome.commands.onCommand.addListener((command, tab) => {
  if (command !== 'capture-baseline') return;
  if (tab) void capture(tab, 'baseline');
  else void chrome.tabs.query({ active: true, currentWindow: true }).then(([current]) => capture(current, 'baseline'));
});
chrome.tabs.onUpdated.addListener((tabId, change) => {
  if (change.status === 'loading' || Object.hasOwn(change, 'url')) invalidatePending('navigation', session => session.tabId === tabId);
});
chrome.tabs.onRemoved.addListener(tabId => invalidatePending('tab_closed', session => session.tabId === tabId));
chrome.tabs.onActivated.addListener(info => invalidatePending('tab_activation', session => info.windowId !== session.windowId || info.tabId !== session.tabId));
chrome.windows.onFocusChanged.addListener(windowId => {
  // WINDOW_ID_NONE can be caused by native key-window activity, which is an observation, not a source-tab switch.
  log('chrome_window_focus', { windowId });
  if (windowId !== chrome.windows.WINDOW_ID_NONE) invalidatePending('window_activation', session => session.windowId !== windowId);
});

globalThis.phase1Control = {
  reset() { expireSession('diagnostic_reset'); },
  // Starts a new observation window; connection and session state are unchanged.
  clearLogs() {
    observation.logs = [];
    observation.droppedEntries = 0;
    log('logs_cleared');
  },
  shutdown() {
    expireSession('diagnostic_shutdown');
    shuttingDown = true;
    if (port && observation.status.connection === 'ready') {
      try { send({ version: 1, type: 'shutdown' }); } catch { disconnect('host_shutdown', false); }
    } else disconnect('host_shutdown', false);
  },
};
log('worker_started');
