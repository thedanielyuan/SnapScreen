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
  showThinking: ReturnType<typeof vi.fn>;
  streamUpdates: string[];
  toasts: string[];
}

function createHarness(imageFit?: 'contain' | 'fill'): ControllerHarness {
  const panels: ResultPanelOptions[] = [];
  const selections: SnipOverlayOptions[] = [];
  const streamUpdates: string[] = [];
  const toasts: string[] = [];
  const sendMessage = vi.fn(async () => ({ ok: true }));
  const showThinking = vi.fn();
  const ui: CaptureControllerUi = {
    disposeResultPanel: vi.fn(),
    disposeSnipOverlay: vi.fn(),
    showErrorToast: (message) => toasts.push(message),
    showResultPanel: (options) => panels.push(options),
    showThinking,
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
    showThinking,
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

function sentMessages<T extends CsToBgMessage['type']>(
  harness: ControllerHarness,
  type: T,
): Extract<CsToBgMessage, { type: T }>[] {
  return harness.sendMessage.mock.calls
    .map(([message]) => message)
    .filter((message): message is Extract<CsToBgMessage, { type: T }> => (
      message.type === type
    ));
}

function idsOf(request: { captureId: string; requestId: string; screenshotId: string }) {
  const { captureId, requestId, screenshotId } = request;
  return { captureId, requestId, screenshotId };
}

const INTERRUPTED_ANSWER =
  'Partial answer\n\nResponse interrupted: Request timed out. Please try again.';

async function interruptFirstAnswer(
  harness: ControllerHarness,
): Promise<Extract<CsToBgMessage, { type: 'ANALYZE' }>> {
  startAndSelect(harness);
  const initial = await deliverCrop(harness);
  harness.controller.handleMessage({
    type: 'ANALYZE_CHUNK',
    ...idsOf(initial),
    text: 'Partial answer',
  });
  harness.controller.handleMessage({
    type: 'ANALYZE_ERROR',
    ...idsOf(initial),
    code: 'timeout',
    message: 'Request timed out. Please try again.',
  });
  return initial;
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

  it('keeps a first answer that fails partway and offers Try again', async () => {
    const harness = createHarness(imageFit);
    const initial = await interruptFirstAnswer(harness);

    const failed = harness.panels.at(-1)!;
    expect(failed).toEqual(expect.objectContaining({
      error: undefined,
      messages: [{ role: 'assistant', content: INTERRUPTED_ANSWER, status: 'failed' }],
      pending: false,
    }));
    expect(failed.failedAnswerActions?.onRemove).toBeUndefined();

    failed.failedAnswerActions!.onRetry();

    expect(harness.panels.at(-1)).toEqual(expect.objectContaining({
      failedAnswerActions: undefined,
      messages: [],
      pending: true,
    }));
    const analyzeRequests = sentMessages(harness, 'ANALYZE');
    expect(analyzeRequests).toHaveLength(2);
    const { requestId: retryRequestId, ...retry } = analyzeRequests[1];
    const { requestId: initialRequestId, ...original } = initial;
    expect(retry).toEqual(original);
    expect(retryRequestId).not.toBe(initialRequestId);
  });

  it('builds a follow-up on an interrupted first answer', async () => {
    const harness = createHarness(imageFit);
    await interruptFirstAnswer(harness);

    harness.panels.at(-1)!.onFollowUp('Go on.');

    expect(harness.panels.at(-1)).toEqual(expect.objectContaining({
      failedAnswerActions: undefined,
      pending: true,
    }));
    const [followUp] = sentMessages(harness, 'FOLLOW_UP');
    expect(followUp.text).toBe('Go on.');
    expect(followUp.history).toEqual([
      {
        role: 'user',
        content: [
          {
            type: 'image',
            source: { type: 'base64', media_type: 'image/png', data: 'CROPPED' },
          },
          { type: 'text', text: 'Screenshot task guidance:\nKeep the diagram context.' },
        ],
      },
      { role: 'assistant', content: INTERRUPTED_ANSWER },
    ]);
  });

  it('drops text a refused first answer streamed', async () => {
    const harness = createHarness(imageFit);
    startAndSelect(harness);
    const initial = await deliverCrop(harness);
    harness.controller.handleMessage({
      type: 'ANALYZE_CHUNK',
      ...idsOf(initial),
      text: 'Refused start',
    });
    harness.controller.handleMessage({
      type: 'ANALYZE_ERROR',
      ...idsOf(initial),
      code: 'refusal',
      message: 'Claude declined to answer this question.',
    });

    expect(harness.panels.at(-1)).toEqual(expect.objectContaining({
      error: 'Claude declined to answer this question.',
      errorCode: 'refusal',
      failedAnswerActions: undefined,
      messages: [],
    }));
  });

  it('drops text a refused follow-up streamed from both histories', async () => {
    const harness = createHarness(imageFit);
    startAndSelect(harness);
    const initial = await deliverCrop(harness);
    harness.controller.handleMessage({
      type: 'ANALYZE_RESULT',
      ...idsOf(initial),
      text: 'Answer',
      history: [
        { role: 'user', content: 'Screenshot' },
        { role: 'assistant', content: 'Answer' },
      ],
    });
    harness.panels.at(-1)!.onFollowUp('Why?');
    const [refused] = sentMessages(harness, 'FOLLOW_UP');
    harness.controller.handleMessage({
      type: 'ANALYZE_CHUNK',
      ...idsOf(refused),
      text: 'Refused start',
    });
    harness.controller.handleMessage({
      type: 'ANALYZE_ERROR',
      ...idsOf(refused),
      code: 'refusal',
      message: 'Claude declined to answer this question.',
    });

    expect(harness.panels.at(-1)?.messages?.at(-1)).toEqual({
      role: 'assistant',
      content: 'Response failed: Claude declined to answer this question.',
      status: 'failed',
    });
    harness.panels.at(-1)!.onFollowUp('Something else?');
    const [, next] = sentMessages(harness, 'FOLLOW_UP');
    expect(JSON.stringify(next.history)).not.toContain('Refused start');
  });

  it('shows that the model is thinking about the active request', async () => {
    const harness = createHarness(imageFit);
    startAndSelect(harness);
    const initial = await deliverCrop(harness);
    expect(harness.panels.at(-1)).toEqual(expect.objectContaining({
      pending: true,
      thinking: false,
    }));

    harness.controller.handleMessage({
      type: 'ANALYZE_THINKING',
      ...idsOf(initial),
      requestId: 'stale-request',
    });
    expect(harness.showThinking).not.toHaveBeenCalled();
    harness.controller.handleMessage({ type: 'ANALYZE_THINKING', ...idsOf(initial) });
    expect(harness.showThinking).toHaveBeenCalledOnce();

    // A redraw mid-request keeps the request's start time and thinking state.
    harness.controller.handleMessage({
      type: 'RESNIP_UNAVAILABLE',
      message: 'The source tab was closed.',
    });
    const redrawn = harness.panels.at(-1)!;
    expect(redrawn).toEqual(expect.objectContaining({ pending: true, thinking: true }));
    expect(redrawn.pendingSince).toBeTypeOf('number');

    harness.controller.handleMessage({
      type: 'ANALYZE_RESULT',
      ...idsOf(initial),
      text: 'Answer',
    });
    expect(harness.panels.at(-1)).toEqual(expect.objectContaining({
      pending: false,
      pendingSince: undefined,
      thinking: false,
    }));
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
