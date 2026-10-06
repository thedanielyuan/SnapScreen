import type { Rect } from './messages';

export const NATIVE_HOST_NAME = 'com.snapscreen.companion';
export const NATIVE_PROTOCOL_VERSION = 3;
export const MAX_NATIVE_FRAME_BYTES = 512 * 1024;
export const MAX_EXTENSION_FRAME_BYTES = 32 * 1024 * 1024;
export const MAX_IMAGE_DATA_URL_BYTES = 24 * 1024 * 1024;
export const MAX_NATIVE_ANSWER_LENGTH = 262_144;
export const MAX_NATIVE_INPUT_LENGTH = 50_000;
/** Bounds a notice's count of conversation turns removed before a request. */
export const MAX_NATIVE_REMOVED_TURNS = 1_000;

const MAX_ERROR_MESSAGE_LENGTH = 1_024;
const BASE_KEYS = ['version', 'type', 'connectionId'];
const SESSION_KEYS = [...BASE_KEYS, 'sessionId', 'requestId'];
const PNG_PREFIX = 'data:image/png;base64,';

interface NativeEnvelope {
  version: typeof NATIVE_PROTOCOL_VERSION;
  connectionId: string;
}

interface NativeSessionEnvelope extends NativeEnvelope {
  sessionId: string;
  requestId: string;
}

export type ExtensionToNativeMessage =
  | (NativeEnvelope & { type: 'hello' })
  | (NativeSessionEnvelope & { type: 'capture'; imageDataUrl: string })
  | (NativeSessionEnvelope & {
      type: 'accepted';
      imageDataUrl: string;
      maxInputCharacters: number;
    })
  | (NativeSessionEnvelope & { type: 'started' | 'thinking' })
  | (NativeSessionEnvelope & {
      type: 'answer';
      text: string;
      status: 'streaming' | 'done' | 'stopped';
    })
  | (NativeSessionEnvelope & { type: 'error'; code: string; message: string })
  | (NativeSessionEnvelope & { type: 'notice'; message: string; removedTurns: number })
  | (NativeSessionEnvelope & { type: 'expired'; message: string });

export type NativeToExtensionMessage =
  | (NativeEnvelope & { type: 'ready' })
  | (NativeSessionEnvelope & { type: 'selected'; rect: Rect })
  | (NativeSessionEnvelope & { type: 'followup'; text: string })
  | (NativeSessionEnvelope & { type: 'stop' | 'retry' | 'close' | 'cancelled' });

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function hasKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  return Object.keys(value).length === keys.length
    && keys.every(key => Object.hasOwn(value, key));
}

function isId(value: unknown): value is string {
  return typeof value === 'string' && value.length > 0 && value.length <= 80
    && !/[^A-Za-z0-9_-]/u.test(value);
}

function isText(value: unknown, maximum: number): value is string {
  return typeof value === 'string' && value.length <= maximum;
}

function isNonemptyText(value: unknown, maximum: number): value is string {
  return isText(value, maximum) && value.trim().length > 0;
}

function isImageDataUrl(value: unknown): value is string {
  if (!isText(value, MAX_IMAGE_DATA_URL_BYTES) || !value.startsWith(PNG_PREFIX)) return false;
  const payload = value.slice(PNG_PREFIX.length);
  // A regex `$` also matches before a final newline; require the match to consume every byte.
  const match = /^[A-Za-z0-9+/]+={0,2}$/u.exec(payload);
  return payload.length > 0
    && payload.length % 4 === 0
    && match?.[0].length === payload.length;
}

function isWithinFrameLimit(value: Record<string, unknown>, maximum: number): boolean {
  return new TextEncoder().encode(JSON.stringify(value)).byteLength <= maximum;
}

function isSessionEnvelope(value: Record<string, unknown>): boolean {
  return isId(value.sessionId) && isId(value.requestId);
}

