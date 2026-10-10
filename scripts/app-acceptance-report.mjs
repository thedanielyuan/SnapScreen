// Analyzes a round of the standalone app's acceptance (scripts/app-acceptance.mjs). It finds each
// snip in the observer's window log, then checks Chrome's page, the frontmost app, prompts, the
// pasteboard and the rebuild. Reports hold metadata only: the page probe redacts printable keys,
// and the observer records no window titles or pasteboard contents.
// `node scripts/app-acceptance-report.mjs <report.json>` summarizes a saved round again.
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

// Window levels as CGWindowList reports them: the overlay's .screenSaver and the panels' .floating.
export const OVERLAY_LAYER = 1000;
export const PANEL_LAYER = 3;
// The overlay closes before the conversation opens, so a snip ends only after its windows have
// been gone this long.
export const SESSION_GAP_MS = 500;
// How long before the overlay appears the shortcut's key events can reach the page.
export const SHORTCUT_LOOKBACK_MS = 1500;
// macOS's own alerts take focus by themselves, such as replayd's periodic check on an app that
// captures the screen without the system picker, so they're reported apart from SnapScreen's
// behavior. Page events this close to an alert belong to it.
export const SYSTEM_ALERTS = new Set(['com.apple.UserNotificationCenter', 'com.apple.SecurityAgent',
  'com.apple.coreservices.uiagent', 'com.apple.universalAccessAuthWarn']);
const ALERT_MARGIN_MS = 100;

export const PHASES = [
  { name: 'normal', steps: '1–2', setting: 'Chrome, normal window' },
  { name: 'fullscreen', steps: '3', setting: 'Chrome, fullscreen' },
  { name: 'preview', steps: '4', setting: 'a PDF in Preview' },
  { name: 'rebuilt', steps: '5', setting: 'after the rebuild' },
];

const MODIFIER_KEYS = new Set(['Alt', 'Control', 'Meta', 'Shift']);
const FOCUS_TYPES = new Set(['focus', 'blur', 'focusin', 'focusout']);
const KEY_TYPES = new Set(['keydown', 'keyup']);
const TEXT_TYPES = new Set(['beforeinput', 'input', 'compositionstart', 'compositionupdate', 'compositionend',
  'copy', 'cut', 'paste', 'select', 'selectionchange']);
const POINTER_TYPES = new Set(['pointerdown', 'pointerup', 'pointermove', 'pointercancel', 'pointerover',
  'pointerout', 'click', 'dblclick', 'contextmenu', 'wheel']);
const DISCRETE_POINTER_TYPES = new Set(['pointerdown', 'pointerup', 'pointercancel', 'click', 'dblclick',
  'contextmenu', 'wheel']);

function covers(window, display) {
  return Math.abs(window.x - display.x) <= 1 && Math.abs(window.y - display.y) <= 1
    && Math.abs(window.width - display.width) <= 1 && Math.abs(window.height - display.height) <= 1;
}

/**
 * Follows snips through the observer's lists of SnapScreen's windows. A snip starts when an
 * overlay covers a display, keeps the panels that open after its overlay closes (the
 * conversation and preview), and ends once all of them have been gone for SESSION_GAP_MS. A
 * panel that opens with no snip to belong to is a notice.
 */
export class SessionTracker {
  constructor(displays) {
    this.displays = displays;
    this.sessions = [];
    this.notices = [];
    this.owners = new Map();
  }

