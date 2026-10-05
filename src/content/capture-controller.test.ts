import { describe, expect, it, vi } from 'vitest';
import type { BgToCsMessage, CsToBgMessage } from '../lib/messages';
import { DEFAULT_LIMITS } from '../lib/storage';
import {
  createCaptureController,
  type CaptureControllerUi,
} from './capture-controller';
import type { ResultPanelOptions } from './result-panel';
import type { SnipOverlayOptions } from './snip-overlay';

interface ControllerHarness {
  controller: ReturnType<typeof createCaptureController>;
  panels: ResultPanelOptions[];
  selections: SnipOverlayOptions[];
  sendMessage: ReturnType<typeof vi.fn<(message: CsToBgMessage) => Promise<unknown>>>;
  streamUpdates: string[];
  toasts: string[];
}

function createHarness(imageFit?: 'contain' | 'fill'): ControllerHarness {
  const panels: ResultPanelOptions[] = [];
  const selections: SnipOverlayOptions[] = [];
  const streamUpdates: string[] = [];
  const toasts: string[] = [];
  const sendMessage = vi.fn(async () => ({ ok: true }));
  const ui: CaptureControllerUi = {
    disposeResultPanel: vi.fn(),
    disposeSnipOverlay: vi.fn(),
    showErrorToast: (message) => toasts.push(message),
    showResultPanel: (options) => panels.push(options),
    startSnipOverlay: (options) => {
      selections.push(options);
      return vi.fn();
    },
    updateStreamingAnswer: (text) => streamUpdates.push(text),
  };
  return {
    controller: createCaptureController({ imageFit, sendMessage, ui }),
    panels,
    selections,
    sendMessage,
    streamUpdates,
    toasts,
  };
}

function startAndSelect(harness: ControllerHarness, captureId = 'capture-1'): void {
  harness.controller.handleMessage({
    type: 'START_SNIP',
    captureId,
    dataUrl: 'data:image/png;base64,FROZEN',
    defaultPrompt: 'Keep the diagram context.',
    limits: DEFAULT_LIMITS,
  });
  harness.selections.at(-1)!.onRegionSelected({
    viewportRect: { x: 10, y: 20, width: 300, height: 200 },
    normalizedRect: { x: 0.1, y: 0.2, width: 0.3, height: 0.4 },
  });
}

async function deliverCrop(harness: ControllerHarness, captureId = 'capture-1'): Promise<Extract<
CsToBgMessage,
{ type: 'ANALYZE' }
>> {
  harness.controller.handleMessage({
    type: 'CROPPED_IMAGE',
    captureId,
    dataUrl: 'data:image/png;base64,CROPPED',
  });
  await vi.waitFor(() => {
    expect(harness.sendMessage.mock.calls.some(
      ([message]) => message.type === 'ANALYZE',
    )).toBe(true);
  });
  return harness.sendMessage.mock.calls
    .map(([message]) => message)
    .find((message): message is Extract<CsToBgMessage, { type: 'ANALYZE' }> => (
      message.type === 'ANALYZE'
    ))!;
}

const adapters = [
  { label: 'in-page iframe adapter', imageFit: undefined },
  { label: 'trusted workspace adapter', imageFit: 'contain' as const },
];

describe.each(adapters)('shared capture controller — $label', ({ imageFit }) => {
  it('uses normalized selection, streams, follows up, stops, and resnips', async () => {
    const harness = createHarness(imageFit);
    startAndSelect(harness);

    expect(harness.selections[0]).toEqual(expect.objectContaining({
      dataUrl: 'data:image/png;base64,FROZEN',
      imageFit,
    }));
    expect(harness.sendMessage).toHaveBeenCalledWith({
      type: 'CAPTURE_REGION',
      captureId: 'capture-1',
      dataUrl: 'data:image/png;base64,FROZEN',
      selection: {
        viewportRect: { x: 10, y: 20, width: 300, height: 200 },
        normalizedRect: { x: 0.1, y: 0.2, width: 0.3, height: 0.4 },
      },
    });

    const initial = await deliverCrop(harness);
    harness.controller.handleMessage({
      type: 'ANALYZE_CHUNK',
      captureId: initial.captureId,
      requestId: initial.requestId,
      screenshotId: initial.screenshotId,
      text: 'Partial',
    });
    expect(harness.streamUpdates).toEqual(['Partial']);
    harness.panels.at(-1)!.onStop?.();
    expect(harness.sendMessage).toHaveBeenCalledWith({
      type: 'CANCEL_GENERATION',
      captureId: initial.captureId,
      requestId: initial.requestId,
    });

    harness.panels.at(-1)!.onFollowUp('Try another reading.');
    expect(harness.sendMessage.mock.calls.some(
      ([message]) => (
        message.type === 'FOLLOW_UP'
        && message.text === 'Try another reading.'
      ),
    )).toBe(true);

    harness.panels.at(-1)!.onResnip?.();
    expect(harness.sendMessage).toHaveBeenCalledWith({
      type: 'REQUEST_SNIP',
      sessionSettings: {
        defaultPrompt: 'Keep the diagram context.',
        limits: DEFAULT_LIMITS,
      },
    });
  });

  it('retries the same capture after a missing API key is added', async () => {
    const harness = createHarness(imageFit);
    startAndSelect(harness);
    const initial = await deliverCrop(harness);
    harness.controller.handleMessage({
      type: 'ANALYZE_ERROR',
      captureId: initial.captureId,
      requestId: initial.requestId,
      screenshotId: initial.screenshotId,
      code: 'no_api_key',
      message: 'No API key configured.',
    });

    const failed = harness.panels.at(-1)!;
    expect(failed).toEqual(expect.objectContaining({
      error: 'No API key configured.',
      errorCode: 'no_api_key',
      pending: false,
    }));
    failed.onRetry!();

    expect(harness.panels.at(-1)).toEqual(expect.objectContaining({
      error: undefined,
      pending: true,
    }));
    const analyzeRequests = harness.sendMessage.mock.calls
      .map(([message]) => message)
      .filter((message): message is Extract<CsToBgMessage, { type: 'ANALYZE' }> => (
        message.type === 'ANALYZE'
      ));
    expect(analyzeRequests).toHaveLength(2);
    const { requestId: retryRequestId, ...retry } = analyzeRequests[1];
    const { requestId: initialRequestId, ...original } = initial;
    expect(retry).toEqual(original);
    expect(retryRequestId).not.toBe(initialRequestId);
  });

  it('keeps the conversation but removes New snip when the source expires', async () => {
    const harness = createHarness(imageFit);
    startAndSelect(harness);
    const initial = await deliverCrop(harness);
    harness.controller.handleMessage({
      type: 'ANALYZE_RESULT',
      captureId: initial.captureId,
      requestId: initial.requestId,
      screenshotId: initial.screenshotId,
      text: 'Existing answer',
      history: [{ role: 'assistant', content: 'Existing answer' }],
    });

    const message: BgToCsMessage = {
      type: 'RESNIP_UNAVAILABLE',
      message: 'The source tab was closed.',
    };
    harness.controller.handleMessage(message);

    expect(harness.toasts).toContain('The source tab was closed.');
    expect(harness.panels.at(-1)?.messages).toEqual([
      { role: 'assistant', content: 'Existing answer' },
    ]);
    expect(harness.panels.at(-1)?.onResnip).toBeUndefined();
    expect(harness.panels.at(-1)?.onFollowUp).toBeTypeOf('function');
  });
});
