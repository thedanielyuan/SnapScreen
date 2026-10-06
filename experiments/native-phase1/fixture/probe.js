// The observer must never render a live log: rendering would contaminate DOM observations.
// Keep event metadata only. In particular, never retain text, key characters, clipboard data,
// attribute values, screenshot data, or element HTML.
(() => {
  const MAX_ENTRIES = 12000;
  const SAMPLE_INTERVAL_MS = 25;
  const ownIds = new Set(['page-input', 'reset-log', 'inspect-log', 'download-log', 'log-output']);
  const namedKeys = new Set([
    'Alt', 'AltGraph', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'ArrowUp', 'Backspace',
    'CapsLock', 'Control', 'Delete', 'End', 'Enter', 'Escape', 'Home', 'Insert', 'Meta',
    'NumLock', 'PageDown', 'PageUp', 'Pause', 'ScrollLock', 'Shift', 'Tab',
    'F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12',
  ]);
  const input = document.getElementById('page-input');
  const output = document.getElementById('log-output');
  let records = new Array(MAX_ENTRIES);
  let total = 0;
  let startedAt = performance.now();
  let startedAtIso = new Date().toISOString();
  let previousSample;

  function describeTarget(target) {
    if (target === window) return { kind: 'window' };
    if (target === document) return { kind: 'document' };
    if (!target || target.nodeType !== 1) return { kind: 'other' };
    return {
      kind: 'element',
      tag: target.tagName.toLowerCase(),
      fixtureId: ownIds.has(target.id) ? target.id : null,
      hasId: Boolean(target.id),
    };
  }

  function readState() {
    return {
      hasFocus: document.hasFocus(),
      activeElement: describeTarget(document.activeElement),
      visibilityState: document.visibilityState,
      hidden: document.hidden,
      iframeCount: document.querySelectorAll('iframe').length,
      viewport: {
        width: window.innerWidth,
        height: window.innerHeight,
        scrollX: window.scrollX,
        scrollY: window.scrollY,
        devicePixelRatio: window.devicePixelRatio,
        visualWidth: window.visualViewport?.width ?? null,
        visualHeight: window.visualViewport?.height ?? null,
        visualScale: window.visualViewport?.scale ?? null,
        visualOffsetLeft: window.visualViewport?.offsetLeft ?? null,
        visualOffsetTop: window.visualViewport?.offsetTop ?? null,
      },
    };
  }

  function record(type, detail = {}) {
    const now = performance.now();
    records[total % MAX_ENTRIES] = {
      sequence: total,
      type,
      elapsedMs: Number((now - startedAt).toFixed(3)),
      epochMs: performance.timeOrigin + now,
      detail,
      state: readState(),
    };
    total += 1;
  }

  function mark(label) {
    // Use fixed action labels, never text from the tested input or a conversation.
    const safeLabel = Array.from(String(label)).filter((character) => {
      const code = character.charCodeAt(0);
      return code >= 32 && code !== 127;
    }).join('').slice(0, 120);
    record('mark', { label: safeLabel });
  }

  function snapshot() {
    const count = Math.min(total, MAX_ENTRIES);
    const first = total - count;
    return {
      schemaVersion: 1,
      startedAt: startedAtIso,
      collectedAt: new Date().toISOString(),
      sampleIntervalMs: SAMPLE_INTERVAL_MS,
      capacity: MAX_ENTRIES,
      droppedEntries: Math.max(0, total - MAX_ENTRIES),
      environment: {
        userAgent: navigator.userAgent,
        platform: navigator.platform,
        language: navigator.language,
        screen: {
          width: window.screen.width,
          height: window.screen.height,
          availableWidth: window.screen.availWidth,
          availableHeight: window.screen.availHeight,
          colorDepth: window.screen.colorDepth,
        },
        browserWindow: {
          x: window.screenX,
          y: window.screenY,
          outerWidth: window.outerWidth,
          outerHeight: window.outerHeight,
        },
      },
      state: readState(),
      entries: Array.from({ length: count }, (_, index) => records[(first + index) % MAX_ENTRIES]),
    };
  }

  function reset() {
    observer.takeRecords();
    records = new Array(MAX_ENTRIES);
    total = 0;
    startedAt = performance.now();
    startedAtIso = new Date().toISOString();
    previousSample = JSON.stringify(readState());
    record('recording-start');
  }

  // Establish the requested initial state before instrumentation starts. A trial is valid only
  // when its recording-start entry confirms hasFocus=true and fixtureId=page-input.
  input.focus({ preventScroll: true });

  for (const type of ['focus', 'blur', 'focusin', 'focusout', 'visibilitychange', 'pageshow', 'pagehide']) {
    window.addEventListener(type, (event) => {
      record(type, {
        target: describeTarget(event.target),
        relatedTarget: describeTarget(event.relatedTarget),
        trusted: event.isTrusted,
      });
    }, true);
  }

  for (const type of ['pointerdown', 'pointerup', 'pointermove', 'pointercancel', 'pointerover', 'pointerout', 'click', 'dblclick', 'contextmenu', 'wheel']) {
    window.addEventListener(type, (event) => {
      record(type, {
        target: describeTarget(event.target),
        trusted: event.isTrusted,
        pointerType: event.pointerType ?? null,
        x: event.clientX,
        y: event.clientY,
        button: event.button,
        buttons: event.buttons,
        deltaX: event.deltaX ?? null,
        deltaY: event.deltaY ?? null,
      });
    }, { capture: true, passive: true });
  }

  for (const type of ['keydown', 'keyup', 'beforeinput', 'input', 'compositionstart', 'compositionupdate', 'compositionend', 'copy', 'cut', 'paste', 'select', 'selectionchange']) {
    window.addEventListener(type, (event) => {
      record(type, {
        target: describeTarget(event.target),
        trusted: event.isTrusted,
        // key/code for printable keys would reveal typed text. Preserve only named controls.
        key: typeof event.key === 'string' ? (namedKeys.has(event.key) ? event.key : '[redacted]') : null,
        repeat: event.repeat ?? null,
        alt: event.altKey ?? null,
        control: event.ctrlKey ?? null,
        meta: event.metaKey ?? null,
        shift: event.shiftKey ?? null,
        isComposing: event.isComposing ?? null,
        inputType: event.inputType ?? null,
      });
    }, true);
  }

  for (const type of ['resize', 'scroll']) {
    window.addEventListener(type, (event) => record(type, {
      target: describeTarget(event.target),
      trusted: event.isTrusted,
    }), { capture: true, passive: true });
    window.visualViewport?.addEventListener(type, () => record(`visual-viewport-${type}`), { passive: true });
  }

  const observer = new MutationObserver((mutations) => {
    record('dom-mutation', {
      count: mutations.length,
      // Bound the size of a batch independently of the ring buffer.
      omittedRecords: Math.max(0, mutations.length - 30),
      mutations: mutations.slice(0, 30).map((mutation) => ({
        type: mutation.type,
        target: describeTarget(mutation.target),
        attributeName: mutation.attributeName,
        addedCount: mutation.addedNodes.length,
        removedCount: mutation.removedNodes.length,
        addedElements: Array.from(mutation.addedNodes).slice(0, 10).map(describeTarget),
        removedElements: Array.from(mutation.removedNodes).slice(0, 10).map(describeTarget),
      })),
    });
  });
  observer.observe(document.documentElement, {
    attributes: true,
    childList: true,
    characterData: true,
    subtree: true,
  });

  setInterval(() => {
    const sample = JSON.stringify(readState());
    if (sample !== previousSample) {
      record('sample-state-change');
      previousSample = sample;
    }
  }, SAMPLE_INTERVAL_MS);

  document.getElementById('reset-log').addEventListener('click', () => {
    output.textContent = 'Recording in memory. No live log is rendered.';
    input.focus({ preventScroll: true });
    reset();
  });

  document.getElementById('inspect-log').addEventListener('click', () => {
    mark('trial-end:inspect');
    output.textContent = JSON.stringify(snapshot(), null, 2);
  });

  document.getElementById('download-log').addEventListener('click', () => {
    mark('trial-end:download');
    const blob = new Blob([JSON.stringify(snapshot(), null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = 'native-phase1-page-observations.json';
    link.click();
    URL.revokeObjectURL(url);
  });

  globalThis.phase1Probe = Object.freeze({ mark, snapshot, reset });
  reset();
})();