  update(at, windows) {
    const classified = [];
    for (const window of windows) {
      const display = this.displays.find(candidate => covers(window, candidate));
      if (window.layer >= OVERLAY_LAYER && display) classified.push({ window, display });
      // The pointer shield covers a display at the panels' level and belongs to no snip.
      else if (window.layer === PANEL_LAYER && !display) classified.push({ window, display: null });
    }
    const visible = new Set(classified.map(({ window }) => window.id));
    // Close overlays first, so a conversation that replaced its overlay in this list joins its snip.
    for (const session of this.sessions) {
      if (session.outcome === null && session.overlayEnd === null && !visible.has(session.overlay)) session.overlayEnd = at;
    }
    for (const { window, display } of classified) {
      if (this.owners.has(window.id)) continue;
      if (display) {
        const session = { start: at, display: display.id, overlay: window.id, overlayEnd: null,
          conversationAt: null, end: null, outcome: null, windows: new Set([window.id]), goneAt: null };
        this.sessions.push(session);
        this.owners.set(window.id, session);
        continue;
      }
      const owner = this.sessions.findLast(session => session.outcome === null);
      if (owner && owner.overlayEnd !== null) {
        owner.windows.add(window.id);
        owner.conversationAt ??= at;
        this.owners.set(window.id, owner);
      } else {
        this.notices.push({ at, width: window.width, height: window.height });
        this.owners.set(window.id, null);
      }
    }
    for (const session of this.sessions) {
      if (session.outcome !== null) continue;
      if ([...session.windows].some(id => visible.has(id))) session.goneAt = null;
      else session.goneAt ??= at;
    }
  }

  /** Ends the snips whose windows have been gone long enough, and returns them. */
  flush(at) {
    const ended = [];
    for (const session of this.sessions) {
      if (session.outcome !== null || session.goneAt === null || at - session.goneAt < SESSION_GAP_MS) continue;
      session.end = session.goneAt;
      session.outcome = session.conversationAt === null ? 'cancelled' : 'closed';
      ended.push(session);
    }
    return ended;
  }
}

/** Replays an observer log into snips and notices. */
export function trackSessions(observer) {
  const ready = observer.find(event => event.type === 'ready');
  const tracker = new SessionTracker(ready?.displays ?? []);
  for (const event of observer) {
    tracker.flush(event.at);
    if (event.type === 'windows') tracker.update(event.at, event.windows);
  }
  tracker.flush(Infinity);
  return tracker;
}

const plural = (count, noun) => `${count} ${noun}${count === 1 ? '' : 's'}`;

function phaseAt(phases, at) {
  return phases.findLast(phase => phase.at <= at)?.name ?? null;
}

function frontmostTimeline(observer) {
  const timeline = [];
  for (const event of observer) {
    if (event.type === 'ready' && event.frontmost?.pid) timeline.push({ at: event.at, ...event.frontmost });
    if (event.type === 'frontmost' && event.pid) timeline.push({ at: event.at, bundleId: event.bundleId, pid: event.pid });
  }
  return timeline;
}

/** When each system alert was frontmost, until the next app came forward. */
function alertTimes(timeline) {
  return timeline.flatMap((entry, index) => (SYSTEM_ALERTS.has(entry.bundleId)
    ? [{ from: entry.at, to: timeline[index + 1]?.at ?? Infinity, bundleId: entry.bundleId }] : []));
}

/**
 * What reached Chrome's page from SHORTCUT_LOOKBACK_MS before a snip through its end, leaving out
 * the times when a system alert had focus.
 */
