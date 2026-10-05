import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { chromium } from 'playwright';

const ROOT = resolve(import.meta.dirname, '..');
const DIST = join(ROOT, 'dist');
const FIXTURE_URL = 'https://api.anthropic.com/snapscreen-smoke';
const API_URL = 'https://api.anthropic.com/v1/messages';
const UI_HOST_SELECTOR = '#snapscreen-ui-host';
const UI_FRAME_PATH = '/src/ui/result-frame.html';
const WORKSPACE_PATH = '/src/workspace/workspace.html';
const OPTIONS_PATH = '/src/options/options.html';
const ANSWER_SENTINEL = 'SNAPSCREEN_SMOKE_ANSWER_7C91F2';
const COMPOSER_SENTINEL = 'SNAPSCREEN_SMOKE_COMPOSER_4A8DE6';
const CODE_SENTINEL = 'SNAPSCREEN_SMOKE_CODE_5B3E9D';
const PARTIAL_SENTINELS = [
  'SNAPSCREEN_SMOKE_PARTIAL_1D6A40',
  'SNAPSCREEN_SMOKE_PARTIAL_8F2C17',
];
const FOLLOW_UP_SENTINEL = 'SNAPSCREEN_SMOKE_FOLLOW_UP_3E57B9';
const LONG_ANSWER_SENTINELS = [
  'SNAPSCREEN_SMOKE_LONG_ANSWER_6B1E04',
  'SNAPSCREEN_SMOKE_LONG_ANSWER_2D9C51',
];
const SMOKE_CODE = `def answer():\n    return "${CODE_SENTINEL}"`;
const SMOKE_ANSWER = `${ANSWER_SENTINEL}\n\n\`\`\`python\n${SMOKE_CODE}\n\`\`\``;
const HIDDEN_PROMPT = 'What does this show? Answer accurately and concisely.';
const TEST_API_KEY = 'sk-ant-snapscreen-smoke-only-93C57A';
const REQUIRED_SNIP_INSTRUCTION = 'Drag to select a region. Click to cancel';
const FORBIDDEN_SNIP_INSTRUCTIONS = [
  'Keyboard:',
  'Escape cancels',
  'press Enter',
  'Arrow keys move',
  'Enter confirms',
  '·',
];
const TEST_CROP_DATA_URL =
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
// Wider than the 2,576 px edge limit, like a full-width snip on a 2x screen.
const OVERSIZE_CROP_SIZE = { width: 3_000, height: 48 };
const DOWNSCALED_CROP_WIDTH = 2_576;
const TEST_TIMEOUT_MS = 15_000;
const OVERALL_TIMEOUT_MS = 30_000;

function sleep(milliseconds) {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, milliseconds));
}

async function verifyBuild() {
  const manifestPath = join(DIST, 'manifest.json');
  let manifest;
  try {
    manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
  } catch (error) {
    throw new Error(`Could not read ${manifestPath}. Run npm run build first.`, { cause: error });
  }

  if (manifest.manifest_version !== 3 || !manifest.background?.service_worker) {
    throw new Error('dist/manifest.json is not a built Manifest V3 extension.');
  }
  if (!Array.isArray(manifest.permissions) || !manifest.permissions.includes('activeTab')) {
    throw new Error('The built extension is missing its activeTab permission.');
  }
  if (
    !Array.isArray(manifest.optional_host_permissions)
    || !manifest.optional_host_permissions.includes('file:///*')
  ) {
    throw new Error('The built extension is missing its optional local-file permission.');
  }

  const webAccessibleResources = (manifest.web_accessible_resources ?? [])
    .flatMap((entry) => entry.resources ?? []);
  if (webAccessibleResources.includes(WORKSPACE_PATH.slice(1))) {
    throw new Error('The trusted workspace must not be web-accessible.');
  }

  const contentScript = 'src/content/index.js';
  const contentSource = await readFile(join(DIST, contentScript), 'utf8');
  if (
    !contentSource.trimStart().startsWith('(function()')
    || contentSource.includes('import(')
    || !contentSource.includes('onMessage.addListener')
  ) {
    throw new Error('The built content script is not a synchronous IIFE with its listener inline.');
  }
  try {
    await readFile(join(DIST, UI_FRAME_PATH.slice(1)), 'utf8');
  } catch (error) {
    throw new Error(`Could not read the built UI frame at ${UI_FRAME_PATH}.`, { cause: error });
  }
  try {
    await readFile(join(DIST, WORKSPACE_PATH.slice(1)), 'utf8');
  } catch (error) {
    throw new Error(`Could not read the built workspace at ${WORKSPACE_PATH}.`, { cause: error });
  }

  return contentScript;
}

async function createOversizeCrop(worker) {
  return worker.evaluate(async ({ width, height }) => {
    const canvas = new OffscreenCanvas(width, height);
    const context = canvas.getContext('2d');
    context.fillStyle = '#ffffff';
    context.fillRect(0, 0, width, height);
    context.fillStyle = '#000000';
    context.font = '32px sans-serif';
    context.fillText('What is 2 + 2?', 16, 36);
    const blob = await canvas.convertToBlob({ type: 'image/png' });
    let binary = '';
    for (const byte of new Uint8Array(await blob.arrayBuffer())) {
      binary += String.fromCharCode(byte);
    }
    return `data:image/png;base64,${btoa(binary)}`;
  }, OVERSIZE_CROP_SIZE);
}

async function waitForExtensionWorker(context) {
  const existing = context.serviceWorkers()[0];
  if (existing) return existing;
  return context.waitForEvent('serviceworker', { timeout: TEST_TIMEOUT_MS });
}

function isUiFrame(frame) {
  try {
    const url = new URL(frame.url());
    return url.protocol === 'chrome-extension:' && url.pathname === UI_FRAME_PATH;
  } catch {
    return false;
  }
}

