import assert from 'node:assert/strict';
import { test } from 'node:test';
import { SESSION_GAP_MS, SessionTracker, analyzePage, analyzeRound, formatSummary, trackSessions } from './app-acceptance-report.mjs';

const display = { id: 1, x: 0, y: 0, width: 1728, height: 1117, pixelWidth: 3456, pixelHeight: 2234 };
const overlay = (id, pid = 700) => ({ id, pid, layer: 1000, alpha: 1, x: 0, y: 0, width: 1728, height: 1117 });
const shield = { id: 11, pid: 700, layer: 3, alpha: 1, x: 0, y: 0, width: 1728, height: 1117 };
const panel = (id, pid = 700) => ({ id, pid, layer: 3, alpha: 1, x: 900, y: 200, width: 460, height: 560 });
const focused = { hasFocus: true, visibilityState: 'visible', hidden: false,
  activeElement: { kind: 'element', tag: 'input', fixtureId: 'page-input', hasId: true } };
const entry = (epochMs, type, detail = {}, state = focused) => ({ epochMs, type, detail, state });

/** A round in which every step passes: two Chrome snips, one over Preview and one after the rebuild. */
function round() {
  const windows = (at, list) => ({ type: 'windows', at, windows: list });
  return {
    startedAt: '2026-10-10T18:00:00.000Z',
    environment: { macOS: '27.0.1', macOSBuild: '26A434', browser: 'Chrome/154.0.8037.98', chromePid: 500 },
    builds: [
      { cdhash: 'a'.repeat(40), team: 'TEAM', certificateRequirement: true, bundleVersion: '1.1.0' },
      { cdhash: 'b'.repeat(40), team: 'TEAM', certificateRequirement: true, bundleVersion: '1.1.0.1791650000' },
    ],
    phases: [{ name: 'normal', at: 1000 }, { name: 'fullscreen', at: 6000 }, { name: 'preview', at: 10000 },
      { name: 'rebuilt', at: 14000 }, { name: 'done', at: 19000 }],
    observer: [
      { type: 'ready', at: 0, displays: [display], frontmost: { bundleId: 'com.google.Chrome', pid: 500 },
        pointer: { x: 10, y: 10 }, watched: 'com.snapscreen.app' },
      { type: 'app', at: 1, pids: [700] },
      windows(2000, [overlay(10)]),
      windows(3000, [panel(12), shield]),
      { type: 'pasteboard', at: 4000, changeCount: 2, types: ['public.utf8-plain-text'] },
      windows(5000, []),
      windows(7000, [overlay(20)]),
      windows(8000, [panel(21), shield]),
      windows(9000, []),
      { type: 'frontmost', at: 10100, bundleId: 'com.apple.Preview', pid: 600 },
      windows(11000, [overlay(30)]),
      windows(12000, [panel(31), shield]),
      windows(13000, []),
      { type: 'app', at: 14100, pids: [] },
      { type: 'app', at: 15000, pids: [800] },
      windows(16000, [overlay(40, 800)]),
      windows(17000, [panel(41, 800)]),
      windows(18000, []),
    ],
    probe: {
      droppedEntries: 0,
      entries: [
        entry(0, 'recording-start'),
        // The shortcut's modifiers, the accepted limitation.
        entry(1900, 'keydown', { key: 'Control' }),
        entry(1950, 'keydown', { key: 'Shift' }),
        entry(2100, 'keyup', { key: 'Control' }),
        entry(2500, 'pointermove', { buttons: 0 }),
        entry(10150, 'blur', {}, { ...focused, hasFocus: false }),
      ],
    },
  };
}

test('a snip keeps its conversation, even when the overlay and panel swap in one list or after a pause', () => {
  const tracker = new SessionTracker([display]);
  tracker.update(0, [overlay(10)]);
  tracker.update(100, [panel(12), shield]);
  tracker.update(200, [panel(12), shield, panel(13)]);
  tracker.update(300, [shield]);
  assert.deepEqual(tracker.flush(300 + SESSION_GAP_MS - 1), []);
  const [ended] = tracker.flush(300 + SESSION_GAP_MS);
  assert.equal(ended.outcome, 'closed');
  assert.deepEqual([ended.start, ended.overlayEnd, ended.conversationAt, ended.end], [0, 100, 100, 300]);
  assert.deepEqual([...ended.windows], [10, 12, 13]);

  tracker.update(1000, [overlay(20)]);
  tracker.update(1100, []);
  tracker.update(1300, [panel(21)]);
  assert.deepEqual(tracker.flush(5000), []);
  tracker.update(6000, []);
  assert.equal(tracker.flush(7000)[0].conversationAt, 1300);
  assert.equal(tracker.sessions.length, 2);
  assert.deepEqual(tracker.notices, []);
});

