// Chrome launches the extracted, installed production artifact. No native test hooks or API calls.
// This verifies transport/lifecycle and packaging, not physical focus or UI interaction acceptance.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { access, cp, mkdir, mkdtemp, readFile, readdir, realpath, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import { chromium } from 'playwright';
import { EXTENSION_KEY, EXTENSION_ID } from '../experiments/native-phase1/extension/config.mjs';
import { describeFileChanges, hashFiles, hashSummary, selectNativeExtension } from './native-extension-artifact.mjs';

const ROOT = resolve(import.meta.dirname, '..');
const { version } = JSON.parse(await readFile(join(ROOT, 'package.json'), 'utf8'));
const { values } = parseArgs({ options: {
  archive: { type: 'string' },
  'extension-dir': { type: 'string' },
  help: { type: 'boolean', default: false },
} });
if (values.help) {
  console.log('Usage: node scripts/native-companion-packaged-test.mjs [--archive file.zip] [--extension-dir directory] (default: dist/)');
  process.exit(0);
}
const selectedExtension = await selectNativeExtension(values['extension-dir']);
const { protocolVersion } = selectedExtension;
const architecture = process.arch === 'arm64' ? 'arm64' : 'x86_64';
const archive = resolve(values.archive ?? join(ROOT, 'native/macos/build/package',
  `SnapScreenCompanion-${version}-macos-${architecture}-unsigned.zip`));
if (process.platform !== 'darwin') throw new Error('The packaged companion test requires macOS.');

