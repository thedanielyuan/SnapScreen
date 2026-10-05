import {
  disposeResultPanel,
  showErrorToast,
  showResultPanel,
  updateStreamingAnswer,
} from '../content/result-panel';
import { disposeSnipOverlay, startSnipOverlay } from '../content/snip-overlay';
import { setDocumentUiRoot } from '../content/ui-root';
import {
  UI_CLAIM_CAPABILITY,
  UI_READY_MESSAGE,
  UiBootstrapGate,
  isControllerToFrameMessage,
  isUiAttestationSuccess,
  type FrameToControllerMessage,
  type UiPanelAction,
} from '../lib/ui-protocol';

function getBootstrapParameters(): { sessionId: string; nonce: string } | null {
  const params = new URLSearchParams(location.hash.slice(1));
  const sessionId = params.get('session');
  const nonce = params.get('nonce');
  if (!sessionId || !nonce) return null;
  return { sessionId, nonce };
}

const bootstrap = getBootstrapParameters();

if (bootstrap) {
  const { sessionId, nonce } = bootstrap;
  const gate = new UiBootstrapGate(sessionId, nonce);
  let controllerPort: MessagePort | null = null;

  // Keep the capability out of this document's current URL once it is parsed.
  history.replaceState(null, '', `${location.pathname}${location.search}`);
  setDocumentUiRoot(document.body);

  const post = (message: FrameToControllerMessage): void => {
    controllerPort?.postMessage(message);
  };

  const postAction = (action: UiPanelAction): void => {
    post({ type: 'SNAPSCREEN_UI_ACTION', sessionId, action });
  };

  const disposeFrameUi = (): void => {
    disposeSnipOverlay();
    disposeResultPanel();
  };

  const handleControllerMessage = (value: unknown): void => {
    if (!isControllerToFrameMessage(value, sessionId)) return;

    switch (value.type) {
      case 'SNAPSCREEN_UI_START_SNIP':
        disposeResultPanel();
        startSnipOverlay({
          dataUrl: value.dataUrl,
          imageFit: value.imageFit,
          onRegionSelected(selection) {
            post({ type: 'SNAPSCREEN_UI_REGION_SELECTED', sessionId, selection });
          },
          onCancelled() {
            post({ type: 'SNAPSCREEN_UI_SNIP_CANCELLED', sessionId });
          },
        });
        break;

      case 'SNAPSCREEN_UI_DISPOSE_SNIP':
        disposeSnipOverlay();
        break;

      case 'SNAPSCREEN_UI_RENDER_RESULT': {
        const { state } = value;
        disposeSnipOverlay();
        showResultPanel({
          anchorRect: state.anchorRect,
          dataUrl: state.dataUrl,
          error: state.error,
          errorCode: state.errorCode,
          failedAnswerActions: state.canRetryFailedAnswer
            ? {
                onRemove: state.canRemoveFailedAnswer
                  ? () => postAction('remove_failed')
                  : undefined,
                onRetry: () => postAction('retry_failed'),
              }
            : undefined,
          maxInputCharacters: state.maxInputCharacters,
          messages: state.messages,
          onClose: () => postAction('close'),
          onFollowUp: (text) => {
            post({ type: 'SNAPSCREEN_UI_FOLLOW_UP', sessionId, text });
          },
          onOpenSettings: () => postAction('open_settings'),
          onResnip: state.canResnip ? () => postAction('resnip') : undefined,
          onRetry: state.canRetry ? () => postAction('retry') : undefined,
          onStop: state.canStop ? () => postAction('stop') : undefined,
          pending: state.pending,
        });
        break;
      }

      case 'SNAPSCREEN_UI_UPDATE_STREAM':
        updateStreamingAnswer(value.text);
        break;

      case 'SNAPSCREEN_UI_SHOW_TOAST':
        showErrorToast(value.message);
        break;

      case 'SNAPSCREEN_UI_DISPOSE_RESULT':
        disposeResultPanel();
        break;

      case 'SNAPSCREEN_UI_DISPOSE_ALL':
        disposeFrameUi();
        controllerPort?.close();
        controllerPort = null;
        break;
    }
  };

  const handleBootstrap = (event: MessageEvent<unknown>): void => {
    if (event.ports.length !== 1) return;
    if (event.source !== null && event.source !== parent) return;
    if (!gate.accept(event.data)) return;

    const [port] = event.ports;
    controllerPort = port;
    window.removeEventListener('message', handleBootstrap);

    void chrome.runtime.sendMessage({
      type: UI_CLAIM_CAPABILITY,
      sessionId,
      nonce,
    }).then((response: unknown) => {
      if (controllerPort !== port || !isUiAttestationSuccess(response)) {
        disposeFrameUi();
        port.close();
        if (controllerPort === port) controllerPort = null;
        return;
      }

      port.addEventListener('message', (portEvent: MessageEvent<unknown>) => {
        handleControllerMessage(portEvent.data);
      });
      port.addEventListener('messageerror', () => {
        disposeFrameUi();
        port.close();
        controllerPort = null;
      }, { once: true });
      port.start();
      post({ type: UI_READY_MESSAGE, sessionId });
    }).catch(() => {
      disposeFrameUi();
      port.close();
      if (controllerPort === port) controllerPort = null;
    });
  };

  window.addEventListener('message', handleBootstrap);
  window.addEventListener('pagehide', () => {
    disposeFrameUi();
    controllerPort?.close();
    controllerPort = null;
  }, { once: true });
}