export function analyzePage(entries, session, alerts = []) {
  const end = session.end ?? Infinity;
  const duringAlert = entry => alerts.some(alert => entry.epochMs >= alert.from - ALERT_MARGIN_MS
    && entry.epochMs <= alert.to + ALERT_MARGIN_MS);
  const startState = entries.findLast(entry => entry.epochMs < session.start && !duringAlert(entry))?.state ?? null;
  const startFocus = JSON.stringify([startState?.hasFocus, startState?.activeElement]);
  const findings = { focus: 0, visibility: 0, keys: 0, modifierKeys: 0, text: 0, pointer: 0, hover: 0,
    mutations: 0, viewport: 0 };
  const failures = [];
  const flag = (entry, what) => {
    if (failures.length < 20) failures.push({ at: entry.epochMs, type: entry.type, what, key: entry.detail?.key ?? null });
  };
  for (const entry of entries) {
    if (entry.epochMs < session.start - SHORTCUT_LOOKBACK_MS || entry.epochMs > end || duringAlert(entry)) continue;
    const { type, detail, state } = entry;
    const during = entry.epochMs >= session.start;
    // Modifier keys reaching the page are the accepted known limitation, before and during a snip.
    if (KEY_TYPES.has(type)) {
      if (MODIFIER_KEYS.has(detail?.key)) findings.modifierKeys += 1;
      else {
        findings.keys += 1;
        flag(entry, during ? 'key' : 'shortcut key');
      }
      continue;
    }
    if (!during) continue;
    if (FOCUS_TYPES.has(type) || (state && JSON.stringify([state.hasFocus, state.activeElement]) !== startFocus)) {
      findings.focus += 1;
      flag(entry, 'focus');
    }
    if (type === 'visibilitychange' || state?.visibilityState === 'hidden' || state?.hidden === true) {
      findings.visibility += 1;
      flag(entry, 'visibility');
    }
    if (TEXT_TYPES.has(type)) {
      findings.text += 1;
      flag(entry, 'text');
    }
    if (POINTER_TYPES.has(type)) {
      if ((detail?.buttons ?? 0) > 0 || DISCRETE_POINTER_TYPES.has(type)) {
        findings.pointer += 1;
        flag(entry, 'pointer');
      } else findings.hover += 1;
    }
    if (type === 'dom-mutation') findings.mutations += detail?.count ?? 1;
    if (['resize', 'scroll', 'visual-viewport-resize', 'visual-viewport-scroll'].includes(type)) findings.viewport += 1;
  }
  return {
    startState,
    startValid: startState?.hasFocus === true && startState.visibilityState === 'visible',
    startInField: startState?.activeElement?.fixtureId === 'page-input',
    focusKept: findings.focus === 0,
    visible: findings.visibility === 0,
    inputIsolated: findings.keys === 0 && findings.text === 0 && findings.pointer === 0,
    findings,
    failures,
  };
}

