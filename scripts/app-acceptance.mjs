// The standalone app's physical acceptance round (Phase 4 of docs/standalone-app-plan.md). It
// builds and restarts build/SnapScreen.app, opens a probe page in a fresh Chrome profile, and
// watches SnapScreen's windows and the frontmost app (scripts/app-acceptance-observer.swift)
// while you snip over Chrome in a normal window, then fullscreen, then a PDF in Preview, then
// once more after a rebuild. Each time a step's snip closes, it sets up the next step itself,
// and after the last one it saves a report and summary under build/acceptance/.
//
// Answers are real, so the app needs your API key. Commands on standard input: status,
// phase <normal|fullscreen|preview|rebuilt>, save and quit. Feed them from a file
// (tail -f commands.txt | npm run experiment:app) so that no terminal takes focus.
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { parseArgs } from 'node:util';
import { PHASES, SessionTracker, analyzeRound, formatSummary } from './app-acceptance-report.mjs';

const { values } = parseArgs({ options: {
  browser: { type: 'string', default: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' },
  output: { type: 'string' },
  help: { type: 'boolean', default: false },
} });
if (values.help) {
  console.log('Usage: node scripts/app-acceptance.mjs [--browser executable] [--output directory]');
  process.exit(0);
}
if (process.platform !== 'darwin') throw new Error('The acceptance round needs macOS.');
const root = resolve(import.meta.dirname, '..');
const bundleId = 'com.snapscreen.app';
const browser = resolve(values.browser);
const fixture = join(root, 'experiments/native-phase1/fixture');
const runName = new Date().toISOString().replace(/\.\d+Z$/, '').replaceAll(':', '-');
const output = join(resolve(values.output ?? join(root, 'build/acceptance')), runName);
const delay = milliseconds => new Promise(resolvePromise => setTimeout(resolvePromise, milliseconds));

if (spawnSync('security', ['find-generic-password', '-s', bundleId, '-a', 'anthropic-api-key']).status !== 0) {
  throw new Error('Save your API key in SnapScreen\'s Settings first: the round asks for real answers.');
}
if (spawnSync(browser, ['--version']).status !== 0) throw new Error(`No browser at ${browser}; pass --browser.`);

const STEPS = {
  normal: 'Step 1 of 5: click the text field, press ⌃⌥⇧S, drag over the code below, and release. Read the answer. '
    + 'Step 2: ask a follow-up, such as “Rewrite it in Python”, click Copy on a code block, and close SnapScreen\'s window.',
  fullscreen: 'Step 3 of 5: Chrome is now fullscreen. Click the text field, press ⌃⌥⇧S, select some colored cells, '
    + 'read the answer, and close the window.',
  preview: 'Step 4 of 5: follow the PDF in Preview.',
  rebuilt: 'Step 5 of 5: follow the PDF in Preview.',
  done: 'The round is finished.',
};
// The Preview step's document, for cupsfilter's plain text to PDF.
const PDF_TEXT = `SnapScreen acceptance round

Step 4 of 5
Press Control-Option-Shift-S over this PDF,
select the function below, read the answer,
and close SnapScreen's window.

  def median(values):
      values.sort()
      middle = len(values) // 2
      return values[middle]

Step 5 of 5
SnapScreen then quits, rebuilds and reopens:
its menu bar icon disappears and comes back
within a few seconds. Then press the shortcut
again, select anything, check that an answer
arrives with no Screen Recording or password
prompt, and close the window.
`;
const CELLS = ['red', 'orange', 'yellow', 'green', 'mint', 'cyan', 'blue', 'purple', 'pink', 'brown', 'gray', 'white'];
// The Phase 1 probe needs its log controls, so they stay in the page, hidden.
const PAGE = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <title>SnapScreen acceptance</title>
    <link rel="stylesheet" href="style.css">
    <style>
      #step { margin: 0 0 24px; padding: 16px 20px; font-size: 19px; font-weight: 600; background: #fff7d6;
        border: 2px solid #c9a227; border-radius: 8px; }
      pre.sample { max-height: none; margin: 0; padding: 16px 20px; font: 17px/1.5 ui-monospace, monospace;
        background: #fff; border: 1px solid #c5d4c6; border-radius: 8px; }
    </style>
    <script src="probe.js" defer></script>
  </head>
  <body>
    <main>
      <p id="step">Getting the round ready…</p>
      <section class="starting-state">
        <label for="page-input">Page text field: click it before each snip in Chrome</label>
        <input id="page-input" type="text" value="Page input starts here" autofocus autocomplete="off" spellcheck="false">
        <p>This page records focus, visibility, key and pointer events in memory, never what you type.</p>
      </section>
      <section>
        <h2>What's wrong with this function?</h2>
        <pre class="sample">function average(values) {
  let total = 0;
  for (let i = 0; i &lt;= values.length; i++) {
    total += values[i];
  }
  return total / values.length;
}</pre>
      </section>
      <section>
        <h2>Colored cells</h2>
        <div class="capture-grid">
${CELLS.map((color, index) => `          <div class="cell ${color}">R${Math.floor(index / 4) + 1} · C${index % 4 + 1}<span>${color}</span></div>`).join('\n')}
        </div>
      </section>
      <div hidden>
        <button id="reset-log" type="button">Reset</button>
        <button id="inspect-log" type="button">Inspect</button>
        <button id="download-log" type="button">Download</button>
        <pre id="log-output"></pre>
      </div>
    </main>
  </body>
</html>
`;

/** The parts of the app's signature that macOS's approvals depend on. */
function signature(app) {
  const details = spawnSync('codesign', ['-dvvv', app], { encoding: 'utf8' });
  const requirement = spawnSync('codesign', ['-d', '-r-', app], { encoding: 'utf8' });
  const team = details.stderr.match(/^TeamIdentifier=(.+)$/m)?.[1];
  return {
    cdhash: details.stderr.match(/^CDHash=([0-9a-f]+)$/m)?.[1] ?? null,
    team: team && team !== 'not set' ? team : null,
    // Screen Recording and the Keychain follow a requirement on the certificate, not on one build.
    certificateRequirement: /anchor apple generic and certificate leaf/.test(requirement.stdout + requirement.stderr),
    bundleVersion: execFileSync('plutil', ['-extract', 'CFBundleVersion', 'raw', '-o', '-', join(app, 'Contents/Info.plist')],
      { encoding: 'utf8' }).trim(),
  };
}

/** Runs scripts/build-app.sh, and returns the app and its signature. */
function buildApp(buildNumber) {
  return new Promise((resolvePromise, reject) => {
    const env = { ...process.env, ...(buildNumber ? { SNAPSCREEN_BUILD_NUMBER: String(buildNumber) } : {}) };
    const child = spawn(join(root, 'scripts/build-app.sh'), [], { env, stdio: ['ignore', 'pipe', 'inherit'] });
    let stdout = '';
    child.stdout.setEncoding('utf8').on('data', chunk => { stdout += chunk; });
    child.once('error', reject);
    child.once('exit', status => {
      if (status !== 0) return reject(new Error(`scripts/build-app.sh exited with ${status}.`));
      const app = resolve(stdout.trim().split('\n').at(-1), '../../..');
      resolvePromise({ app, at: Date.now(), ...signature(app) });
    });
  });
}

let profile;
let observer;
let browserProcess;
let browserExited;
let transport;
let lines;
let closing;
let nextRequestId = 0;
const pending = new Map();
const sessionIds = new Map();
const observerLog = [];
let appPids = [];
const server = createServer(async (request, response) => {
  try {
    if (request.url === '/') {
      response.writeHead(200, { 'Content-Type': 'text/html', 'Cache-Control': 'no-store' }).end(PAGE);
    } else if (request.url === '/probe.js' || request.url === '/style.css') {
      const type = request.url.endsWith('.js') ? 'text/javascript' : 'text/css';
      response.writeHead(200, { 'Content-Type': type, 'Cache-Control': 'no-store' })
        .end(await readFile(join(fixture, request.url.slice(1))));
    } else response.writeHead(404).end();
  } catch { response.writeHead(500).end(); }
});

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
    // The pipe protocol separates JSON messages with NUL bytes.
    transport.commands.write(`${JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) })}\0`);
  });
}

async function evaluate(targetId, expression) {
  if (!sessionIds.has(targetId)) {
    sessionIds.set(targetId, (await send('Target.attachToTarget', { targetId, flatten: true })).sessionId);
  }
  const response = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }, sessionIds.get(targetId));
  if (response.exceptionDetails) throw new Error('Evaluation failed in the test browser.');
  return response.result.value;
}

async function waitFor(read, description, timeout = 30000) {
  for (const deadline = Date.now() + timeout; Date.now() < deadline; await delay(100)) {
    const value = await read();
    if (value) return value;
  }
  throw new Error(`Timed out waiting for ${description}.`);
}

async function close() {
  if (closing) return closing;
  closing = (async () => {
    lines?.close();
    if (transport?.open) void send('Browser.close').catch(() => { /* The transport closes first. */ });
    if (browserProcess && browserExited) {
      await Promise.race([browserExited, delay(3000)]);
      if (browserProcess.exitCode === null && browserProcess.signalCode === null) browserProcess.kill('SIGKILL');
    }
    failPending('The runner closed.');
    observer?.stdin.end();
    if (server.listening) await new Promise(resolvePromise => server.close(resolvePromise));
    if (profile) await rm(profile, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 });
  })();
  return closing;
}
process.once('SIGINT', () => { void close().then(() => process.exit(0)); });
process.once('SIGTERM', () => { void close().then(() => process.exit(0)); });

try {
  await mkdir(output, { recursive: true });
  profile = await mkdtemp(join(tmpdir(), 'snapscreen-app-acceptance-'));
  const pdf = join(output, 'step-4.pdf');
  await writeFile(join(profile, 'step-4.txt'), PDF_TEXT);
  // Seven characters an inch and four lines an inch keep the text easy to select.
  const pdfData = spawnSync('cupsfilter', ['-o', 'cpi=7', '-o', 'lpi=4', '-i', 'text/plain', '-m', 'application/pdf',
    join(profile, 'step-4.txt')], { maxBuffer: 16 * 1024 * 1024 });
  if (pdfData.status !== 0) throw new Error('cupsfilter couldn\'t write the Preview step\'s PDF.');
  await writeFile(pdf, pdfData.stdout);

  const observerBinary = join(profile, 'observer');
  const compiled = spawnSync('xcrun', ['swiftc', '-O', '-o', observerBinary, join(root, 'scripts/app-acceptance-observer.swift')],
    { encoding: 'utf8' });
  if (compiled.status !== 0) throw new Error(`The observer didn't compile:\n${compiled.stderr}`);
  observer = spawn(observerBinary, [bundleId], { stdio: ['pipe', 'pipe', 'inherit'] });
  observer.once('exit', status => { if (!closing) console.error(`The observer exited with ${status}.`); });
  let tracker = null;
  let onWindows = null;
  createInterface({ input: observer.stdout }).on('line', line => {
    let event;
    try { event = JSON.parse(line); } catch { return; }
    observerLog.push(event);
    if (event.type === 'ready') tracker = new SessionTracker(event.displays);
    if (event.type === 'app') appPids = event.pids;
    if (event.type === 'windows' && tracker) {
      const before = tracker.sessions.length;
      tracker.update(event.at, event.windows);
      onWindows?.(tracker.sessions.slice(before), event);
    }
  });
  const ready = await waitFor(() => observerLog.find(event => event.type === 'ready'), 'the observer');

  const builds = [await buildApp()];
  if (!builds[0].team || !builds[0].certificateRequirement) {
    console.error('Warning: the app isn\'t signed with your Apple Development certificate, so the rebuild will lose its approvals.');
  }
  async function stopApp() {
    for (const pid of appPids) {
      try { process.kill(pid, 'SIGTERM'); } catch { /* It already quit. */ }
    }
    await waitFor(() => appPids.length === 0, 'SnapScreen to quit', 10000);
  }
  async function startApp() {
    // In the background, so the app you're using keeps focus.
    execFileSync('open', ['-g', builds.at(-1).app]);
    await waitFor(() => appPids.length > 0, 'SnapScreen to start', 20000);
  }
  await stopApp();
  await startApp();

  await new Promise((resolvePromise, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolvePromise);
  });
  const url = `http://127.0.0.1:${server.address().port}/`;
  // On the display under the pointer, where you're working.
  const display = ready.displays.find(candidate => ready.pointer.x >= candidate.x && ready.pointer.x < candidate.x + candidate.width
    && ready.pointer.y >= candidate.y && ready.pointer.y < candidate.y + candidate.height) ?? ready.displays[0];
  const width = Math.min(1280, display.width - 80);
  const height = Math.min(960, display.height - 100);
  browserProcess = spawn(browser, [
    `--user-data-dir=${profile}/chrome`,
    '--remote-debugging-pipe',
    '--use-mock-keychain',
    '--no-first-run',
    '--no-default-browser-check',
    `--window-position=${display.x + Math.floor((display.width - width) / 2)},${display.y + 60}`,
    `--window-size=${width},${height}`,
    url,
  ], { stdio: ['ignore', 'ignore', 'ignore', 'pipe', 'pipe'] });
  browserExited = new Promise(resolvePromise => browserProcess.once('exit', resolvePromise));
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
      const request = response.id && pending.get(response.id);
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
    failPending('The browser closed.');
  });
  const pageId = (await waitFor(async () => (await send('Target.getTargets')).targetInfos
    .find(target => target.type === 'page' && target.url === url), 'the probe page')).targetId;
  await waitFor(() => evaluate(pageId, 'Boolean(globalThis.phase1Probe)'), 'the page probe');

  // The probe keeps 12,000 entries, so the runner collects and resets it after each step.
  const probe = { entries: [], droppedEntries: 0, environment: null };
  async function collectProbe() {
    const snapshot = await evaluate(pageId, `(() => {
      const value = globalThis.phase1Probe.snapshot();
      globalThis.phase1Probe.reset();
      return value;
    })()`);
    probe.entries.push(...snapshot.entries);
    probe.droppedEntries += snapshot.droppedEntries;
    probe.environment ??= snapshot.environment;
  }
  const windowState = async () => (await send('Browser.getWindowForTarget', { targetId: pageId })).bounds;
  async function setWindowState(state) {
    const { windowId, bounds } = await send('Browser.getWindowForTarget', { targetId: pageId });
    if (bounds.windowState === state) return;
    await send('Browser.setWindowBounds', { windowId, bounds: { windowState: state } });
    // macOS animates into and out of a fullscreen Space.
    await waitFor(async () => (await windowState()).windowState === state, `Chrome's ${state} window`, 10000);
    await delay(1000);
  }
  const setBanner = text => evaluate(pageId, `document.getElementById('step').textContent = ${JSON.stringify(text)}`);

  const version = await send('Browser.getVersion');
  const startedAt = new Date().toISOString();
  const environment = {
    macOS: execFileSync('sw_vers', ['-productVersion'], { encoding: 'utf8' }).trim(),
    macOSBuild: execFileSync('sw_vers', ['-buildVersion'], { encoding: 'utf8' }).trim(),
    architecture: process.arch,
    browser: version.product,
    chromePid: browserProcess.pid,
    window: await windowState(),
  };
  const phases = [];
  let phase = null;
  let busy = false;

  async function save() {
    await collectProbe();
    const report = { schemaVersion: 1, kind: 'snapscreen-app-acceptance', startedAt, savedAt: new Date().toISOString(),
      environment, builds, phases, observer: observerLog, probe };
    const summary = formatSummary(analyzeRound(report), report);
    await writeFile(join(output, 'report.json'), `${JSON.stringify(report)}\n`);
    await writeFile(join(output, 'summary.md'), summary);
    console.log(summary);
    console.log(JSON.stringify({ saved: output }));
  }

  async function enter(name) {
    busy = true;
    try {
      if (name !== 'done' && !PHASES.some(entry => entry.name === name)) throw new Error(`Unknown phase ${name}.`);
      await collectProbe();
      phase = name;
      const entry = { name, at: Date.now() };
      phases.push(entry);
      if (name === 'normal' || name === 'preview') await setWindowState('normal');
      await setBanner(STEPS[name]);
      if (name === 'fullscreen') await setWindowState('fullscreen');
      if (name === 'preview') execFileSync('open', ['-a', 'Preview', pdf]);
      if (name === 'rebuilt') {
        await stopApp();
        builds.push(await buildApp(Math.floor(Date.now() / 1000)));
        await startApp();
      }
      entry.windowState = (await windowState()).windowState;
      entry.readyAt = Date.now();
      console.log(JSON.stringify({ phase: name, windowState: entry.windowState }));
      if (name === 'done') await save();
    } finally {
      busy = false;
    }
  }

  // Follows snips as the observer reports windows, and moves on when a step's snip closes.
  onWindows = (started, event) => {
    for (const session of started) console.log(JSON.stringify({ snipStarted: phase, display: session.display }));
    if (tracker.notices.at(-1)?.at === event.at) console.log(JSON.stringify({ notice: phase }));
  };
  setInterval(() => {
    for (const session of tracker.flush(Date.now())) {
      console.log(JSON.stringify({ snipEnded: phase, outcome: session.outcome, seconds: Math.round((session.end - session.start) / 1000) }));
      const next = PHASES.findIndex(entry => entry.name === phase) + 1;
      if (busy || session.outcome !== 'closed' || session.start < (phases.at(-1)?.readyAt ?? 0) || next === 0) continue;
      void enter(PHASES[next]?.name ?? 'done').catch(error => console.error(`Couldn't set up the next step: ${error.message}`));
    }
  }, 100).unref();

  await enter('normal');
  console.log(JSON.stringify({ ready: true, output, environment, build: builds[0] }));
  console.log('Commands: status, phase <normal|fullscreen|preview|rebuilt>, save, quit.');
  lines = createInterface({ input: process.stdin, terminal: false });
  for await (const line of lines) {
    const [command, value] = line.trim().split(/\s+/);
    if (command === 'quit') break;
    try {
      if (command === 'status') {
        console.log(JSON.stringify({ phase, busy, snips: tracker.sessions.length, notices: tracker.notices.length,
          appPids, window: await windowState() }));
      } else if (command === 'phase') await enter(value);
      else if (command === 'save') await save();
      else if (command) console.log('Unknown command. Use status, phase, save or quit.');
    } catch (error) { console.error(error.message); }
  }
  if (phase !== 'done') await save();
} finally { await close(); }
