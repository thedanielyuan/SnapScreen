import { describe, expect, it } from 'vitest';
import {
  isExtensionToNativeMessage,
  isNativeToExtensionMessage,
  isNormalizedRect,
  MAX_IMAGE_DATA_URL_BYTES,
  MAX_NATIVE_ANSWER_LENGTH,
  MAX_NATIVE_INPUT_LENGTH,
  NATIVE_PROTOCOL_VERSION,
} from './native-protocol';

const base = { version: NATIVE_PROTOCOL_VERSION, connectionId: 'connection-1' };
const session = { ...base, sessionId: 'session-1', requestId: 'request-1' };
const imageDataUrl = 'data:image/png;base64,aGVsbG8=';
const rect = { x: 0.1, y: 0.2, width: 0.4, height: 0.5 };
const extensionMessages = [
  { ...base, type: 'hello' },
  { ...session, type: 'capture', imageDataUrl },
  { ...session, type: 'accepted', imageDataUrl, maxInputCharacters: 4_000 },
  { ...session, type: 'started' },
  { ...session, type: 'thinking' },
  { ...session, type: 'answer', text: 'answer', status: 'streaming' },
  { ...session, type: 'answer', text: 'answer', status: 'done' },
  { ...session, type: 'answer', text: '', status: 'stopped' },
  { ...session, type: 'error', code: 'request_failed', message: 'Try again.' },
  { ...session, type: 'notice', message: '2 older conversation turns were removed.' },
  { ...session, type: 'expired', message: 'Start a new snip.' },
];
const nativeMessages = [
  { ...base, type: 'ready' },
  { ...session, type: 'selected', rect },
  { ...session, type: 'followup', text: 'Why?' },
  ...['stop', 'retry', 'close', 'cancelled'].map(type => ({ ...session, type })),
];