test('a cancelled selection ends without a conversation, and a panel without a snip is a notice', () => {
  const tracker = new SessionTracker([display]);
  tracker.update(0, [overlay(10)]);
  tracker.update(400, []);
  assert.equal(tracker.flush(400 + SESSION_GAP_MS)[0].outcome, 'cancelled');
  tracker.update(2000, [{ ...panel(50), width: 330, height: 90 }]);
  assert.deepEqual(tracker.notices, [{ at: 2000, width: 330, height: 90 }]);
  assert.equal(tracker.sessions.length, 1);
});

test('a second snip while a conversation stays open is its own snip', () => {
  const tracker = new SessionTracker([display]);
  tracker.update(0, [overlay(10)]);
  tracker.update(100, [panel(12)]);
  tracker.update(1000, [panel(12), overlay(20)]);
  tracker.update(1100, [panel(12), panel(22)]);
  tracker.update(2000, [panel(22)]);
  tracker.update(3000, []);
  tracker.flush(Infinity);
  assert.deepEqual(tracker.sessions.map(session => [session.start, session.end, [...session.windows]]),
    [[0, 2000, [10, 12]], [1000, 3000, [20, 22]]]);
});

test('page checks accept modifier keys but not other keys, focus loss, hiding, text or clicks', () => {
  const session = { start: 2000, end: 5000 };
  const clean = analyzePage(round().probe.entries, session);
  assert.deepEqual([clean.startValid, clean.startInField, clean.focusKept, clean.visible, clean.inputIsolated],
    [true, true, true, true, true]);
  assert.deepEqual([clean.findings.modifierKeys, clean.findings.hover], [3, 1]);

  const cases = [
    [entry(1980, 'keydown', { key: '[redacted]' }), 'shortcut key', 'inputIsolated'],
    [entry(3000, 'keydown', { key: 'Enter' }), 'key', 'inputIsolated'],
    [entry(3000, 'beforeinput'), 'text', 'inputIsolated'],
    [entry(3000, 'pointerdown', { buttons: 1 }), 'pointer', 'inputIsolated'],
    [entry(3000, 'wheel', { buttons: 0 }), 'pointer', 'inputIsolated'],
    [entry(3000, 'blur', {}, { ...focused, hasFocus: false }), 'focus', 'focusKept'],
    [entry(3000, 'sample-state-change', {}, { ...focused, activeElement: { kind: 'element', tag: 'body', fixtureId: null, hasId: false } }),
      'focus', 'focusKept'],
    [entry(3000, 'visibilitychange', {}, { ...focused, visibilityState: 'hidden', hidden: true }), 'visibility', 'visible'],
  ];
  for (const [added, what, verdict] of cases) {
    const result = analyzePage([...round().probe.entries, added].sort((a, b) => a.epochMs - b.epochMs), session);
    assert.equal(result[verdict], false, what);
    assert.equal(result.failures[0].what, what);
  }
  const unfocused = analyzePage([entry(1000, 'blur', {}, { ...focused, hasFocus: false })], session);
  assert.equal(unfocused.startValid, false);
});

