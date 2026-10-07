// Serialized only into the disposable browser fixture, after inspecting the archive.
// Native transport, capture, and API responses are mocked; the built worker, crop,
// conversation controller, and SSE parser run unchanged. No API request can escape.
export function installNativeSmokeShim({ apiUrl, apiKey, answer, prompt }) {
  const state = {
    bootId: crypto.randomUUID(), actions: [], commands: [], ports: [], requests: [], forbidden: [], badges: [],
    captures: 0, hostMode: 'ready', apiMode: 'answer', observing: false,
  };
  globalThis.__snapscreenNativeState = state;
  for (const [event, listeners] of [
    [chrome.action.onClicked, state.actions], [chrome.commands.onCommand, state.commands],
  ]) {
    const add = event.addListener.bind(event);
    event.addListener = listener => { listeners.push(listener); add(listener); };
  }
  for (const [owner, key] of [
    [chrome.tabs, 'sendMessage'], [chrome.tabs, 'create'], [chrome.tabs, 'update'],
    [chrome.windows, 'create'], [chrome.windows, 'update'],
    [chrome.permissions, 'request'], [chrome.runtime, 'openOptionsPage'],
  ]) {
    const original = owner[key].bind(owner);
    owner[key] = async (...args) => {
      if (!state.observing) return original(...args);
      state.forbidden.push(key);
      throw new Error(`Capture attempted ${key}.`);
    };
  }
  if (chrome.scripting) throw new Error('Native-only worker exposes chrome.scripting.');
  const setBadge = chrome.action.setBadgeText.bind(chrome.action);
  chrome.action.setBadgeText = async details => { state.badges.push(details); await setBadge(details); };
  chrome.runtime.getPlatformInfo = async () => ({ os: 'mac', arch: 'arm', nacl_arch: 'arm' });
  chrome.tabs.captureVisibleTab = async () => {
    state.captures += 1;
    const canvas = new OffscreenCanvas(8, 6);
    const paint = canvas.getContext('2d');
    paint.fillStyle = '#ff0000';
    paint.fillRect(0, 0, 8, 6);
    const png = new Uint8Array(await (await canvas.convertToBlob()).arrayBuffer());
    return `data:image/png;base64,${btoa(String.fromCharCode(...png))}`;
  };
  chrome.runtime.connectNative = host => {
    if (host !== 'com.snapscreen.companion') throw new Error('Unexpected native host.');
    const messages = new Set();
    const disconnects = new Set();
    const mode = state.hostMode;
    const event = listeners => ({
      addListener: listener => listeners.add(listener),
      removeListener: listener => listeners.delete(listener),
    });
    const port = {
      sent: [], disconnected: false, onMessage: event(messages), onDisconnect: event(disconnects),
      listenerCounts: () => [messages.size, disconnects.size],
      emit: message => { for (const listener of [...messages]) listener(message); },
      drop: () => { for (const listener of [...disconnects]) listener(); },
      command: (type, extra = {}) => {
        const { version, connectionId, sessionId, requestId } = port.sent.at(-1);
        port.emit({ version, connectionId, sessionId, requestId, type, ...extra });
      },
      disconnect: () => { port.disconnected = true; },
      postMessage: message => {
        const serialized = JSON.stringify(message);
        if (serialized.includes(apiKey) || serialized.includes(prompt)
          || Object.keys(message).some(key => /system|history|apiKey/iu.test(key))) {
          state.forbidden.push('private data sent to native host');
          throw new Error('Private data leaked to companion.');
        }
        port.sent.push(message);
        if (message.type === 'hello') queueMicrotask(() => {
          if (mode === 'missing') return port.drop();
          port.emit({ version: mode === 'incompatible' ? 999 : message.version,
            connectionId: message.connectionId, type: 'ready',
            ...(mode === 'malformed' ? { extra: apiKey } : {}),
          });
        });
      },
    };
    state.ports.push(port);
    return port;
  };
  const realFetch = globalThis.fetch.bind(globalThis);
  globalThis.fetch = async (input, options = {}) => {
    const url = typeof input === 'string' ? input : input.url;
    if (url.startsWith('data:image/png;base64,')) return realFetch(input, options);
    if (url !== apiUrl) throw new Error('Native smoke fixture blocks external fetch.');
    const request = { headers: Object.fromEntries(new Headers(options.headers)),
      body: JSON.parse(options.body), aborted: false, finished: false };
    state.requests.push(request);
    if (state.apiMode === 'error') return new Response(JSON.stringify({
      type: 'error', error: { type: 'invalid_request_error',
        message: `Rejected ${apiKey}\u0001 ${'x'.repeat(800)}` },
    }), { status: 400, headers: { 'content-type': 'application/json' } });
    const encoder = new TextEncoder();
    const body = new ReadableStream({
      start(controller) {
        const enqueue = event => controller.enqueue(encoder.encode(
          `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`));
        const abort = () => {
          request.aborted = true;
          controller.error(options.signal.reason);
        };
        options.signal.addEventListener('abort', abort, { once: true });
        enqueue({ type: 'content_block_start', index: 0,
          content_block: { type: 'thinking', thinking: '' } });
        enqueue({ type: 'content_block_delta', index: 1,
          delta: { type: 'text_delta', text: answer } });
        request.complete = () => {
          if (request.aborted || request.finished) return;
          request.finished = true;
          options.signal.removeEventListener('abort', abort);
          enqueue({ type: 'message_stop' });
          controller.close();
        };
        if (state.apiMode !== 'slow') request.complete();
      },
    });
    return new Response(body, { headers: { 'content-type': 'text/event-stream' } });
  };
}
