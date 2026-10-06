export const PROTOCOL_VERSION = 1;
export const MAX_FRAME_BYTES = 8 * 1024 * 1024;
export const MAX_IMAGE_DATA_URL_BYTES = MAX_FRAME_BYTES - 2048;
export const MAX_NATIVE_FRAME_BYTES = 64 * 1024;
export const MAX_FOLLOWUP_LENGTH = 4000;
export const MAX_ANSWER_LENGTH = 16_000;
export const MAX_GEOMETRY_MAGNITUDE = 1_000_000;
// Fixed OS identifiers such as `com.apple.keylayout.US`; the host replaces anything else with `other`.
const TELEMETRY_TOKEN = /^[A-Za-z0-9_.-]{1,120}$/;

function record(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function shape(value, required, optional = []) {
  return record(value)
    && required.every(key => Object.hasOwn(value, key))
    && Object.keys(value).every(key => required.includes(key) || optional.includes(key));
}

function text(value, max) {
  return typeof value === 'string' && value.length > 0 && value.length <= max;
}

export function isSessionId(value) {
  return typeof value === 'string' && /^[A-Za-z0-9_-]{1,80}$/.test(value);
}

export function isNormalizedRect(value) {
  return shape(value, ['x', 'y', 'width', 'height'])
    && Object.values(value).every(Number.isFinite)
    && value.x >= 0 && value.y >= 0
    && value.width > 0 && value.height > 0
    && value.x + value.width <= 1 && value.y + value.height <= 1;
}

function isGeometry(value) {
  return shape(value, ['x', 'y', 'width', 'height'])
    && Object.values(value).every(number => Number.isFinite(number) && Math.abs(number) <= MAX_GEOMETRY_MAGNITUDE)
    && value.width > 0 && value.height > 0;
}

function isTelemetryGeometry(value) {
  const hasFrame = Object.hasOwn(value, 'frame');
  const hasScroll = Object.hasOwn(value, 'scroll');
  const hasSource = Object.hasOwn(value, 'geometrySource');
  if (hasFrame || hasScroll) {
    if (!hasSource || !['baseline', 'notification', 'poll', 'close'].includes(value.geometrySource)) return false;
  } else if (hasSource) return false;
  if (hasFrame && (!isGeometry(value.frame)
    || (!/^(selection|answer|preview)\.(shown|moved|resized|closed|cancelled)$/.test(value.event)
      && value.event !== 'preview.closed_with_parent'))) return false;
  return !hasScroll || (isGeometry(value.scroll) && ['answer.shown', 'answer.scroll_changed'].includes(value.event));
}

function isImageDataUrl(value) {
  if (typeof value !== 'string' || value.length > MAX_IMAGE_DATA_URL_BYTES) return false;
  const header = /^data:image\/(?:png|jpeg);base64,/.exec(value);
  if (!header) return false;
  const payload = value.slice(header[0].length);
  return payload.length > 0 && payload.length % 4 === 0 && /^[A-Za-z0-9+/]+={0,2}$/.test(payload);
}

export function serializedBytes(value) {
  return new TextEncoder().encode(JSON.stringify(value)).length;
}

export function isExtensionMessage(value) {
  if (!record(value) || value.version !== PROTOCOL_VERSION) return false;
  switch (value.type) {
    case 'hello':
    case 'shutdown':
      return shape(value, ['version', 'type']);
    case 'capture':
      return shape(value, ['version', 'type', 'sessionId', 'imageDataUrl'])
        && isSessionId(value.sessionId) && isImageDataUrl(value.imageDataUrl)
        && serializedBytes(value) <= MAX_FRAME_BYTES;
    case 'answer':
      return shape(value, ['version', 'type', 'sessionId', 'text', 'done'])
        && isSessionId(value.sessionId) && typeof value.text === 'string'
        && value.text.length <= MAX_ANSWER_LENGTH && typeof value.done === 'boolean';
    case 'reset':
      return shape(value, ['version', 'type', 'sessionId']) && isSessionId(value.sessionId);
    default:
      return false;
  }
}

export function isNativeMessage(value) {
  if (!record(value) || value.version !== PROTOCOL_VERSION) return false;
  switch (value.type) {
    case 'hello':
      return shape(value, ['version', 'type', 'pid'])
        && Number.isInteger(value.pid) && value.pid > 0 && value.pid <= 2147483647;
    case 'selected':
      return shape(value, ['version', 'type', 'sessionId', 'rect'])
        && isSessionId(value.sessionId) && isNormalizedRect(value.rect);
    case 'followup':
      return shape(value, ['version', 'type', 'sessionId', 'text'])
        && isSessionId(value.sessionId) && text(value.text, MAX_FOLLOWUP_LENGTH)
        && value.text.trim().length > 0;
    case 'closed':
    case 'cancelled':
      return shape(value, ['version', 'type', 'sessionId']) && isSessionId(value.sessionId);
    case 'telemetry':
      return shape(value, ['version', 'type', 'event', 'at', 'appActive', 'keyWindow'], ['sessionId', 'frame', 'scroll', 'geometrySource', 'inputSource'])
        && text(value.event, 80) && /^[A-Za-z0-9_.-]+$/.test(value.event)
        && Number.isFinite(value.at) && value.at >= 0
        && typeof value.appActive === 'boolean' && typeof value.keyWindow === 'boolean'
        && (!Object.hasOwn(value, 'sessionId') || isSessionId(value.sessionId))
        && (!Object.hasOwn(value, 'inputSource') || (typeof value.inputSource === 'string' && TELEMETRY_TOKEN.test(value.inputSource)))
        && isTelemetryGeometry(value);
    default:
      return false;
  }
}
