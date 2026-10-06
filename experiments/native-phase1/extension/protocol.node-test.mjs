import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import test from 'node:test';
import { EXTENSION_ID, EXTENSION_KEY, manifest } from './config.mjs';
import {
  MAX_ANSWER_LENGTH,
  MAX_FOLLOWUP_LENGTH,
  MAX_FRAME_BYTES,
  MAX_GEOMETRY_MAGNITUDE,
  MAX_IMAGE_DATA_URL_BYTES,
  isExtensionMessage,
  isNativeMessage,
  isNormalizedRect,
  serializedBytes,
} from './protocol.mjs';

const sessionId = '9a581869-efcb-45f3-b67b-fd6347283e54';
const session = { version: 1, sessionId };
const rect = { x: 0.1, y: 0.2, width: 0.5, height: 0.5 };
const imageDataUrl = 'data:image/png;base64,aW1hZ2U=';

test('test build has a stable key-derived ID and only the two experimental permissions', () => {
  const id = createHash('sha256').update(Buffer.from(EXTENSION_KEY, 'base64')).digest('hex').slice(0, 32)
    .replace(/[0-9a-f]/g, digit => String.fromCharCode(97 + parseInt(digit, 16)));
  assert.equal(id, EXTENSION_ID);
  assert.deepEqual(manifest.permissions, ['activeTab', 'nativeMessaging']);
  for (const forbidden of ['content_scripts', 'host_permissions', 'web_accessible_resources', 'options_page', 'options_ui']) {
    assert.equal(Object.hasOwn(manifest, forbidden), false);
  }
  assert.equal(manifest.commands._execute_action.suggested_key.mac, 'Alt+Shift+S');
});

test('native input accepts every defined discriminant and rejects protocol or shape changes', () => {
  const messages = [
    { version: 1, type: 'hello', pid: 100 },
    { ...session, type: 'selected', rect },
    { ...session, type: 'followup', text: 'A sample question' },
    { ...session, type: 'closed' },
    { ...session, type: 'cancelled' },
    { ...session, type: 'telemetry', event: 'panel_shown', at: 100, appActive: false, keyWindow: true },
    { version: 1, type: 'telemetry', event: 'host_ready', at: 100, appActive: false, keyWindow: false },
  ];
  for (const message of messages) {
    assert.equal(isNativeMessage(message), true, message.type);
    assert.equal(isNativeMessage({ ...message, version: 2 }), false);
    assert.equal(isNativeMessage({ ...message, extra: 'unexpected' }), false);
    for (const key of Object.keys(message)) {
      const missing = { ...message };
      delete missing[key];
      if (key !== 'sessionId' || message.type !== 'telemetry') assert.equal(isNativeMessage(missing), false, `${message.type} missing ${key}`);
    }
  }
  for (const value of [null, [], 'hello', {}, { version: 1, type: 'capture', sessionId, imageDataUrl }]) {
    assert.equal(isNativeMessage(value), false);
  }
});

test('outbound messages are bounded and discriminate shutdown/reset from capture', () => {
  for (const message of [
    { version: 1, type: 'hello' },
    { version: 1, type: 'shutdown' },
    { ...session, type: 'capture', imageDataUrl },
    { ...session, type: 'answer', text: 'Chunk', done: false },
    { ...session, type: 'answer', text: '', done: true },
    { ...session, type: 'reset' },
  ]) {
    assert.equal(isExtensionMessage(message), true, message.type);
    assert.equal(isExtensionMessage({ ...message, extra: true }), false);
    assert.equal(isExtensionMessage({ ...message, version: 0 }), false);
  }
  assert.equal(isExtensionMessage({ version: 1, type: 'reset' }), false);
  assert.equal(isExtensionMessage({ ...session, type: 'answer', text: 'x'.repeat(MAX_ANSWER_LENGTH + 1), done: false }), false);
  assert.equal(isExtensionMessage({ ...session, type: 'answer', text: 'x', done: 'yes' }), false);
});

test('rectangles are finite, nonempty, and entirely inside the image', () => {
  assert.equal(isNormalizedRect(rect), true);
  assert.equal(isNormalizedRect({ x: 0, y: 0, width: 1, height: 1 }), true);
  for (const invalid of [
    { ...rect, x: -0.1 }, { ...rect, width: 0 }, { ...rect, height: -0.1 },
    { ...rect, x: 0.6 }, { ...rect, y: 0.6 }, { ...rect, x: NaN },
    { ...rect, y: Infinity }, { ...rect, width: '0.1' }, { ...rect, extra: 0 },
    null, [],
  ]) assert.equal(isNormalizedRect(invalid), false);
});

test('screenshot payloads reject incorrect encoding and remain below the native frame cap', () => {
  for (const invalid of [
    'https://example.com/image.png', 'data:text/plain;base64,aW1hZ2U=',
    'data:image/png;base64,', 'data:image/png;base64,aW1hZ2U',
    'data:image/png;base64,aW1h=2U=', 'data:image/png;base64,AAAA\nAAA',
  ]) assert.equal(isExtensionMessage({ ...session, type: 'capture', imageDataUrl: invalid }), false);
  const prefix = 'data:image/png;base64,';
  const largest = prefix + 'A'.repeat(Math.floor((MAX_IMAGE_DATA_URL_BYTES - prefix.length) / 4) * 4);
  const message = { ...session, type: 'capture', imageDataUrl: largest };
  assert.equal(isExtensionMessage(message), true);
  assert.ok(serializedBytes(message) < MAX_FRAME_BYTES);
  assert.equal(isExtensionMessage({ ...message, imageDataUrl: `${largest}AAAA` }), false);
});