async function waitForUiFrame(page) {
  const existing = page.frames().find(isUiFrame);
  const frame = existing ?? await page.waitForEvent('framenavigated', {
    predicate: isUiFrame,
    timeout: TEST_TIMEOUT_MS,
  });
  await frame.waitForLoadState('domcontentloaded');
  return frame;
}

function isOptionsPage(page) {
  try {
    const url = new URL(page.url());
    return url.protocol === 'chrome-extension:' && url.pathname === OPTIONS_PATH;
  } catch {
    return false;
  }
}

// Unit tests stub chrome.runtime, so only a real browser shows whether the
// in-page panel can open Settings. Saves a key there the way a user would and
// returns to the page, where the error's Try again button is still waiting.
async function saveKeyFromMissingKeyError(context, page, frame) {
  const overlay = frame.locator('#snapscreen-overlay-root');
  await overlay.waitFor({ state: 'visible', timeout: TEST_TIMEOUT_MS });
  await overlay.press('Enter');
  await overlay.press('Enter');

  const error = frame.locator('.snapscreen-error');
  const openSettings = error.getByRole('button', { name: 'Open Settings' });
  await openSettings.waitFor({ state: 'visible', timeout: TEST_TIMEOUT_MS });

  // Chrome may focus an open Settings tab instead of opening another, so close
  // the one opened on install.
  for (const existing of context.pages()) {
    if (isOptionsPage(existing)) await existing.close();
  }
  const opened = context.waitForEvent('page', { timeout: TEST_TIMEOUT_MS });
  await openSettings.click();
  const optionsPage = await opened;
  await optionsPage.waitForURL((url) => url.pathname === OPTIONS_PATH, {
    timeout: TEST_TIMEOUT_MS,
  });
  await verifyCollapsedLimitValidation(optionsPage);
  await optionsPage.locator('#api-key').fill(TEST_API_KEY);
  await optionsPage.locator('#save-settings').click();
  await optionsPage.locator('#status').filter({ hasText: 'Settings saved.' }).waitFor({
    state: 'visible',
    timeout: TEST_TIMEOUT_MS,
  });
  await optionsPage.close();

  await page.bringToFront();
  const tryAgain = error.getByRole('button', { name: 'Try again' });
  await tryAgain.waitFor({ state: 'visible', timeout: TEST_TIMEOUT_MS });
  return tryAgain;
}

// Chrome can't focus an invalid field inside a closed <details>, so unless the
// options page opens the Advanced section first, Save does nothing visible.
async function verifyCollapsedLimitValidation(optionsPage) {
  const advanced = optionsPage.locator('#advanced-settings');
  const summary = advanced.locator('summary');
  const turns = optionsPage.locator('#max-conversation-turns');
  if (await advanced.evaluate((details) => details.open)) {
    throw new Error('Settings opened with the Advanced section expanded.');
  }

  await summary.click();
  const savedTurns = await turns.inputValue();
  await turns.fill('1');
  await summary.click();
  await optionsPage.locator('#save-settings').click();
  try {
    await optionsPage.waitForFunction(
      () => document.getElementById('advanced-settings')?.open === true
        && document.activeElement?.id === 'max-conversation-turns',
      undefined,
      { timeout: TEST_TIMEOUT_MS },
    );
  } catch (error) {
    throw new Error('Save did not reveal an invalid limit in the collapsed Advanced section.', {
      cause: error,
    });
  }
  if (!await optionsPage.locator('#status').isHidden()) {
    throw new Error('Settings saved an invalid limit.');
  }

  await turns.fill(savedTurns);
  await summary.click();
}

// Reads the PNG header of the screenshot an answer request sent.
function readSentImageWidth(apiRequest) {
  let body;
  try {
    body = JSON.parse(apiRequest.postData ?? '');
  } catch {
    return 0;
  }
  const imageBlock = body.messages?.[0]?.content?.find?.((block) => block.type === 'image');
  const sentPng = Buffer.from(imageBlock?.source?.data ?? '', 'base64');
  return sentPng.length >= 24 ? sentPng.readUInt32BE(16) : 0;
}

async function waitForAnswer(frame, apiRequests) {
  try {
    await frame.getByText(ANSWER_SENTINEL, { exact: true }).waitFor({
      state: 'visible',
      timeout: TEST_TIMEOUT_MS,
    });
  } catch (error) {
    const frameText = await frame.locator('body').innerText().catch(() => '');
    throw new Error(
      `The isolated result did not render (API requests=${apiRequests.length}, frame text=${JSON.stringify(frameText)}).`,
      { cause: error },
    );
  }
}

async function verifyEscapeClose(page, frame, focusTarget, flow) {
  await focusTarget.focus();
  await page.keyboard.down('Escape');
  try {
    // Hold the key across renderer and MessageChannel tasks so teardown cannot
    // win a race against an immediately dispatched keyup.
    await sleep(100);
    if (frame.isDetached() || await page.locator(UI_HOST_SELECTOR).count() !== 1) {
      throw new Error(`${flow}: the UI frame was removed before Escape was released.`);
    }
    if (!await frame.evaluate(() => document.hasFocus())) {
      throw new Error(`${flow}: the UI frame lost focus before Escape was released.`);
    }
  } finally {
    await page.keyboard.up('Escape');
  }
  await page.locator(UI_HOST_SELECTOR).waitFor({
    state: 'detached',
    timeout: TEST_TIMEOUT_MS,
  });
}

async function verifyInternalOverlayStyle(frame) {
  const overlay = frame.locator('#snapscreen-overlay-root');
  await overlay.waitFor({ state: 'visible', timeout: TEST_TIMEOUT_MS });
  const styles = await overlay.evaluate((element) => {
    const computed = getComputedStyle(element);
    const bounds = element.getBoundingClientRect();
    return {
      cursor: computed.cursor,
      height: bounds.height,
      pointerEvents: computed.pointerEvents,
      position: computed.position,
      width: bounds.width,
    };
  });
  if (
    styles.position !== 'fixed'
    || styles.cursor !== 'crosshair'
    || styles.pointerEvents !== 'auto'
  ) {
    throw new Error(
      `Host CSP blocked UI-frame snip styles (position=${styles.position}, cursor=${styles.cursor}, pointer-events=${styles.pointerEvents}).`,
    );
  }
  if (styles.width < 500 || styles.height < 300) {
    throw new Error('The styled UI-frame snip overlay does not cover the test viewport.');
  }
}

