// Groups a saved Phase 1 session report by native capture session (real invocation through
// close, cancellation, or expiry) and reports the page signals that fail the focus, visibility,
// and input-isolation requirements. Prints metadata only. With --evidence it also writes a
// metadata-only extract of each session for the results directory.
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { basename } from 'node:path';

const ACTIVATION_KEYS = new Set(['Alt', 'Shift', 'Meta', 'Control']);
const ACTIVATION_WINDOW_MS = 1500;
const focusTypes = new Set(['focus', 'blur', 'focusin', 'focusout']);
const keyTypes = new Set(['keydown', 'keyup']);
const textTypes = new Set(['beforeinput', 'input', 'compositionstart', 'compositionupdate', 'compositionend',
  'copy', 'cut', 'paste', 'select', 'selectionchange']);
const pointerTypes = new Set(['pointerdown', 'pointerup', 'pointermove', 'pointercancel', 'pointerover',
  'pointerout', 'click', 'dblclick', 'contextmenu', 'wheel']);
const discretePointerTypes = new Set(['pointerdown', 'pointerup', 'pointercancel', 'click', 'dblclick', 'contextmenu', 'wheel']);
const endEvents = new Set(['native_closed', 'native_cancelled', 'session_expired', 'source_changed', 'new_invocation',
  'baseline_finished', 'diagnostic_reset', 'diagnostic_shutdown', 'capture_failed', 'capture_too_large', 'no_source_tab']);
// Repetitive records omitted from the evidence extract; their counts remain in nativeCounts.
const repetitiveNative = /(^|\.)(pointer_move|pointer_drag|delta)$/;

const time = epochMs => new Date(epochMs).toISOString().slice(11, 23);
const cell = value => String(value).replace(/[\n\r|]/gu, ' ').slice(0, 400);
const validStart = state => state?.hasFocus === true && state.visibilityState === 'visible'
  && state.activeElement?.fixtureId === 'page-input';

function nativeAt(entry) {
  return entry.event === 'native_telemetry' && Number.isFinite(entry.nativeAt) ? entry.nativeAt : entry.at;
}

function findSessions(logs) {
  const sessions = [];
  let current = null;
  for (const entry of logs) {
    if (entry.event === 'invocation') {
      if (current && current.endAt === null) Object.assign(current, { endAt: entry.at, end: 'superseded' });
      current = { kind: entry.kind, invocationAt: entry.at, sessionId: null, endAt: null, end: null, hostPid: null, cold: false };
      sessions.push(current);
    } else if (current && current.endAt === null) {
      if (entry.event === 'host_connect') current.cold = true;
      if (entry.event === 'host_ready') current.hostPid = entry.pid;
      if (entry.event === 'capture_started') current.sessionId = entry.sessionId;
      if (endEvents.has(entry.event) && (!entry.sessionId || entry.sessionId === current.sessionId)) {
        Object.assign(current, { endAt: entry.at, end: entry.event });
      } else if (['host_disconnected', 'host_unavailable', 'host_shutdown', 'invalid_native_message',
        'handshake_timeout', 'answer_delivery_failed'].includes(entry.event)) {
        Object.assign(current, { endAt: entry.at, end: entry.event });
      }
    }
  }
  for (const session of sessions) if (session.endAt === null) Object.assign(session, { endAt: logs.at(-1)?.at ?? session.invocationAt, end: 'open' });
  return sessions;
}

