import { createServer } from 'node:http';
import { access, mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { parseArgs } from 'node:util';
import { createHash } from 'node:crypto';
import { EXTENSION_ID, hashFiles, prepareAcceptanceExtension } from './native-companion-acceptance-fixture.mjs';
import { selectNativeExtension } from './native-extension-artifact.mjs';
import { chromium } from 'playwright';

// Use Playwright only to locate its installed browser binary. Attaching through Playwright
// enables focus emulation, invalidating the focus/visibility observations this experiment needs.
// Raw CDP runs over --remote-debugging-pipe, the transport Extensions.loadUnpacked requires;
// branded Google Chrome 137+ ignores --load-extension, so this also works with installed Chrome.
const { values } = parseArgs({ options: {
  app: { type: 'string' },
  output: { type: 'string' },
  browser: { type: 'string' },
  'extension-dir': { type: 'string' },
  'trial-seconds': { type: 'string', default: '45' },
  help: { type: 'boolean', default: false },
} });
if (values.help) {
  console.log('Usage: node scripts/native-companion-acceptance.mjs --app /absolute/path/SnapScreenCompanion.app [--extension-dir directory] [--output directory] [--browser executable] [--trial-seconds 45] (extension default: dist/)');
  process.exit(0);
}
const selectedExtension = await selectNativeExtension(values['extension-dir']);
if (process.platform !== 'darwin') throw new Error('Packaged companion acceptance requires macOS.');
if (!values.app) throw new Error('Pass --app with the extracted or installed packaged companion. This runner never builds it.');
const actionWindowMs = Number(values['trial-seconds']) * 1000;
if (!Number.isInteger(actionWindowMs) || actionWindowMs < 10_000 || actionWindowMs > 300_000) {
  throw new Error('--trial-seconds must be between 10 and 300.');
}
const root = resolve(import.meta.dirname, '..');
const experiment = join(root, 'experiments/native-phase1');
const app = resolve(values.app);
const host = join(app, 'Contents/MacOS/SnapScreenCompanion');
const selfTest = spawnSync(host, ['--self-test'], { encoding: 'utf8', timeout: 30_000 });
if (selfTest.status !== 0 || !selfTest.stdout.includes('checks passed') || selfTest.stdout.includes('test hooks')) {
  throw new Error('The supplied packaged companion must pass its production self-test and contain no test hooks.');
}
const appHashes = await hashFiles(app);
const profile = await mkdtemp(join(tmpdir(), 'snapscreen-acceptance-'));
const extensionDirectory = join(profile, 'fixture-extension');
const output = resolve(values.output ?? join(root, 'native/macos/build/acceptance-results'));
const extensionId = EXTENSION_ID;
let extension;
const fixtureFiles = new Map([
  ['/', ['index.html', 'text/html']],
  ['/probe.js', ['probe.js', 'text/javascript']],
  ['/style.css', ['style.css', 'text/css']],
]);
const server = createServer(async (request, response) => {
  const entry = fixtureFiles.get(request.url);
  if (!entry) { response.writeHead(404).end(); return; }
  try {
    let contents = await readFile(join(experiment, 'fixture', entry[0]));
    if (entry[0] === 'index.html') contents = contents.toString().replaceAll('Phase 1', 'Packaged acceptance')
      .replace('experimental extension', 'packaged acceptance extension');
    response.writeHead(200, { 'Content-Type': entry[1], 'Cache-Control': 'no-store' });
    response.end(contents);
  } catch { response.writeHead(500).end(); }
});

const delay = milliseconds => new Promise(resolvePromise => setTimeout(resolvePromise, milliseconds));
let browserProcess;
let browserExited;
let browserError;
let transport;
let lines;
let closing;
let activeTrial;
let nextRequestId = 0;
const pending = new Map();
const targetSessions = new Map();

function failPending(message) {
  for (const request of pending.values()) {
    clearTimeout(request.timer);
    request.reject(new Error(message));
  }
  pending.clear();
}

function send(method, params = {}, sessionId) {
  if (!transport?.open) return Promise.reject(new Error('CDP connection is closed.'));
  const id = ++nextRequestId;
  return new Promise((resolvePromise, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`CDP timeout: ${method}`));
    }, 15000);
    pending.set(id, { resolve: resolvePromise, reject, timer });
    try {
      // The pipe protocol separates JSON messages with NUL bytes.
      transport.commands.write(`${JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) })}\0`);
    } catch (error) {
      clearTimeout(timer);
      pending.delete(id);
      reject(error);
    }
  });
}