async function verifySnipInstruction(frame, flow) {
  const hint = frame.locator('.snapscreen-hint');
  await hint.waitFor({ state: 'visible', timeout: TEST_TIMEOUT_MS });
  const hintText = await hint.textContent();
  if (hintText !== REQUIRED_SNIP_INSTRUCTION) {
    throw new Error(
      `${flow} rendered the wrong snip instruction: ${JSON.stringify(hintText)}.`,
    );
  }

  const renderedStrings = await frame.locator('body').evaluate((body) => {
    const strings = [body.textContent ?? ''];
    for (const element of body.querySelectorAll('*')) {
      strings.push(
        element.getAttribute('aria-label') ?? '',
        element.getAttribute('title') ?? '',
        getComputedStyle(element, '::before').content,
        getComputedStyle(element, '::after').content,
      );
    }
    return strings;
  });
  for (const forbidden of FORBIDDEN_SNIP_INSTRUCTIONS) {
    if (renderedStrings.some((value) => value.includes(forbidden))) {
      throw new Error(`${flow} exposed forbidden snip guidance: ${forbidden}`);
    }
  }
}

async function verifyCodeBlockCopy(page, frame) {
  const codeBlocks = frame.locator('.snapscreen-code-block');
  if (await codeBlocks.count() !== 1) {
    throw new Error('The completed answer did not render exactly one code block.');
  }
  const language = await codeBlocks.locator('.snapscreen-code-language').textContent();
  const code = await codeBlocks.locator('.snapscreen-code code').textContent();
  if (language !== 'python' || code !== SMOKE_CODE) {
    throw new Error(
      `The code block rendered the wrong content (language=${JSON.stringify(language)}, code=${JSON.stringify(code)}).`,
    );
  }

  await codeBlocks.locator('.snapscreen-code-copy-btn').click();
  await frame.locator('.snapscreen-code-copy-btn[aria-label="Copied"]').waitFor({
    state: 'attached',
    timeout: TEST_TIMEOUT_MS,
  });
  // Reading needs a focused page and a granted permission; the extension frame
  // itself only ever writes.
  await page.bringToFront();
  const clipboardText = await page.evaluate(() => navigator.clipboard.readText());
  if (clipboardText !== SMOKE_CODE) {
    throw new Error(
      `Copy code wrote ${JSON.stringify(clipboardText)} instead of the code block.`,
    );
  }
}

