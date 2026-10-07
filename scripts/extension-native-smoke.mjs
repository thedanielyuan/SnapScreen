import assert from 'node:assert/strict';
import { cp, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { chromium } from 'playwright';

const ROOT = resolve(import.meta.dirname, '..');
const DIST = join(ROOT, 'dist-native');
const NORMAL_DIST = join(ROOT, 'dist');
const OPTIONS_PATH = 'src/options/options-native.html';
const FIXTURE_URL = 'https://api.anthropic.com/snapscreen-native-smoke';
const API_URL = 'https://api.anthropic.com/v1/messages';
const TEST_API_KEY = 'sk-ant-native-only-smoke-not-a-real-key';
const ANSWER = 'SNAPSCREEN_NATIVE_ONLY_SMOKE_ANSWER';
const SCREENSHOT = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
const TIMEOUT_MS = 10_000;

async function readJson(path) {
  return JSON.parse(await readFile(path, 'utf8'));
}

async function listFiles(directory, prefix = '') {
  const entries = await readdir(directory, { withFileTypes: true });
  const nested = await Promise.all(entries.map(async (entry) => {
    const path = prefix + entry.name;
    return entry.isDirectory() ? listFiles(join(directory, entry.name), `${path}/`) : [path];
  }));
  return nested.flat();
}

async function verifyBuild() {
  let manifest;
  let normalManifest;
  try {
    [manifest, normalManifest] = await Promise.all([
      readJson(join(DIST, 'manifest.json')),
      readJson(join(NORMAL_DIST, 'manifest.json')),
    ]);
  } catch (error) {
    throw new Error('Run npm run build and npm run build:extension-native first.', { cause: error });
  }
  const { version } = await readJson(join(ROOT, 'package.json'));
  assert.equal(manifest.version, version, 'Native-only manifest version must match package.json.');
  assert.equal(normalManifest.version, version, 'Rebuild the normal extension for the probe control.');
  assert.equal(manifest.manifest_version, 3);
  assert.equal(manifest.minimum_chrome_version, '116');
  assert.deepEqual([...manifest.permissions].sort(), ['activeTab', 'nativeMessaging', 'storage']);
  assert.deepEqual(manifest.host_permissions, ['https://api.anthropic.com/*']);
  assert.deepEqual(manifest.optional_host_permissions, ['file:///*']);
  assert.equal(manifest.content_scripts, undefined, 'Native-only package declares content scripts.');
  assert.equal(manifest.web_accessible_resources, undefined, 'Native-only package exposes resources.');
  assert.equal(manifest.options_page, OPTIONS_PATH);
  assert.equal(manifest.background?.type, 'module');
  assert.equal(manifest.content_security_policy?.extension_pages,
    "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src https://api.anthropic.com data:; object-src 'none'; base-uri 'none'");
  assert.ok(manifest.commands?.snip?.suggested_key?.default);
  assert.ok(manifest.action?.default_icon?.['16']);

  const files = await listFiles(DIST);
  for (const file of files) {
    assert.ok(!/^src\/(content|ui|workspace)\//u.test(file), `Excluded UI file shipped: ${file}`);
    assert.ok(!/test|smoke|acceptance/iu.test(file), `Test-only file shipped: ${file}`);
    if (!/\.(?:js|html|json)$/u.test(file)) continue;
    const source = await readFile(join(DIST, file), 'utf8');
    assert.ok(!/SNAPSCREEN_TEST_HOOKS|__snapscreen|snapscreen-ui-host|snapscreenWorkspace:|\?script&iife/u.test(source),
      `Page UI or test hook shipped in ${file}`);
    assert.ok(!/chrome\.scripting\b/u.test(source), `Script injection code shipped in ${file}`);
  }
  for (const file of [manifest.background.service_worker, manifest.options_page,
    ...Object.values(manifest.icons), ...Object.values(manifest.action.default_icon)]) {
    assert.ok(files.includes(file), `Manifest asset is missing: ${file}`);
  }
  assert.ok((normalManifest.web_accessible_resources ?? [])
    .some(entry => entry.resources.includes(normalManifest.icons['16'])),
  'Normal build must expose its icon for the positive probe control.');
  return { manifest, normalManifest };
}

async function prepareExtension(directory, manifest) {
  const extensionDirectory = join(directory, 'native-extension');
  await cp(DIST, extensionDirectory, { recursive: true });
  const loaderPath = join(extensionDirectory, manifest.background.service_worker);
  const originalPath = 'native-smoke-original-worker.js';
  await writeFile(join(extensionDirectory, originalPath), await readFile(loaderPath, 'utf8'));
  // Only the disposable copy records the production listener. Calling it below
  // exercises the built routing but does not establish genuine activeTab consent.
  const shimPath = 'native-smoke-action-shim.js';
  await writeFile(join(extensionDirectory, shimPath), `
const original = chrome.action.onClicked.addListener.bind(chrome.action.onClicked);
globalThis.__snapscreenNativeActions = [];
chrome.action.onClicked.addListener = (listener) => {
  globalThis.__snapscreenNativeActions.push(listener);
  original(listener);
};
`);
  await writeFile(loaderPath, `import './${shimPath}';\nimport './${originalPath}';\n`);
  return extensionDirectory;
}

async function waitForWorkers(context) {
  const deadline = Date.now() + TIMEOUT_MS;
  while (Date.now() < deadline) {
    const workers = context.serviceWorkers();
    for (const worker of workers) {
      const manifest = await worker.evaluate(() => chrome.runtime.getManifest());
      if (manifest.options_page === OPTIONS_PATH) {
        const normal = workers.find(candidate => candidate !== worker);
        if (normal && await worker.evaluate(() => globalThis.__snapscreenNativeActions?.length === 1)) {
          return { native: worker, normal };
        }
      }
    }
    await new Promise(resolvePromise => setTimeout(resolvePromise, 50));
  }
  throw new Error('Both packaged extension workers did not start.');
}

async function verifySettings(context, worker, extensionId) {
  await worker.evaluate(() => chrome.storage.local.set({ interfaceMode: 'extension' }));
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(`chrome-extension://${extensionId}/${OPTIONS_PATH}`);
  await page.waitForFunction(() => !document.getElementById('save-settings').disabled);
  assert.equal(await page.locator('#interface-mode').count(), 0, 'Native Settings has an interface selector.');
  assert.ok(await page.locator('#companion-section').isVisible());
  await page.locator('#api-key').fill(TEST_API_KEY);
  await page.locator('#toggle-key').click();
  assert.equal(await page.locator('#api-key').getAttribute('type'), 'text');
  await page.locator('#default-prompt').fill('Native-only smoke prompt');
  await page.locator('#advanced-settings > summary').click();
  await page.locator('#max-conversation-turns').fill('8');
  await page.locator('#save-settings').click();
  await page.waitForFunction(() => document.getElementById('status').textContent === 'Settings saved.');
  const saved = await worker.evaluate(() => chrome.storage.local.get(['apiKey', 'defaultPrompt', 'limits']));
  assert.equal(saved.apiKey, TEST_API_KEY);
  assert.equal(saved.defaultPrompt, 'Native-only smoke prompt');
  assert.equal(saved.limits.maxConversationTurns, 8);

  // The diagnostic uses the shipped Settings controller, with a transport mock
  // so this check never launches a locally registered companion.
  await page.evaluate(() => {
    globalThis.__snapscreenDiagnosticMessages = [];
    chrome.runtime.getPlatformInfo = async () => ({ os: 'mac', arch: 'arm', nacl_arch: 'arm' });
    chrome.runtime.connectNative = () => {
      const listeners = new Set();
      return {
        onMessage: { addListener: fn => listeners.add(fn), removeListener: fn => listeners.delete(fn) },
        onDisconnect: { addListener: () => undefined, removeListener: () => undefined },
        disconnect: () => undefined,
        postMessage: message => {
          globalThis.__snapscreenDiagnosticMessages.push(message);
          queueMicrotask(() => {
            for (const listener of listeners) listener({
              version: message.version, type: 'ready', connectionId: message.connectionId,
            });
          });
        },
      };
    };
  });
  await page.locator('#check-companion').click();
  await page.locator('#companion-status[data-state="ready"]').waitFor();
  const messages = await page.evaluate(() => globalThis.__snapscreenDiagnosticMessages);
  assert.equal(messages.length, 1);
  assert.deepEqual(Object.keys(messages[0]).sort(), ['connectionId', 'type', 'version']);
  assert.equal(messages[0].type, 'hello');
  await page.locator('#remove-key').click();
  await page.waitForFunction(() => document.getElementById('status').textContent === 'API key removed.');
  assert.equal((await worker.evaluate(() => chrome.storage.local.get('apiKey'))).apiKey, undefined);
  assert.equal(await page.locator('#api-key').inputValue(), '');
  assert.equal(await page.locator('#api-key').getAttribute('type'), 'password');
  assert.deepEqual(errors, [], 'Bundled Settings failed to initialize.');
  await page.close();
}

async function verifyResources(page, nativeId, normalId, normalManifest) {
  // This fixture deliberately has no CSP. The exposed normal-build icon must
  // load, so a webpage policy or failed harness cannot masquerade as isolation.
  const targets = {
    positive: `chrome-extension://${normalId}/${normalManifest.icons['16']}`,
    negative: `chrome-extension://${normalId}/not-a-real-resource.png`,
    icon: `chrome-extension://${nativeId}/${normalManifest.icons['16']}`,
    content: `chrome-extension://${nativeId}/src/content/index.js`,
    frame: `chrome-extension://${nativeId}/src/ui/result-frame.html`,
    workspace: `chrome-extension://${nativeId}/src/workspace/workspace.html`,
    settings: `chrome-extension://${nativeId}/${OPTIONS_PATH}`,
  };
  const results = await page.evaluate(async (urls) => Object.fromEntries(await Promise.all(
    Object.entries(urls).map(async ([name, url]) => {
      try {
        const response = await fetch(url, { signal: AbortSignal.timeout(3_000) });
        return [name, response.ok && (await response.arrayBuffer()).byteLength > 0];
      } catch {
        return [name, false];
      }
    }),
  )), targets);
  assert.equal(results.positive, true, 'Known exposed normal-build icon was inaccessible; probe is invalid.');
  for (const [name, loaded] of Object.entries(results)) {
    if (name !== 'positive') assert.equal(loaded, false, `Webpage accessed ${name} resource.`);
  }
}

async function verifyNativeAction(context, page, worker, apiRequests) {
  await page.bringToFront();
  await page.evaluate(() => {
    window.__snapscreenNativeMutations = 0;
    new MutationObserver(records => { window.__snapscreenNativeMutations += records.length; })
      .observe(document, { attributes: true, characterData: true, childList: true, subtree: true });
  });
  const pagesBefore = context.pages().map(candidate => candidate.url()).sort();
  await worker.evaluate(({ screenshot, apiKey }) => {
    const state = { forbidden: [], messages: [], scenario: '', captures: 0 };
    globalThis.__snapscreenNativeState = state;
    for (const [owner, key] of [
      [chrome.tabs, 'sendMessage'], [chrome.tabs, 'create'], [chrome.tabs, 'update'],
      [chrome.windows, 'update'], [chrome.runtime, 'openOptionsPage'], [chrome.permissions, 'request'],
    ]) {
      owner[key] = async () => { state.forbidden.push(key); };
    }
    if (chrome.scripting) throw new Error('Native-only worker exposes chrome.scripting.');
    chrome.runtime.getPlatformInfo = async () => ({ os: 'mac', arch: 'arm', nacl_arch: 'arm' });
    chrome.tabs.captureVisibleTab = async () => { state.captures += 1; return screenshot; };
    const setBadge = chrome.action.setBadgeText.bind(chrome.action);
    chrome.action.setBadgeText = async details => {
      await setBadge(details);
      if (details.text === '!') state.finish?.();
    };
    chrome.runtime.connectNative = host => {
      if (host !== 'com.snapscreen.companion') throw new Error('Unexpected native host.');
      const messages = new Set();
      const disconnects = new Set();
      const event = listeners => ({
        addListener: listener => listeners.add(listener),
        removeListener: listener => listeners.delete(listener),
      });
      const emit = message => { for (const listener of messages) listener(message); };
      const drop = () => { for (const listener of disconnects) listener(); };
      state.emit = emit;
      return {
        onMessage: event(messages), onDisconnect: event(disconnects),
        disconnect: () => { state.disconnected = true; drop(); },
        postMessage: message => {
          if (JSON.stringify(message).includes(apiKey)) throw new Error('API key leaked to companion.');
          state.messages.push(message);
          const { version, connectionId, sessionId, requestId } = message;
          if (message.type === 'hello') queueMicrotask(() => {
            if (state.scenario === 'missing') drop();
            else emit({ version: state.scenario === 'incompatible' ? 999 : version, type: 'ready', connectionId });
          });
          else if (message.type === 'capture') queueMicrotask(() => {
            if (state.scenario === 'disconnected') drop();
            else emit({ version, connectionId, sessionId, requestId, type: 'selected',
              rect: { x: 0, y: 0, width: 1, height: 1 } });
          });
          else if (message.type === 'answer' && message.status === 'done') state.finish?.();
          else if (message.type === 'error' || message.type === 'expired') state.finish?.();
        },
      };
    };
  }, { screenshot: SCREENSHOT, apiKey: TEST_API_KEY });

  for (const scenario of ['success', 'missing', 'incompatible', 'disconnected']) {
    const requestsBefore = apiRequests.length;
    const result = await worker.evaluate(async ({ scenario, apiKey }) => {
      const state = globalThis.__snapscreenNativeState;
      Object.assign(state, { scenario, messages: [], captures: 0, disconnected: false });
      // A migrated preference must never redirect this package into page UI.
      await chrome.storage.local.set({ interfaceMode: 'extension', apiKey });
      const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
      await new Promise((resolvePromise, reject) => {
        const timer = setTimeout(() => reject(new Error(`Native ${scenario} did not settle.`)), 5_000);
        state.finish = () => { clearTimeout(timer); resolvePromise(); };
        globalThis.__snapscreenNativeActions[0](tab);
      });
      const answer = state.messages.find(message => message.type === 'answer' && message.status === 'done');
      if (answer) {
        const { version, connectionId, sessionId, requestId } = answer;
        state.emit({ version, connectionId, sessionId, requestId, type: 'close' });
      }
      return {
        answer: answer?.text, captures: state.captures, forbidden: state.forbidden,
        disconnected: state.disconnected, types: state.messages.map(message => message.type),
        badge: await chrome.action.getBadgeText({ tabId: tab.id }),
        title: await chrome.action.getTitle({ tabId: tab.id }),
      };
    }, { scenario, apiKey: TEST_API_KEY });
    assert.deepEqual(result.forbidden, [], `Native ${scenario} attempted page UI or activation.`);
    assert.equal(result.disconnected, true, `Native ${scenario} left the port open.`);
    if (scenario === 'success') {
      assert.equal(result.answer, ANSWER);
      assert.equal(result.captures, 1);
      assert.ok(['hello', 'capture', 'accepted', 'started', 'answer'].every(type => result.types.includes(type)));
      assert.equal(apiRequests.length, requestsBefore + 1);
      assert.equal(apiRequests.at(-1).headers['x-api-key'], TEST_API_KEY);
    } else {
      assert.equal(result.badge, '!');
      assert.equal(result.captures, scenario === 'disconnected' ? 1 : 0);
      assert.equal(apiRequests.length, requestsBefore);
      assert.ok(result.title.includes(scenario === 'disconnected' ? 'native session ended' : 'companion could not start'));
    }
    assert.equal(await page.evaluate(() => window.__snapscreenNativeMutations), 0);
    assert.equal(page.frames().length, 1);
    assert.deepEqual(context.pages().map(candidate => candidate.url()).sort(), pagesBefore);
  }
}

let context;
let directory;
let timeout;
try {
  await Promise.race([
    (async () => {
      const { manifest, normalManifest } = await verifyBuild();
      directory = await mkdtemp(join(tmpdir(), 'snapscreen-native-smoke-'));
      const extensionDirectory = await prepareExtension(directory, manifest);
      context = await chromium.launchPersistentContext(join(directory, 'profile'), {
        channel: 'chromium', headless: true,
        args: [
          `--disable-extensions-except=${extensionDirectory},${NORMAL_DIST}`,
          `--load-extension=${extensionDirectory},${NORMAL_DIST}`,
        ],
      });
      context.setDefaultTimeout(TIMEOUT_MS);
      await context.route(FIXTURE_URL, route => route.fulfill({
        body: '<!doctype html><html><body><h1>Native-only smoke fixture</h1></body></html>',
        contentType: 'text/html',
      }));
      const apiRequests = [];
      await context.route(API_URL, route => {
        apiRequests.push({ headers: route.request().headers() });
        return route.fulfill({
          contentType: 'text/event-stream',
          body: `event: content_block_delta\ndata: ${JSON.stringify({ type: 'content_block_delta', delta: { type: 'text_delta', text: ANSWER } })}\n\nevent: message_stop\ndata: {"type":"message_stop"}\n\n`,
        });
      });
      const { native, normal } = await waitForWorkers(context);
      const nativeId = new URL(native.url()).hostname;
      const normalId = new URL(normal.url()).hostname;
      await verifySettings(context, native, nativeId);
      assert.equal(apiRequests.length, 0, 'Settings diagnostic or key management called the API.');
      const page = await context.newPage();
      await page.goto(FIXTURE_URL);
      await verifyResources(page, nativeId, normalId, normalManifest);
      await verifyNativeAction(context, page, native, apiRequests);
      process.stdout.write('Native-only browser smoke passed: package exclusions and CSP, bundled Settings, controlled resource probes, stale interface preference, mocked native answer and host failures without page UI or tab activation. Physical focus and real toolbar/shortcut gestures are not tested.\n');
    })(),
    new Promise((_, reject) => {
      timeout = setTimeout(() => reject(new Error('Native-only smoke exceeded 30 seconds.')), 30_000);
    }),
  ]);
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.stack : String(error)}\n`);
  process.exitCode = 1;
} finally {
  clearTimeout(timeout);
  if (context) await context.close();
  if (directory) await rm(directory, { recursive: true, force: true });
}