async function attach(targetId) {
  if (targetSessions.has(targetId)) return targetSessions.get(targetId);
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  targetSessions.set(targetId, sessionId);
  return sessionId;
}

async function evaluate(targetId, expression) {
  const sessionId = await attach(targetId);
  const response = await send('Runtime.evaluate', {
    expression,
    returnByValue: true,
    awaitPromise: true,
  }, sessionId);
  if (response.exceptionDetails) throw new Error('Evaluation failed in the measured browser.');
  return response.result.value;
}

async function waitForValue(read, description) {
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    if (browserError) throw browserError;
    if (browserProcess?.exitCode !== null || browserProcess?.signalCode !== null) {
      throw new Error('Test browser exited before setup completed.');
    }
    const value = await read();
    if (value) return value;
    await delay(100);
  }
  throw new Error(`Timed out waiting for ${description}.`);
}

async function close() {
  if (closing) return closing;
  closing = (async () => {
    if (activeTrial) {
      clearTimeout(activeTrial.startTimer);
      clearTimeout(activeTrial.endTimer);
      console.error(`Trial ${activeTrial.label} interrupted by collector shutdown; no complete trial was saved.`);
      activeTrial = null;
    }
    lines?.close();
    if (transport?.open) {
      // Browser.close may close its transport before acknowledging the command.
      void send('Browser.close').catch(() => { /* Transport closure is expected during shutdown. */ });
    }
    if (browserProcess && browserExited) {
      await Promise.race([browserExited, delay(3000)]);
      if (browserProcess.exitCode === null && browserProcess.signalCode === null) {
        browserProcess.kill('SIGTERM');
        await Promise.race([browserExited, delay(3000)]);
      }
      if (browserProcess.exitCode === null && browserProcess.signalCode === null) {
        browserProcess.kill('SIGKILL');
        await browserExited;
      }
    }
    failPending('Collector closed.');
    transport?.commands.destroy();
    transport?.events.destroy();
    if (server.listening) await new Promise(resolvePromise => server.close(resolvePromise));
    await rm(profile, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 });
  })();
  return closing;
}
process.once('SIGINT', () => { void close().then(() => process.exit(0)); });
process.once('SIGTERM', () => { void close().then(() => process.exit(0)); });