test('a clean round passes every check and summarizes each step', () => {
  const report = round();
  const analysis = analyzeRound(report);
  assert.deepEqual(analysis.checks.filter(check => !check.pass), []);
  assert.equal(analysis.passed, true);
  assert.deepEqual(analysis.sessions.map(session => [session.phase, session.outcome, session.over.bundleId, Boolean(session.page)]), [
    ['normal', 'closed', 'com.google.Chrome', true],
    ['fullscreen', 'closed', 'com.google.Chrome', true],
    ['preview', 'closed', 'com.apple.Preview', false],
    ['rebuilt', 'closed', 'com.apple.Preview', false],
  ]);
  assert.equal(analysis.modifierKeys, 3);
  const summary = formatSummary(analysis, report);
  assert.match(summary, /^# SnapScreen acceptance round/);
  assert.match(summary, /1728×1117 at 2×/);
  assert.match(summary, /\| 1–2 \| .+ \| test Chrome \| 1\.0 s \| pass \| pass \| pass \| pass \| closed after 3 s \|/);
  assert.doesNotMatch(summary, /FAIL/);
});

test('the round fails when SnapScreen comes forward, a prompt appears, or the rebuild keeps its signature', () => {
  let changed = round();
  const failing = name => analyzeRound(changed).checks.find(check => check.name === name).pass;
  changed.observer.push({ type: 'frontmost', at: 16500, bundleId: 'com.snapscreen.app', pid: 800 });
  changed.observer.sort((a, b) => a.at - b.at);
  assert.equal(failing('SnapScreen never became the frontmost app'), false);
  assert.equal(failing('The app beneath stayed frontmost'), false);

  changed = round();
  changed.observer.push({ type: 'prompts', at: 15500, owners: { SecurityAgent: 1 } });
  changed.observer.sort((a, b) => a.at - b.at);
  assert.equal(failing('No Keychain password prompt appeared'), false);
  assert.equal(failing('After the rebuild, Screen Recording and the Keychain worked without a prompt'), false);

  // Granting Screen Recording for the first time, before the rebuild, is only reported.
  changed = round();
  changed.observer.push({ type: 'prompts', at: 1500, owners: { 'System Settings': 1 } }, { type: 'prompts', at: 1800, owners: {} },
    { type: 'windows', at: 1600, windows: [{ ...panel(60), width: 330, height: 90 }] }, { type: 'windows', at: 1700, windows: [] });
  changed.observer.sort((a, b) => a.at - b.at);
  assert.deepEqual(analyzeRound(changed).checks.filter(check => !check.pass), []);
  assert.match(formatSummary(analyzeRound(changed), changed), /Notice at .+, with no snip\.\nWindow from System Settings at /);

  changed = round();
  changed.observer.push({ type: 'windows', at: 15500, windows: [{ ...panel(60, 800), width: 330, height: 90 }] },
    { type: 'windows', at: 15600, windows: [] });
  changed.observer.sort((a, b) => a.at - b.at);
  assert.equal(failing('After the rebuild, Screen Recording and the Keychain worked without a prompt'), false);

  changed = round();
  changed.builds[1].cdhash = changed.builds[0].cdhash;
  assert.equal(failing('The rebuild changed the signature and kept its requirement'), false);

  changed = round();
  changed.observer = changed.observer.filter(event => event.type !== 'pasteboard');
  assert.equal(failing('A code block was copied'), false);

  changed = round();
  changed.probe.entries = changed.probe.entries.filter(item => item.type !== 'blur');
  assert.equal(failing('The probe saw Chrome lose focus when Preview opened'), false);

  // macOS's screen capture alert as the first snip starts: reported, and left out of the page checks.
  changed = round();
  changed.observer.push({ type: 'frontmost', at: 1980, bundleId: 'com.apple.UserNotificationCenter', pid: 900 },
    { type: 'prompts', at: 1985, owners: { UserNotificationCenter: 1 } },
    { type: 'frontmost', at: 2600, bundleId: 'com.google.Chrome', pid: 500 }, { type: 'prompts', at: 2605, owners: {} });
  changed.observer.sort((a, b) => a.at - b.at);
  changed.probe.entries.push(entry(1990, 'blur', {}, { ...focused, hasFocus: false }), entry(2603, 'focus'));
  changed.probe.entries.sort((a, b) => a.epochMs - b.epochMs);
  const alerted = analyzeRound(changed);
  assert.deepEqual(alerted.checks.filter(check => !check.pass).map(check => [check.name, check.detail]),
    [['No macOS alert took focus during a snip', 'com.apple.UserNotificationCenter for 0.6 s in step 1–2']]);
  assert.deepEqual([alerted.sessions[0].over.testChrome, alerted.sessions[0].frontmostKept, alerted.sessions[0].page.focusKept],
    [true, true, true]);
  assert.match(formatSummary(alerted, changed), /a macOS alert \(com\.apple\.UserNotificationCenter\) had focus for 0\.6 s/);

  changed = round();
  changed.observer.push({ type: 'frontmost', at: 3500, bundleId: 'com.apple.finder', pid: 950 },
    { type: 'frontmost', at: 3600, bundleId: 'com.google.Chrome', pid: 500 });
  changed.observer.sort((a, b) => a.at - b.at);
  assert.equal(failing('The app beneath stayed frontmost'), false);
  assert.deepEqual(analyzeRound(changed).sessions[0].frontmostChanges, [{ at: 3500, bundleId: 'com.apple.finder' }]);

  changed = round();
  changed.observer.splice(-4, 3);
  assert.equal(failing('Every step has a finished snip'), false);
  assert.equal(trackSessions(changed.observer).sessions.length, 3);
});
