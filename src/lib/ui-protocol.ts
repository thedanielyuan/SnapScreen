import type { CaptureSelection, DisplayMessage, Rect } from './messages';

export const UI_FRAME_PATH = 'src/ui/result-frame.html';
export const UI_CONNECT_MESSAGE = 'SNAPSCREEN_UI_CONNECT' as const;
export const UI_READY_MESSAGE = 'SNAPSCREEN_UI_READY' as const;
export const UI_REGISTER_CAPABILITY = 'SNAPSCREEN_UI_REGISTER_CAPABILITY' as const;
export const UI_CLAIM_CAPABILITY = 'SNAPSCREEN_UI_CLAIM_CAPABILITY' as const;
export const UI_REVOKE_CAPABILITY = 'SNAPSCREEN_UI_REVOKE_CAPABILITY' as const;

const MAX_PROTOCOL_TEXT = 2_000_000;
const MAX_SCREENSHOT_DATA_URL = 32_000_000;
const MAX_PROTOCOL_MESSAGES = 200;

export type UiPanelAction =
  | 'close'
  | 'open_settings'
  | 'remove_failed'
  | 'resnip'
  | 'retry'
  | 'retry_failed'
  | 'stop';

export interface SerializedResultPanelState {
  anchorRect?: Rect;
  canRemoveFailedAnswer: boolean;
  canResnip: boolean;
  canRetry: boolean;
  canRetryFailedAnswer: boolean;
  canStop: boolean;
  dataUrl?: string;
  error?: string;
  errorCode?: string;
  maxInputCharacters?: number;
  messages: DisplayMessage[];
  pending: boolean;
  pendingSince?: number;
  thinking: boolean;
}

export type ControllerToFrameMessage =
  | {
      type: 'SNAPSCREEN_UI_START_SNIP';
      sessionId: string;
      dataUrl: string;
      imageFit?: 'contain' | 'fill';
    }
  | { type: 'SNAPSCREEN_UI_DISPOSE_SNIP'; sessionId: string }
  | {
      type: 'SNAPSCREEN_UI_RENDER_RESULT';
      sessionId: string;
      state: SerializedResultPanelState;
    }
  | {
      type: 'SNAPSCREEN_UI_UPDATE_STREAM';
      sessionId: string;
      text: string;
    }
  | { type: 'SNAPSCREEN_UI_SHOW_THINKING'; sessionId: string }
  | {
      type: 'SNAPSCREEN_UI_SHOW_TOAST';
      sessionId: string;
      message: string;
    }
  | { type: 'SNAPSCREEN_UI_DISPOSE_RESULT'; sessionId: string }
  | { type: 'SNAPSCREEN_UI_DISPOSE_ALL'; sessionId: string };

export type FrameToControllerMessage =
  | { type: typeof UI_READY_MESSAGE; sessionId: string }
  | {
      type: 'SNAPSCREEN_UI_REGION_SELECTED';
      sessionId: string;
      selection: CaptureSelection;
    }
  | { type: 'SNAPSCREEN_UI_SNIP_CANCELLED'; sessionId: string }
  | {
      type: 'SNAPSCREEN_UI_FOLLOW_UP';
      sessionId: string;
      text: string;
    }
  | {
      type: 'SNAPSCREEN_UI_ACTION';
      sessionId: string;
      action: UiPanelAction;
    };

export interface UiBootstrapMessage {
  type: typeof UI_CONNECT_MESSAGE;
  sessionId: string;
  nonce: string;
}

export type UiAttestationMessage =
  | {
      type: typeof UI_REGISTER_CAPABILITY;
      sessionId: string;
      nonce: string;
    }
  | {
      type: typeof UI_CLAIM_CAPABILITY;
      sessionId: string;
      nonce: string;
    }
  | {
      type: typeof UI_REVOKE_CAPABILITY;
      sessionId: string;
    };

export type UiAttestationResponse =
  | { ok: true }
  | { ok: false; error: 'ui_auth_failed' };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isBoundedString(value: unknown, max = MAX_PROTOCOL_TEXT): value is string {
  return typeof value === 'string' && value.length <= max;
}

function isSessionId(value: unknown): value is string {
  return isBoundedString(value, 200) && value.length > 0;
}

function isUiNonce(value: unknown): value is string {
  return typeof value === 'string' && /^[A-Za-z0-9_-]{43}$/u.test(value);
}

function isOptionalBoundedString(value: unknown, max = MAX_PROTOCOL_TEXT): boolean {
  return value === undefined || isBoundedString(value, max);
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value);
}

function isRect(value: unknown): value is Rect {
  if (!isRecord(value)) return false;
  return isFiniteNumber(value.x)
    && isFiniteNumber(value.y)
    && isFiniteNumber(value.width)
    && isFiniteNumber(value.height)
    && value.width >= 0
    && value.height >= 0;
}

function isNormalizedRect(value: unknown): value is Rect {
  return isRect(value)
    && value.x >= 0
    && value.y >= 0
    && value.width > 0
    && value.height > 0
    && value.x + value.width <= 1
    && value.y + value.height <= 1;
}

function isCaptureSelection(value: unknown): value is CaptureSelection {
  return isRecord(value)
    && isRect(value.viewportRect)
    && isNormalizedRect(value.normalizedRect);
}

function isDisplayMessage(value: unknown): value is DisplayMessage {
  if (!isRecord(value)) return false;
  return (value.role === 'user' || value.role === 'assistant')
    && isBoundedString(value.content)
    && (value.status === undefined || value.status === 'failed');
}

function isPanelAction(value: unknown): value is UiPanelAction {
  return value === 'close'
    || value === 'open_settings'
    || value === 'remove_failed'
    || value === 'resnip'
    || value === 'retry'
    || value === 'retry_failed'
    || value === 'stop';
}

