import { createHash } from 'node:crypto';
import { cp, readFile, readdir, writeFile } from 'node:fs/promises';
import { dirname, join, relative, resolve } from 'node:path';
import { EXTENSION_ID, EXTENSION_KEY } from '../experiments/native-phase1/extension/config.mjs';

export { EXTENSION_ID };

// This function is serialized into the disposable extension, never the shipped build. It
// deliberately has no passthrough fetch: fixture mistakes cannot spend API credit.
export function installAcceptanceShim() {
  const entries = [];
  const ports = new Set();
  let total = 0;
  let requests = 0;
  let scenario = 'answer';
  function record(type, detail = {}) {
    entries.push({ sequence: total++, epochMs: Date.now(), type, ...detail });
    if (entries.length > 2000) entries.shift();
  }
  function messageDetail(message) {
    return {
      messageType: typeof message?.type === 'string' ? message.type : 'invalid',
      connectionId: message?.connectionId,
      sessionId: message?.sessionId,
      requestId: message?.requestId,
      status: message?.status,
      textLength: typeof message?.text === 'string' ? message.text.length : undefined,
      imageLength: typeof message?.imageDataUrl === 'string' ? message.imageDataUrl.length : undefined,
    };
  }
  const connect = chrome.runtime.connectNative.bind(chrome.runtime);
  chrome.runtime.connectNative = (name) => {
    record('native-connect');
    const port = connect(name);
    ports.add(port);
    const post = port.postMessage.bind(port);
    port.postMessage = message => { record('native-out', messageDetail(message)); return post(message); };
    port.onMessage.addListener(message => record('native-in', messageDetail(message)));
    let ended = false;
    const end = () => {
      if (!ended) record('native-disconnect');
      ended = true;
      ports.delete(port);
    };
    port.onDisconnect.addListener(() => { void chrome.runtime.lastError; end(); });
    const disconnect = port.disconnect.bind(port);
    port.disconnect = () => { end(); disconnect(); };
    return port;
  };
  for (const [event, route] of [[chrome.action.onClicked, 'toolbar'], [chrome.commands.onCommand, 'shortcut']]) {
    const add = event.addListener.bind(event);
    event.addListener = listener => add((...args) => { record('invocation', { route }); return listener(...args); });
  }
  const capture = chrome.tabs.captureVisibleTab.bind(chrome.tabs);
  chrome.tabs.captureVisibleTab = async (...args) => {
    record('capture-start');
    try { const image = await capture(...args); record('capture-complete'); return image; }
    catch (error) { record('capture-failed'); throw error; }
  };
  globalThis.fetch = async (input, options = {}) => {
    const url = typeof input === 'string' ? input : input.url;
    if (url !== 'https://api.anthropic.com/v1/messages') throw new Error('Acceptance fixture blocks external fetch.');
    requests += 1;
    const mode = scenario;
    record('mock-api-start', { number: requests, scenario: mode });
    if (mode === 'error') {
      scenario = 'answer';
      return new Response(JSON.stringify({ type: 'error', error: { type: 'overloaded_error',
        message: 'Fixture error. Press Retry to receive the mocked answer.' } }),
      { status: 529, headers: { 'content-type': 'application/json' } });
    }
    const text = 'This is a mocked answer for physical acceptance. No request was sent to Anthropic.\n\n'
      + '```python\nprint(2 + 2)\n```\n\n'
      + Array.from({ length: 12 }, (_, i) => `Paragraph ${i + 1}: Use this content to test scrolling, text selection, Copy, preview, and resizing.\n\n`).join('');
    const chunks = text.match(/[\s\S]{1,100}/g);
    const events = [
      { type: 'message_start', message: { id: 'msg_acceptance', type: 'message', role: 'assistant',
        content: [], usage: { input_tokens: 1, output_tokens: 0 } } },
      { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
      ...chunks.map(text => ({ type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text } })),
      { type: 'content_block_stop', index: 0 },
      { type: 'message_delta', delta: { stop_reason: 'end_turn' }, usage: { output_tokens: 1 } },
      { type: 'message_stop' },
    ];
    const encoder = new TextEncoder();
    let timer;
    let finished = false;
    let abort;
    const clean = () => { clearTimeout(timer); options.signal?.removeEventListener('abort', abort); };
    const body = new ReadableStream({
      start(controller) {
        abort = () => {
          if (finished) return;
          finished = true;
          clean();
          record('mock-api-aborted');
          controller.error(new DOMException('Aborted', 'AbortError'));
        };
        options.signal?.addEventListener('abort', abort, { once: true });
        if (options.signal?.aborted) { abort(); return; }
        let index = 0;
        const emit = () => {
          if (finished) return;
          const event = events[index++];
          controller.enqueue(encoder.encode(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`));
          if (index === events.length) {
            finished = true;
            clean();
            controller.close();
            record('mock-api-complete');
          } else timer = setTimeout(emit, mode === 'slow' ? 1500 : 250);
        };
        timer = setTimeout(emit, mode === 'slow' ? 6000 : 250);
      },
      cancel() { finished = true; clean(); record('mock-api-cancelled'); },
    });
    return new Response(body, { status: 200, headers: { 'content-type': 'text/event-stream' } });
  };
  globalThis.nativeAcceptance = Object.freeze({
    snapshot: () => ({ entries: [...entries], droppedEntries: total - entries.length,
      activeConnections: ports.size, requests, scenario }),
    reset: () => { entries.length = 0; total = 0; },
    scenario: value => {
      if (!['answer', 'slow', 'error'].includes(value)) throw new Error('Use answer, slow, or error.');
      scenario = value;
    },
    disconnect: () => { for (const port of ports) port.disconnect(); },
    ready: chrome.storage.local.set({ interfaceMode: 'native',
      apiKey: 'sk-ant-snapscreen-physical-fixture-only', defaultPrompt: '' }),
  });
}

export async function hashFiles(directory) {
  const result = {};
  async function visit(current) {
    for (const entry of (await readdir(current, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name))) {
      const path = join(current, entry.name);
      if (entry.isSymbolicLink()) throw new Error(`Artifact contains a symbolic link: ${path}`);
      if (entry.isDirectory()) await visit(path);
      else if (entry.isFile()) result[relative(directory, path)] = createHash('sha256').update(await readFile(path)).digest('hex');
    }
  }
  await visit(directory);
  return result;
}

export async function prepareAcceptanceExtension(source, destination) {
  const derivedId = createHash('sha256').update(Buffer.from(EXTENSION_KEY, 'base64')).digest('hex')
    .slice(0, 32).replace(/[0-9a-f]/g, digit => String.fromCharCode(97 + parseInt(digit, 16)));
  if (derivedId !== EXTENSION_ID) throw new Error('Fixture extension key and ID disagree.');
  const originalHashes = await hashFiles(source);
  await cp(source, destination, { recursive: true });
  const manifest = JSON.parse(await readFile(join(destination, 'manifest.json'), 'utf8'));
  if (!manifest.permissions?.includes('nativeMessaging') || manifest.background?.type !== 'module') {
    throw new Error('Build the current SnapScreen extension before running acceptance.');
  }
  const worker = resolve(destination, manifest.background.service_worker);
  if (!worker.startsWith(`${resolve(destination)}/`)) throw new Error('The worker must be inside the extension.');
  manifest.key = EXTENSION_KEY;
  manifest.name = 'SnapScreen — packaged companion acceptance';
  await writeFile(join(destination, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
  await writeFile(join(dirname(worker), 'native-acceptance-original-worker.js'), await readFile(worker));
  await writeFile(join(dirname(worker), 'native-acceptance-shim.js'), `(${installAcceptanceShim.toString()})();\n`);
  await writeFile(worker, "import './native-acceptance-shim.js';\nimport './native-acceptance-original-worker.js';\n");
  return { originalHashes, fixtureHashes: await hashFiles(destination), extensionId: EXTENSION_ID,
    modifications: ['Public fixture key and display name', 'Worker loader imports mock-only API and metadata observer shim'],
    manifest };
}