try {
  extension = await prepareAcceptanceExtension(selectedExtension.directory, extensionDirectory);
  await new Promise((resolvePromise, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolvePromise);
  });
  const fixtureUrl = `http://127.0.0.1:${server.address().port}/`;
  await mkdir(join(profile, 'NativeMessagingHosts'), { recursive: true });
  await writeFile(join(profile, 'NativeMessagingHosts/com.snapscreen.companion.json'), JSON.stringify({
    name: 'com.snapscreen.companion',
    description: 'SnapScreen packaged companion acceptance fixture',
    path: host,
    type: 'stdio',
    allowed_origins: [`chrome-extension://${extensionId}/`],
  }, null, 2));
  browserProcess = spawn(values.browser ? resolve(values.browser) : chromium.executablePath(), [
    `--user-data-dir=${profile}`,
    '--remote-debugging-pipe',
    '--enable-unsafe-extension-debugging',
    '--use-mock-keychain',
    '--no-first-run',
    '--no-default-browser-check',
    '--window-size=1200,850',
    fixtureUrl,
  ], { stdio: ['ignore', 'ignore', 'ignore', 'pipe', 'pipe'] });
  browserExited = new Promise(resolvePromise => {
    browserProcess.once('exit', resolvePromise);
    browserProcess.once('error', error => { browserError = error; resolvePromise(); });
  });
  // The browser reads commands from descriptor 3 and writes responses and events to descriptor 4.
  transport = { open: true, commands: browserProcess.stdio[3], events: browserProcess.stdio[4] };
  transport.commands.on('error', () => { /* Reported through the closed events pipe. */ });
  let received = '';
  transport.events.setEncoding('utf8');
  transport.events.on('data', chunk => {
    received += chunk;
    for (let end = received.indexOf('\0'); end >= 0; end = received.indexOf('\0')) {
      const response = JSON.parse(received.slice(0, end));
      received = received.slice(end + 1);
      if (response.method === 'Target.detachedFromTarget') {
        for (const [targetId, sessionId] of targetSessions) {
          if (sessionId === response.params.sessionId) targetSessions.delete(targetId);
        }
      }
      if (!response.id) continue;
      const request = pending.get(response.id);
      if (!request) continue;
      clearTimeout(request.timer);
      pending.delete(response.id);
      if (response.error) request.reject(new Error(`CDP request failed: ${response.error.message}`));
      else request.resolve(response.result);
    }
  });
  transport.events.on('error', () => { /* Followed by close. */ });
  transport.events.on('close', () => {
    transport.open = false;
    failPending('CDP transport disconnected.');
  });
  const loaded = await send('Extensions.loadUnpacked', { path: extensionDirectory }).catch(error => {
    throw new Error(`The browser did not load the fixture extension (${error.message}). Use a current Chrome, Chromium, or Chrome for Testing build.`);
  });
  if (loaded.id !== extensionId) throw new Error('The fixture extension loaded with an unexpected ID.');
  const pageTarget = await waitForValue(async () => {
    const { targetInfos } = await send('Target.getTargets');
    return targetInfos.find(target => target.type === 'page' && target.url === fixtureUrl);
  }, 'the fixture tab');
  const pageId = pageTarget.targetId;
  await waitForValue(() => evaluate(pageId, 'Boolean(globalThis.phase1Probe)'), 'the page probe');
  async function workerId() {
    const { targetInfos } = await send('Target.getTargets');
    return targetInfos.find(target => target.type === 'service_worker' && target.url.startsWith(`chrome-extension://${extensionId}/`))?.targetId;
  }
  // Attach once during setup; refresh the target identity if a diagnostic restarts the worker.
  const initialWorker = await waitForValue(workerId, 'the built extension worker');
  await waitForValue(() => evaluate(initialWorker, 'Boolean(globalThis.nativeAcceptance)'), 'the fixture worker observer');
  await evaluate(initialWorker, 'globalThis.nativeAcceptance.ready');
  // First-install Settings is a real production behavior. Close its setup tab before measuring;
  // the extension opens it asynchronously after loading, so allow it a moment to appear.
  for (let closed = false, deadline = Date.now() + 5000; !closed && Date.now() < deadline;) {
    for (const target of (await send('Target.getTargets')).targetInfos) {
      if (target.type === 'page' && target.url.startsWith(`chrome-extension://${extensionId}/`)) {
        await send('Target.closeTarget', { targetId: target.targetId });
        closed = true;
      }
    }
    if (!closed) await delay(100);
  }
  const version = await send('Browser.getVersion');
  // Chrome skips a suggested shortcut that conflicts with another extension; trials need the real one.
  const shortcut = await evaluate(initialWorker,
    'chrome.commands.getAll().then(commands => commands.find(command => command.name === "snip")?.shortcut ?? "")');
  const environment = {
    capturedAt: new Date().toISOString(),
    acceptance: 'pending-physical-review',
    appPath: app,
    extensionVariant: extension.originalExtension.variant,
    extensionDirectory: extension.originalExtension.directory,
    extensionSha256: extension.originalExtension.sha256,
    nativeProtocolVersion: extension.originalExtension.protocolVersion,
    artifacts: {
      packagedApp: appHashes,
      productionExtension: extension.originalHashes,
      fixtureExtension: extension.fixtureHashes,
      fixtureExtensionSha256: extension.fixtureSha256,
      fixtureModifications: extension.modifications,
      probe: await hashFiles(join(experiment, 'fixture')),
      collector: Object.fromEntries(await Promise.all([
        'native-companion-acceptance.mjs', 'native-companion-acceptance-fixture.mjs',
        'native-extension-artifact.mjs', 'extension-native-package.mjs',
      ].map(async file => [file, createHash('sha256').update(await readFile(join(root, 'scripts', file))).digest('hex')]))),
    },
    productionSelfTest: selfTest.stdout.trim(),
    nativeTestHooks: false,
    mockedApi: true,
    macOS: execFileSync('sw_vers', ['-productVersion'], { encoding: 'utf8' }).trim(),
    macOSBuild: execFileSync('sw_vers', ['-buildVersion'], { encoding: 'utf8' }).trim(),
    architecture: process.arch,
    browserVersion: version.product,
    browserRevision: version.revision,
    observationTransport: 'raw-cdp-pipe',
    focusEmulation: false,
    focusEmulationPolicy: 'Never enabled; browser launched directly, without Playwright attachment.',
    extensionId,
    snipShortcut: shortcut || null,
    viewport: await evaluate(pageId, '({ width: innerWidth, height: innerHeight, devicePixelRatio, screenWidth: screen.width, screenHeight: screen.height })'),
  };
  async function collectReport(trial) {
    const targetId = await workerId();
    const { targetInfos } = await send('Target.getTargets');
    return {
      environment,
      ...(trial ? { trial } : {}),
      probe: await evaluate(pageId, 'globalThis.phase1Probe.snapshot()'),
      extension: targetId ? await evaluate(targetId, 'globalThis.nativeAcceptance.snapshot()') : null,
      openPages: targetInfos.filter(target => target.type === 'page').map(target => target.url),
      // Browser window state at collection time ('normal', 'maximized', 'fullscreen', ...).
      window: await send('Browser.getWindowForTarget', { targetId: pageId }).catch(() => null),
    };
  }
  async function resetObservations() {
    // Neither reset changes the page DOM, focus, the native connection, or its session.
    await evaluate(pageId, 'globalThis.phase1Probe.reset()');
    const targetId = await workerId();
    if (targetId) await evaluate(targetId, 'globalThis.nativeAcceptance.reset()');
  }
  async function saveReport(filename, report, exclusive = false) {
    if (!/^[a-zA-Z0-9_-]+\.json$/.test(filename)) throw new Error('Use a plain .json filename.');
    await mkdir(output, { recursive: true });
    const path = join(output, filename);
    await writeFile(path, JSON.stringify(report, null, 2), exclusive ? { flag: 'wx' } : {});
    console.log(JSON.stringify({ saved: path }));
  }
  async function scheduleTrial(label) {
    if (activeTrial) throw new Error(`Trial ${activeTrial.label} is already scheduled or recording.`);
    if (!/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}$/.test(label)) {
      throw new Error('Use a 1–80 character trial label containing letters, digits, underscores, or hyphens, starting with a letter or digit.');
    }
    try {
      await access(join(output, `${label}.json`));
      throw new Error('A report with that trial label already exists; choose a new label.');
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    const trial = {
      label,
      metadata: {
        label,
        scheduledAt: new Date().toISOString(),
        preparationMs: 5000,
        actionWindowMs,
        status: 'scheduled',
        startValid: false,
      },
      startTimer: null,
      endTimer: null,
    };
    activeTrial = trial;
    trial.startTimer = setTimeout(async () => {
      try {
        if (activeTrial !== trial || closing) return;
        // Reset only in-memory logs. Neither reset nor mark changes the page DOM or focus.
        await resetObservations();
        const start = await evaluate(pageId, `(() => {
          globalThis.phase1Probe.mark(${JSON.stringify(`trial:${label}:start`)});
          const snapshot = globalThis.phase1Probe.snapshot();
          return { state: snapshot.state, at: snapshot.collectedAt };
        })()`);
        if (activeTrial !== trial || closing) return;
        trial.metadata.startedAt = start.at;
        trial.metadata.startState = start.state;
        trial.metadata.startValid = start.state.hasFocus === true
          && start.state.visibilityState === 'visible'
          && start.state.activeElement?.fixtureId === 'page-input';
        trial.metadata.status = 'recording';
        console.log(JSON.stringify({ trialStarted: label, startValid: trial.metadata.startValid, actionWindowMs }));
        if (!trial.metadata.startValid) {
          console.error('Invalid trial start: the visible page input did not have document focus. Evidence will be saved but cannot establish acceptance.');
        }
        trial.endTimer = setTimeout(async () => {
          try {
            if (activeTrial !== trial || closing) return;
            await evaluate(pageId, `globalThis.phase1Probe.mark(${JSON.stringify(`trial:${label}:end`)})`);
            trial.metadata.endedAt = new Date().toISOString();
            trial.metadata.status = 'recorded';
            await saveReport(`${label}.json`, await collectReport(trial.metadata), true);
            console.log('Timed trial saved. This records observations; it does not establish that the native workflow passed.');
          } catch (error) {
            console.error(`Trial ${label} could not be saved: ${error.message}`);
          } finally {
            if (activeTrial === trial) activeTrial = null;
          }
        }, trial.metadata.actionWindowMs);
      } catch (error) {
        console.error(`Trial ${label} could not start: ${error.message}`);
        if (activeTrial === trial) activeTrial = null;
      }
    }, trial.metadata.preparationMs);
    console.log(`Trial ${label} starts in 5 seconds. Return to Chrome and focus the page field, then perform the action during the following ${actionWindowMs / 1000} seconds. The report will save automatically without returning to this terminal.`);
  }
  console.log(JSON.stringify({ ready: true, fixtureUrl, environment }));
  if (!shortcut) console.error('The fixture snip command has no shortcut. Assign one at chrome://extensions/shortcuts before shortcut trials.');
  console.log('Commands: trial <label>, mark <label>, state, status, save <filename>, reset, window, move <left> <top>, fullscreen, normal, scenario <answer|slow|error>, disconnect, restart-worker, quit. Perform actual OS application/tab-switch positive controls, then use the real Chrome toolbar/shortcut and native UI. No interaction claim is inferred from a saved report.');
  lines = createInterface({ input: process.stdin, terminal: false });
  for await (const line of lines) {
    const [command, ...rest] = line.trim().split(' ');
    const value = rest.join(' ');
    if (command === 'quit') break;
    try {
      if (command === 'trial') {
        await scheduleTrial(value);
      } else if (command === 'mark') {
        await evaluate(pageId, `globalThis.phase1Probe.mark(${JSON.stringify(value)})`);
        console.log(JSON.stringify({ marked: value }));
      } else if (command === 'reset') {
        if (activeTrial) throw new Error('Cannot reset while a timed trial is scheduled or recording.');
        await resetObservations();
        console.log('Page probe and extension logs reset.');
      } else if (command === 'state') {
        const targetId = await workerId();
        console.log(JSON.stringify({
          page: await evaluate(pageId, `(() => {
            const snapshot = globalThis.phase1Probe.snapshot();
            return { state: snapshot.state, entries: snapshot.entries.length, droppedEntries: snapshot.droppedEntries };
          })()`),
          extension: targetId ? await evaluate(targetId, 'globalThis.nativeAcceptance.snapshot()') : null,
        }));
      } else if (command === 'window') {
        console.log(JSON.stringify(await send('Browser.getWindowForTarget', { targetId: pageId })));
      } else if (command === 'move') {
        // Setup only: move the normal window to screen coordinates, e.g. onto another display.
        const [left, top] = value.split(' ').map(Number);
        if (!Number.isInteger(left) || !Number.isInteger(top)) throw new Error('Use: move <left> <top>');
        const { windowId } = await send('Browser.getWindowForTarget', { targetId: pageId });
        await send('Browser.setWindowBounds', { windowId, bounds: { left, top } });
        console.log(JSON.stringify(await send('Browser.getWindowForTarget', { targetId: pageId })));
      } else if (command === 'fullscreen' || command === 'normal') {
        // Setup only: macOS fullscreen (its own Space) or a normal window, before a recorded action.
        const { windowId } = await send('Browser.getWindowForTarget', { targetId: pageId });
        await send('Browser.setWindowBounds', { windowId, bounds: { windowState: command } });
        console.log(JSON.stringify({ requestedWindowState: command }));
      } else if (command === 'scenario') {
        if (!['answer', 'slow', 'error'].includes(value)) throw new Error('Use: scenario answer|slow|error');
        const targetId = await workerId();
        if (!targetId) throw new Error('The extension worker is not running. Invoke the extension again.');
        await evaluate(targetId, `globalThis.nativeAcceptance.scenario(${JSON.stringify(value)})`);
        console.log(`The next mocked request uses ${value}. Error resets to answer after one failure.`);
      } else if (command === 'disconnect') {
        const targetId = await workerId();
        if (!targetId) throw new Error('The extension worker is not running.');
        await evaluate(targetId, 'globalThis.nativeAcceptance.disconnect()');
        console.log('Closed fixture native connections. A new capture requires a real extension invocation.');
      } else if (command === 'restart-worker') {
        const targetId = await workerId();
        if (!targetId) throw new Error('The extension worker is not running.');
        const pageSession = await attach(pageId);
        await send('ServiceWorker.enable', {}, pageSession);
        await send('ServiceWorker.stopAllWorkers', {}, pageSession);
        console.log('Worker stop requested. Invoke the extension again to start a fresh worker; no request is replayed by this runner.');
      } else if (command === 'status' || command === 'save') {
        const report = await collectReport(activeTrial?.metadata);
        if (command === 'save') {
          await saveReport(value, report);
        } else console.log(JSON.stringify(report));
      } else if (command) console.log('Unknown command. Use trial, mark, state, status, save, reset, window, move, fullscreen, normal, scenario, disconnect, restart-worker, or quit.');
    } catch (error) { console.error(error.message); }
  }
} finally { await close(); }
