import { describe, expect, it, vi } from 'vitest';
import { createUiNonce } from '../content/result-frame-host';
import {
  UI_CLAIM_CAPABILITY,
  UI_CONNECT_MESSAGE,
  UI_REGISTER_CAPABILITY,
  UiBootstrapGate,
  UiCommandBuffer,
  isControllerToFrameMessage,
  isFrameToControllerMessage,
  isUiAttestationMessage,
  type ControllerToFrameMessage,
} from './ui-protocol';

const sessionId = 'session-123';
const nonce = 'a'.repeat(43);

describe('extension-frame capability bootstrap', () => {
  it('creates a 32-byte base64url nonce without padding', () => {
    const nonce = createUiNonce((bytes) => {
      bytes.forEach((_value, index) => {
        bytes[index] = index;
      });
    });

    expect(nonce).toHaveLength(43);
    expect(nonce).toMatch(/^[A-Za-z0-9_-]+$/u);
    expect(nonce).not.toContain('=');
  });

  it('rejects a wrong capability and accepts the expected capability once', () => {
    const gate = new UiBootstrapGate(sessionId, nonce);
    const valid = {
      type: UI_CONNECT_MESSAGE,
      sessionId,
      nonce,
    } as const;

    expect(gate.accept({ ...valid, nonce: 'wrong' })).toBe(false);
    expect(gate.accept(valid)).toBe(true);
    expect(gate.accept(valid)).toBe(false);
  });
});

describe('extension-frame command buffering', () => {
  it('withholds state until READY and preserves command order', () => {
    const posted: ControllerToFrameMessage[] = [];
    const buffer = new UiCommandBuffer((message) => posted.push(message));
    const first: ControllerToFrameMessage = {
      type: 'SNAPSCREEN_UI_UPDATE_STREAM',
      sessionId,
      text: 'private answer',
    };
    const second: ControllerToFrameMessage = {
      type: 'SNAPSCREEN_UI_SHOW_TOAST',
      sessionId,
      message: 'private error',
    };

    expect(buffer.enqueue(first)).toBe(true);
    expect(posted).toEqual([]);

    buffer.markReady();
    expect(posted).toEqual([first]);

    expect(buffer.enqueue(second)).toBe(true);
    expect(posted).toEqual([first, second]);
  });

  it('drops buffered and future state after disposal', () => {
    const post = vi.fn();
    const buffer = new UiCommandBuffer(post);
    const message: ControllerToFrameMessage = {
      type: 'SNAPSCREEN_UI_UPDATE_STREAM',
      sessionId,
      text: 'must not escape',
    };

    buffer.enqueue(message);
    buffer.dispose();
    buffer.markReady();

    expect(buffer.enqueue(message)).toBe(false);
    expect(buffer.isReady).toBe(false);
    expect(post).not.toHaveBeenCalled();
  });
});

describe('extension-frame protocol validation', () => {
  it('accepts the snip command without an instruction payload', () => {
    expect(isControllerToFrameMessage({
      type: 'SNAPSCREEN_UI_START_SNIP',
      sessionId,
      dataUrl: 'data:image/png;base64,FROZEN',
    }, sessionId)).toBe(true);
  });

  it('rejects mismatched sessions and malformed sensitive payloads', () => {
    expect(isControllerToFrameMessage({
      type: 'SNAPSCREEN_UI_UPDATE_STREAM',
      sessionId: 'other-session',
      text: 'answer',
    }, sessionId)).toBe(false);
    expect(isControllerToFrameMessage({
      type: 'SNAPSCREEN_UI_RENDER_RESULT',
      sessionId,
      state: {
        messages: [{ role: 'system', content: 'not allowed' }],
        pending: false,
        canStop: false,
        canRetry: false,
        canResnip: false,
        canRetryFailedAnswer: false,
        canRemoveFailedAnswer: false,
      },
    }, sessionId)).toBe(false);
    expect(isFrameToControllerMessage({
      type: 'SNAPSCREEN_UI_ACTION',
      sessionId,
      action: 'execute_arbitrary_code',
    }, sessionId)).toBe(false);
    expect(isUiAttestationMessage({
      type: UI_REGISTER_CAPABILITY,
      sessionId,
      nonce: 'too-short',
    })).toBe(false);
    expect(isUiAttestationMessage({
      type: UI_CLAIM_CAPABILITY,
      sessionId,
      nonce,
    })).toBe(true);
  });
});
