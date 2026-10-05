import {
  disposeResultPanel,
  disposeSnipOverlay,
  showErrorToast,
  showResultPanel,
  showThinking,
  startSnipOverlay,
  updateStreamingAnswer,
} from './ui-proxy';
import { createCaptureController } from './capture-controller';
import type { BgToCsMessage } from '../lib/messages';

declare global {
  interface Window {
    __snapscreenListenerReady?: boolean;
  }
}

const controller = createCaptureController({
  sendMessage: (message) => chrome.runtime.sendMessage(message),
  ui: {
    disposeResultPanel,
    disposeSnipOverlay,
    showErrorToast,
    showResultPanel,
    showThinking,
    startSnipOverlay,
    updateStreamingAnswer,
  },
});

if (!window.__snapscreenListenerReady) {
  window.__snapscreenListenerReady = true;

  chrome.runtime.onMessage.addListener((message: BgToCsMessage, _sender, sendResponse) => {
    if (message.type === 'PREPARE_SNIP_CAPTURE') {
      controller.prepareForCapture();
      requestAnimationFrame(() => {
        requestAnimationFrame(() => sendResponse({ ok: true }));
      });
      return true;
    }

    controller.handleMessage(message);
    return undefined;
  });
}
