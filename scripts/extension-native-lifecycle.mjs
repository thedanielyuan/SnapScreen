import assert from 'node:assert/strict';

async function waitFor(label, check) {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    if (await check()) return;
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  throw new Error(`Timed out waiting for ${label}.`);
}

async function snapshot(worker) {
  return worker.evaluate(() => {
    const state = globalThis.__snapscreenNativeState;
    return { captures: state.captures, forbidden: state.forbidden, badges: state.badges,
      requests: state.requests.map(({ headers, body, aborted, finished }) => ({ headers, body, aborted, finished })),
      ports: state.ports.map(port => ({ sent: port.sent, disconnected: port.disconnected,
        listeners: port.listenerCounts() })),
    };
  });
}

async function command(worker, index, type, extra = {}) {
  await worker.evaluate(({ index, type, extra }) => {
    globalThis.__snapscreenNativeState.ports[index].command(type, extra);
  }, { index, type, extra });
}

async function waitForMessage(worker, index, type, status) {
  await waitFor(`${type}${status ? `/${status}` : ''} on session ${index}`, async () =>
    (await snapshot(worker)).ports[index]?.sent.some(message => message.type === type
      && (!status || message.status === status)));
}

async function assertClosed(worker, index) {
  await waitFor(`session ${index} cleanup`, async () => (await snapshot(worker)).ports[index].disconnected);
  assert.deepEqual((await snapshot(worker)).ports[index].listeners, [0, 0]);
}

async function observe(page) {
  await page.evaluate(() => {
    window.__snapscreenNativeMutations = 0;
    new MutationObserver(records => { window.__snapscreenNativeMutations += records.length; })
      .observe(document, { attributes: true, characterData: true, childList: true, subtree: true });
  });
}

