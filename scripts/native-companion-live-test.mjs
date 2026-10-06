// Real Chrome-launched companion test: a disposable browser profile and host registration, mocked
// API answers, and an unattended companion build (test hooks). Companion windows appear briefly.
import { spawnSync } from 'node:child_process';
import { cp, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { chromium } from 'playwright';
import { EXTENSION_KEY, EXTENSION_ID } from '../experiments/native-phase1/extension/config.mjs';

const ROOT = resolve(import.meta.dirname, '..');
const DIST = join(ROOT, 'dist');
const FIXTURE_URL = 'https://api.anthropic.com/snapscreen-native-live';
const API_URL = 'https://api.anthropic.com/v1/messages';
const TEST_API_KEY = 'sk-ant-snapscreen-native-live-only-5D21C8';
const FIRST_ANSWER = 'SNAPSCREEN_LIVE_FIRST_ANSWER_8B2D41\n\n```python\nprint(2 + 2)\n```\n\nThe result is 4.';
// Typed by the companion's test hook after the first answer (native/macos/main.swift).
const FOLLOW_UP = 'SNAPSCREEN_LIVE_FOLLOW_UP';
const FOLLOW_UP_ANSWER = 'SNAPSCREEN_LIVE_FOLLOW_UP_ANSWER_47C0E9';
const STEP_TIMEOUT_MS = 20_000;
const OVERALL_TIMEOUT_MS = 90_000;

const sleep = milliseconds => new Promise(resolvePromise => setTimeout(resolvePromise, milliseconds));

function answerSse(text) {
  const half = Math.ceil(text.length / 2);
  return [
    { type: 'message_start', message: { id: 'msg_snapscreen_native_live', type: 'message', role: 'assistant',
      model: 'claude-opus-5-5', content: [], stop_reason: null, stop_sequence: null,
      usage: { input_tokens: 1, output_tokens: 0 } } },
    { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
    { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: text.slice(0, half) } },
    { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: text.slice(half) } },
    { type: 'content_block_stop', index: 0 },
    { type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 2 } },
    { type: 'message_stop' },
  ].map(data => `event: ${data.type}\ndata: ${JSON.stringify(data)}\n\n`).join('');
}

async function waitFor(description, predicate, timeout = STEP_TIMEOUT_MS) {
  const deadline = Date.now() + timeout;
  for (;;) {
    const value = await predicate();
    if (value) return value;
    if (Date.now() > deadline) throw new Error(`Timed out waiting for ${description}.`);
    await sleep(50);
  }
}

async function prepareExtension(directory) {
  await cp(DIST, directory, { recursive: true });
  const manifest = JSON.parse(await readFile(join(directory, 'manifest.json'), 'utf8'));
  manifest.key = EXTENSION_KEY;
  await writeFile(join(directory, 'manifest.json'), JSON.stringify(manifest));
  const loaderPath = join(directory, manifest.background.service_worker);
  await writeFile(join(directory, 'native-live-original-worker.js'), await readFile(loaderPath, 'utf8'));
  // Records the real action callback so the test can invoke it; only this disposable copy has it.
  await writeFile(join(directory, 'native-live-action-shim.js'), `
const addActionListener = chrome.action.onClicked.addListener.bind(chrome.action.onClicked);
globalThis.__nativeLiveActionListeners = [];
chrome.action.onClicked.addListener = (listener) => {
  globalThis.__nativeLiveActionListeners.push(listener);
  addActionListener(listener);
};
`);
  await writeFile(loaderPath, "import './native-live-action-shim.js';\nimport './native-live-original-worker.js';\n");
}

