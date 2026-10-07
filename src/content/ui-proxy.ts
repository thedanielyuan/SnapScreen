import type { ResultPanelOptions } from './result-panel';
import { ResultFrameHost } from './result-frame-host';
import type {
  SnipOverlayDisposer,
  SnipOverlayOptions,
} from './snip-overlay';
import type { CsToBgMessage } from '../lib/messages';
import type {
  FrameToControllerMessage,
  SerializedResultPanelState,
  UiPanelAction,
} from '../lib/ui-protocol';

let activeHost: ResultFrameHost | null = null;
let overlayOptions: SnipOverlayOptions | null = null;
let panelOptions: ResultPanelOptions | null = null;
let captureGapCancel: (() => void) | null = null;
let toastCleanup: ReturnType<typeof setTimeout> | null = null;

function clearToastCleanup(): void {
  if (toastCleanup === null) return;
  clearTimeout(toastCleanup);
  toastCleanup = null;
}

function clearHostState(host: ResultFrameHost): void {
  if (activeHost !== host) return;
  activeHost = null;
  overlayOptions = null;
  panelOptions = null;
  captureGapCancel = null;
  clearToastCleanup();
}

function handleUnexpectedDispose(host: ResultFrameHost): void {
  if (activeHost !== host) return;
  const overlay = overlayOptions;
  const panel = panelOptions;
  const cancelCaptureGap = captureGapCancel;
  clearHostState(host);

  // Removing or navigating the outer frame is denial of service, not a trusted
  // UI action. Route it through the existing cancellation paths so capture or
  // generation work does not continue invisibly.
  if (overlay) {
    overlay.onCancelled();
  } else if (panel) {
    panel?.onClose();
  } else {
    cancelCaptureGap?.();
  }
}

function handleUnavailable(host: ResultFrameHost): void {
  if (activeHost !== host) return;
  const overlay = overlayOptions;
  const panel = panelOptions;
  const cancelCaptureGap = captureGapCancel;
  clearHostState(host);

  if (overlay) {
    overlay.onCancelled();
  } else if (panel) {
    panel.onClose();
  } else {
    cancelCaptureGap?.();
  }

  void chrome.runtime.sendMessage({ type: 'UI_UNAVAILABLE' }).catch(() => undefined);
}

function ensureHost(): ResultFrameHost {
  if (activeHost && !activeHost.isDisposed) return activeHost;

  let host!: ResultFrameHost;
  host = new ResultFrameHost({
    onMessage: (message) => handleFrameMessage(host, message),
    onUnexpectedDispose: () => handleUnexpectedDispose(host),
    onUnavailable: () => handleUnavailable(host),
  });
  activeHost = host;
  return host;
}

function handleFrameMessage(
  host: ResultFrameHost,
  message: Exclude<FrameToControllerMessage, { type: 'SNAPSCREEN_UI_READY' }>,
): void {
  if (activeHost !== host) return;

  switch (message.type) {
    case 'SNAPSCREEN_UI_REGION_SELECTED': {
      const options = overlayOptions;
      if (!options) return;
      captureGapCancel = options.onCancelled;
      overlayOptions = null;
      host.setInteractive(false);
      options.onRegionSelected(message.selection);
      break;
    }

    case 'SNAPSCREEN_UI_SNIP_CANCELLED': {
      const options = overlayOptions;
      if (!options) return;
      overlayOptions = null;
      options.onCancelled();
      break;
    }

    case 'SNAPSCREEN_UI_FOLLOW_UP':
      panelOptions?.onFollowUp(message.text);
      break;

    case 'SNAPSCREEN_UI_ACTION':
      handlePanelAction(message.action);
      break;
  }
}