function command(executable, args, env = process.env) {
  const result = spawnSync(executable, args, { encoding: 'utf8', timeout: 30_000, env });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${executable} failed: ${result.stderr}`);
  return result.stdout.trim();
}

const delay = milliseconds => new Promise(resolvePromise => setTimeout(resolvePromise, milliseconds));
async function waitFor(description, predicate) {
  const deadline = Date.now() + 12_000;
  do {
    if (await predicate()) return;
    await delay(50);
  } while (Date.now() < deadline);
  throw new Error(`Timed out waiting for ${description}.`);
}

const root = await mkdtemp(join(tmpdir(), 'snapscreen-packaged-'));
const contexts = [];
let executable;
let browserVersion;
const hostPids = () => !executable ? [] : command('ps', ['-axo', 'pid=,comm=']).split('\n')
  .map(line => /^\s*(\d+)\s+(.+)$/.exec(line))
  .filter(match => match?.[2] === executable).map(match => Number(match[1]));

try {
  const archiveHash = createHash('sha256').update(await readFile(archive)).digest('hex');
  const extracted = join(root, 'extracted');
  command('ditto', ['-x', '-k', archive, extracted]);
  const folders = await readdir(extracted);
  assert.equal(folders.length, 1, 'The archive must contain one release folder.');
  const release = join(extracted, folders[0]);
  const app = join(release, 'SnapScreenCompanion.app');
  const build = JSON.parse(await readFile(join(app, 'Contents/Resources/snapscreen-build.json'), 'utf8'));
  assert.equal(build.testHooks, false);
  assert.equal(build.version, version);
  assert.equal(build.protocolVersion, selectedExtension.protocolVersion);
  const selfTest = command(join(app, 'Contents/MacOS/SnapScreenCompanion'), ['--self-test']);
  assert.match(selfTest, /checks passed/);
  assert.doesNotMatch(selfTest, /test hooks/);

  const extension = join(root, 'extension');
  await cp(selectedExtension.directory, extension, { recursive: true });
  assert.deepEqual(await hashFiles(extension), selectedExtension.hashes,
    'The copied extension differs from the selected build.');
  const manifestPath = join(extension, 'manifest.json');
  const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
  assert.equal(manifest.version, version);
  manifest.key = EXTENSION_KEY;
  await writeFile(manifestPath, JSON.stringify(manifest));
  const loader = join(extension, manifest.background.service_worker);
  await writeFile(join(dirname(loader), 'packaged-original-worker.js'), await readFile(loader));
  await writeFile(join(dirname(loader), 'packaged-action-shim.js'), `
const addListener = chrome.action.onClicked.addListener.bind(chrome.action.onClicked);
globalThis.__packagedAction = [];
chrome.action.onClicked.addListener = listener => {
  globalThis.__packagedAction.push(listener);
  addListener(listener);
};
`);
  await writeFile(loader, "import './packaged-action-shim.js';\nimport './packaged-original-worker.js';\n");
  const fixtureHashes = await hashFiles(extension);
  const extensionEvidence = { originalExtension: selectedExtension,
    fixtureHashes, fixtureSha256: hashSummary(fixtureHashes),
    modifications: describeFileChanges(selectedExtension.hashes, fixtureHashes) };
  // The documented commands use the default location, whose "Application Support" path has a space.
  const home = join(root, 'home');
  await mkdir(home);
  const installation = join(await realpath(home), 'Library/Application Support/SnapScreen');
  const installer = (...args) => command(process.execPath,
    [join(release, 'native-companion-install.mjs'), ...args], { ...process.env, HOME: home });
  for (let index = 0; index < 2; index += 1) {
    const profile = join(root, `profile-${index}`);
    await mkdir(profile);
    installer('--app', app, '--extension-id', EXTENSION_ID, '--user-data-dir', profile);
    const registration = JSON.parse(await readFile(join(profile, 'NativeMessagingHosts/com.snapscreen.companion.json'), 'utf8'));
    assert.deepEqual(registration.allowed_origins, [`chrome-extension://${EXTENSION_ID}/`]);
    assert.equal(registration.path, join(installation, 'SnapScreenCompanion.app/Contents/MacOS/SnapScreenCompanion'));
    executable = registration.path;
    const context = await chromium.launchPersistentContext(profile, {
      channel: 'chromium', headless: true,
      args: [`--disable-extensions-except=${extension}`, `--load-extension=${extension}`],
    });
    contexts.push(context);
    browserVersion = context.browser().version();
    // Any accidental API/network dependency fails offline; no credential is installed.
    await context.route('https://api.anthropic.com/**', route => route.abort());
    const worker = context.serviceWorkers()[0] ?? await context.waitForEvent('serviceworker');
    assert.equal(new URL(worker.url()).host, EXTENSION_ID);
    await worker.evaluate(() => { globalThis.__packaged = new Map(); });
  }
  const workers = contexts.map(context => context.serviceWorkers()[0]);
  const connect = (worker, id, message = { type: 'hello', version: protocolVersion, connectionId: id }) =>
    worker.evaluate(({ id, message }) => {
      const port = chrome.runtime.connectNative('com.snapscreen.companion');
      const state = { port, messages: [], disconnected: false };
      globalThis.__packaged.set(id, state);
      port.onMessage.addListener(value => state.messages.push(value));
      port.onDisconnect.addListener(() => {
        state.disconnected = true;
        state.error = chrome.runtime.lastError?.message;
      });
      port.postMessage(message);
    }, { id, message });
  const state = (worker, id) => worker.evaluate(id => {
    const { messages, disconnected } = globalThis.__packaged.get(id);
    return { messages, disconnected };
  }, id);
  const ready = async (worker, id) => {
    await connect(worker, id);
    await waitFor(`ready ${id}`, async () => (await state(worker, id)).messages.length > 0);
    assert.deepEqual((await state(worker, id)).messages, [{ type: 'ready', version: protocolVersion, connectionId: id }]);
  };
  const disconnect = (worker, id) => worker.evaluate(id => globalThis.__packaged.get(id).port.disconnect(), id);

  // Two independent Chrome user-data directories share an installed app, never a host process.
  await ready(workers[0], 'profile_a');
  await ready(workers[1], 'profile_b');
  await waitFor('two isolated host processes', () => hostPids().length === 2);
  await disconnect(workers[0], 'profile_a');
  await waitFor('only the disconnected host to exit', () => hostPids().length === 1);
  assert.equal((await state(workers[1], 'profile_b')).disconnected, false);
  await disconnect(workers[1], 'profile_b');
  await waitFor('both hosts to exit', () => hostPids().length === 0);

  // Invalid requests must terminate the real host before any capture can be processed.
  for (const [id, message] of [
    ['version', { type: 'hello', version: 999, connectionId: 'version' }],
    ['extra_key', { type: 'hello', version: protocolVersion, connectionId: 'extra_key', unexpected: true }],
    ['oversized', { type: 'hello', version: protocolVersion, connectionId: 'oversized', padding: 'x'.repeat(32 * 1024 * 1024) }],
  ]) {
    await connect(workers[0], id, message);
    await waitFor(`rejection of ${id}`, async () => (await state(workers[0], id)).disconnected);
    assert.deepEqual((await state(workers[0], id)).messages, []);
    await waitFor(`exit after ${id}`, () => hostPids().length === 0);
  }

  // Production selection surface receives a real PNG. A transport loss releases it and exits.
  await ready(workers[0], 'capture');
  await workers[0].evaluate(async (version) => {
    const canvas = new OffscreenCanvas(800, 600);
    const paint = canvas.getContext('2d');
    paint.fillStyle = '#ffffff'; paint.fillRect(0, 0, 800, 600);
    const png = new Uint8Array(await (await canvas.convertToBlob()).arrayBuffer());
    const imageDataUrl = `data:image/png;base64,${btoa(String.fromCharCode(...png))}`;
    globalThis.__packaged.get('capture').port.postMessage({ type: 'capture', version,
      connectionId: 'capture', sessionId: 'session', requestId: 'request', imageDataUrl });
  }, protocolVersion);
  await delay(300);
  assert.equal((await state(workers[0], 'capture')).disconnected, false);
  assert.equal(hostPids().length, 1);
  await disconnect(workers[0], 'capture');
  await waitFor('capturing host to exit', () => hostPids().length === 0);

  // Start a selection through the built extension's actual controller, then lose its worker.
  // The callback/capture are test supplied; this is lifecycle coverage, not activation evidence.
  const source = await contexts[0].newPage();
  const fixtureUrl = 'https://api.anthropic.com/snapscreen-packaged-test';
  await source.route(fixtureUrl, route => route.fulfill({ contentType: 'text/html',
    body: '<!doctype html><title>Packaged test</title><p>Dummy capture</p>' }));
  await source.goto(fixtureUrl);
  await source.bringToFront();
  await workers[0].evaluate(async (url) => {
    globalThis.__managedTypes = [];
    const connect = chrome.runtime.connectNative.bind(chrome.runtime);
    chrome.runtime.connectNative = name => {
      const port = connect(name);
      const post = port.postMessage.bind(port);
      port.postMessage = message => { globalThis.__managedTypes.push(message.type); post(message); };
      return port;
    };
    const canvas = new OffscreenCanvas(800, 600);
    const paint = canvas.getContext('2d');
    paint.fillStyle = '#ffffff'; paint.fillRect(0, 0, 800, 600);
    const png = new Uint8Array(await (await canvas.convertToBlob()).arrayBuffer());
    const imageDataUrl = `data:image/png;base64,${btoa(String.fromCharCode(...png))}`;
    chrome.tabs.captureVisibleTab = async () => imageDataUrl;
    await chrome.storage.local.set({ interfaceMode: 'native', apiKey: 'sk-ant-packaged-test-dummy' });
    const [tab] = await chrome.tabs.query({ url });
    if (globalThis.__packagedAction.length !== 1) throw new Error('Missing packaged action callback.');
    globalThis.__packagedAction[0](tab);
  }, fixtureUrl);
  await waitFor('extension-managed native capture', () => workers[0].evaluate(() => globalThis.__managedTypes.includes('capture')));
  assert.equal(hostPids().length, 1);
  const cdp = await contexts[0].newCDPSession(contexts[0].pages()[0]);
  const versions = new Map();
  cdp.on('ServiceWorker.workerVersionUpdated', ({ versions: updates }) => {
    for (const update of updates) versions.set(update.versionId, update);
  });
  await cdp.send('ServiceWorker.enable');
  await waitFor('the extension worker version', () => [...versions.values()]
    .some(value => value.scriptURL === workers[0].url() && value.runningStatus === 'running'));
  const workerVersion = [...versions.values()].find(value => value.scriptURL === workers[0].url()
    && value.runningStatus === 'running');
  await cdp.send('ServiceWorker.stopWorker', { versionId: workerVersion.versionId });
  await waitFor('host exit after worker stop', () => hostPids().length === 0);
  const options = await contexts[0].newPage();
  await options.goto(`chrome-extension://${EXTENSION_ID}/${manifest.options_page}`);
  await options.evaluate(() => chrome.runtime.sendMessage({ type: 'packaged-test-wakeup' }).catch(() => undefined));
  await delay(500);
  assert.equal(hostPids().length, 0, 'Worker restart unexpectedly replayed a native session.');

  for (const context of contexts) await context.close();
  contexts.length = 0;
  for (let index = 0; index < 2; index += 1) {
    installer('--remove', '--extension-id', EXTENSION_ID, '--user-data-dir', join(root, `profile-${index}`));
    await assert.rejects(access(join(root, `profile-${index}`, 'NativeMessagingHosts/com.snapscreen.companion.json')),
      { code: 'ENOENT' });
    if (index === 0) {
      await access(executable);
      await access(join(root, 'profile-1/NativeMessagingHosts/com.snapscreen.companion.json'));
    } else {
      // The last removal deletes the app, its receipt, and the then-empty default folder.
      await assert.rejects(access(installation), { code: 'ENOENT' });
    }
  }
  console.log(JSON.stringify({ passed: true, archive, archiveSha256: archiveHash, version,
    extension: extensionEvidence,
    browserVersion, architecture: process.arch, macOS: command('sw_vers', ['-productVersion']),
    checks: ['production self-tests', 'packaged install at the default path', 'real Chrome handshake', 'two profiles',
      'version and shape rejection', 'oversized malformed request rejection', 'capture disconnect',
      'worker restart without replay', 'uninstall'], physicalAcceptance: 'not measured' }, null, 2));
} finally {
  for (const context of contexts) await context.close().catch(() => undefined);
  for (const pid of hostPids()) { try { process.kill(pid, 'SIGTERM'); } catch { /* Already exited. */ } }
  await rm(root, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 });
}