function analyze(session, entries, logs) {
  const lookback = entries.filter(entry => entry.epochMs >= session.invocationAt - ACTIVATION_WINDOW_MS && entry.epochMs < session.invocationAt);
  const during = entries.filter(entry => entry.epochMs >= session.invocationAt && entry.epochMs <= session.endAt);
  const before = entries.filter(entry => entry.epochMs < session.invocationAt).at(-1);
  const activation = [];
  const findings = { focusEvents: [], focusStates: [], visibility: [], keys: [], text: [], pressed: [], discrete: [], hover: 0, mutations: 0, viewport: 0 };
  for (const entry of lookback) {
    if (keyTypes.has(entry.type) && ACTIVATION_KEYS.has(entry.detail?.key)) activation.push(entry);
  }
  // Focus is judged against the state at invocation; an invalid start is reported separately.
  const startFocus = JSON.stringify([before?.state?.hasFocus, before?.state?.activeElement]);
  for (const entry of during) {
    const { type, detail, state } = entry;
    if (keyTypes.has(type) && ACTIVATION_KEYS.has(detail?.key) && entry.epochMs - session.invocationAt <= ACTIVATION_WINDOW_MS) {
      activation.push(entry);
      continue;
    }
    if (focusTypes.has(type)) findings.focusEvents.push(entry);
    if (type === 'visibilitychange' || state?.hidden === true || state?.visibilityState === 'hidden') findings.visibility.push(entry);
    if (state && (state.hasFocus !== true || JSON.stringify([state.hasFocus, state.activeElement]) !== startFocus)) findings.focusStates.push(entry);
    if (keyTypes.has(type)) findings.keys.push(entry);
    if (textTypes.has(type)) findings.text.push(entry);
    if (pointerTypes.has(type)) {
      if ((detail?.buttons ?? 0) > 0) findings.pressed.push(entry);
      else if (discretePointerTypes.has(type)) findings.discrete.push(entry);
      else findings.hover += 1;
    }
    if (type === 'dom-mutation') findings.mutations += detail?.count ?? 1;
    if (['resize', 'scroll', 'visual-viewport-resize', 'visual-viewport-scroll'].includes(type)) findings.viewport += 1;
  }
  const native = logs.filter(entry => nativeAt(entry) >= session.invocationAt && nativeAt(entry) <= session.endAt);
  const nativeCounts = {};
  const inputSources = new Set();
  for (const entry of native) {
    if (entry.event !== 'native_telemetry') continue;
    nativeCounts[entry.nativeEvent] = (nativeCounts[entry.nativeEvent] ?? 0) + 1;
    if (entry.inputSource) inputSources.add(entry.inputSource);
  }
  const after = entries.find(entry => entry.epochMs > session.endAt
    && (focusTypes.has(entry.type) || entry.type === 'visibilitychange' || entry.state?.hasFocus === false));
  const routeKeys = activation.filter(entry => entry.type === 'keydown').map(entry => entry.detail.key);
  return {
    startState: before?.state ?? null,
    startValid: validStart(before?.state),
    route: session.kind === 'baseline' ? 'capture-only shortcut' : routeKeys.length ? `shortcut (${[...new Set(routeKeys)].join('+')})` : 'toolbar or menu',
    activationEvents: activation.map(entry => `${entry.type}:${entry.detail.key}`),
    focusPass: findings.focusEvents.length === 0 && findings.focusStates.length === 0,
    visibilityPass: findings.visibility.length === 0,
    inputPass: !findings.keys.length && !findings.text.length && !findings.pressed.length && !findings.discrete.length,
    domPass: findings.mutations === 0,
    findings,
    nativeCounts,
    inputSources: [...inputSources],
    firstTransitionAfterEnd: after ? { type: after.type, afterMs: Math.round(after.epochMs - session.endAt) } : null,
    lookback,
    during,
    native,
  };
}

function describe(entries) {
  const counts = {};
  for (const entry of entries) {
    const label = entry.type + ((entry.detail?.buttons ?? 0) > 0 ? '[pressed]' : '');
    counts[label] = (counts[label] ?? 0) + 1;
  }
  const range = entries.length ? ` ${time(entries[0].epochMs)}–${time(entries.at(-1).epochMs)}` : '';
  return `${Object.entries(counts).map(([type, count]) => `${type}×${count}`).join(', ')}${range}`;
}