function handlePanelAction(action: UiPanelAction): void {
  const options = panelOptions;
  if (!options) return;

  switch (action) {
    case 'close':
      options.onClose();
      break;
    case 'open_settings':
      if (options.onOpenSettings) {
        options.onOpenSettings();
      } else {
        // Content scripts can't call chrome.runtime.openOptionsPage().
        void chrome.runtime.sendMessage({ type: 'OPEN_SETTINGS' } satisfies CsToBgMessage)
          .catch(() => undefined);
      }
      break;
    case 'resnip':
      options.onResnip?.();
      break;
    case 'retry':
      options.onRetry?.();
      break;
    case 'stop':
      options.onStop?.();
      break;
    case 'retry_failed':
      options.failedAnswerActions?.onRetry();
      break;
    case 'remove_failed':
      options.failedAnswerActions?.onRemove?.();
      break;
  }
}

export function startSnipOverlay(options: SnipOverlayOptions): SnipOverlayDisposer {
  disposeSnipOverlay();
  clearToastCleanup();
  panelOptions = null;
  captureGapCancel = null;
  overlayOptions = options;
  const host = ensureHost();
  host.setInteractive(true);
  host.send({
    type: 'SNAPSCREEN_UI_START_SNIP',
    dataUrl: options.dataUrl,
    imageFit: options.imageFit,
  });

  let disposed = false;
  return () => {
    if (disposed) return;
    disposed = true;
    if (activeHost !== host || overlayOptions !== options) return;
    overlayOptions = null;
    host.send({ type: 'SNAPSCREEN_UI_DISPOSE_SNIP' });
    if (!panelOptions) host.setInteractive(false);
  };
}

export function disposeSnipOverlay(): void {
  overlayOptions = null;
  if (!activeHost || activeHost.isDisposed) return;
  activeHost.send({ type: 'SNAPSCREEN_UI_DISPOSE_SNIP' });
  if (!panelOptions) activeHost.setInteractive(false);
}

export function showResultPanel(options: ResultPanelOptions): void {
  clearToastCleanup();
  overlayOptions = null;
  captureGapCancel = null;
  panelOptions = options;
  const host = ensureHost();
  host.setInteractive(true);

  const state: SerializedResultPanelState = {
    anchorRect: options.anchorRect,
    canRemoveFailedAnswer: typeof options.failedAnswerActions?.onRemove === 'function',
    canResnip: typeof options.onResnip === 'function',
    canRetry: typeof options.onRetry === 'function',
    canRetryFailedAnswer: options.failedAnswerActions !== undefined,
    canStop: typeof options.onStop === 'function',
    dataUrl: options.dataUrl,
    error: options.error,
    errorCode: options.errorCode,
    maxInputCharacters: options.maxInputCharacters,
    messages: options.messages ? [...options.messages] : [],
    pending: !!options.pending,
    pendingSince: options.pendingSince,
    thinking: !!options.thinking,
  };
  host.send({ type: 'SNAPSCREEN_UI_RENDER_RESULT', state });
}

export function showThinking(): void {
  activeHost?.send({ type: 'SNAPSCREEN_UI_SHOW_THINKING' });
}

export function updateStreamingAnswer(text: string): void {
  activeHost?.send({ type: 'SNAPSCREEN_UI_UPDATE_STREAM', text });
}

export function showErrorToast(message: string): void {
  clearToastCleanup();
  const host = ensureHost();
  if (!overlayOptions && !panelOptions) host.setInteractive(false);
  host.send({ type: 'SNAPSCREEN_UI_SHOW_TOAST', message });

  if (!overlayOptions && !panelOptions) {
    toastCleanup = setTimeout(() => {
      toastCleanup = null;
      if (activeHost !== host || overlayOptions || panelOptions) return;
      clearHostState(host);
      host.dispose();
    }, 4_250);
  }
}

export function disposeResultPanel(): void {
  clearToastCleanup();
  panelOptions = null;
  overlayOptions = null;
  captureGapCancel = null;
  const host = activeHost;
  if (!host) return;
  activeHost = null;
  host.send({ type: 'SNAPSCREEN_UI_DISPOSE_ALL' });
  host.dispose();
}
