import { createCaptureController } from '../content/capture-controller';
import {
  disposeResultPanel,
  showErrorToast,
  showResultPanel,
  updateStreamingAnswer,
} from '../content/result-panel';
import {
  disposeSnipOverlay,
  startSnipOverlay,
} from '../content/snip-overlay';
import { setDocumentUiRoot } from '../content/ui-root';
import type { CsToBgMessage } from '../lib/messages';
import { API_REQUEST_TIMEOUT_MS } from '../lib/request-limits';
import {
  WORKSPACE_PORT_NAME,
  isBackgroundToWorkspaceMessage,
  type BackgroundToWorkspaceMessage,
  type WorkspaceError,
} from '../lib/workspace-protocol';

const REQUEST_TIMEOUT_MS = 30_000;
// Answers stream until the API client's own timeout; wait slightly longer so
// its specific error reaches the panel before this generic one.
const GENERATION_REQUEST_TIMEOUT_MS = API_REQUEST_TIMEOUT_MS + 5_000;
const RECONNECT_DELAY_MS = 250;
const MAX_RECONNECT_ATTEMPTS = 5;

interface BootstrapParameters {
  sessionId: string;
  nonce: string;
}

interface PendingRequest {
  reject: (error: Error) => void;
  resolve: (response: unknown) => void;
  timeout: ReturnType<typeof setTimeout>;
}

function getBootstrapParameters(): BootstrapParameters | null {
  const params = new URLSearchParams(location.hash.slice(1));
  const sessionId = params.get('session');
  const nonce = params.get('nonce');
  if (!sessionId || !nonce) return null;
  return { sessionId, nonce };
}

const status = document.getElementById('workspace-status') as HTMLElement;
const bootstrap = getBootstrapParameters();

