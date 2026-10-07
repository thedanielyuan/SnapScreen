import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { cp, readFile, realpath, writeFile } from 'node:fs/promises';
import { basename, dirname, join, relative, resolve } from 'node:path';
import { EXTENSION_ID, EXTENSION_KEY } from '../experiments/native-phase1/extension/config.mjs';
import { hashFiles, hashSummary, selectNativeExtension } from './native-extension-artifact.mjs';

export { EXTENSION_ID, hashFiles };

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

// The selected extension path is canonical, so compare the not-yet-created destination
// through its existing parents too (for example macOS /var -> /private/var).
async function canonicalPath(path) {
  try { return await realpath(path); }
  catch (error) {
    if (error.code !== 'ENOENT' || dirname(path) === path) throw error;
    return join(await canonicalPath(dirname(path)), basename(path));
  }
}

export async function prepareAcceptanceExtension(source, destination) {
  const derivedId = createHash('sha256').update(Buffer.from(EXTENSION_KEY, 'base64')).digest('hex')
    .slice(0, 32).replace(/[0-9a-f]/g, digit => String.fromCharCode(97 + parseInt(digit, 16)));
  if (derivedId !== EXTENSION_ID) throw new Error('Fixture extension key and ID disagree.');
  // Validate the untouched production artifact, including native-only exclusions, before
  // adding any fixture code. Never relax the package gate to accommodate instrumentation.
  const originalExtension = await selectNativeExtension(source);
  const originalHashes = originalExtension.hashes;
  destination = await canonicalPath(resolve(destination));
  const manifest = structuredClone(originalExtension.manifest);
  const worker = resolve(destination, manifest.background.service_worker);
  if (!worker.startsWith(`${destination}/`)) throw new Error('The worker must be inside the extension.');
  if (destination === originalExtension.directory || destination.startsWith(`${originalExtension.directory}/`)) {
    throw new Error('The acceptance fixture must be outside the production extension.');
  }
  const originalWorker = join(dirname(worker), 'native-acceptance-original-worker.js');
  const shim = join(dirname(worker), 'native-acceptance-shim.js');
  if ([originalWorker, shim].some(path => Object.hasOwn(originalHashes, relative(destination, path)))) {
    throw new Error('The production extension already contains acceptance fixture files.');
  }
  await cp(originalExtension.directory, destination, { recursive: true, errorOnExist: true, force: false });
  assert.deepEqual(await hashFiles(destination), originalHashes,
    'The copied acceptance extension differs from the selected production artifact.');
  const modifications = [];
  const currentHashes = { ...originalHashes };
  async function modify(path, contents, description) {
    const file = relative(destination, path);
    await writeFile(path, contents);
    const afterSha256 = createHash('sha256').update(contents).digest('hex');
    modifications.push({ path: file, description, beforeSha256: currentHashes[file] ?? null, afterSha256 });
    currentHashes[file] = afterSha256;
  }
  manifest.key = EXTENSION_KEY;
  await modify(join(destination, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`, 'Set the public fixture extension key');
  manifest.name = 'SnapScreen — packaged companion acceptance';
  await modify(join(destination, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`, 'Set the fixture display name');
  await modify(originalWorker, await readFile(worker), 'Preserve the byte-identical production worker beside its loader');
  await modify(shim, `(${installAcceptanceShim.toString()})();\n`, 'Add mock-only API responses and metadata observation');
  await modify(worker, "import './native-acceptance-shim.js';\nimport './native-acceptance-original-worker.js';\n",
    'Load the fixture shim before the unmodified production worker');
  const fixtureHashes = await hashFiles(destination);
  assert.deepEqual(fixtureHashes, currentHashes, 'The acceptance fixture modifications do not match the recorded hashes.');
  return { originalExtension, originalHashes, fixtureHashes, fixtureSha256: hashSummary(fixtureHashes),
    extensionId: EXTENSION_ID, modifications, manifest };
}
