import { describe, expect, it } from 'vitest';
import {
  isBackgroundToWorkspaceMessage,
  isWorkspaceToBackgroundMessage,
} from './workspace-protocol';

const sessionId = 'workspace-session';
const nonce = 'a'.repeat(43);
const limits = {
  maxInputCharacters: 4_000,
  maxScreenshotBytes: 5_000_000,
  maxScreenshotDimension: 2_576,
  maxConversationTurns: 12,
};

describe('workspace protocol validation', () => {
  it('accepts one initial credential or one reconnect credential', () => {
    expect(isWorkspaceToBackgroundMessage({
      type: 'SNAPSCREEN_WORKSPACE_CLAIM',
      sessionId,
      nonce,
      needsInitialState: true,
    })).toBe(true);
    expect(isWorkspaceToBackgroundMessage({
      type: 'SNAPSCREEN_WORKSPACE_CLAIM',
      sessionId,
      reconnectToken: nonce,
      needsInitialState: false,
    })).toBe(true);
    expect(isWorkspaceToBackgroundMessage({
      type: 'SNAPSCREEN_WORKSPACE_CLAIM',
      sessionId,
      nonce,
      reconnectToken: nonce,
      needsInitialState: true,
    })).toBe(false);
  });

  it('validates normalized capture requests before background dispatch', () => {
    const request = {
      type: 'SNAPSCREEN_WORKSPACE_REQUEST',
      sessionId,
      requestId: 'rpc-1',
      message: {
        type: 'CAPTURE_REGION',
        captureId: 'capture-1',
        dataUrl: 'data:image/png;base64,FROZEN',
        selection: {
          viewportRect: { x: 20, y: 30, width: 100, height: 80 },
          normalizedRect: { x: 0.1, y: 0.2, width: 0.5, height: 0.4 },
        },
      },
    };

    expect(isWorkspaceToBackgroundMessage(request)).toBe(true);
    expect(isWorkspaceToBackgroundMessage({
      ...request,
      message: {
        ...request.message,
        selection: {
          ...request.message.selection,
          normalizedRect: { x: 0.9, y: 0, width: 0.2, height: 1 },
        },
      },
    })).toBe(false);
    expect(isWorkspaceToBackgroundMessage({
      ...request,
      message: { type: 'EXECUTE', sourceTabId: 7 },
    })).toBe(false);
    expect(isWorkspaceToBackgroundMessage({
      ...request,
      message: { type: 'OPEN_SETTINGS' },
    })).toBe(true);
  });

  it('requires correlated ready and streaming envelopes to be well formed', () => {
    expect(isBackgroundToWorkspaceMessage({
      type: 'SNAPSCREEN_WORKSPACE_READY',
      sessionId,
      reconnectToken: nonce,
      initialMessage: {
        type: 'START_SNIP',
        captureId: 'capture-1',
        dataUrl: 'data:image/png;base64,FROZEN',
        defaultPrompt: 'Answer this.',
        limits,
      },
    })).toBe(true);
    expect(isBackgroundToWorkspaceMessage({
      type: 'SNAPSCREEN_WORKSPACE_EVENT',
      sessionId,
      message: {
        type: 'ANALYZE_CHUNK',
        captureId: 'capture-1',
        requestId: 'generation-1',
        screenshotId: 'screenshot-1',
        text: 'partial answer',
      },
    })).toBe(true);
    expect(isBackgroundToWorkspaceMessage({
      type: 'SNAPSCREEN_WORKSPACE_EVENT',
      sessionId,
      message: { type: 'ANALYZE_CHUNK', text: 'uncorrelated' },
    })).toBe(false);
  });
});
