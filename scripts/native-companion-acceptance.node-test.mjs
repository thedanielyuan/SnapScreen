import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { runInNewContext } from 'node:vm';
import { EXTENSION_ID, hashFiles, installAcceptanceShim, prepareAcceptanceExtension } from './native-companion-acceptance-fixture.mjs';

function fixture() {
  function event() {
    const listeners = [];
    return { listeners, addListener: listener => listeners.push(listener) };
  }
  const sent = [];
  const port = { postMessage: message => sent.push(message), disconnect() { /* Native transport stub. */ },
    onMessage: event(), onDisconnect: event() };
  const capture = [];
  const stored = [];
  const context = {
    chrome: {
      runtime: { connectNative: () => port },
      action: { onClicked: event() }, commands: { onCommand: event() },
      tabs: { captureVisibleTab: async (...args) => { capture.push(args); return 'data:image/png;base64,PRIVATE_SCREENSHOT'; } },
      storage: { local: { set: async value => { stored.push(value); } } },
    },
    Response, ReadableStream, TextEncoder, DOMException,
    setTimeout: fn => setTimeout(fn, 0), clearTimeout,
  };
  runInNewContext(`(${installAcceptanceShim.toString()})();`, context);
  return { context, port, sent, capture, stored, control: context.nativeAcceptance };
}

test('fixture preparation preserves production files and adds a stable isolated wrapper', async () => {
  const root = await mkdtemp(join(tmpdir(), 'snapscreen-acceptance-test-'));
  try {
    const source = join(root, 'source');
    const destination = join(root, 'fixture');
    await mkdir(source);
    await writeFile(join(source, 'manifest.json'), JSON.stringify({ name: 'SnapScreen', permissions: ['nativeMessaging'],
      background: { type: 'module', service_worker: 'worker.js' } }));
    await writeFile(join(source, 'worker.js'), 'globalThis.originalWorker = true;\n');
    const before = await hashFiles(source);
    const result = await prepareAcceptanceExtension(source, destination);
    assert.deepEqual(await hashFiles(source), before);
    assert.deepEqual(result.originalHashes, before);
    assert.equal(result.extensionId, EXTENSION_ID);
    assert.ok(result.manifest.key);
    assert.equal(await readFile(join(destination, 'native-acceptance-original-worker.js'), 'utf8'),
      await readFile(join(source, 'worker.js'), 'utf8'));
    assert.match(await readFile(join(destination, 'worker.js'), 'utf8'), /native-acceptance-shim/);
    assert.equal(Object.keys(result.fixtureHashes).length, 4);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('the mock has no network passthrough and streams a complete answer', async () => {
  const { context, control, stored } = fixture();
  await control.ready;
  assert.equal(stored[0].interfaceMode, 'native');
  await assert.rejects(context.fetch('https://example.com'), /blocks external fetch/);
  const response = await context.fetch('https://api.anthropic.com/v1/messages');
  const stream = await response.text();
  assert.equal(response.status, 200);
  assert.match(stream, /event: content_block_delta/);
  const answer = stream.split('\n').filter(line => line.startsWith('data: '))
    .map(line => JSON.parse(line.slice(6))).filter(event => event.type === 'content_block_delta')
    .map(event => event.delta.text).join('');
  assert.match(answer, /```python\nprint\(2 \+ 2\)\n```/);
  assert.match(stream, /event: message_stop/);
  assert.equal(control.snapshot().requests, 1);
  assert.ok(control.snapshot().entries.some(entry => entry.type === 'mock-api-complete'));
});

test('mocked failure is one-shot so the production Retry button can succeed', async () => {
  const { context, control } = fixture();
  control.scenario('error');
  assert.equal((await context.fetch('https://api.anthropic.com/v1/messages')).status, 529);
  assert.equal(control.snapshot().scenario, 'answer');
  assert.equal(await (await context.fetch('https://api.anthropic.com/v1/messages')).text()
    .then(text => text.includes('message_stop')), true);
  assert.throws(() => control.scenario('unknown'), /answer, slow, or error/);
});

test('mocked streaming honors Stop and disconnect aborts', async () => {
  const { context, control } = fixture();
  const controller = new AbortController();
  const response = await context.fetch('https://api.anthropic.com/v1/messages', { signal: controller.signal });
  controller.abort();
  await assert.rejects(response.text(), { name: 'AbortError' });
  assert.ok(control.snapshot().entries.some(entry => entry.type === 'mock-api-aborted'));
  assert.ok(!control.snapshot().entries.some(entry => entry.type === 'mock-api-complete'));
});

test('observer preserves real capture and activation and does not log content', async () => {
  const { context, control, port, sent, capture } = fixture();
  let activated;
  context.chrome.action.onClicked.addListener(tab => { activated = tab.id; });
  context.chrome.action.onClicked.listeners[0]({ id: 42 });
  assert.equal(activated, 42);
  const image = await context.chrome.tabs.captureVisibleTab(7, { format: 'png' });
  assert.deepEqual(capture, [[7, { format: 'png' }]]);
  const connection = context.chrome.runtime.connectNative('com.snapscreen.companion');
  connection.postMessage({ type: 'capture', connectionId: 'connection-1', imageDataUrl: image });
  port.onMessage.listeners[0]({ type: 'followup', text: 'PRIVATE_QUESTION', requestId: 'request-1' });
  assert.equal(sent[0].imageDataUrl, image);
  const report = JSON.stringify(control.snapshot());
  assert.doesNotMatch(report, /PRIVATE_|sk-ant-/);
  assert.match(report, /imageLength/);
  assert.match(report, /invocation/);
  control.disconnect();
  port.onDisconnect.listeners[0]();
  assert.equal(control.snapshot().activeConnections, 0);
  assert.equal(control.snapshot().entries.filter(entry => entry.type === 'native-disconnect').length, 1);
});