function isSerializedResultPanelState(value: unknown): value is SerializedResultPanelState {
  if (!isRecord(value) || !Array.isArray(value.messages)) return false;
  return value.messages.length <= MAX_PROTOCOL_MESSAGES
    && value.messages.every(isDisplayMessage)
    && typeof value.pending === 'boolean'
    && typeof value.thinking === 'boolean'
    && (
      value.pendingSince === undefined
      || (isFiniteNumber(value.pendingSince) && value.pendingSince >= 0)
    )
    && typeof value.canStop === 'boolean'
    && typeof value.canRetry === 'boolean'
    && typeof value.canResnip === 'boolean'
    && typeof value.canRetryFailedAnswer === 'boolean'
    && typeof value.canRemoveFailedAnswer === 'boolean'
    && isOptionalBoundedString(value.dataUrl, 16_000_000)
    && isOptionalBoundedString(value.error, 10_000)
    && isOptionalBoundedString(value.errorCode, 200)
    && (value.anchorRect === undefined || isRect(value.anchorRect))
    && (
      value.maxInputCharacters === undefined
      || (Number.isInteger(value.maxInputCharacters) && (value.maxInputCharacters as number) > 0)
    );
}

export function isUiBootstrapMessage(value: unknown): value is UiBootstrapMessage {
  if (!isRecord(value)) return false;
  return value.type === UI_CONNECT_MESSAGE
    && isSessionId(value.sessionId)
    && isUiNonce(value.nonce);
}

export function isUiAttestationMessage(value: unknown): value is UiAttestationMessage {
  if (!isRecord(value) || !isSessionId(value.sessionId)) return false;
  switch (value.type) {
    case UI_REGISTER_CAPABILITY:
    case UI_CLAIM_CAPABILITY:
      return isUiNonce(value.nonce);
    case UI_REVOKE_CAPABILITY:
      return true;
    default:
      return false;
  }
}

export function isUiAttestationSuccess(value: unknown): value is { ok: true } {
  return isRecord(value) && value.ok === true;
}

export function isControllerToFrameMessage(
  value: unknown,
  expectedSessionId?: string,
): value is ControllerToFrameMessage {
  if (!isRecord(value) || !isSessionId(value.sessionId)) return false;
  if (expectedSessionId !== undefined && value.sessionId !== expectedSessionId) return false;

  switch (value.type) {
    case 'SNAPSCREEN_UI_DISPOSE_SNIP':
    case 'SNAPSCREEN_UI_DISPOSE_RESULT':
    case 'SNAPSCREEN_UI_DISPOSE_ALL':
    case 'SNAPSCREEN_UI_SHOW_THINKING':
      return true;
    case 'SNAPSCREEN_UI_START_SNIP':
      return isBoundedString(value.dataUrl, MAX_SCREENSHOT_DATA_URL)
        && value.dataUrl.startsWith('data:image/png;base64,')
        && (
          value.imageFit === undefined
          || value.imageFit === 'contain'
          || value.imageFit === 'fill'
        );
    case 'SNAPSCREEN_UI_RENDER_RESULT':
      return isSerializedResultPanelState(value.state);
    case 'SNAPSCREEN_UI_UPDATE_STREAM':
      return isBoundedString(value.text);
    case 'SNAPSCREEN_UI_SHOW_TOAST':
      return isBoundedString(value.message, 10_000);
    default:
      return false;
  }
}

export function isFrameToControllerMessage(
  value: unknown,
  expectedSessionId?: string,
): value is FrameToControllerMessage {
  if (!isRecord(value) || !isSessionId(value.sessionId)) return false;
  if (expectedSessionId !== undefined && value.sessionId !== expectedSessionId) return false;

  switch (value.type) {
    case UI_READY_MESSAGE:
    case 'SNAPSCREEN_UI_SNIP_CANCELLED':
      return true;
    case 'SNAPSCREEN_UI_REGION_SELECTED':
      return isCaptureSelection(value.selection);
    case 'SNAPSCREEN_UI_FOLLOW_UP':
      return isBoundedString(value.text, 100_000);
    case 'SNAPSCREEN_UI_ACTION':
      return isPanelAction(value.action);
    default:
      return false;
  }
}

export class UiBootstrapGate {
  readonly #sessionId: string;
  readonly #nonce: string;
  #accepted = false;

  constructor(sessionId: string, nonce: string) {
    this.#sessionId = sessionId;
    this.#nonce = nonce;
  }

  accept(value: unknown): value is UiBootstrapMessage {
    if (this.#accepted || !isUiBootstrapMessage(value)) return false;
    if (value.sessionId !== this.#sessionId || value.nonce !== this.#nonce) return false;
    this.#accepted = true;
    return true;
  }
}

export class UiCommandBuffer {
  #disposed = false;
  #ready = false;
  #pending: ControllerToFrameMessage[] = [];
  readonly #post: (message: ControllerToFrameMessage) => void;

  constructor(post: (message: ControllerToFrameMessage) => void) {
    this.#post = post;
  }

  enqueue(message: ControllerToFrameMessage): boolean {
    if (this.#disposed) return false;
    if (this.#ready) {
      this.#post(message);
    } else {
      this.#pending.push(message);
    }
    return true;
  }

  markReady(): void {
    if (this.#disposed || this.#ready) return;
    this.#ready = true;
    const pending = this.#pending;
    this.#pending = [];
    for (const message of pending) this.#post(message);
  }

  dispose(): void {
    this.#disposed = true;
    this.#pending = [];
  }

  get isReady(): boolean {
    return this.#ready && !this.#disposed;
  }
}