/** Per-snip results and the round's checks for a saved report. */
export function analyzeRound(report) {
  const observer = report.observer ?? [];
  const entries = report.probe?.entries ?? [];
  const phases = report.phases ?? [];
  const watched = observer.find(event => event.type === 'ready')?.watched ?? 'com.snapscreen.app';
  const chromePid = report.environment?.chromePid ?? null;
  const roundStart = phases[0]?.at ?? 0;
  const tracker = trackSessions(observer);
  const timeline = frontmostTimeline(observer);
  const allAlerts = alertTimes(timeline);
  const sessions = tracker.sessions.map((session, index) => {
    const end = session.end ?? Infinity;
    const atStart = timeline.findLast(entry => entry.at <= session.start && !SYSTEM_ALERTS.has(entry.bundleId)) ?? null;
    // Another app coming forward, but not an alert or the return from one.
    const changes = timeline.filter(entry => entry.at > session.start && entry.at <= end
      && !SYSTEM_ALERTS.has(entry.bundleId) && entry.pid !== atStart?.pid);
    const alerts = allAlerts.filter(alert => alert.from <= end && alert.to >= session.start - SHORTCUT_LOOKBACK_MS);
    const overChrome = chromePid !== null && atStart?.pid === chromePid;
    return {
      index: index + 1,
      phase: phaseAt(phases, session.start),
      start: session.start,
      end: session.end,
      outcome: session.outcome ?? 'open',
      display: session.display,
      selectionMs: session.overlayEnd === null ? null : session.overlayEnd - session.start,
      over: atStart ? { bundleId: atStart.bundleId, testChrome: overChrome } : null,
      frontmostKept: changes.length === 0,
      frontmostChanges: changes.map(change => ({ at: change.at, bundleId: change.bundleId })),
      alerts: alerts.map(alert => ({ at: alert.from, bundleId: alert.bundleId, ms: alert.to - alert.from })),
      pasteboardChanges: observer.filter(event => event.type === 'pasteboard' && event.at >= session.start && event.at <= end).length,
      page: overChrome ? analyzePage(entries, session, alerts) : null,
    };
  });
  const answered = sessions.filter(session => session.outcome === 'closed');
  const prompts = observer.filter(event => event.type === 'prompts' && event.at >= roundStart && Object.keys(event.owners).length)
    .map(event => ({ at: event.at, owners: Object.keys(event.owners) }));
  const snapscreenFrontmost = timeline.filter(entry => entry.at >= roundStart && entry.bundleId === watched);
  const chromeSessions = answered.filter(session => session.page);
  const phaseSessions = name => answered.filter(session => session.phase === name);
  const [first, rebuilt] = report.builds ?? [];
  const previewAt = phases.find(phase => phase.name === 'preview')?.at;
  // Before the rebuild, a notice or System Settings can be the first Screen Recording request.
  const rebuiltAt = phases.find(phase => phase.name === 'rebuilt')?.at ?? Infinity;
  const afterRebuild = [...tracker.notices.filter(notice => notice.at >= rebuiltAt).map(() => 'a notice'),
    ...prompts.filter(prompt => prompt.at >= rebuiltAt).flatMap(prompt => prompt.owners)];
  const passwordPrompts = prompts.filter(prompt => prompt.owners.includes('SecurityAgent'));
  const check = (name, pass, detail) => ({ name, pass, detail });
  const checks = [
    check('Every step has a finished snip', PHASES.every(phase => phaseSessions(phase.name).length > 0),
      PHASES.map(phase => `step ${phase.steps}: ${phaseSessions(phase.name).length}`).join(', ')),
    check('Chrome snips started with the page focused and visible',
      chromeSessions.length > 0 && chromeSessions.every(session => session.page.startValid),
      `${chromeSessions.filter(session => session.page.startValid).length} of ${chromeSessions.length}`),
    check('The page kept focus', chromeSessions.length > 0 && chromeSessions.every(session => session.page.focusKept),
      `${chromeSessions.filter(session => session.page.focusKept).length} of ${chromeSessions.length} Chrome snips`),
    check('The page stayed visible', chromeSessions.length > 0 && chromeSessions.every(session => session.page.visible),
      `${chromeSessions.filter(session => session.page.visible).length} of ${chromeSessions.length} Chrome snips`),
    check('No keys, text or clicks reached the page',
      chromeSessions.length > 0 && chromeSessions.every(session => session.page.inputIsolated),
      `${chromeSessions.filter(session => session.page.inputIsolated).length} of ${chromeSessions.length} Chrome snips`),
    check('SnapScreen never became the frontmost app', snapscreenFrontmost.length === 0,
      snapscreenFrontmost.length ? plural(snapscreenFrontmost.length, 'time') : 'never'),
    check('The app beneath stayed frontmost', answered.length > 0 && answered.every(session => session.frontmostKept),
      `${answered.filter(session => session.frontmostKept).length} of ${answered.length} snips`),
    check('No macOS alert took focus during a snip', answered.every(session => session.alerts.length === 0),
      answered.flatMap(session => session.alerts.map(alert => `${alert.bundleId} for ${(alert.ms / 1000).toFixed(1)} s in step `
        + `${PHASES.find(phase => phase.name === session.phase)?.steps ?? '?'}`)).join(', ') || 'none'),
    check('A code block was copied', phaseSessions('normal').some(session => session.pasteboardChanges > 0),
      plural(phaseSessions('normal').reduce((total, session) => total + session.pasteboardChanges, 0), 'pasteboard change')
        + ' in steps 1–2'),
    check('The rebuild changed the signature and kept its requirement',
      Boolean(first && rebuilt && first.cdhash !== rebuilt.cdhash && first.team && first.team === rebuilt.team
        && first.certificateRequirement && rebuilt.certificateRequirement),
      first && rebuilt ? `${first.cdhash.slice(0, 10)} → ${rebuilt.cdhash.slice(0, 10)}, team ${rebuilt.team ?? 'none'}` : 'no rebuild'),
    check('After the rebuild, Screen Recording and the Keychain worked without a prompt',
      phaseSessions('rebuilt').length > 0 && afterRebuild.length === 0,
      afterRebuild.length ? afterRebuild.join(', ') : `${plural(phaseSessions('rebuilt').length, 'snip')}, no prompt or notice`),
    check('No Keychain password prompt appeared', passwordPrompts.length === 0, plural(passwordPrompts.length, 'prompt')),
    check('The probe saw Chrome lose focus when Preview opened',
      previewAt !== undefined && entries.some(entry => entry.epochMs >= previewAt && entry.state?.hasFocus === false),
      'a positive control: without it, the page results prove nothing'),
  ];
  return {
    sessions,
    notices: tracker.notices,
    prompts,
    cancelled: sessions.filter(session => session.outcome === 'cancelled').length,
    modifierKeys: chromeSessions.reduce((total, session) => total + session.page.findings.modifierKeys, 0),
    checks,
    passed: checks.every(entry => entry.pass),
  };
}