export function isNormalizedRect(value: unknown): value is Rect {
  return isRecord(value)
    && hasKeys(value, ['x', 'y', 'width', 'height'])
    && typeof value.x === 'number' && Number.isFinite(value.x)
    && typeof value.y === 'number' && Number.isFinite(value.y)
    && typeof value.width === 'number' && Number.isFinite(value.width)
    && typeof value.height === 'number' && Number.isFinite(value.height)
    && value.x >= 0 && value.y >= 0
    && value.width > 0 && value.height > 0
    && value.x + value.width <= 1 && value.y + value.height <= 1;
}

export function isExtensionToNativeMessage(value: unknown): value is ExtensionToNativeMessage {
  if (!isRecord(value) || value.version !== NATIVE_PROTOCOL_VERSION || !isId(value.connectionId)) {
    return false;
  }
  if (value.type === 'hello') return hasKeys(value, BASE_KEYS);
  if (!isSessionEnvelope(value)) return false;

  let valid: boolean;
  switch (value.type) {
    case 'capture':
      valid = hasKeys(value, [...SESSION_KEYS, 'imageDataUrl']) && isImageDataUrl(value.imageDataUrl);
      break;
    case 'accepted':
      valid = hasKeys(value, [...SESSION_KEYS, 'imageDataUrl', 'maxInputCharacters'])
        && isImageDataUrl(value.imageDataUrl)
        && typeof value.maxInputCharacters === 'number'
        && Number.isInteger(value.maxInputCharacters)
        && value.maxInputCharacters > 0
        && value.maxInputCharacters <= MAX_NATIVE_INPUT_LENGTH;
      break;
    case 'started':
    case 'thinking':
      valid = hasKeys(value, SESSION_KEYS);
      break;
    case 'answer':
      valid = hasKeys(value, [...SESSION_KEYS, 'text', 'status'])
        && isText(value.text, MAX_NATIVE_ANSWER_LENGTH)
        && (value.status === 'streaming' || value.status === 'done' || value.status === 'stopped');
      break;
    case 'error':
      valid = hasKeys(value, [...SESSION_KEYS, 'code', 'message'])
        && isId(value.code)
        && isNonemptyText(value.message, MAX_ERROR_MESSAGE_LENGTH);
      break;
    case 'notice':
      valid = hasKeys(value, [...SESSION_KEYS, 'message', 'removedTurns'])
        && isNonemptyText(value.message, MAX_ERROR_MESSAGE_LENGTH)
        && typeof value.removedTurns === 'number'
        && Number.isInteger(value.removedTurns)
        && value.removedTurns >= 0
        && value.removedTurns <= MAX_NATIVE_REMOVED_TURNS;
      break;
    case 'expired':
      valid = hasKeys(value, [...SESSION_KEYS, 'message'])
        && isNonemptyText(value.message, MAX_ERROR_MESSAGE_LENGTH);
      break;
    default:
      return false;
  }
  return valid && isWithinFrameLimit(value, MAX_EXTENSION_FRAME_BYTES);
}

export function isNativeToExtensionMessage(value: unknown): value is NativeToExtensionMessage {
  if (!isRecord(value) || value.version !== NATIVE_PROTOCOL_VERSION || !isId(value.connectionId)) {
    return false;
  }
  if (value.type === 'ready') return hasKeys(value, BASE_KEYS);
  if (!isSessionEnvelope(value)) return false;

  let valid: boolean;
  switch (value.type) {
    case 'selected':
      valid = hasKeys(value, [...SESSION_KEYS, 'rect']) && isNormalizedRect(value.rect);
      break;
    case 'followup':
      valid = hasKeys(value, [...SESSION_KEYS, 'text'])
        && isNonemptyText(value.text, MAX_NATIVE_INPUT_LENGTH);
      break;
    case 'stop':
    case 'retry':
    case 'close':
    case 'cancelled':
      valid = hasKeys(value, SESSION_KEYS);
      break;
    default:
      return false;
  }
  return valid && isWithinFrameLimit(value, MAX_NATIVE_FRAME_BYTES);
}