// With `interrupted`, the stream ends after the first text, the way a dropped
// connection does, so the answer fails partway through.
function answerSse(answer, { interrupted = false } = {}) {
  const events = [
    {
      event: 'message_start',
      data: {
        type: 'message_start',
        message: {
          id: 'msg_snapscreen_smoke',
          type: 'message',
          role: 'assistant',
          model: 'claude-sonnet-5-5',
          content: [],
          stop_reason: null,
          stop_sequence: null,
          usage: { input_tokens: 1, output_tokens: 0 },
        },
      },
    },
    {
      event: 'content_block_start',
      data: {
        type: 'content_block_start',
        index: 0,
        content_block: { type: 'text', text: '' },
      },
    },
    {
      event: 'content_block_delta',
      data: {
        type: 'content_block_delta',
        index: 0,
        delta: { type: 'text_delta', text: answer },
      },
    },
    {
      event: 'content_block_stop',
      data: { type: 'content_block_stop', index: 0 },
    },
    {
      event: 'message_delta',
      data: {
        type: 'message_delta',
        delta: { stop_reason: 'end_turn', stop_sequence: null },
        usage: { output_tokens: 1 },
      },
    },
    {
      event: 'message_stop',
      data: { type: 'message_stop' },
    },
  ];
  return (interrupted ? events.slice(0, 3) : events)
    .map(({ event, data }) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`)
    .join('');
}

// Answers long enough to scroll the panel body.
function longAnswer(sentinel) {
  const lines = Array.from({ length: 40 }, (_, index) => `Line ${index + 1} of a long answer.`);
  return [...lines, sentinel].join('\n');
}

async function readBodyScroll(frame) {
  // Let the panel apply any scroll it scheduled for the next frame.
  await frame.evaluate(() => new Promise((resolve) => {
    requestAnimationFrame(() => requestAnimationFrame(resolve));
  }));
  return frame.locator('.snapscreen-panel-body').evaluate((body) => ({
    max: body.scrollHeight - body.clientHeight,
    top: body.scrollTop,
  }));
}

async function scrollBodyTo(frame, top) {
  await frame.locator('.snapscreen-panel-body').evaluate((body, value) => {
    body.scrollTop = value;
  }, top);
}

async function waitForFinishedAnswer(frame, sentinel) {
  await frame.locator('.snapscreen-msg-assistant:not(.snapscreen-msg-streaming)')
    .filter({ hasText: sentinel })
    .waitFor({ state: 'attached', timeout: TEST_TIMEOUT_MS });
}

// The panel follows a streaming answer only while the reader is at its end.
// Asking a question brings it into view, and a reader who scrolled up stays
// put while the next answer streams and finishes.
async function verifyScrollFollowing(frame, queuedApiBodies, apiGate) {
  const [firstSentinel, followUpSentinel] = LONG_ANSWER_SENTINELS;
  queuedApiBodies.push(answerSse(longAnswer(firstSentinel)));
  const overlay = frame.locator('#snapscreen-overlay-root');
  await overlay.waitFor({ state: 'visible', timeout: TEST_TIMEOUT_MS });
  await overlay.press('Enter');
  await overlay.press('Enter');

  await waitForFinishedAnswer(frame, firstSentinel);
  let scroll = await readBodyScroll(frame);
  if (scroll.max <= 0) {
    throw new Error('The long smoke answer did not overflow the panel body.');
  }
  if (scroll.top < scroll.max - 1) {
    throw new Error(`The panel stopped following an answer the reader stayed at the end of (scrollTop ${scroll.top} of ${scroll.max}).`);
  }

  await scrollBodyTo(frame, 0);
  apiGate.hold();
  queuedApiBodies.push(answerSse(longAnswer(followUpSentinel)));
  const composer = frame.locator('.snapscreen-input');
  await composer.fill('Tell me more.');
  await composer.press('Enter');
  await frame.locator('.snapscreen-pending').waitFor({
    state: 'visible',
    timeout: TEST_TIMEOUT_MS,
  });
  scroll = await readBodyScroll(frame);
  if (scroll.top < scroll.max - 1) {
    throw new Error(`Asking a question did not bring it into view (scrollTop ${scroll.top} of ${scroll.max}).`);
  }

  await scrollBodyTo(frame, 40);
  apiGate.release();
  await waitForFinishedAnswer(frame, followUpSentinel);
  scroll = await readBodyScroll(frame);
  if (Math.abs(scroll.top - 40) > 1) {
    throw new Error(`The panel moved a reader who scrolled up (scrollTop ${scroll.top}, expected 40).`);
  }
  return composer;
}

// Answers in the worker with a stream that starts a thinking block and then
// stalls until the request is aborted. Playwright can only fulfill a route with
// a complete body, so it can't hold a stream open.
async function installStalledThinkingStream(worker) {
  await worker.evaluate((apiUrl) => {
    const realFetch = globalThis.fetch;
    globalThis.__snapscreenSmokeRealFetch = realFetch;
    globalThis.__snapscreenSmokeStreamAborted = false;
    globalThis.fetch = async (input, init) => {
      const url = typeof input === 'string' ? input : input.url;
      if (url !== apiUrl) return realFetch(input, init);

      const encoder = new TextEncoder();
      const events = [
        {
          type: 'message_start',
          message: {
            id: 'msg_snapscreen_smoke_thinking',
            type: 'message',
            role: 'assistant',
            model: 'claude-sonnet-5-5',
            content: [],
            stop_reason: null,
            stop_sequence: null,
            usage: { input_tokens: 1, output_tokens: 0 },
          },
        },
        {
          type: 'content_block_start',
          index: 0,
          content_block: { type: 'thinking', thinking: '', signature: '' },
        },
      ];
      const body = new ReadableStream({
        start(controller) {
          for (const event of events) {
            controller.enqueue(encoder.encode(
              `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`,
            ));
          }
          init?.signal?.addEventListener('abort', () => {
            globalThis.__snapscreenSmokeStreamAborted = true;
            controller.error(init.signal.reason);
          }, { once: true });
        },
      });
      return new Response(body, { headers: { 'content-type': 'text/event-stream' } });
    };
  }, API_URL);
}

async function restoreWorkerFetch(worker) {
  await worker.evaluate(() => {
    globalThis.fetch = globalThis.__snapscreenSmokeRealFetch;
  });
}

// A slow answer says how long it has taken, says Thinking once the stream
// starts a thinking block, and can still be stopped. The fake clock stands in
// for a 30-second wait.
async function verifySlowAnswerStatus(context, worker, frame) {
  const overlay = frame.locator('#snapscreen-overlay-root');
  await overlay.waitFor({ state: 'visible', timeout: TEST_TIMEOUT_MS });
  await overlay.press('Enter');
  await overlay.press('Enter');
  await frame.locator('.snapscreen-pending').waitFor({
    state: 'visible',
    timeout: TEST_TIMEOUT_MS,
  });

  await context.clock.fastForward(30_000);
  const label = frame.locator('.snapscreen-pending-label');
  try {
    await label.filter({ hasText: 'Thinking…' }).waitFor({
      state: 'visible',
      timeout: TEST_TIMEOUT_MS,
    });
  } catch (error) {
    throw new Error(
      `A slow answer did not say Thinking (status ${JSON.stringify(await label.textContent())}).`,
      { cause: error },
    );
  }
  const elapsed = await frame.locator('.snapscreen-pending-time').textContent();
  if (!/^0:3\d$/.test(elapsed ?? '')) {
    throw new Error(`A 30-second wait showed ${JSON.stringify(elapsed)} instead of a running timer.`);
  }

  await frame.getByRole('button', { name: 'Stop generating' }).click();
  await frame.getByText('Generation stopped.').waitFor({
    state: 'visible',
    timeout: TEST_TIMEOUT_MS,
  });
  if (await frame.locator('.snapscreen-pending').count() !== 0) {
    throw new Error('The pending status stayed after Stop.');
  }
  if (!await worker.evaluate(() => globalThis.__snapscreenSmokeStreamAborted)) {
    throw new Error('Stop did not cancel the stalled request.');
  }
  return frame.locator('.snapscreen-input');
}

// A first answer that fails partway keeps its text and offers Try again, which
// answers the same capture again. A follow-up can then build on the
// interrupted answer, and must resend the oversize capture downscaled, like
// the first request.
async function verifyInterruptedFirstAnswer(frame, apiRequests, queuedApiBodies) {
  const [firstPartial, secondPartial] = PARTIAL_SENTINELS;
  queuedApiBodies.push(
    answerSse(firstPartial, { interrupted: true }),
    answerSse(secondPartial, { interrupted: true }),
  );
  const overlay = frame.locator('#snapscreen-overlay-root');
  await overlay.waitFor({ state: 'visible', timeout: TEST_TIMEOUT_MS });
  await overlay.press('Enter');
  await overlay.press('Enter');

  const failed = frame.locator('.snapscreen-msg-failed');
  await failed.filter({ hasText: firstPartial }).waitFor({
    state: 'visible',
    timeout: TEST_TIMEOUT_MS,
  });
  if (!(await failed.textContent())?.includes('Response interrupted:')) {
    throw new Error('The interrupted first answer was not marked as interrupted.');
  }

  await frame.getByRole('button', { name: 'Try again' }).click();
  await failed.filter({ hasText: secondPartial }).waitFor({
    state: 'visible',
    timeout: TEST_TIMEOUT_MS,
  });
  if (await frame.locator('.snapscreen-msg').count() !== 1) {
    throw new Error('Try again did not replace the interrupted first answer.');
  }

  const composer = frame.locator('.snapscreen-input');
  await composer.fill(FOLLOW_UP_SENTINEL);
  await composer.press('Enter');
  await waitForAnswer(frame, apiRequests);

  const requests = apiRequests.splice(0);
  if (requests.length !== 3) {
    throw new Error(`Expected 3 requests for the interrupted-answer flow, got ${requests.length}.`);
  }
  const [, retryRequest, followUpRequest] = requests;
  const retryMessages = JSON.parse(retryRequest.postData ?? '{}').messages ?? [];
  if (retryMessages.length !== 1 || readSentImageWidth(retryRequest) !== DOWNSCALED_CROP_WIDTH) {
    throw new Error('Try again did not resend the capture as a new first answer.');
  }
  const followUpMessages = JSON.parse(followUpRequest.postData ?? '{}').messages ?? [];
  if (
    followUpMessages.length !== 3
    || !String(followUpMessages[1]?.content).includes(`${secondPartial}\n\nResponse interrupted:`)
    || followUpMessages[2]?.content !== FOLLOW_UP_SENTINEL
  ) {
    throw new Error('The follow-up did not build on the interrupted first answer.');
  }
  const followUpWidth = readSentImageWidth(followUpRequest);
  if (followUpWidth !== DOWNSCALED_CROP_WIDTH) {
    throw new Error(
      `Expected the follow-up to resend the capture at ${DOWNSCALED_CROP_WIDTH} px wide, got ${followUpWidth} px.`,
    );
  }
  return composer;
}

async function installHostProbe(page) {
  await page.addInitScript(
    ({ answerSentinel, codeSentinel, composerSentinel }) => {
      // Init scripts also run in child frames. The probe models the hostile
      // host page, which cannot run script inside the extension frame; there
      // it would cancel the frame's own clicks.
      if (window !== window.top) return;
      const sentinels = [answerSentinel, codeSentinel, composerSentinel];
      const probe = { events: [], exposures: [] };
      Object.defineProperty(window, '__snapscreenSmokeHostProbe', {
        configurable: false,
        value: probe,
      });

      const eventTypes = [
        'keydown',
        'keyup',
        'beforeinput',
        'input',
        'pointerdown',
        'pointermove',
        'pointerup',
        'click',
      ];
      const recordEvent = (listener) => (event) => {
        probe.events.push({
          listener,
          type: event.type,
          key: typeof event.key === 'string' ? event.key : undefined,
          inputType: typeof event.inputType === 'string' ? event.inputType : undefined,
          target: event.target instanceof Element
            ? `${event.target.tagName.toLowerCase()}#${event.target.id}`
            : String(event.target),
        });
        if (event.type.startsWith('pointer') || event.type === 'click') {
          event.preventDefault();
          event.stopImmediatePropagation();
        }
      };
      for (const type of eventTypes) {
        window.addEventListener(type, recordEvent('window'), true);
        document.addEventListener(type, recordEvent('document'), true);
      }

      const recordExposure = (source, value) => {
        for (const sentinel of sentinels) {
          if (value.includes(sentinel) && probe.exposures.length < 20) {
            probe.exposures.push({ source, sentinel });
          }
        }
      };
      const inspectPageDom = (source) => {
        const bodyText = document.body?.textContent ?? '';
        const queriedText = Array.from(document.querySelectorAll('body *'))
          .map((element) => {
            const value = 'value' in element && typeof element.value === 'string'
              ? element.value
              : '';
            return `${element.textContent ?? ''}\n${value}`;
          })
          .join('\n');
        recordExposure(`${source}:body`, bodyText);
        recordExposure(`${source}:querySelector`, queriedText);
      };

      document.addEventListener('DOMContentLoaded', () => {
        for (const type of eventTypes) {
          document.body?.addEventListener(type, recordEvent('body'), true);
        }
        inspectPageDom('domcontentloaded');
      }, { once: true });

      new MutationObserver(() => inspectPageDom('mutation')).observe(document, {
        attributes: true,
        characterData: true,
        childList: true,
        subtree: true,
      });
      window.addEventListener('message', (event) => {
        let value = '';
        try {
          value = JSON.stringify(event.data);
        } catch {
          value = String(event.data);
        }
        recordExposure('message', value);
      });
    },
    {
      answerSentinel: ANSWER_SENTINEL,
      codeSentinel: CODE_SENTINEL,
      composerSentinel: COMPOSER_SENTINEL,
    },
  );
}