const clock = at => new Date(at).toLocaleTimeString('en-GB', { hour12: false });
const verdict = pass => (pass ? 'pass' : '**FAIL**');

/** The analysis as Markdown. */
export function formatSummary(analysis, report) {
  const environment = report.environment ?? {};
  const displays = (report.observer?.find(event => event.type === 'ready')?.displays ?? [])
    .map(display => `${display.width}×${display.height} at ${display.pixelWidth / display.width || 1}×`).join(', ');
  const lines = [
    `# SnapScreen acceptance round, ${new Date(report.startedAt ?? Date.now()).toLocaleString('en-GB')}`,
    '',
    `macOS ${environment.macOS} (${environment.macOSBuild}), ${environment.browser ?? 'browser unknown'}, displays ${displays || 'unknown'}.`,
    '',
    '| Step | Snip | Over | Selection | Frontmost kept | Page focus | Page visible | Input isolated | Ended |',
    '| --- | --- | --- | --- | --- | --- | --- | --- | --- |',
  ];
  for (const session of analysis.sessions) {
    const phase = PHASES.find(entry => entry.name === session.phase);
    const page = session.page;
    const pageCell = value => (page ? verdict(value) : '—');
    lines.push(`| ${phase?.steps ?? '—'} | ${clock(session.start)} | ${session.over?.testChrome ? 'test Chrome' : session.over?.bundleId ?? 'unknown'} | `
      + `${session.selectionMs === null ? 'open' : `${(session.selectionMs / 1000).toFixed(1)} s`} | ${verdict(session.frontmostKept)} | `
      + `${pageCell(page?.focusKept)} | ${pageCell(page?.visible)} | ${pageCell(page?.inputIsolated)} | `
      + `${session.outcome}${session.end ? ` after ${((session.end - session.start) / 1000).toFixed(0)} s` : ''} |`);
  }
  lines.push('', '| Check | Result | Detail |', '| --- | --- | --- |');
  for (const entry of analysis.checks) lines.push(`| ${entry.name} | ${verdict(entry.pass)} | ${entry.detail} |`);
  lines.push('');
  lines.push(`Accepted limitation: modifier keys reached the page ${plural(analysis.modifierKeys, 'time')}.`);
  if (analysis.cancelled) lines.push(`Cancelled selections, which don't count toward a step: ${analysis.cancelled}.`);
  for (const notice of analysis.notices) lines.push(`Notice at ${clock(notice.at)}, with no snip.`);
  for (const prompt of analysis.prompts) lines.push(`Window from ${prompt.owners.join(' and ')} at ${clock(prompt.at)}.`);
  for (const session of analysis.sessions) {
    if (!session.page?.failures.length && !session.frontmostChanges.length && !session.alerts.length) continue;
    lines.push('', `Snip ${session.index} at ${clock(session.start)}:`);
    if (session.page && !session.page.startValid) lines.push('- The page wasn\'t focused and visible when it started.');
    for (const failure of session.page?.failures ?? []) {
      lines.push(`- ${clock(failure.at)} ${failure.what}: ${failure.type}${failure.key ? ` (${failure.key})` : ''}`);
    }
    for (const change of session.frontmostChanges) lines.push(`- ${clock(change.at)} ${change.bundleId} became frontmost`);
    for (const alert of session.alerts) {
      lines.push(`- ${clock(alert.at)} a macOS alert (${alert.bundleId}) had focus for ${(alert.ms / 1000).toFixed(1)} s, `
        + 'which the page checks leave out');
    }
  }
  lines.push('', 'The report can\'t see answers, so confirm that each snip answered and the follow-up worked.');
  return `${lines.join('\n')}\n`;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const report = JSON.parse(await readFile(process.argv[2], 'utf8'));
  process.stdout.write(formatSummary(analyzeRound(report), report));
}