describe('native protocol', () => {
  it('accepts every extension and native message variant', () => {
    for (const message of extensionMessages) expect(isExtensionToNativeMessage(message)).toBe(true);
    for (const message of nativeMessages) expect(isNativeToExtensionMessage(message)).toBe(true);
  });

  it('does not accept messages in the opposite direction', () => {
    for (const message of extensionMessages) expect(isNativeToExtensionMessage(message)).toBe(false);
    for (const message of nativeMessages) expect(isExtensionToNativeMessage(message)).toBe(false);
  });

  it('rejects unknown, missing, inherited, and extra fields for every variant', () => {
    for (const [messages, validate] of [
      [extensionMessages, isExtensionToNativeMessage],
      [nativeMessages, isNativeToExtensionMessage],
    ] as const) {
      for (const message of messages) {
        expect(validate({ ...message, apiKey: 'forbidden' })).toBe(false);
        expect(validate({ ...message, type: 'unknown' })).toBe(false);
        for (const key of Object.keys(message)) {
          const missing: Record<string, unknown> = { ...message };
          delete missing[key];
          expect(validate(missing)).toBe(false);
        }
        expect(validate(Object.create(message))).toBe(false);
      }
      for (const value of [undefined, null, [], 2, true, 'ready']) expect(validate(value)).toBe(false);
    }
  });

  it('requires version 2 and bounded opaque connection, session, and request identities', () => {
    for (const validate of [isNativeToExtensionMessage, isExtensionToNativeMessage]) {
      const type = validate === isNativeToExtensionMessage ? 'stop' : 'started';
      for (const version of [undefined, 1, 3, '2', 2.1]) {
        expect(validate({ ...session, type, version })).toBe(false);
      }
      for (const field of ['connectionId', 'sessionId', 'requestId']) {
        for (const invalid of ['', 'a'.repeat(81), 'has space', 'a/b', 'é', 'id\n', 'id\r', 'id\u2028', 'id\u2029', 1, null]) {
          expect(validate({ ...session, type, [field]: invalid })).toBe(false);
        }
        expect(validate({ ...session, type, [field]: 'a_B-0'.repeat(16) })).toBe(true);
      }
    }
  });

  it('accepts only the handshake fields in hello and ready', () => {
    expect(isExtensionToNativeMessage({ ...session, type: 'hello' })).toBe(false);
    expect(isNativeToExtensionMessage({ ...session, type: 'ready' })).toBe(false);
  });

  it('requires finite normalized, positive crop rectangles with exact fields', () => {
    expect(isNormalizedRect({ x: 0, y: 0, width: 1, height: 1 })).toBe(true);
    for (const invalid of [
      null,
      [],
      { ...rect, x: -0.1 },
      { ...rect, y: -0.1 },
      { ...rect, x: 0.8 },
      { ...rect, y: 0.8 },
      { ...rect, width: 0 },
      { ...rect, height: -1 },
      { ...rect, width: NaN },
      { ...rect, x: Infinity },
      { ...rect, height: '0.5' },
      { ...rect, tabId: 9 },
    ]) {
      expect(isNormalizedRect(invalid)).toBe(false);
      expect(isNativeToExtensionMessage({ ...session, type: 'selected', rect: invalid })).toBe(false);
    }
  });

  it('requires bounded PNG base64 data URLs for frozen images and accepted previews', () => {
    for (const type of ['capture', 'accepted']) {
      const message = type === 'accepted'
        ? { ...session, type, maxInputCharacters: 4_000 }
        : { ...session, type };
      for (const invalid of [
        '',
        'data:image/jpeg;base64,aGVsbG8=',
        'https://example.com/image.png',
        'data:image/png;base64,',
        'data:image/png;base64,aaaaa',
        'data:image/png;base64,aaa!',
        'data:image/png;base64,====',
        'data:image/png;base64,a===',
        'data:image/png;base64,aa=a',
        'data:image/png;base64,aaaa\n',
        'data:image/png;base64,aaa\n',
        'data:image/png;base64,aaa\r',
        'data:image/png;base64,aaa\u2028',
        'data:image/png;base64,aaa\u2029',
      ]) expect(isExtensionToNativeMessage({ ...message, imageDataUrl: invalid })).toBe(false);
    }
    const prefix = 'data:image/png;base64,';
    const longestPayload = 'a'.repeat(Math.floor((MAX_IMAGE_DATA_URL_BYTES - prefix.length) / 4) * 4);
    expect(isExtensionToNativeMessage({ ...session, type: 'capture', imageDataUrl: prefix + longestPayload })).toBe(true);
    expect(isExtensionToNativeMessage({ ...session, type: 'capture', imageDataUrl: prefix + longestPayload + 'aaaa' })).toBe(false);
  });

  it('bounds UTF-16 answer and follow-up lengths and rejects empty questions', () => {
    const answer = { ...session, type: 'answer', status: 'done' };
    expect(isExtensionToNativeMessage({ ...answer, text: 'a'.repeat(MAX_NATIVE_ANSWER_LENGTH) })).toBe(true);
    expect(isExtensionToNativeMessage({ ...answer, text: 'a'.repeat(MAX_NATIVE_ANSWER_LENGTH + 1) })).toBe(false);
    expect(isExtensionToNativeMessage({ ...answer, text: '😀'.repeat(MAX_NATIVE_ANSWER_LENGTH / 2 + 1) })).toBe(false);
    expect(isExtensionToNativeMessage({ ...answer, text: 'hello', status: 'failed' })).toBe(false);
    const followup = { ...session, type: 'followup' };
    expect(isNativeToExtensionMessage({ ...followup, text: 'a'.repeat(MAX_NATIVE_INPUT_LENGTH) })).toBe(true);
    expect(isNativeToExtensionMessage({ ...followup, text: '\u0000'.repeat(MAX_NATIVE_INPUT_LENGTH) })).toBe(true);
    expect(isNativeToExtensionMessage({ ...followup, text: 'a'.repeat(MAX_NATIVE_INPUT_LENGTH + 1) })).toBe(false);
    for (const text of ['', ' \t\n ', 12, null]) {
      expect(isNativeToExtensionMessage({ ...followup, text })).toBe(false);
    }
  });

  it('bounds the offered input limit, error codes, and displayed error text', () => {
    for (const maxInputCharacters of [0, -1, 1.1, Infinity, 50_001, '4000']) {
      expect(isExtensionToNativeMessage({ ...session, type: 'accepted', imageDataUrl, maxInputCharacters })).toBe(false);
    }
    expect(isExtensionToNativeMessage({ ...session, type: 'accepted', imageDataUrl, maxInputCharacters: 50_000 })).toBe(true);
    expect(isExtensionToNativeMessage({ ...session, type: 'error', code: 'bad code', message: 'Try again.' })).toBe(false);
    expect(isExtensionToNativeMessage({ ...session, type: 'error', code: 'bad\n', message: 'Try again.' })).toBe(false);
    for (const type of ['error', 'notice', 'expired']) {
      const message = type === 'error' ? { ...session, type, code: 'request_failed' } : { ...session, type };
      expect(isExtensionToNativeMessage({ ...message, message: 'a'.repeat(1_024) })).toBe(true);
      for (const text of ['', ' ', 'a'.repeat(1_025)]) {
        expect(isExtensionToNativeMessage({ ...message, message: text })).toBe(false);
      }
    }
  });
});