async function injectAndStartSnip(
  worker,
  contentLoader,
  { apiKey, croppedDataUrl },
) {
  return worker.evaluate(
    async ({
      apiKey,
      croppedDataUrl,
      fixtureUrl,
      hiddenPrompt,
      loader,
      screenshotDataUrl,
    }) => {
      const tab = (await chrome.tabs.query({})).find(
        (candidate) => candidate.url === fixtureUrl,
      );
      if (typeof tab?.id !== 'number') {
        throw new Error('Could not find the smoke fixture tab from the extension worker.');
      }

      await chrome.storage.local.set({ apiKey });
      if (!globalThis.__snapscreenSmokeCaptureMockInstalled) {
        globalThis.__snapscreenSmokeCaptureMockInstalled = true;
        chrome.runtime.onMessage.addListener((message, sender) => {
          if (
            message?.type !== 'CAPTURE_REGION'
            || typeof message.captureId !== 'string'
            || typeof sender.tab?.id !== 'number'
          ) return;

          const options = typeof sender.documentId === 'string'
            ? { documentId: sender.documentId }
            : undefined;
          void chrome.tabs.sendMessage(
            sender.tab.id,
            {
              type: 'CROPPED_IMAGE',
              captureId: message.captureId,
              dataUrl: croppedDataUrl,
            },
            options,
          );
        });
      }
      const [injectionResult] = await chrome.scripting.executeScript({
        target: { tabId: tab.id },
        files: [loader],
      });
      if (!injectionResult?.documentId) {
        throw new Error('The smoke injection did not return a document id.');
      }

      const message = {
        type: 'START_SNIP',
        captureId: crypto.randomUUID(),
        dataUrl: screenshotDataUrl,
        defaultPrompt: hiddenPrompt,
        limits: {
          maxInputCharacters: 4_000,
          maxScreenshotBytes: 5_242_880,
          maxScreenshotDimension: 2_576,
          maxConversationTurns: 12,
        },
      };

      await chrome.tabs.sendMessage(
        tab.id,
        message,
        { documentId: injectionResult.documentId },
      );
    },
    {
      apiKey,
      croppedDataUrl,
      fixtureUrl: FIXTURE_URL,
      hiddenPrompt: HIDDEN_PROMPT,
      loader: contentLoader,
      screenshotDataUrl: TEST_CROP_DATA_URL,
    },
  );
}