test('session identifiers and untrusted text are bounded and telemetry cannot carry payload fields', () => {
  for (const badId of ['', '../source', 'a'.repeat(81), 123, 'session\n']) {
    assert.equal(isNativeMessage({ ...session, sessionId: badId, type: 'closed' }), false);
    assert.equal(isExtensionMessage({ ...session, sessionId: badId, type: 'reset' }), false);
  }
  for (const text of ['', '   ', 'x'.repeat(MAX_FOLLOWUP_LENGTH + 1), null]) {
    assert.equal(isNativeMessage({ ...session, type: 'followup', text }), false);
  }
  const telemetry = { version: 1, type: 'telemetry', event: 'copy', at: 10, appActive: false, keyWindow: false };
  assert.equal(isNativeMessage({ ...telemetry, text: 'private' }), false);
  assert.equal(isNativeMessage({ ...telemetry, imageDataUrl }), false);
  assert.equal(isNativeMessage({ ...telemetry, event: 'user wrote: private' }), false);
  assert.equal(isNativeMessage({ ...telemetry, at: NaN }), false);
  assert.equal(isNativeMessage({ ...telemetry, appActive: 0 }), false);
  for (const inputSource of ['com.apple.keylayout.US', 'com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese', 'other']) {
    assert.equal(isNativeMessage({ ...telemetry, inputSource }), true, inputSource);
  }
  for (const inputSource of ['', 'user wrote: private', 'x'.repeat(121), 42, null, 'com.apple.keylayout.US\n']) {
    assert.equal(isNativeMessage({ ...telemetry, inputSource }), false, String(inputSource));
  }
});

test('geometry telemetry accepts only exact numeric records on the documented events', () => {
  const telemetry = { ...session, type: 'telemetry', event: 'answer.shown', at: 10, appActive: false, keyWindow: true };
  const frame = { x: -1728, y: 20.5, width: 640, height: 520 };
  const scroll = { x: -0.5, y: 130.25, width: 610, height: 350 };
  assert.equal(isNativeMessage({ ...telemetry, frame, scroll, geometrySource: 'baseline' }), true);
  assert.equal(isNativeMessage({ ...telemetry, frame: { x: -MAX_GEOMETRY_MAGNITUDE, y: MAX_GEOMETRY_MAGNITUDE, width: MAX_GEOMETRY_MAGNITUDE, height: 1 }, geometrySource: 'baseline' }), true);
  for (const surface of ['selection', 'answer', 'preview']) {
    for (const suffix of ['shown', 'moved', 'resized', 'closed', 'cancelled']) {
      assert.equal(isNativeMessage({ ...telemetry, event: `${surface}.${suffix}`, frame, geometrySource: 'notification' }), true);
    }
  }
  assert.equal(isNativeMessage({ ...telemetry, event: 'preview.closed_with_parent', frame, geometrySource: 'close' }), true);
  for (const geometrySource of ['notification', 'poll', 'close']) {
    assert.equal(isNativeMessage({ ...telemetry, event: 'answer.scroll_changed', scroll, geometrySource }), true);
  }
  for (const invalid of [
    null, [], { x: 0, y: 0, width: 100 },
    { ...frame, x: 'private' }, { ...frame, y: Infinity }, { ...frame, width: NaN },
    { ...frame, height: 0 }, { ...frame, width: -1 }, { ...frame, text: 'private' },
    { ...frame, x: -MAX_GEOMETRY_MAGNITUDE - 1 }, { ...frame, y: MAX_GEOMETRY_MAGNITUDE + 1 },
    { ...frame, width: MAX_GEOMETRY_MAGNITUDE + 1 }, { ...frame, height: MAX_GEOMETRY_MAGNITUDE + 1 },
    { ...frame, imageDataUrl }, { ...frame, title: 'private' },
  ]) {
    assert.equal(isNativeMessage({ ...telemetry, frame: invalid, geometrySource: 'baseline' }), false);
    assert.equal(isNativeMessage({ ...telemetry, scroll: invalid, geometrySource: 'baseline' }), false);
  }
  assert.equal(isNativeMessage({ ...telemetry, frame }), false);
  assert.equal(isNativeMessage({ ...telemetry, frame, geometrySource: 'user-entered-text' }), false);
  assert.equal(isNativeMessage({ ...telemetry, geometrySource: 'baseline' }), false);
  assert.equal(isNativeMessage({ ...telemetry, event: 'answer.copied', frame, geometrySource: 'notification' }), false);
  assert.equal(isNativeMessage({ ...telemetry, event: 'preview.shown', scroll, geometrySource: 'baseline' }), false);
  assert.equal(isNativeMessage({ ...telemetry, event: 'answer.scroll_changed', frame, geometrySource: 'poll' }), false);
});
