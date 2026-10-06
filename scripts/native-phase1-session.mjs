import { createServer } from 'node:http';
import { access, mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { execFileSync, spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chromium } from 'playwright';

// Use Playwright only to locate its installed browser binary. Attaching through Playwright
// enables focus emulation, invalidating the focus/visibility observations this experiment needs.
const root = resolve(import.meta.dirname, '..');
const experiment = join(root, 'experiments/native-phase1');
const output = join(experiment, 'build');
const host = join(output, 'SnapScreenPhase1.app/Contents/MacOS/SnapScreenPhase1');
const manifest = JSON.parse(await readFile(join(output, 'extension/manifest.json'), 'utf8'));
const extensionId = [...createHash('sha256').update(Buffer.from(manifest.key, 'base64'))
  .digest().subarray(0, 16)].map((byte) => String.fromCharCode(97 + (byte >> 4), 97 + (byte & 15))).join('');
const profile = await mkdtemp(join(tmpdir(), 'snapscreen-phase1-'));
const fixtureFiles = new Map([
  ['/', ['index.html', 'text/html']],
  ['/probe.js', ['probe.js', 'text/javascript']],
  ['/style.css', ['style.css', 'text/css']],
]);
const server = createServer(async (request, response) => {
  const entry = fixtureFiles.get(request.url);
  if (!entry) { response.writeHead(404).end(); return; }
  try {
    const contents = await readFile(join(experiment, 'fixture', entry[0]));
    response.writeHead(200, { 'Content-Type': entry[1], 'Cache-Control': 'no-store' });
    response.end(contents);
  } catch { response.writeHead(500).end(); }
});

const delay = milliseconds => new Promise(resolvePromise => setTimeout(resolvePromise, milliseconds));
let browserProcess;
let browserExited;
let browserError;
let socket;
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
  if (!socket || socket.readyState !== WebSocket.OPEN) return Promise.reject(new Error('CDP connection is closed.'));
  const id = ++nextRequestId;
  return new Promise((resolvePromise, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`CDP timeout: ${method}`));
    }, 15000);
    pending.set(id, { resolve: resolvePromise, reject, timer });
    try {
      socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
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
    if (socket?.readyState === WebSocket.OPEN) {
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
    socket?.close();
    if (server.listening) await new Promise(resolvePromise => server.close(resolvePromise));
    await rm(profile, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 });
  })();
  return closing;
}
process.once('SIGINT', () => { void close().then(() => process.exit(0)); });
process.once('SIGTERM', () => { void close().then(() => process.exit(0)); });