async function assertHostPageIsolation(page) {
  const observation = await page.evaluate(
    ({ answerSentinel, codeSentinel, composerSentinel, framePath }) => {
      const probe = window.__snapscreenSmokeHostProbe;
      const bodyText = document.body?.textContent ?? '';
      const queriedElements = Array.from(document.querySelectorAll('body *'));
      const queriedText = queriedElements
        .map((element) => {
          const value = 'value' in element && typeof element.value === 'string'
            ? element.value
            : '';
          return `${element.textContent ?? ''}\n${value}`;
        })
        .join('\n');
      return {
        bodyContainsAnswer: bodyText.includes(answerSentinel),
        bodyContainsCode: bodyText.includes(codeSentinel),
        bodyContainsComposer: bodyText.includes(composerSentinel),
        events: probe?.events ?? null,
        exposures: probe?.exposures ?? null,
        queryContainsAnswer: queriedText.includes(answerSentinel),
        queryContainsCode: queriedText.includes(codeSentinel),
        queryContainsComposer: queriedText.includes(composerSentinel),
        queryFoundFrame: document.querySelector(`iframe[src*="${framePath}"]`) !== null,
        queryFoundInternalUi: document.querySelector([
          '#snapscreen-overlay-root',
          '.snapscreen-panel',
          '.snapscreen-msg-assistant',
          '.snapscreen-code-block',
          '.snapscreen-input',
        ].join(',')) !== null,
      };
    },
    {
      answerSentinel: ANSWER_SENTINEL,
      codeSentinel: CODE_SENTINEL,
      composerSentinel: COMPOSER_SENTINEL,
      framePath: UI_FRAME_PATH,
    },
  );

  if (!Array.isArray(observation.events) || !Array.isArray(observation.exposures)) {
    throw new Error('The hostile-page observation probe was not installed.');
  }
  const sensitiveEvents = observation.events.filter(
    ({ type }) => type === 'keydown'
      || type === 'keyup'
      || type === 'beforeinput'
      || type === 'input',
  );
  if (sensitiveEvents.length > 0) {
    throw new Error(
      `Host page observed private keyboard/input events: ${JSON.stringify(sensitiveEvents.slice(0, 10))}`,
    );
  }
  const pointerEvents = observation.events.filter(
    ({ type }) => type.startsWith('pointer') || type === 'click',
  );
  if (pointerEvents.some(({ target }) => target !== 'div#snapscreen-ui-host')) {
    throw new Error(
      `Host page observed private pointer targets: ${JSON.stringify(pointerEvents.slice(0, 10))}`,
    );
  }
  if (observation.exposures.length > 0) {
    throw new Error(
      `Host page observed private UI text: ${JSON.stringify(observation.exposures)}`,
    );
  }
  if (
    observation.bodyContainsAnswer
    || observation.bodyContainsCode
    || observation.bodyContainsComposer
    || observation.queryContainsAnswer
    || observation.queryContainsCode
    || observation.queryContainsComposer
    || observation.queryFoundFrame
    || observation.queryFoundInternalUi
  ) {
    throw new Error(`Host DOM exposed extension-frame state: ${JSON.stringify(observation)}`);
  }
}

async function closeContext(context) {
  if (!context) return;
  await Promise.race([
    context.close().catch(() => undefined),
    sleep(3_000),
  ]);
}

let context;
let profileDirectory;
let failure;
let overallTimeoutHandle;

const timeoutFailure = new Promise((_, reject) => {
  overallTimeoutHandle = setTimeout(() => {
    reject(new Error('Extension smoke test exceeded its overall 30 second timeout.'));
  }, OVERALL_TIMEOUT_MS);
});