const interesting = /(\.modifier_[a-z_]+|\.shield_raised|^shield\.lowered|\.(shown|confirmed|cancelled|closed|closed_with_parent|complete|copied|text_selected|pressed_pointer_left|pressed_pointer_returned|pressed_pointer_released_outside|resize_drag_start|resize_drag_end|resize_drag_cancelled|resize_keyboard|keyboard_move|keyboard_resize|drag_start|drag_end|submitted|rejected|paste_matches_copy|paste_differs_from_copy|paste_without_copy|select_all|composition_update|composition_committed|edit_begin|scroll_changed|moved|resized|live_resize_begin|live_resize_end))$/;

async function main() {
  const args = process.argv.slice(2);
  const evidenceIndex = args.indexOf('--evidence');
  const evidencePath = evidenceIndex >= 0 ? args[evidenceIndex + 1] : null;
  const methodIndex = args.indexOf('--method');
  const method = methodIndex >= 0 ? args[methodIndex + 1] : null;
  const optionValues = new Set([evidenceIndex, methodIndex].filter(index => index >= 0).map(index => index + 1));
  const paths = args.filter((value, index) => !value.startsWith('--') && !optionValues.has(index));
  if (paths.length !== 1) {
    console.error('Usage: node experiments/native-phase1/fixture/sessions.mjs <report.json> [--evidence out.json --method "how actions were performed"]');
    process.exitCode = 1;
    return;
  }
  const raw = await readFile(paths[0]);
  const report = JSON.parse(raw);
  const entries = report.probe?.entries ?? [];
  const logs = report.extension?.logs ?? [];
  const warnings = [];
  if (report.environment?.focusEmulation !== false) warnings.push('focus emulation not recorded as disabled: focus results invalid');
  if (report.probe?.droppedEntries) warnings.push(`${report.probe.droppedEntries} page entries dropped`);
  if (report.extension?.droppedEntries) warnings.push(`${report.extension.droppedEntries} extension entries dropped`);
  const sessions = findSessions(logs).map(session => ({ ...session, ...analyze(session, entries, logs) }));

  console.log(`\n### ${cell(basename(paths[0]))}\n`);
  const environment = report.environment ?? {};
  console.log(`macOS ${environment.macOS} (${environment.macOSBuild}); Chrome ${environment.browserVersion}; host ${environment.artifacts?.nativeHostSha256?.slice(0, 12)}; ${entries.length} page and ${logs.length} extension entries.`);
  for (const warning of warnings) console.log(`- WARNING: ${warning}`);
  console.log('\n| # | Invoked (UTC) | Route | Host | Start valid | Focus | Visibility | Input isolation | DOM | Ended |');
  console.log('| ---: | --- | --- | --- | --- | --- | --- | --- | --- | --- |');
  sessions.forEach((session, index) => {
    const verdict = pass => (pass ? 'pass' : '**FAIL**');
    console.log(`| ${index + 1} | ${time(session.invocationAt)} | ${session.route} | ${session.kind === 'baseline' ? '—' : `${session.cold ? 'cold' : 'warm'}${session.hostPid ? ` PID ${session.hostPid}` : ''}`} | ${session.startValid ? 'yes' : '**no**'} | ${verdict(session.focusPass)} | ${verdict(session.visibilityPass)} | ${verdict(session.inputPass)} | ${verdict(session.domPass)} | ${session.end} after ${((session.endAt - session.invocationAt) / 1000).toFixed(1)} s |`);
  });
  sessions.forEach((session, index) => {
    const f = session.findings;
    console.log(`\n**Session ${index + 1}** (${time(session.invocationAt)}–${time(session.endAt)})`);
    console.log(`- Activation signals: ${session.activationEvents.join(', ') || 'none'}`);
    if (f.focusEvents.length || f.focusStates.length) console.log(`- Focus: ${describe(f.focusEvents) || 'state change only'}; first non-focused state ${f.focusStates[0] ? time(f.focusStates[0].epochMs) : 'n/a'}`);
    if (f.visibility.length) console.log(`- Visibility: ${describe(f.visibility)}`);
    if (f.keys.length) console.log(`- Page keys: ${describe(f.keys)} (${f.keys.map(entry => `${entry.type}:${entry.detail?.key}`).slice(0, 12).join(', ')})`);
    if (f.text.length) console.log(`- Page text/clipboard/composition: ${describe(f.text)}`);
    if (f.pressed.length) console.log(`- Pressed-button page pointer events: ${describe(f.pressed)}`);
    if (f.discrete.length) console.log(`- Page clicks/wheel/down/up: ${describe(f.discrete)}`);
    console.log(`- Unpressed page hover/motion: ${f.hover}; DOM records: ${f.mutations}; viewport events: ${f.viewport}`);
    const native = Object.entries(session.nativeCounts).filter(([event]) => interesting.test(event))
      .map(([event, count]) => `${event}×${count}`).join(', ');
    console.log(`- Native: ${native || 'none'}`);
    if (session.inputSources.length) console.log(`- Input sources: ${session.inputSources.join(', ')}`);
    if (session.firstTransitionAfterEnd) console.log(`- First page focus/visibility transition after end: ${session.firstTransitionAfterEnd.type} +${session.firstTransitionAfterEnd.afterMs} ms`);
  });
  const outside = entries.filter(entry => (focusTypes.has(entry.type) || entry.type === 'visibilitychange' || entry.type === 'mark')
    && !sessions.some(session => entry.epochMs >= session.invocationAt && entry.epochMs <= session.endAt));
  console.log(`\nOutside sessions (controls and returning to other apps): ${outside.map(entry => `${time(entry.epochMs)} ${entry.type}${entry.type === 'mark' ? `:${entry.detail.label}` : ''}${entry.state?.hidden ? '(hidden)' : ''}`).join('; ') || 'none'}`);

  if (evidencePath) {
    const keep = entry => entry.event !== 'answer_chunk'
      && !(entry.event === 'native_telemetry' && repetitiveNative.test(entry.nativeEvent));
    const evidence = {
      schemaVersion: 1,
      kind: 'phase1-session-evidence',
      method,
      environment: report.environment,
      observedEnvironment: report.probe?.environment,
      trial: report.trial ?? null,
      sourceReport: {
        name: basename(paths[0]),
        sha256: createHash('sha256').update(raw).digest('hex'),
        pageEntries: entries.length,
        extensionEntries: logs.length,
        droppedPageEntries: report.probe?.droppedEntries ?? null,
        droppedExtensionEntries: report.extension?.droppedEntries ?? null,
      },
      extraction: `Per native session: every page entry from ${ACTIVATION_WINDOW_MS} ms before invocation through session end, and every extension/native record in the session except answer chunks and repetitive native pointer-move/drag and answer-delta records (counted in nativeCounts). Page focus/visibility/mark entries outside sessions are in outsideSessions.`,
      sessions: sessions.map(session => ({
        kind: session.kind,
        sessionId: session.sessionId,
        invocationAt: session.invocationAt,
        endAt: session.endAt,
        end: session.end,
        cold: session.cold,
        hostPid: session.hostPid,
        route: session.route,
        startValid: session.startValid,
        startState: session.startState,
        verdicts: { focus: session.focusPass, visibility: session.visibilityPass, inputIsolation: session.inputPass, dom: session.domPass },
        activationEvents: session.activationEvents,
        pressedPointerEvents: session.findings.pressed.length,
        unpressedHoverEvents: session.findings.hover,
        nativeCounts: session.nativeCounts,
        inputSources: session.inputSources,
        firstTransitionAfterEnd: session.firstTransitionAfterEnd,
        pageEvents: [...session.lookback, ...session.during],
        extensionEvents: session.native.filter(keep),
      })),
      outsideSessions: outside,
      chromeFocusTimeline: logs.filter(entry => entry.event === 'chrome_window_focus'),
    };
    await writeFile(evidencePath, `${JSON.stringify(evidence, null, 1)}\n`);
    console.log(`\nEvidence written: ${evidencePath}`);
  }
}

await main();
