import assert from 'node:assert/strict';
import { lstat, mkdtemp, mkdir, readFile, realpath, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { test } from 'node:test';
import { runInNewContext } from 'node:vm';
import { EXTENSION_ID, hashFiles, installAcceptanceShim, prepareAcceptanceExtension } from './native-companion-acceptance-fixture.mjs';
import { hashSummary } from './native-extension-artifact.mjs';

async function extensionFixture(root, variant = 'ordinary') {
  const repository = resolve(import.meta.dirname, '..');
  const source = join(root, 'source');
  const manifest = JSON.parse(await readFile(join(repository,
    variant === 'native-only' ? 'src/manifest-native.json' : 'src/manifest.json'), 'utf8'));
  manifest.version = JSON.parse(await readFile(join(repository, 'package.json'), 'utf8')).version;
  manifest.background.service_worker = 'worker.js';
  manifest.icons = { 16: 'icon.png' };
  manifest.action.default_icon = { 16: 'icon.png' };
  if (variant === 'ordinary') manifest.web_accessible_resources = [{ resources: ['icon.png'], matches: ['https://*/*'] }];
  for (const [file, contents] of [
    ['manifest.json', JSON.stringify(manifest)],
    ['worker.js', 'globalThis.originalWorker = true;\n'],
    ['settings.js', 'globalThis.originalSettings = true;\n'],
    [manifest.options_page, '<script type="module" src="/settings.js"></script>'],
    ['icon.png', Buffer.from([137, 80, 78, 71])],
  ]) {
    await mkdir(dirname(join(source, file)), { recursive: true });
    await writeFile(join(source, file), contents);
  }
  return { source, manifest };
}

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

for (const variant of ['ordinary', 'native-only']) test(`${variant} fixture preserves production files and records every isolated edit`, async () => {
  const root = await mkdtemp(join(tmpdir(), 'snapscreen-acceptance-test-'));
  try {
    const { source, manifest } = await extensionFixture(root, variant);
    const destination = join(root, 'fixture');
    const before = await hashFiles(source);
    const result = await prepareAcceptanceExtension(source, destination);
    assert.deepEqual(await hashFiles(source), before);
    assert.deepEqual(result.originalHashes, before);
    assert.equal(result.originalExtension.directory, await realpath(source));
    assert.equal(result.originalExtension.variant, variant);
    assert.equal(result.originalExtension.sha256, hashSummary(before));
    assert.equal(result.originalExtension.protocolVersion, 3);
    assert.deepEqual(result.originalExtension.manifest, manifest);
    assert.equal(result.extensionId, EXTENSION_ID);
    assert.ok(result.manifest.key);
    assert.equal(await readFile(join(destination, 'native-acceptance-original-worker.js'), 'utf8'),
      await readFile(join(source, 'worker.js'), 'utf8'));
    assert.match(await readFile(join(destination, 'worker.js'), 'utf8'), /native-acceptance-shim/);
    assert.equal(Object.keys(result.fixtureHashes).length, Object.keys(before).length + 2);
    assert.equal(result.fixtureSha256, hashSummary(result.fixtureHashes));
    assert.deepEqual(result.modifications.map(change => change.path), [
      'manifest.json', 'manifest.json', 'native-acceptance-original-worker.js', 'native-acceptance-shim.js', 'worker.js',
    ]);
    const observed = { ...before };
    for (const change of result.modifications) {
      assert.equal(change.beforeSha256, observed[change.path] ?? null);
      assert.match(change.afterSha256, /^[a-f\d]{64}$/u);
      assert.ok(change.description);
      observed[change.path] = change.afterSha256;
    }
    assert.deepEqual(observed, result.fixtureHashes);
    const fixtureManifest = { ...result.manifest };
    const productionManifest = { ...manifest };
    delete fixtureManifest.key;
    delete fixtureManifest.name;
    delete productionManifest.name;
    assert.deepEqual(fixtureManifest, productionManifest);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('fixture preparation rejects excluded native-only assets before copying or adding instrumentation', async () => {
  const root = await mkdtemp(join(tmpdir(), 'snapscreen-acceptance-test-'));
  try {
    const { source } = await extensionFixture(root, 'native-only');
    await writeFile(join(source, 'worker.js'), 'globalThis.__nativeLive = true;\n');
    const before = await hashFiles(source);
    const destination = join(root, 'fixture');
    await assert.rejects(prepareAcceptanceExtension(source, destination), /test hook/);
    assert.deepEqual(await hashFiles(source), before);
    await assert.rejects(readFile(join(destination, 'manifest.json')), { code: 'ENOENT' });
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('fixture preparation refuses to alter the selected production directory', async () => {
  const root = await mkdtemp(join(tmpdir(), 'snapscreen-acceptance-test-'));
  try {
    const { source } = await extensionFixture(root);
    const before = await hashFiles(source);
    await assert.rejects(prepareAcceptanceExtension(source, source), /outside the production extension/);
    await assert.rejects(prepareAcceptanceExtension(source, join(source, 'fixture')), /outside the production extension/);
    assert.deepEqual(await hashFiles(source), before);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('fixture preparation through a symlinked build instruments a real copy only', async () => {
  const root = await mkdtemp(join(tmpdir(), 'snapscreen-acceptance-test-'));
  try {
    const { source } = await extensionFixture(root, 'native-only');
    const link = join(root, 'linked-source');
    await symlink(source, link);
    const before = await hashFiles(source);
    const destination = join(root, 'fixture');
    const result = await prepareAcceptanceExtension(link, destination);
    assert.equal(result.originalExtension.directory, await realpath(source));
    assert.equal((await lstat(destination)).isSymbolicLink(), false);
    assert.match(await readFile(join(destination, 'worker.js'), 'utf8'), /native-acceptance-shim/);
    assert.deepEqual(await hashFiles(source), before);
    // A destination reached through the link is still inside the production extension.
    await assert.rejects(prepareAcceptanceExtension(source, join(link, 'fixture')), /outside the production extension/);
    assert.deepEqual(await hashFiles(source), before);
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
  context.chrome.action.onClicked.addListener(tab => { activated = tab.id; return 'toolbar-result'; });
  assert.equal(context.chrome.action.onClicked.listeners[0]({ id: 42 }), 'toolbar-result');
  assert.equal(activated, 42);
  const shortcutTab = { id: 43 };
  let shortcut;
  context.chrome.commands.onCommand.addListener(async (command, tab) => { shortcut = { command, tab }; return 'shortcut-result'; });
  assert.equal(await context.chrome.commands.onCommand.listeners[0]('snip', shortcutTab), 'shortcut-result');
  assert.equal(shortcut.command, 'snip');
  assert.equal(shortcut.tab, shortcutTab);
  const invocations = control.snapshot().entries.filter(entry => entry.type === 'invocation');
  assert.equal(invocations.length, 2);
  assert.equal(invocations[0].route, 'toolbar');
  assert.equal(invocations[1].route, 'shortcut');
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
