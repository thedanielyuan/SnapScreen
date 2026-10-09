import assert from 'node:assert/strict';
import { cp, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { chromium } from 'playwright';
import { inspectNativeExtension, verifyNativeArchive } from './extension-native-package.mjs';
import { installNativeSmokeShim } from './extension-native-fixture.mjs';
import { verifyNativeLifecycle } from './extension-native-lifecycle.mjs';

const ROOT = resolve(import.meta.dirname, '..');
const DIST = join(ROOT, 'dist-native');
const NORMAL_DIST = join(ROOT, 'dist');
const OPTIONS_PATH = 'src/options/options-native.html';
const FIXTURE_URL = 'https://api.anthropic.com/snapscreen-native-smoke';
const API_URL = 'https://api.anthropic.com/v1/messages';
const TEST_API_KEY = 'sk-ant-native-only-smoke-not-a-real-key';
const ANSWER = 'SNAPSCREEN_NATIVE_ONLY_SMOKE_ANSWER';
const PRIVATE_PROMPT = 'Native-only smoke prompt';
const TIMEOUT_MS = 10_000;

async function readJson(path) {
  return JSON.parse(await readFile(path, 'utf8'));
}

async function prepareExtension(directory, archive) {
  const extensionDirectory = join(directory, 'native-extension');
  await cp(archive.extensionDirectory, extensionDirectory, { recursive: true });
  const loaderPath = join(extensionDirectory, archive.manifest.background.service_worker);
  const originalPath = 'native-smoke-original-worker.js';
  await writeFile(join(extensionDirectory, originalPath), await readFile(loaderPath, 'utf8'));
  const shimPath = 'native-smoke-action-shim.js';
  await writeFile(join(extensionDirectory, shimPath),
    `(${installNativeSmokeShim.toString()})(${JSON.stringify({
      apiUrl: API_URL, apiKey: TEST_API_KEY, answer: ANSWER, prompt: PRIVATE_PROMPT,
    })});\n`);
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
        if (normal && await worker.evaluate(() => globalThis.__snapscreenNativeState?.actions.length === 1)) {
          return { native: worker, normal };
        }
      }
    }
    await new Promise(resolvePromise => setTimeout(resolvePromise, 50));
  }
  throw new Error('Both packaged extension workers did not start.');
}

// Each extension opens Settings on install, and Chrome navigates an active blank tab there
// instead of opening another. Wait for both, so neither takes over a page this test opens.
async function waitForInstallSettings(context, urls) {
  const deadline = Date.now() + TIMEOUT_MS;
  while (Date.now() < deadline) {
    const open = new Set(context.pages().map(page => page.url()));
    if (urls.every(url => open.has(url))) return;
    await new Promise(resolvePromise => setTimeout(resolvePromise, 50));
  }
  throw new Error('Both extensions did not open Settings on install.');
}

async function verifySettings(context, worker, extensionId, protocolVersion) {
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
  assert.equal(messages[0].version, protocolVersion, 'Bundled Settings protocol differs from the companion.');
  await page.locator('#remove-key').click();
  await page.waitForFunction(() => document.getElementById('status').textContent === 'API key removed.');
  assert.equal((await worker.evaluate(() => chrome.storage.local.get('apiKey'))).apiKey, undefined);
  assert.equal(await page.locator('#api-key').inputValue(), '');
  assert.equal(await page.locator('#api-key').getAttribute('type'), 'password');
  assert.deepEqual(errors, [], 'Bundled Settings failed to initialize.');
  await page.close();
}

async function verifyResources(page, nativeId, normalId, normalManifest) {
  // This fixture deliberately has no CSP. The normal build's web-accessible UI
  // frame must load, so a webpage policy or failed harness cannot masquerade
  // as isolation.
  const targets = {
    positive: `chrome-extension://${normalId}/src/ui/result-frame.html`,
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
  assert.equal(results.positive, true, 'Known exposed normal-build UI frame was inaccessible; probe is invalid.');
  for (const [name, loaded] of Object.entries(results)) {
    if (name !== 'positive') assert.equal(loaded, false, `Webpage accessed ${name} resource.`);
  }
}

let context;
let directory;
let timeout;
try {
  await Promise.race([
    (async () => {
      // Inspect both the build and the bytes extracted from the temporary ZIP.
      await inspectNativeExtension(DIST);
      const normalManifest = await readJson(join(NORMAL_DIST, 'manifest.json'));
      const { version } = await readJson(join(ROOT, 'package.json'));
      assert.equal(normalManifest.version, version, 'Rebuild the normal extension for probe controls.');
      directory = await mkdtemp(join(tmpdir(), 'snapscreen-native-smoke-'));
      const archive = await verifyNativeArchive(DIST, directory);
      const extensionDirectory = await prepareExtension(directory, archive);
      context = await chromium.launchPersistentContext(join(directory, 'profile'), {
        channel: 'chromium', headless: true,
        args: [
          `--disable-extensions-except=${extensionDirectory},${NORMAL_DIST}`,
          `--load-extension=${extensionDirectory},${NORMAL_DIST}`,
        ],
      });
      context.setDefaultTimeout(TIMEOUT_MS);
      await context.route(`${FIXTURE_URL}*`, route => route.fulfill({
        body: '<!doctype html><html><body><h1>Native-only smoke fixture</h1></body></html>',
        contentType: 'text/html',
      }));
      // The serialized mock has no external API fallback, and browser routing adds
      // a second guard against accidental paid requests from either extension.
      const escapedRequests = [];
      await context.route(API_URL, route => {
        escapedRequests.push(route.request().url());
        return route.abort();
      });
      const { native, normal } = await waitForWorkers(context);
      const nativeId = new URL(native.url()).hostname;
      const normalId = new URL(normal.url()).hostname;
      await waitForInstallSettings(context, [
        `chrome-extension://${nativeId}/${OPTIONS_PATH}`,
        `chrome-extension://${normalId}/${normalManifest.options_page}`,
      ]);
      await verifySettings(context, native, nativeId, archive.protocolVersion);
      assert.deepEqual(escapedRequests, [], 'Settings unexpectedly called the API.');
      const page = await context.newPage();
      await page.goto(FIXTURE_URL);
      await verifyResources(page, nativeId, normalId, normalManifest);
      await verifyNativeLifecycle(context, page, native, {
        protocolVersion: archive.protocolVersion, apiKey: TEST_API_KEY, answer: ANSWER, fixtureUrl: FIXTURE_URL,
      });
      assert.deepEqual(escapedRequests, [], 'A mocked API request escaped the fixture.');
      process.stdout.write('Native-only gates passed: build and extracted ZIP, bundled Settings/CSP, controlled resource probes, streaming/follow-ups/Stop/Retry, cancellation/host failures, source invalidation, concurrent sessions, and worker restart without replay. No capture path injected UI or activated tabs. Capture and native transport are mocked; physical focus, natural suspension, and real toolbar/shortcut gestures are not tested.\n');
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