async function run(root) {
  let manifest;
  try {
    manifest = JSON.parse(await readFile(join(DIST, 'manifest.json'), 'utf8'));
  } catch (error) {
    throw new Error('Could not read dist/manifest.json. Run npm run build first.', { cause: error });
  }
  if (!manifest.permissions?.includes('nativeMessaging')) throw new Error('dist/ lacks nativeMessaging.');

  const bundle = join(root, 'SnapScreenCompanionTest.app');
  const build = spawnSync(process.execPath, [join(ROOT, 'scripts/native-companion-build.mjs'),
    '--test-hooks', '--bundle', bundle], { encoding: 'utf8' });
  if (build.status !== 0) throw new Error(`Test companion build failed:\n${build.stderr}`);
  const hostExecutable = join(bundle, 'Contents/MacOS/SnapScreenCompanion');
  const hostPids = () => spawnSync('pgrep', ['-f', hostExecutable], { encoding: 'utf8' })
    .stdout.trim().split('\n').filter(Boolean);

  const extension = join(root, 'extension');
  const profile = join(root, 'profile');
  const scenarioFile = join(root, 'scenario.txt');
  await prepareExtension(extension);
  await writeFile(scenarioFile, 'hold');

  const apiRequests = [];
  const context = await chromium.launchPersistentContext(profile, {
    channel: 'chromium',
    headless: true,
    args: [`--disable-extensions-except=${extension}`, `--load-extension=${extension}`],
    // Chrome passes its environment to native hosts; the test-hook build reads its scenario here.
    env: { ...process.env, SNAPSCREEN_TEST_SCENARIO_FILE: scenarioFile },
  });
  try {
    await context.route(FIXTURE_URL, route => route.fulfill({
      body: '<!doctype html><html><body><h1>What is 2 + 2?</h1></body></html>', contentType: 'text/html' }));
    await context.route(API_URL, async (route) => {
      const request = route.request();
      apiRequests.push({ key: request.headers()['x-api-key'], body: request.postData() ?? '' });
      await route.fulfill({ status: 200, contentType: 'text/event-stream',
        body: answerSse(apiRequests.length === 1 ? FIRST_ANSWER : FOLLOW_UP_ANSWER) });
    });
    const worker = context.serviceWorkers()[0] ?? await context.waitForEvent('serviceworker');
    const extensionId = new URL(worker.url()).host;
    if (extensionId !== EXTENSION_ID) throw new Error('Unexpected live-test extension ID.');
    const installer = (...extra) => spawnSync(process.execPath, [join(ROOT, 'scripts/native-companion-install.mjs'),
      '--extension-id', extensionId, '--user-data-dir', profile, '--executable', hostExecutable, ...extra],
    { encoding: 'utf8' });
    const registered = installer();
    if (registered.status !== 0) throw new Error(`Host registration failed:\n${registered.stderr}`);

    const page = await context.newPage();
    await page.goto(FIXTURE_URL, { waitUntil: 'domcontentloaded' });
    await worker.evaluate(async ({ apiKey }) => {
      const trace = [];
      const leaks = [];
      globalThis.__nativeLive = { trace, leaks };
      const connect = chrome.runtime.connectNative.bind(chrome.runtime);
      chrome.runtime.connectNative = (name) => {
        const port = connect(name);
        const post = port.postMessage.bind(port);
        port.postMessage = (message) => {
          if (JSON.stringify(message).includes(apiKey)) leaks.push(message.type);
          trace.push({ direction: 'out', type: message.type, status: message.status, text: message.text });
          return post(message);
        };
        port.onMessage.addListener(message => trace.push({ direction: 'in', type: message?.type }));
        // Chrome fires onDisconnect only for the other end, so record the extension's own close too.
        let ended = false;
        const end = () => {
          if (!ended) trace.push({ direction: 'end', type: 'disconnect' });
          ended = true;
        };
        port.onDisconnect.addListener(end);
        const disconnect = port.disconnect.bind(port);
        port.disconnect = () => { end(); disconnect(); };
        return port;
      };
      // An invocation from the test has no user gesture for activeTab, so supply a realistically
      // large screenshot: 2880×1800 with an incompressible region, about 10 MB as a data URL.
      const canvas = new OffscreenCanvas(2880, 1800);
      const context2d = canvas.getContext('2d');
      context2d.fillStyle = '#f8fafc';
      context2d.fillRect(0, 0, 2880, 1800);
      const noise = context2d.createImageData(1200, 900);
      for (let i = 0; i < noise.data.length; i += 1) noise.data[i] = i % 4 === 3 ? 255 : Math.random() * 255;
      context2d.putImageData(noise, 200, 200);
      const bytes = new Uint8Array(await (await canvas.convertToBlob({ type: 'image/png' })).arrayBuffer());
      let binary = '';
      for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
      const dataUrl = `data:image/png;base64,${btoa(binary)}`;
      chrome.tabs.captureVisibleTab = async () => dataUrl;
      globalThis.__nativeLive.captureCount = 0;
      const capture = chrome.tabs.captureVisibleTab;
      chrome.tabs.captureVisibleTab = async () => {
        globalThis.__nativeLive.captureCount += 1;
        return capture();
      };
      await chrome.storage.local.set({ interfaceMode: 'native', apiKey });
    }, { apiKey: TEST_API_KEY });

    // A real toolbar click always targets the active tab.
    const invoke = async () => { await page.bringToFront(); await worker.evaluate(async (url) => {
      const [tab] = await chrome.tabs.query({ url });
      globalThis.__nativeLive.tabId = tab.id;
      globalThis.__nativeLive.trace.length = 0;
      await chrome.action.setBadgeText({ tabId: tab.id, text: '' });
      globalThis.__nativeLiveActionListeners[0](tab);
    }, FIXTURE_URL); };
    const trace = () => worker.evaluate(() => globalThis.__nativeLive.trace);
    const types = async () => (await trace()).map(entry => `${entry.direction}:${entry.type}`);
    const hostExited = () => waitFor('the companion process to exit', () => hostPids().length === 0, 5_000);

    const checkOptions = async (expectedStatus, expectReady) => {
      const requestCount = apiRequests.length;
      const captureCount = await worker.evaluate(() => globalThis.__nativeLive.captureCount);
      const options = await context.newPage();
      try {
        await options.addInitScript(() => {
          const trace = [];
          globalThis.__companionAvailabilityTrace = trace;
          const connect = chrome.runtime.connectNative.bind(chrome.runtime);
          chrome.runtime.connectNative = (name) => {
            trace.push({ direction: 'connect', name });
            const port = connect(name);
            const post = port.postMessage.bind(port);
            port.postMessage = (message) => {
              trace.push({ direction: 'out', message });
              return post(message);
            };
            port.onMessage.addListener(message => trace.push({ direction: 'in', message }));
            const disconnect = port.disconnect.bind(port);
            port.disconnect = () => {
              trace.push({ direction: 'end' });
              disconnect();
            };
            return port;
          };
          const capture = chrome.tabs.captureVisibleTab.bind(chrome.tabs);
          chrome.tabs.captureVisibleTab = (...args) => {
            trace.push({ direction: 'capture' });
            return capture(...args);
          };
        });
        await options.goto(`chrome-extension://${extensionId}/${manifest.options_page}`);
        await options.locator('#save-settings').waitFor({ state: 'visible' });
        await waitFor('Settings hydration', () => options.locator('#save-settings').isEnabled());
        if ((await options.evaluate(() => globalThis.__companionAvailabilityTrace)).length
          || hostPids().length) throw new Error('Opening Settings launched the companion.');

        await options.locator('#check-companion').click();
        await waitFor(`Settings availability: ${expectedStatus}`, async () =>
          (await options.locator('#companion-status').textContent()).includes(expectedStatus));
        await waitFor('the Settings check to finish', () => options.locator('#check-companion').isEnabled());
        const availabilityTrace = await options.evaluate(() => globalThis.__companionAvailabilityTrace);
        const outgoing = availabilityTrace.filter(entry => entry.direction === 'out');
        const incoming = availabilityTrace.filter(entry => entry.direction === 'in');
        if (availabilityTrace.filter(entry => entry.direction === 'connect').length !== 1
          || outgoing.length !== 1 || outgoing[0].message.type !== 'hello'
          || JSON.stringify(Object.keys(outgoing[0].message).sort()) !== JSON.stringify(['connectionId', 'type', 'version'])
          || availabilityTrace.filter(entry => entry.direction === 'end').length !== 1
          || availabilityTrace.some(entry => entry.direction === 'capture')
          || apiRequests.length !== requestCount
          || await worker.evaluate(() => globalThis.__nativeLive.captureCount) !== captureCount) {
          throw new Error('Settings availability check did more than one handshake.');
        }
        if (expectReady && (incoming.length !== 1 || incoming[0].message.type !== 'ready'
          || incoming[0].message.connectionId !== outgoing[0].message.connectionId
          || incoming[0].message.version !== outgoing[0].message.version)) {
          throw new Error('Settings availability check did not complete a matching version handshake.');
        }
        if (!expectReady && incoming.length) throw new Error('A missing host responded to the Settings check.');
        await hostExited();
      } finally {
        await options.close();
        await page.bringToFront();
      }
    };

    // Settings checks a real host only on request and closes it before any capture or API call.
    await checkOptions('Companion is installed and responding.', true);

    // 1. A complete unattended exchange: select, answer, follow-up, answer, close.
    await writeFile(scenarioFile, 'exchange');
    await invoke();
    await waitFor('the exchange to close', async () => (await types()).includes('end:disconnect'));
    const exchange = await trace();
    const expected = ['out:hello', 'in:ready', 'out:capture', 'in:selected', 'out:accepted', 'out:started',
      'out:answer', 'in:followup', 'out:started', 'out:answer', 'in:close', 'end:disconnect'];
    const observed = exchange.map(entry => `${entry.direction}:${entry.type}`)
      .filter((entry, index, all) => entry !== 'out:answer' || all[index + 1] !== 'out:answer');
    if (JSON.stringify(observed.filter(entry => expected.includes(entry))) !== JSON.stringify(expected)) {
      throw new Error(`Unexpected exchange: ${JSON.stringify(observed)}`);
    }
    const done = exchange.filter(entry => entry.type === 'answer' && entry.status === 'done').map(entry => entry.text);
    if (JSON.stringify(done) !== JSON.stringify([FIRST_ANSWER, FOLLOW_UP_ANSWER])) {
      throw new Error(`Unexpected answers: ${JSON.stringify(done)}`);
    }
    if (apiRequests.length !== 2 || apiRequests.some(request => request.key !== TEST_API_KEY)
      || !apiRequests[0].body.includes('"type":"image"')
      || !apiRequests[1].body.includes(FOLLOW_UP)
      || !JSON.parse(apiRequests[1].body).messages.some(message => message.role === 'assistant'
        && message.content === FIRST_ANSWER)) {
      throw new Error('The exchange did not make the expected background API requests.');
    }
    await hostExited();

    // 2. Navigation before a region is accepted expires the selection; Chrome then ends the host.
    await writeFile(scenarioFile, 'hold');
    await invoke();
    await waitFor('the held selection', async () => (await types()).includes('out:capture'));
    await sleep(500);
    await worker.evaluate(() => chrome.tabs.reload(globalThis.__nativeLive.tabId));
    await waitFor('the expired selection', async () => {
      const current = await types();
      return current.includes('out:expired') && current.includes('end:disconnect');
    });
    if (!(await types()).includes('out:expired')) throw new Error('Navigation did not expire the selection.');
    await hostExited();
    await page.waitForLoadState('domcontentloaded');

    // 3. A missing host reports an installation problem on the badge without any page UI.
    if (installer('--remove').status !== 0) throw new Error('Host registration removal failed.');
    await checkOptions('Companion not found for this browser', false);
    // Settings matches Chrome's exact errors for the two common registration mistakes.
    const registration = join(profile, 'NativeMessagingHosts', 'com.snapscreen.companion.json');
    const register = (path, origin) => writeFile(registration, JSON.stringify({ name: 'com.snapscreen.companion',
      description: 'SnapScreen live-test fixture', path, type: 'stdio', allowed_origins: [origin] }));
    await register(hostExecutable, 'chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/');
    await checkOptions('registered for a different extension ID', false);
    // Chrome reports a missing executable as not found, and an unexecutable one as unstartable.
    await register(join(root, 'missing-companion'), `chrome-extension://${extensionId}/`);
    await checkOptions('Companion not found for this browser', false);
    const unexecutable = join(root, 'unexecutable-companion');
    await writeFile(unexecutable, '#!/bin/sh\n', { mode: 0o644 });
    await register(unexecutable, `chrome-extension://${extensionId}/`);
    await checkOptions("couldn't start it", false);
    await rm(registration);
    await invoke();
    const title = await waitFor('the missing-host badge', () => worker.evaluate(async () => {
      const tabId = globalThis.__nativeLive.tabId;
      return await chrome.action.getBadgeText({ tabId }) === '!' && chrome.action.getTitle({ tabId });
    }));
    if (!title.includes('companion could not start')) throw new Error(`Unexpected missing-host title: ${title}`);

    const leaks = await worker.evaluate(() => globalThis.__nativeLive.leaks);
    if (leaks.length) throw new Error(`The API key reached the companion in: ${leaks.join(', ')}.`);
    if (apiRequests.length !== 2) throw new Error('A failed or expired session made an API request.');
    if (page.frames().length !== 1) throw new Error('Native mode attached a frame to the page.');
  } finally {
    await context.close().catch(() => undefined);
    for (const pid of hostPids()) spawnSync('kill', [pid]);
  }
}

if (process.platform !== 'darwin') throw new Error('The live companion test requires macOS.');
const root = await mkdtemp(join(tmpdir(), 'snapscreen-native-live-'));
let failure;
try {
  await Promise.race([
    run(root),
    sleep(OVERALL_TIMEOUT_MS).then(() => { throw new Error('The live companion test timed out.'); }),
  ]);
} catch (error) {
  failure = error;
} finally {
  await rm(root, { recursive: true, force: true });
}
if (failure) {
  if (failure instanceof Error && /Executable doesn't exist/.test(failure.message)) {
    process.stderr.write('Playwright Chromium is not installed. Run: npx playwright install chromium\n');
  } else {
    process.stderr.write(`${failure instanceof Error ? failure.stack : String(failure)}\n`);
  }
  process.exit(1);
}
process.stdout.write('Native companion live test passed: Chrome-launched handshake, 10 MB capture, unattended '
  + 'selection, streamed answer, follow-up, Close and host exit; navigation expiry; missing-host badge; '
  + 'explicit Settings availability checks with installed, missing, moved, foreign-origin and unstartable hosts.\n');
process.exit(0);