try {
  await Promise.race([
    (async () => {
      const contentLoader = await verifyBuild();
      profileDirectory = await mkdtemp(join(tmpdir(), 'snapscreen-smoke-'));
      const apiRequests = [];
      // Answers wait for releaseApiResponse() so each flow can see its pending
      // state. holdApiResponses() re-arms the gate for the next flow.
      let releaseApiResponse;
      let apiResponseGate;
      const holdApiResponses = () => {
        apiResponseGate = new Promise((resolveGate) => {
          releaseApiResponse = resolveGate;
        });
      };
      holdApiResponses();
      // Bodies queued here answer the next requests in order. Every other
      // request gets the complete smoke answer.
      const queuedApiBodies = [];
      context = await chromium.launchPersistentContext(profileDirectory, {
        channel: 'chromium',
        headless: true,
        args: [
          `--disable-extensions-except=${DIST}`,
          `--load-extension=${DIST}`,
        ],
      });

      await context.route(FIXTURE_URL, async (route) => {
        await route.fulfill({
          body: '<!doctype html><html><body><h1>What is 2 + 2?</h1></body></html>',
          contentType: 'text/html',
          headers: {
            // Content UI must work even when the host rejects all page-provided
            // scripts, styles, images, and network connections.
            'content-security-policy': "default-src 'none'; style-src 'none'; img-src 'none'; script-src 'none'; connect-src 'none'",
          },
        });
      });
      await context.route(API_URL, async (route) => {
        const request = route.request();
        apiRequests.push({
          headers: request.headers(),
          method: request.method(),
          postData: request.postData(),
        });
        await apiResponseGate;
        await route.fulfill({
          status: 200,
          contentType: 'text/event-stream',
          headers: {
            'cache-control': 'no-cache',
          },
          body: queuedApiBodies.shift() ?? answerSse(SMOKE_ANSWER),
        });
      });

      // Lets the smoke test read back what the frame's Copy button wrote.
      await context.grantPermissions(['clipboard-read'], {
        origin: new URL(FIXTURE_URL).origin,
      });

      const worker = await waitForExtensionWorker(context);
      if (!worker.url().startsWith('chrome-extension://')) {
        throw new Error(`Unexpected extension service-worker URL: ${worker.url()}`);
      }

      const oversizeCrop = await createOversizeCrop(worker);
      const page = await context.newPage();
      await installHostProbe(page);
      await page.goto(FIXTURE_URL, { waitUntil: 'domcontentloaded' });
      await page.bringToFront();
      await injectAndStartSnip(worker, contentLoader, {
        apiKey: '',
        croppedDataUrl: oversizeCrop,
      });

      let uiHost = page.locator(UI_HOST_SELECTOR);
      await uiHost.waitFor({ state: 'attached', timeout: TEST_TIMEOUT_MS });
      const hasClosedShadowBoundary = await uiHost.evaluate(
        (host) => host.shadowRoot === null,
      );
      if (!hasClosedShadowBoundary) {
        throw new Error('SnapScreen UI host exposed an open Shadow root to the page.');
      }
      let uiFrame = await waitForUiFrame(page);
      await verifyInternalOverlayStyle(uiFrame);
      await verifySnipInstruction(uiFrame, 'No-API-key flow');

      await verifyEscapeClose(
        page,
        uiFrame,
        uiFrame.locator('#snapscreen-overlay-root'),
        'No-API-key cancellation',
      );

      await injectAndStartSnip(worker, contentLoader, {
        apiKey: '',
        croppedDataUrl: oversizeCrop,
      });
      uiHost = page.locator(UI_HOST_SELECTOR);
      await uiHost.waitFor({ state: 'attached', timeout: TEST_TIMEOUT_MS });
      uiFrame = await waitForUiFrame(page);
      const tryAgain = await saveKeyFromMissingKeyError(context, page, uiFrame);
      if (apiRequests.length !== 0) {
        throw new Error(`The no-API-key flow sent ${apiRequests.length} Anthropic request(s).`);
      }

      // The capture survives the trip to Settings, so no second snip is needed.
      await tryAgain.click();
      await uiFrame.locator('.snapscreen-pending').waitFor({
        state: 'visible',
        timeout: TEST_TIMEOUT_MS,
      });
      releaseApiResponse();
      await waitForAnswer(uiFrame, apiRequests);
      const retryRequests = apiRequests.splice(0);
      if (
        retryRequests.length !== 1
        || retryRequests[0].headers['x-api-key'] !== TEST_API_KEY
      ) {
        throw new Error(
          `Try again sent ${retryRequests.length} Anthropic request(s) instead of one with the saved key.`,
        );
      }
      if (readSentImageWidth(retryRequests[0]) !== DOWNSCALED_CROP_WIDTH) {
        throw new Error('Try again did not resend the original capture.');
      }
      await verifyEscapeClose(
        page,
        uiFrame,
        uiFrame.locator('.snapscreen-input'),
        'Missing-key recovery close',
      );
      holdApiResponses();

      await injectAndStartSnip(worker, contentLoader, {
        apiKey: TEST_API_KEY,
        croppedDataUrl: oversizeCrop,
      });
      uiHost = page.locator(UI_HOST_SELECTOR);
      await uiHost.waitFor({ state: 'attached', timeout: TEST_TIMEOUT_MS });
      uiFrame = await waitForUiFrame(page);
      await verifyInternalOverlayStyle(uiFrame);
      await verifySnipInstruction(uiFrame, 'API-key flow');

      const overlay = uiFrame.locator('#snapscreen-overlay-root');
      await overlay.press('Enter');
      await verifySnipInstruction(uiFrame, 'Keyboard-selection flow');
      await overlay.press('ArrowRight');
      await page.bringToFront();
      await overlay.press('Enter');

      const panel = uiFrame.locator('.snapscreen-panel');
      await panel.waitFor({ state: 'visible', timeout: TEST_TIMEOUT_MS });
      await uiFrame.locator('.snapscreen-pending').waitFor({
        state: 'visible',
        timeout: TEST_TIMEOUT_MS,
      });
      const pendingMarkup = await panel.evaluate((element) => element.outerHTML);
      if (pendingMarkup.includes(HIDDEN_PROMPT)) {
        throw new Error('The pending result UI exposed the hidden screenshot prompt.');
      }
      if (await uiFrame.locator('.snapscreen-msg-user').count() !== 0) {
        throw new Error('The pending result UI rendered an automatic user message.');
      }

      releaseApiResponse();
      await waitForAnswer(uiFrame, apiRequests);

      const completedMarkup = await panel.evaluate((element) => element.outerHTML);
      if (completedMarkup.includes(HIDDEN_PROMPT)) {
        throw new Error('The completed result UI exposed the hidden screenshot prompt.');
      }
      if (await uiFrame.locator('.snapscreen-msg').count() !== 1) {
        throw new Error('The completed initial result did not contain exactly one message.');
      }
      if (await uiFrame.locator('.snapscreen-msg-user').count() !== 0) {
        throw new Error('The completed initial result rendered an automatic user message.');
      }

      const composer = uiFrame.locator('.snapscreen-input');
      await composer.waitFor({ state: 'visible', timeout: TEST_TIMEOUT_MS });
      await composer.click();
      const composerHasFocus = await composer.evaluate(
        (element) => element.ownerDocument.activeElement === element,
      );
      if (!composerHasFocus) {
        throw new Error(
          'Host pointer cancellation prevented the extension-frame composer click.',
        );
      }
      await composer.pressSequentially(COMPOSER_SENTINEL);
      if (await composer.inputValue() !== COMPOSER_SENTINEL) {
        throw new Error('The extension-frame composer did not retain the smoke sentinel.');
      }

      if (apiRequests.length !== 1) {
        throw new Error(`Expected one Anthropic request, received ${apiRequests.length}.`);
      }
      const [apiRequest] = apiRequests;
      if (apiRequest.method !== 'POST' || apiRequest.headers['x-api-key'] !== TEST_API_KEY) {
        throw new Error('The mocked Anthropic request did not use the configured test key.');
      }
      let apiBody;
      try {
        apiBody = JSON.parse(apiRequest.postData ?? '');
      } catch {
        throw new Error('The mocked Anthropic request did not contain a JSON body.');
      }
      if (apiBody.stream !== true) {
        throw new Error('The mocked Anthropic request did not enable SSE streaming.');
      }
      const requestText = JSON.stringify(apiBody.messages);
      if (!requestText.includes(HIDDEN_PROMPT) || !requestText.includes('"type":"image"')) {
        throw new Error('The model request did not retain the hidden prompt and screenshot.');
      }
      const sentWidth = readSentImageWidth(apiRequest);
      if (sentWidth !== DOWNSCALED_CROP_WIDTH) {
        throw new Error(
          `Expected the ${OVERSIZE_CROP_SIZE.width} px capture to be sent at ${DOWNSCALED_CROP_WIDTH} px wide, got ${sentWidth} px.`,
        );
      }

      await verifyCodeBlockCopy(page, uiFrame);

      await sleep(50);
      await assertHostPageIsolation(page);
      await verifyEscapeClose(page, uiFrame, composer, 'Result-panel close');
      await assertHostPageIsolation(page);

      apiRequests.splice(0);
      await injectAndStartSnip(worker, contentLoader, {
        apiKey: TEST_API_KEY,
        croppedDataUrl: oversizeCrop,
      });
      uiHost = page.locator(UI_HOST_SELECTOR);
      await uiHost.waitFor({ state: 'attached', timeout: TEST_TIMEOUT_MS });
      uiFrame = await waitForUiFrame(page);
      const interruptedComposer = await verifyInterruptedFirstAnswer(
        uiFrame,
        apiRequests,
        queuedApiBodies,
      );
      await verifyEscapeClose(page, uiFrame, interruptedComposer, 'Interrupted-answer close');

      await injectAndStartSnip(worker, contentLoader, {
        apiKey: TEST_API_KEY,
        croppedDataUrl: oversizeCrop,
      });
      uiHost = page.locator(UI_HOST_SELECTOR);
      await uiHost.waitFor({ state: 'attached', timeout: TEST_TIMEOUT_MS });
      uiFrame = await waitForUiFrame(page);
      const scrollComposer = await verifyScrollFollowing(uiFrame, queuedApiBodies, {
        hold: holdApiResponses,
        release: () => releaseApiResponse(),
      });
      await verifyEscapeClose(page, uiFrame, scrollComposer, 'Scroll-following close');

      // Last, because the fake clock stays installed for the rest of the run.
      await installStalledThinkingStream(worker);
      await context.clock.install();
      await injectAndStartSnip(worker, contentLoader, {
        apiKey: TEST_API_KEY,
        croppedDataUrl: oversizeCrop,
      });
      uiHost = page.locator(UI_HOST_SELECTOR);
      await uiHost.waitFor({ state: 'attached', timeout: TEST_TIMEOUT_MS });
      uiFrame = await waitForUiFrame(page);
      const slowComposer = await verifySlowAnswerStatus(context, worker, uiFrame);
      await restoreWorkerFetch(worker);
      await verifyEscapeClose(page, uiFrame, slowComposer, 'Slow-answer close');

      process.stdout.write(
        'Unpacked-extension smoke test passed: exact keyed/no-key instruction, no-key Open Settings and Try again, collapsed-limit validation, strict-CSP extension-frame crop, oversize-capture downscale, answer, code-block copy, composer, Escape-release teardown, host-page isolation, interrupted-first-answer Try again and follow-up, streaming scroll-following, and slow-answer status and Stop verified.\n',
      );
    })(),
    timeoutFailure,
  ]);
} catch (error) {
  failure = error;
} finally {
  await closeContext(context);
  if (profileDirectory) {
    await rm(profileDirectory, { force: true, recursive: true }).catch(() => undefined);
  }
  clearTimeout(overallTimeoutHandle);
}

if (failure) {
  if (
    failure instanceof Error
    && /Executable doesn't exist|browserType\.launchPersistentContext/.test(failure.message)
  ) {
    process.stderr.write(
      'Playwright Chromium is not installed. Run: npx playwright install chromium\n',
    );
  } else {
    process.stderr.write(`${failure instanceof Error ? failure.stack : String(failure)}\n`);
  }
  process.exit(1);
}

process.exit(0);