try {
  await new Promise((resolvePromise, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolvePromise);
  });
  const fixtureUrl = `http://127.0.0.1:${server.address().port}/`;
  await mkdir(join(profile, 'NativeMessagingHosts'), { recursive: true });
  await writeFile(join(profile, 'NativeMessagingHosts/com.snapscreen.phase1.json'), JSON.stringify({
    name: 'com.snapscreen.phase1',
    description: 'SnapScreen local Phase 1 interaction experiment',
    path: host,
    type: 'stdio',
    allowed_origins: [`chrome-extension://${extensionId}/`],
  }, null, 2));
  browserProcess = spawn(chromium.executablePath(), [
    `--user-data-dir=${profile}`,
    '--remote-debugging-port=0',
    `--disable-extensions-except=${join(output, 'extension')}`,
    `--load-extension=${join(output, 'extension')}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--window-size=1200,850',
    fixtureUrl,
  ], { stdio: 'ignore' });
  browserExited = new Promise(resolvePromise => {
    browserProcess.once('exit', resolvePromise);
    browserProcess.once('error', error => { browserError = error; resolvePromise(); });
  });
  const debugging = await waitForValue(async () => {
    try {
      const [port, path] = (await readFile(join(profile, 'DevToolsActivePort'), 'utf8')).trim().split('\n');
      return /^\d+$/.test(port) && path?.startsWith('/devtools/browser/') ? { port, path } : null;
    } catch { return null; }
  }, 'the browser debugging endpoint');
  socket = new WebSocket(`ws://127.0.0.1:${debugging.port}${debugging.path}`);
  socket.addEventListener('message', event => {
    const response = JSON.parse(event.data);
    if (response.method === 'Target.detachedFromTarget') {
      for (const [targetId, sessionId] of targetSessions) {
        if (sessionId === response.params.sessionId) targetSessions.delete(targetId);
      }
    }
    if (!response.id) return;
    const request = pending.get(response.id);
    if (!request) return;
    clearTimeout(request.timer);
    pending.delete(response.id);
    if (response.error) request.reject(new Error(`CDP request failed: ${response.error.message}`));
    else request.resolve(response.result);
  });
  socket.addEventListener('close', () => failPending('CDP transport disconnected.'));
  await new Promise((resolvePromise, reject) => {
    socket.addEventListener('open', resolvePromise, { once: true });
    socket.addEventListener('error', () => reject(new Error('Cannot connect to browser debugging endpoint.')), { once: true });
  });
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
  await attach(await waitForValue(workerId, 'the experimental extension worker'));
  const version = await send('Browser.getVersion');
  const environment = {
    capturedAt: new Date().toISOString(),
    artifacts: {
      nativeHostSha256: createHash('sha256').update(await readFile(host)).digest('hex'),
      extensionSha256: Object.fromEntries(await Promise.all(
        ['manifest.json', 'background.mjs', 'protocol.mjs', 'config.mjs'].map(async file => [
          file, createHash('sha256').update(await readFile(join(output, 'extension', file))).digest('hex'),
        ]),
      )),
    },
    macOS: execFileSync('sw_vers', ['-productVersion'], { encoding: 'utf8' }).trim(),
    macOSBuild: execFileSync('sw_vers', ['-buildVersion'], { encoding: 'utf8' }).trim(),
    architecture: process.arch,
    browserVersion: version.product,
    browserRevision: version.revision,
    observationTransport: 'raw-cdp',
    focusEmulation: false,
    focusEmulationPolicy: 'Never enabled; browser launched directly, without Playwright attachment.',
    extensionId,
    viewport: await evaluate(pageId, '({ width: innerWidth, height: innerHeight, devicePixelRatio, screenWidth: screen.width, screenHeight: screen.height })'),
  };
  async function collectReport(trial) {
    const targetId = await workerId();
    const { targetInfos } = await send('Target.getTargets');
    return {
      environment,
      ...(trial ? { trial } : {}),
      probe: await evaluate(pageId, 'globalThis.phase1Probe.snapshot()'),
      extension: targetId ? await evaluate(targetId, 'globalThis.phase1') : null,
      openPages: targetInfos.filter(target => target.type === 'page').map(target => target.url),
      // Browser window state at collection time ('normal', 'maximized', 'fullscreen', ...).
      window: await send('Browser.getWindowForTarget', { targetId: pageId }).catch(() => null),
    };
  }
  async function resetObservations() {
    // Neither reset changes the page DOM, focus, the native connection, or its session.
    await evaluate(pageId, 'globalThis.phase1Probe.reset()');
    const targetId = await workerId();
    if (targetId) await evaluate(targetId, 'globalThis.phase1Control.clearLogs()');
  }
  async function saveReport(filename, report, exclusive = false) {
    if (!/^[a-zA-Z0-9_-]+\.json$/.test(filename)) throw new Error('Use a plain .json filename.');
    await mkdir(join(output, 'results'), { recursive: true });
    const path = join(output, 'results', filename);
    await writeFile(path, JSON.stringify(report, null, 2), exclusive ? { flag: 'wx' } : {});
    console.log(JSON.stringify({ saved: path }));
  }
  async function scheduleTrial(label) {
    if (activeTrial) throw new Error(`Trial ${activeTrial.label} is already scheduled or recording.`);
    if (!/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}$/.test(label)) {
      throw new Error('Use a 1–80 character trial label containing letters, digits, underscores, or hyphens, starting with a letter or digit.');
    }
    try {
      await access(join(output, 'results', `${label}.json`));
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
        actionWindowMs: 25000,
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
        console.log(JSON.stringify({ trialStarted: label, startValid: trial.metadata.startValid, actionWindowMs: 25000 }));
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
    console.log(`Trial ${label} starts in 5 seconds. Return to Chrome and focus the page field, then perform the action during the following 25 seconds. The report will save automatically without returning to this terminal.`);
  }
  console.log(JSON.stringify({ ready: true, fixtureUrl, environment }));
  console.log('Commands: trial <label>, mark <label>, state, status, save <filename>, reset, window, move <left> <top>, fullscreen, normal, shutdown, kill-host, quit. Perform actual OS application/tab-switch positive controls, then use the real Chrome toolbar/shortcut and native UI.');
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
          extension: targetId ? await evaluate(targetId, `(() => ({ status: globalThis.phase1.status,
            entries: globalThis.phase1.logs.length, droppedEntries: globalThis.phase1.droppedEntries }))()`) : null,
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
      } else if (command === 'kill-host') {
        // Simulates a host crash. Only the PID the extension reports for this experiment's executable is killed.
        const targetId = await workerId();
        if (!targetId) throw new Error('Experimental extension worker is not running.');
        const pid = await evaluate(targetId, 'globalThis.phase1.status.pid');
        if (!Number.isInteger(pid) || pid <= 0) throw new Error('No connected native host to terminate.');
        const executable = execFileSync('ps', ['-o', 'comm=', '-p', String(pid)], { encoding: 'utf8' }).trim();
        if (executable !== host) throw new Error('The reported PID is not this experiment host; nothing was terminated.');
        process.kill(pid, 'SIGKILL');
        console.log(JSON.stringify({ killedHostPid: pid, at: Date.now() }));
      } else if (command === 'shutdown') {
        const targetId = await workerId();
        if (!targetId) throw new Error('Experimental extension worker is not running.');
        await evaluate(targetId, 'globalThis.phase1Control.shutdown()');
        console.log('Diagnostic native host shutdown requested.');
      } else if (command === 'status' || command === 'save') {
        const report = await collectReport(activeTrial?.metadata);
        if (command === 'save') {
          await saveReport(value, report);
        } else console.log(JSON.stringify(report));
      } else if (command) console.log('Unknown command. Use trial, mark, state, status, save, reset, window, move, fullscreen, normal, shutdown, kill-host, or quit.');
    } catch (error) { console.error(error.message); }
  }
} finally { await close(); }
