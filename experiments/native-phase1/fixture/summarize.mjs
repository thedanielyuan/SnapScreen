import { readFile } from 'node:fs/promises';
import { basename } from 'node:path';

const focusEvents = new Set(['focus', 'blur', 'focusin', 'focusout']);
const inputEvents = new Set([
  'keydown', 'keyup', 'beforeinput', 'input', 'compositionstart', 'compositionupdate',
  'compositionend', 'copy', 'cut', 'paste', 'select', 'selectionchange',
]);
const pointerEvents = new Set([
  'pointerdown', 'pointerup', 'pointermove', 'pointercancel', 'pointerover', 'pointerout',
  'click', 'dblclick', 'contextmenu', 'wheel',
]);
const viewportEvents = new Set(['resize', 'scroll', 'visual-viewport-resize', 'visual-viewport-scroll']);

function cell(value) {
  return String(value).replace(/[\n\r|]/gu, ' ').replace(/`/gu, '').slice(0, 140);
}

function focusKey(state) {
  if (!state) return null;
  return JSON.stringify([state.hasFocus, state.activeElement]);
}

function visibilityKey(state) {
  if (!state) return null;
  return JSON.stringify([state.visibilityState, state.hidden]);
}

function isPressedPointer(entry) {
  return pointerEvents.has(entry.type)
    && typeof entry.detail?.buttons === 'number' && entry.detail.buttons > 0;
}

function summarizeGroup(group, previousState, extensionLogs) {
  const counts = {
    focusEvents: 0,
    focusStateChanges: 0,
    visibilityEvents: 0,
    visibilityStateChanges: 0,
    mutations: 0,
    mutationDetailsOmitted: 0,
    pageInputEvents: 0,
    pointerEvents: 0,
    pressedPointerEvents: 0,
    viewportEvents: 0,
    sampleChanges: 0,
  };
  let lastState = previousState;
  let focusLossObserved = false;
  let hiddenObserved = false;
  let iframeCountChanged = false;
  let missingState = false;
  let firstPressedEpochMs = null;
  let lastPressedEpochMs = null;
  for (const entry of group.entries) {
    if (focusEvents.has(entry.type)) counts.focusEvents += 1;
    if (inputEvents.has(entry.type)) counts.pageInputEvents += 1;
    if (pointerEvents.has(entry.type)) counts.pointerEvents += 1;
    if (isPressedPointer(entry)) {
      counts.pressedPointerEvents += 1;
      if (Number.isFinite(entry.epochMs)) {
        firstPressedEpochMs = Math.min(firstPressedEpochMs ?? entry.epochMs, entry.epochMs);
        lastPressedEpochMs = Math.max(lastPressedEpochMs ?? entry.epochMs, entry.epochMs);
      }
    }
    if (viewportEvents.has(entry.type)) counts.viewportEvents += 1;
    if (entry.type === 'visibilitychange') counts.visibilityEvents += 1;
    if (entry.type === 'sample-state-change') counts.sampleChanges += 1;
    if (entry.type === 'dom-mutation') {
      counts.mutations += entry.detail?.count ?? 1;
      counts.mutationDetailsOmitted += entry.detail?.omittedRecords ?? 0;
    }
    if (!entry.state) {
      missingState = true;
      continue;
    }
    if (lastState) {
      if (focusKey(entry.state) !== focusKey(lastState)) counts.focusStateChanges += 1;
      if (visibilityKey(entry.state) !== visibilityKey(lastState)) counts.visibilityStateChanges += 1;
      if (entry.state.iframeCount !== lastState.iframeCount) iframeCountChanged = true;
    }
    if (entry.state.hasFocus === false) focusLossObserved = true;
    if (entry.state.hidden === true || entry.state.visibilityState === 'hidden') hiddenObserved = true;
    lastState = entry.state;
  }
  const nativeCounts = {};
  for (const entry of extensionLogs) {
    if (entry.at < group.startEpochMs || entry.at >= group.endEpochMs) continue;
    if (entry.event !== 'native_telemetry' || typeof entry.nativeEvent !== 'string') continue;
    // Native diagnostics are names only; never print payloads or answer/follow-up text.
    const key = cell(entry.nativeEvent);
    nativeCounts[key] = (nativeCounts[key] ?? 0) + 1;
  }
  const findings = [];
  if (counts.pressedPointerEvents) findings.push(`${counts.pressedPointerEvents} pressed-button page events`);
  if (focusLossObserved) findings.push('document focus false');
  if (hiddenObserved) findings.push('document hidden');
  if (counts.pageInputEvents) findings.push('page input events');
  if (counts.pointerEvents) findings.push('page pointer events');
  if (counts.mutations) findings.push('DOM changed');
  if (iframeCountChanged) findings.push('iframe count changed');
  if (missingState) findings.push('missing state: inconclusive');
  if (!findings.length && (counts.focusEvents || counts.focusStateChanges)) findings.push('focus activity');
  if (!findings.length) findings.push('no listed signal recorded; action unverified');
  return { counts, findings, nativeCounts, lastState, firstPressedEpochMs, lastPressedEpochMs };
}

async function summarize(path) {
  const report = JSON.parse(await readFile(path, 'utf8'));
  const probe = report.probe ?? report;
  if (probe.schemaVersion !== 1 || !Array.isArray(probe.entries)) {
    throw new Error('Expected a schemaVersion 1 probe snapshot or session report.');
  }
  const entries = probe.entries;
  const warnings = [];
  if (report.environment?.focusEmulation !== false) {
    warnings.push('Focus emulation was not recorded as disabled: native focus/visibility claims are invalid; retain this as functional evidence only.');
  }
  if (probe.droppedEntries > 0) warnings.push(`${probe.droppedEntries} older entries dropped: the whole trial is inconclusive.`);
  if (!entries.length || entries[0].type !== 'recording-start') warnings.push('Recording start is missing: initial-state and complete-trial claims are inconclusive.');
  const first = entries[0]?.state;
  if (!first || first.hasFocus !== true || first.visibilityState !== 'visible' || first.activeElement?.fixtureId !== 'page-input') {
    warnings.push('Initial state does not establish a visible, focused page input.');
  }
  if (first?.iframeCount !== 0) warnings.push('Initial state does not establish zero page iframes.');
  if (!entries.some((entry) => entry.type === 'mark')) warnings.push('No action markers: action attribution is missing.');
  if (entries.some((entry, index) => index > 0 && entry.sequence !== entries[index - 1].sequence + 1)) {
    warnings.push('Entry sequence has gaps or reordering: complete-trial claims are inconclusive.');
  }
  if (!Array.isArray(report.extension?.logs)) warnings.push('Native/extension observations are missing from this snapshot.');
  else if (report.extension.logs.length >= (report.extension.capacity ?? 2000)) warnings.push('Native/extension log is at its retention cap; earlier native evidence may be missing.');
  if (report.extension?.droppedEntries > 0) warnings.push(`${report.extension.droppedEntries} native/extension entries dropped: earlier native evidence is missing.`);
  if (report.trial?.startValid === false) warnings.push('Timed trial start was invalid: acceptance cannot be established from this trial.');
  if (report.trial && report.trial.status !== 'recorded') warnings.push('Timed trial has not completed its recording window.');
  const initialViewport = report.environment?.viewport;
  const finalViewport = probe.state?.viewport;
  const finalScreen = probe.environment?.screen;
  if (initialViewport && finalViewport) {
    const changes = ['width', 'height', 'devicePixelRatio'].filter(key => initialViewport[key] !== finalViewport[key]);
    if (finalScreen && (initialViewport.screenWidth !== finalScreen.width || initialViewport.screenHeight !== finalScreen.height)) changes.push('screen dimensions');
    if (changes.length) warnings.push(`Display/viewport environment changed since session start (${changes.join(', ')}); document the final configuration before comparing trials.`);
  }
  const groups = [];
  for (const entry of entries) {
    if (entry.type === 'mark' || groups.length === 0) {
      if (groups.length) groups.at(-1).endEpochMs = entry.epochMs;
      groups.push({
        label: entry.type === 'mark' ? entry.detail?.label ?? '(unlabeled marker)' : '(before first marker)',
        startEpochMs: entry.epochMs,
        endEpochMs: null,
        entries: [],
      });
    }
    groups.at(-1).entries.push(entry);
  }
  if (groups.length) {
    const collectedAt = Date.parse(probe.collectedAt);
    groups.at(-1).endEpochMs = Number.isFinite(collectedAt) ? Math.max(collectedAt, entries.at(-1).epochMs) : entries.at(-1).epochMs;
  }

  console.log(`\n### ${cell(basename(path))}\n`);
  const environment = report.environment ?? {};
  console.log(`macOS ${cell(environment.macOS ?? 'not recorded')} (${cell(environment.macOSBuild ?? 'build not recorded')}); Chrome ${cell(environment.browserVersion ?? 'exact version not recorded')}; ${entries.length} retained entries; ${probe.droppedEntries ?? 'unknown'} dropped.\n`);
  for (const warning of warnings) console.log(`- ${warning}`);
  if (warnings.length) console.log('');
  const pressedTotal = entries.filter(isPressedPointer).length;
  console.log(`**Pressed-button page activity: ${pressedTotal} events with buttons > 0.** These are distinct from unpressed hover/motion, but may include legitimate page setup clicks. Use action intervals and native telemetry for attribution; this count alone is not a pass/fail result.\n`);
  console.log('| Marker → next marker | ms | Focus events / state changes | Visibility events / state changes | DOM records | Page input | Pointer total / pressed | Viewport | Observations |');
  console.log('| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |');
  let previousState;
  const nativeLines = [];
  const pressedLines = [];
  let omitted = 0;
  let samples = 0;
  for (const group of groups) {
    const result = summarizeGroup(group, previousState, report.extension?.logs ?? []);
    previousState = result.lastState;
    const counts = result.counts;
    omitted += counts.mutationDetailsOmitted;
    samples += counts.sampleChanges;
    console.log(`| ${cell(group.label)} | ${Math.max(0, Math.round(group.endEpochMs - group.startEpochMs))} | ${counts.focusEvents} / ${counts.focusStateChanges} | ${counts.visibilityEvents} / ${counts.visibilityStateChanges} | ${counts.mutations} | ${counts.pageInputEvents} | ${counts.pointerEvents} / ${counts.pressedPointerEvents} | ${counts.viewportEvents} | ${cell(result.findings.join('; '))} |`);
    if (counts.pressedPointerEvents) {
      const range = result.firstPressedEpochMs === null ? 'timestamps unavailable'
        : `${new Date(result.firstPressedEpochMs).toISOString()} → ${new Date(result.lastPressedEpochMs).toISOString()} (epoch ms ${result.firstPressedEpochMs}–${result.lastPressedEpochMs})`;
      pressedLines.push(`- ${cell(group.label)}: ${counts.pressedPointerEvents} events; ${range}.`);
    }
    const native = Object.entries(result.nativeCounts).map(([event, count]) => `${event} (${count})`).join(', ');
    if (native) nativeLines.push(`- ${cell(group.label)}: ${native}`);
  }
  if (pressedLines.length) console.log(`\nPressed-button intervals (first and last recorded event, not continuous-press duration):\n\n${pressedLines.join('\n')}`);
  console.log(`\nState sampling nominally runs every ${probe.sampleIntervalMs ?? 'unknown'} ms; ${samples} changed-state samples were recorded. Sampling may be throttled and can miss short transitions. Event listeners supplement it. ${omitted} mutation record details were omitted by batch bounds.\n`);
  if (nativeLines.length) console.log(`Native telemetry correlated by extension receipt time:\n\n${nativeLines.join('\n')}\n`);
  console.log('Counts describe observations, not workflow acceptance. Markers delimit intervals but do not establish that real OS actions occurred. Match them to native evidence and the action/environment matrix. Activation signals count toward the complete workflow; untested actions and environments remain not tested.');
  console.log('Even a focusEmulation=false configuration requires positive controls: an actual switch to another application must produce page blur/hasFocus=false, and switching away from the tab must produce hidden/visibilitychange. A successful CDP command alone does not establish that another attached session is no longer emulating focus.');
}

if (process.argv.length < 3) {
  console.error('Usage: node experiments/native-phase1/fixture/summarize.mjs <report.json> [report.json ...]');
  process.exitCode = 1;
} else {
  for (const path of process.argv.slice(2)) {
    try {
      await summarize(path);
    } catch (error) {
      console.error(`${basename(path)}: ${error.message}`);
      process.exitCode = 1;
    }
  }
}