if (!bootstrap) {
  status.textContent = 'This SnapScreen workspace has expired. Return to the source tab and try again.';
} else {
  const { sessionId, nonce } = bootstrap;
  history.replaceState(null, '', `${location.pathname}${location.search}`);
  setDocumentUiRoot(document.body);

  let port: chrome.runtime.Port | null = null;
  let initialized = false;
  let explicitlyClosed = false;
  let reconnectAttempts = 0;
  let reconnectToken: string | null = null;
  const pending = new Map<string, PendingRequest>();
  let readyResolve!: () => void;
  let readyReject!: (error: Error) => void;
  let ready = new Promise<void>((resolve, reject) => {
    readyResolve = resolve;
    readyReject = reject;
  });
  void ready.catch(() => undefined);

  function resetReady(): void {
    ready = new Promise<void>((resolve, reject) => {
      readyResolve = resolve;
      readyReject = reject;
    });
    void ready.catch(() => undefined);
  }

  function rejectPending(message: string): void {
    for (const request of pending.values()) {
      clearTimeout(request.timeout);
      request.reject(new Error(message));
    }
    pending.clear();
  }

  function sendMessage(message: CsToBgMessage): Promise<unknown> {
    return ready.then(() => new Promise((resolve, reject) => {
      if (!port) {
        reject(new Error('The SnapScreen workspace is disconnected.'));
        return;
      }

      const requestId = crypto.randomUUID();
      const isGeneration = message.type === 'ANALYZE' || message.type === 'FOLLOW_UP';
      const timeout = setTimeout(() => {
        pending.delete(requestId);
        const cancellation = isGeneration
          ? {
              type: 'CANCEL_GENERATION' as const,
              captureId: message.captureId,
              requestId: message.requestId,
            }
          : message.type === 'CAPTURE_REGION'
            ? { type: 'SNIP_CANCELLED' as const, captureId: message.captureId }
            : null;
        if (port && cancellation) {
          try {
            port.postMessage({
              type: 'SNAPSCREEN_WORKSPACE_REQUEST',
              sessionId,
              requestId: crypto.randomUUID(),
              message: cancellation,
            });
          } catch {
            // The original timeout remains the useful user-facing failure.
          }
        }
        reject(new Error('The SnapScreen workspace request timed out.'));
      }, isGeneration ? GENERATION_REQUEST_TIMEOUT_MS : REQUEST_TIMEOUT_MS);
      pending.set(requestId, { resolve, reject, timeout });
      port.postMessage({
        type: 'SNAPSCREEN_WORKSPACE_REQUEST',
        sessionId,
        requestId,
        message,
      });
    }));
  }

  const controller = createCaptureController({
    imageFit: 'contain',
    sendMessage,
    ui: {
      disposeResultPanel,
      disposeSnipOverlay,
      showErrorToast,
      showResultPanel,
      startSnipOverlay,
      updateStreamingAnswer,
    },
    onSessionEnded: () => {
      explicitlyClosed = true;
      port?.postMessage({ type: 'SNAPSCREEN_WORKSPACE_CLOSE', sessionId });
    },
  });

  function showFatalError(error: WorkspaceError): void {
    controller.dispose();
    status.hidden = false;
    status.replaceChildren();
    const message = document.createElement('p');
    message.textContent = error.message;
    status.append(message);
    if (error.code === 'file_access_disabled') {
      const manageButton = document.createElement('button');
      manageButton.type = 'button';
      manageButton.textContent = 'Open Manage Extension';
      manageButton.addEventListener('click', () => {
        void chrome.tabs.create({
          url: `chrome://extensions/?id=${encodeURIComponent(chrome.runtime.id)}`,
        });
      });
      status.append(manageButton);
    }
  }

  function handlePortMessage(value: unknown): void {
    if (!isBackgroundToWorkspaceMessage(value) || value.sessionId !== sessionId) return;

    const message: BackgroundToWorkspaceMessage = value;
    switch (message.type) {
      case 'SNAPSCREEN_WORKSPACE_READY':
        reconnectAttempts = 0;
        reconnectToken = message.reconnectToken;
        readyResolve();
        if (message.error) {
          showFatalError(message.error);
          return;
        }
        if (message.initialMessage) {
          initialized = true;
          status.hidden = true;
          controller.handleMessage(message.initialMessage);
        } else if (!initialized) {
          showFatalError(
            {
              code: 'capture_expired',
              message: 'The frozen screenshot expired before the workspace opened. Return to the source tab and try again.',
            },
          );
        }
        break;

      case 'SNAPSCREEN_WORKSPACE_EVENT':
        controller.handleMessage(message.message);
        break;

      case 'SNAPSCREEN_WORKSPACE_RESPONSE': {
        const request = pending.get(message.requestId);
        if (!request) return;
        pending.delete(message.requestId);
        clearTimeout(request.timeout);
        request.resolve(message.response);
        break;
      }
    }
  }

  function connect(): void {
    if (explicitlyClosed) return;
    const nextPort = chrome.runtime.connect({ name: WORKSPACE_PORT_NAME });
    port = nextPort;
    nextPort.onMessage.addListener(handlePortMessage);
    nextPort.onDisconnect.addListener(() => {
      if (port !== nextPort) return;
      port = null;
      readyReject(new Error('The SnapScreen workspace disconnected.'));
      rejectPending('The SnapScreen workspace disconnected.');
      if (explicitlyClosed || reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
        showFatalError({
          code: 'capture_expired',
          message: 'SnapScreen lost its background connection. Reload this tab or capture again.',
        });
        return;
      }
      reconnectAttempts += 1;
      resetReady();
      setTimeout(connect, RECONNECT_DELAY_MS);
    });
    nextPort.postMessage({
      type: 'SNAPSCREEN_WORKSPACE_CLAIM',
      sessionId,
      needsInitialState: !initialized,
      ...(reconnectToken ? { reconnectToken } : { nonce }),
    });
  }

  connect();
  window.addEventListener('pagehide', () => {
    explicitlyClosed = true;
    controller.dispose();
    rejectPending('The SnapScreen workspace closed.');
    port?.disconnect();
    port = null;
  }, { once: true });
}
