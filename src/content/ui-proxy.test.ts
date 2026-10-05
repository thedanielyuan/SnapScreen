import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

interface FakeHostOptions {
  onMessage: (message: {
    type: string;
    sessionId: string;
    action?: string;
    selection?: {
      viewportRect: { x: number; y: number; width: number; height: number };
      normalizedRect: { x: number; y: number; width: number; height: number };
    };
  }) => void;
  onUnexpectedDispose?: () => void;
  onUnavailable?: () => void;
}

const mockState = vi.hoisted(() => ({
  ...(() => {
    const instances: FakeFrameHost[] = [];
    class FakeFrameHost {
      isDisposed = false;
      readonly options: FakeHostOptions;
      readonly send = vi.fn(() => true);
      readonly setInteractive = vi.fn();

      constructor(options: FakeHostOptions) {
        this.options = options;
        instances.push(this);
      }

      dispose(): void {
        this.isDisposed = true;
      }

      emit(message: Parameters<FakeHostOptions['onMessage']>[0]): void {
        this.options.onMessage(message);
      }

      failUnexpectedly(): void {
        this.isDisposed = true;
        this.options.onUnexpectedDispose?.();
      }

      failUnavailable(): void {
        this.isDisposed = true;
        this.options.onUnavailable?.();
      }
    }
    return { FakeFrameHost, instances };
  })(),
}));

vi.mock('./result-frame-host', () => ({
  ResultFrameHost: mockState.FakeFrameHost,
}));

import {
  disposeResultPanel,
  showResultPanel,
  startSnipOverlay as startSnipOverlayInternal,
} from './ui-proxy';

const TEST_DATA_URL = 'data:image/png;base64,FROZEN';

function startSnipOverlay(options: {
  onRegionSelected: (selection: {
    viewportRect: { x: number; y: number; width: number; height: number };
    normalizedRect: { x: number; y: number; width: number; height: number };
  }) => void;
  onCancelled: () => void;
}): ReturnType<typeof startSnipOverlayInternal> {
  return startSnipOverlayInternal({ ...options, dataUrl: TEST_DATA_URL });
}

beforeEach(() => {
  mockState.instances.length = 0;
  // Content scripts get only part of chrome.runtime; openOptionsPage isn't in it.
  vi.stubGlobal('chrome', {
    runtime: {
      sendMessage: vi.fn(async () => ({ ok: true })),
    },
  });
});

afterEach(() => {
  disposeResultPanel();
  mockState.instances.length = 0;
  vi.unstubAllGlobals();
  vi.clearAllMocks();
});

describe('isolated UI proxy lifecycle', () => {
  it('starts snipping without a mutable hint payload', () => {
    startSnipOverlay({ onRegionSelected: vi.fn(), onCancelled: vi.fn() });

    expect(mockState.instances[0].send).toHaveBeenCalledWith({
      type: 'SNAPSCREEN_UI_START_SNIP',
      dataUrl: TEST_DATA_URL,
    });
  });

  it('cancels the capture if the frame disappears after selection but before delivery', () => {
    const onRegionSelected = vi.fn();
    const onCancelled = vi.fn();
    startSnipOverlay({ onRegionSelected, onCancelled });
    const host = mockState.instances[0];

    host.emit({
      type: 'SNAPSCREEN_UI_REGION_SELECTED',
      sessionId: 'session',
      selection: {
        viewportRect: { x: 10, y: 20, width: 100, height: 80 },
        normalizedRect: { x: 0.1, y: 0.2, width: 0.5, height: 0.4 },
      },
    });
    expect(onRegionSelected).toHaveBeenCalledTimes(1);

    host.failUnexpectedly();

    expect(onCancelled).toHaveBeenCalledTimes(1);
  });

  it('cancels active work and requests browser-chrome feedback when the frame is unavailable', async () => {
    const onCancelled = vi.fn();
    startSnipOverlay({ onRegionSelected: vi.fn(), onCancelled });
    const host = mockState.instances[0];

    host.failUnavailable();
    await Promise.resolve();

    expect(onCancelled).toHaveBeenCalledTimes(1);
    expect(chrome.runtime.sendMessage).toHaveBeenCalledWith({
      type: 'UI_UNAVAILABLE',
    });
  });

  it('asks the background to open Settings from the missing-key error', () => {
    showResultPanel({
      error: 'No API key configured.',
      errorCode: 'no_api_key',
      onClose: vi.fn(),
      onFollowUp: vi.fn(),
    });

    mockState.instances[0].emit({
      type: 'SNAPSCREEN_UI_ACTION',
      sessionId: 'session',
      action: 'open_settings',
    });

    expect(chrome.runtime.sendMessage).toHaveBeenCalledWith({ type: 'OPEN_SETTINGS' });
  });

  it('offers a failed first answer Try again but not Remove', () => {
    const onRetry = vi.fn();
    showResultPanel({
      messages: [{ role: 'assistant', content: 'Partial', status: 'failed' }],
      failedAnswerActions: { onRetry },
      onClose: vi.fn(),
      onFollowUp: vi.fn(),
    });

    const [host] = mockState.instances;
    expect(host.send).toHaveBeenCalledWith(expect.objectContaining({
      type: 'SNAPSCREEN_UI_RENDER_RESULT',
      state: expect.objectContaining({
        canRemoveFailedAnswer: false,
        canRetryFailedAnswer: true,
      }),
    }));
    host.emit({ type: 'SNAPSCREEN_UI_ACTION', sessionId: 'session', action: 'remove_failed' });
    host.emit({ type: 'SNAPSCREEN_UI_ACTION', sessionId: 'session', action: 'retry_failed' });
    expect(onRetry).toHaveBeenCalledTimes(1);
  });
});