export async function verifyNativeLifecycle(context, page, initialWorker, {
  protocolVersion, apiKey, answer, fixtureUrl,
}) {
  let worker = initialWorker;
  await page.bringToFront();
  await observe(page);
  await worker.evaluate(async apiKey => {
    // A migrated preference must never redirect this package into page UI.
    await chrome.storage.local.set({ interfaceMode: 'extension', apiKey });
    globalThis.__snapscreenNativeState.observing = true;
  }, apiKey);

  async function invoke({ hostMode = 'ready', apiMode = 'answer', shortcut = false } = {}) {
    const index = await worker.evaluate(async ({ hostMode, apiMode, shortcut }) => {
      const state = globalThis.__snapscreenNativeState;
      Object.assign(state, { hostMode, apiMode });
      const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
      const index = state.ports.length;
      // Exercise the built callbacks; this mock does not establish activeTab consent.
      if (shortcut) state.commands[0]('snip', tab);
      else state.actions[0](tab);
      return index;
    }, { hostMode, apiMode, shortcut });
    if (hostMode === 'ready') await waitForMessage(worker, index, 'capture');
    else await waitFor(`host ${hostMode} failure`, async () => (await snapshot(worker)).ports[index]?.disconnected);
    assert.equal((await snapshot(worker)).ports[index].sent[0].version, protocolVersion,
      'Bundled worker protocol does not match the companion.');
    return index;
  }

  async function select(index) {
    await command(worker, index, 'selected', { rect: { x: 0.25, y: 0, width: 0.5, height: 0.5 } });
    await waitForMessage(worker, index, 'accepted');
  }

  async function complete(request) {
    await worker.evaluate(index => globalThis.__snapscreenNativeState.requests[index].complete(), request);
  }

  async function close(index) {
    await command(worker, index, 'close');
    await assertClosed(worker, index);
  }

  async function assertQuiet(pagesBefore) {
    assert.deepEqual((await snapshot(worker)).forbidden, [], 'Capture attempted injection, page UI, or activation.');
    assert.equal(await page.evaluate(() => window.__snapscreenNativeMutations), 0,
      'Static source page was mutated during native capture.');
    assert.equal(page.frames().length, 1, 'Native capture added a frame.');
    assert.deepEqual(context.pages().map(candidate => candidate.url()).sort(), pagesBefore);
    assert.equal(await worker.evaluate(async () => (await chrome.tabs.query({ active: true, currentWindow: true }))[0]?.url),
      page.url(), 'Capture changed the active tab.');
  }

  const initialPages = context.pages().map(candidate => candidate.url()).sort();
  // Keep SSE open until the production throttled streaming relay has fired.
  const first = await invoke({ apiMode: 'slow' });
  await select(first);
  await waitForMessage(worker, first, 'thinking');
  await waitForMessage(worker, first, 'answer', 'streaming');
  let state = await snapshot(worker);
  assert.equal(state.requests.length, 1);
  assert.equal(state.requests[0].headers['x-api-key'], apiKey);
  assert.equal(state.requests[0].finished, false);
  assert.ok(!state.ports[first].sent.some(message => message.status === 'done'));
  const crop = state.ports[first].sent.find(message => message.type === 'accepted').imageDataUrl;
  assert.deepEqual(await worker.evaluate(async dataUrl => {
    const bitmap = await createImageBitmap(await (await fetch(dataUrl)).blob());
    const dimensions = [bitmap.width, bitmap.height];
    bitmap.close();
    return dimensions;
  }, crop), [4, 3], 'Crop acceptance did not use the real crop pipeline.');
  await complete(0);
  await waitForMessage(worker, first, 'answer', 'done');
  assert.equal((await snapshot(worker)).ports[first].sent.at(-1).text, answer);
  await command(worker, first, 'followup', { text: 'Explain the first answer.' });
  await waitFor('follow-up request', async () => (await snapshot(worker)).requests.length === 2);
  state = await snapshot(worker);
  const [initial, followup] = state.requests;
  assert.deepEqual(followup.body.system, initial.body.system);
  assert.deepEqual(followup.body.messages[0], initial.body.messages[0]);
  assert.deepEqual(followup.body.messages[1], { role: 'assistant', content: answer });
  assert.equal(followup.body.messages[2].content, 'Explain the first answer.');
  await complete(1);
  await waitFor('follow-up answer', async () => (await snapshot(worker)).ports[first].sent
    .filter(message => message.status === 'done').length === 2);
  await close(first);
  await assertQuiet(initialPages);

  const cancelled = await invoke({ shortcut: true });
  await command(worker, cancelled, 'cancelled');
  await assertClosed(worker, cancelled);
  assert.equal((await snapshot(worker)).requests.length, 2, 'Cancelled selection called the API.');
  await assertQuiet(initialPages);

  for (const mode of ['missing', 'incompatible', 'malformed', 'disconnected', 'malformed-session']) {
    const before = await snapshot(worker);
    const postHandshake = mode === 'disconnected' || mode === 'malformed-session';
    const index = await invoke({ hostMode: postHandshake ? 'ready' : mode });
    if (postHandshake) await worker.evaluate(({ index, mode }) => {
      const port = globalThis.__snapscreenNativeState.ports[index];
      if (mode === 'disconnected') port.drop();
      else port.command('selected', { rect: { x: 0, y: 0, width: 1, height: 1 }, unexpected: true });
    }, { index, mode });
    await assertClosed(worker, index);
    await waitFor('failure badge', async () => (await snapshot(worker)).badges.length > before.badges.length);
    state = await snapshot(worker);
    assert.equal(state.badges.at(-1).text, '!');
    assert.equal(state.captures - before.captures, postHandshake ? 1 : 0);
    assert.equal(state.requests.length, before.requests.length);
    const title = await worker.evaluate(async () => {
      const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
      return chrome.action.getTitle({ tabId: tab.id });
    });
    assert.ok(title.includes(postHandshake ? 'native session ended' : 'companion could not start'));
    assert.ok(!title.includes(apiKey));
    await assertQuiet(initialPages);
  }

  const stopped = await invoke({ apiMode: 'slow' });
  await select(stopped);
  await waitForMessage(worker, stopped, 'answer', 'streaming');
  const stoppedRequest = (await snapshot(worker)).requests.length - 1;
  await command(worker, stopped, 'stop');
  await waitForMessage(worker, stopped, 'answer', 'stopped');
  assert.equal((await snapshot(worker)).requests[stoppedRequest].aborted, true);
  assert.ok(!(await snapshot(worker)).ports[stopped].sent.some(message => message.status === 'done'));
  await worker.evaluate(() => { globalThis.__snapscreenNativeState.apiMode = 'answer'; });
  await command(worker, stopped, 'retry');
  await waitForMessage(worker, stopped, 'answer', 'done');
  state = await snapshot(worker);
  assert.deepEqual(state.requests.at(-1).body, state.requests[stoppedRequest].body,
    'Retry replayed stopped partial text or changed request context.');
  await close(stopped);
  await assertQuiet(initialPages);

  const failed = await invoke({ apiMode: 'error' });
  await select(failed);
  await waitForMessage(worker, failed, 'error');
  state = await snapshot(worker);
  const failure = state.ports[failed].sent.at(-1);
  assert.equal(failure.type, 'error');
  assert.ok(failure.message.includes('[REDACTED API KEY]'), 'Provider key was not redacted.');
  assert.ok(!failure.message.includes(apiKey) && !failure.message.includes('\u0001'));
  assert.ok(failure.message.length < 400, 'Provider message was not bounded.');
  const failedBody = state.requests.at(-1).body;
  await worker.evaluate(() => { globalThis.__snapscreenNativeState.apiMode = 'answer'; });
  await command(worker, failed, 'retry');
  await waitForMessage(worker, failed, 'answer', 'done');
  assert.deepEqual((await snapshot(worker)).requests.at(-1).body, failedBody);
  await close(failed);
  await assertQuiet(initialPages);

  // Real tab lifecycle events reach the built worker. Begin observing the new
  // static document after its intentional navigation, excluding fixture setup.
  const navigating = await invoke();
  await page.goto(`${fixtureUrl}?navigation`);
  await observe(page);
  await waitForMessage(worker, navigating, 'expired');
  await assertClosed(worker, navigating);
  await assertQuiet(context.pages().map(candidate => candidate.url()).sort());
  const temporary = await context.newPage();
  await temporary.goto(fixtureUrl);
  await temporary.bringToFront();
  const closing = await invoke();
  await temporary.close();
  await page.bringToFront();
  await waitForMessage(worker, closing, 'expired');
  await assertClosed(worker, closing);

  const accepted = await invoke();
  await select(accepted);
  await waitForMessage(worker, accepted, 'answer', 'done');
  await page.goto(fixtureUrl);
  await observe(page);
  const second = await invoke({ apiMode: 'slow' });
  await select(second);
  await waitForMessage(worker, second, 'answer', 'streaming');
  const concurrentRequest = (await snapshot(worker)).requests.length - 1;
  await command(worker, accepted, 'followup', { text: 'Continue after source navigation.' });
  await waitFor('concurrent request', async () => (await snapshot(worker)).requests.length === concurrentRequest + 2);
  state = await snapshot(worker);
  assert.notEqual(state.ports[accepted].sent.at(-1).sessionId, state.ports[second].sent.at(-1).sessionId);
  await close(second);
  assert.equal((await snapshot(worker)).requests[concurrentRequest].aborted, true);
  assert.equal((await snapshot(worker)).requests[concurrentRequest + 1].aborted, false);
  await complete(concurrentRequest + 1);
  await waitFor('surviving conversation', async () => (await snapshot(worker)).ports[accepted].sent
    .filter(message => message.status === 'done').length === 2);
  await close(accepted);
  await assertQuiet(initialPages);

  // Stop an actual worker with a pending answer. This diagnostic does not test
  // natural suspension or a real host process (the native port is mocked).
  const restarting = await invoke({ apiMode: 'slow' });
  await select(restarting);
  await waitForMessage(worker, restarting, 'answer', 'streaming');
  await assertQuiet(initialPages);
  const cdp = await context.newCDPSession(page);
  try {
    const versions = new Map();
    cdp.on('ServiceWorker.workerVersionUpdated', ({ versions: updates }) => {
      for (const update of updates) versions.set(update.versionId, update);
    });
    await cdp.send('ServiceWorker.enable');
    await waitFor('running worker version', () => [...versions.values()]
      .some(value => value.scriptURL === worker.url() && value.runningStatus === 'running'));
    const version = [...versions.values()].find(value => value.scriptURL === worker.url()
      && value.runningStatus === 'running');
    const workerUrl = worker.url();
    const previousBoot = await worker.evaluate(() => globalThis.__snapscreenNativeState.bootId);
    await cdp.send('ServiceWorker.stopWorker', { versionId: version.versionId });
    await waitFor('stopped worker version', () => versions.get(version.versionId)?.runningStatus === 'stopped');
    await cdp.send('ServiceWorker.startWorker', { scopeURL: new URL('/', workerUrl).href });
    // Chromium may retain the same Playwright Worker object while replacing its
    // execution context. Require a fresh realm, regardless of target reuse.
    await waitFor('restarted worker initialization', async () => {
      for (const candidate of context.serviceWorkers().filter(candidate => candidate.url() === workerUrl)) {
        const fresh = await candidate.evaluate(previousBoot =>
          globalThis.__snapscreenNativeState?.actions.length === 1
          && globalThis.__snapscreenNativeState.bootId !== previousBoot, previousBoot).catch(() => false);
        if (fresh) { worker = candidate; return true; }
      }
      return false;
    });
    // Startup work can reconnect or resend after an awaited storage read.
    await new Promise(resolve => setTimeout(resolve, 500));
    state = await snapshot(worker);
    assert.deepEqual(state.ports, [], 'Restart replayed a native session.');
    assert.deepEqual(state.requests, [], 'Restart replayed an API request.');
    assert.equal(state.captures, 0);
    const stored = await worker.evaluate(() => chrome.storage.local.get(null));
    assert.deepEqual(Object.keys(stored).sort(), ['apiKey', 'defaultPrompt', 'interfaceMode', 'limits']);
    await worker.evaluate(() => { globalThis.__snapscreenNativeState.observing = true; });
    const fresh = await invoke();
    await select(fresh);
    await waitForMessage(worker, fresh, 'answer', 'done');
    assert.equal((await snapshot(worker)).requests[0].body.messages.length, 1,
      'New worker retained old conversation history.');
    await close(fresh);
    state = await snapshot(worker);
    assert.equal(state.ports.length, 1, 'Restart opened an extra native session.');
    assert.equal(state.requests.length, 1, 'Restart sent an extra API request.');
    await assertQuiet(initialPages);
  } finally {
    await cdp.detach();
  }
}
