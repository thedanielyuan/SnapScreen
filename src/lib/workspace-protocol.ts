import type { BgToCsMessage, CsToBgMessage } from './messages';

export const WORKSPACE_PATH = 'src/workspace/workspace.html';
export const WORKSPACE_PORT_NAME = 'SNAPSCREEN_CAPTURE_WORKSPACE';

const MAX_ID_LENGTH = 200;

export type WorkspaceInitialMessage = Extract<BgToCsMessage, { type: 'START_SNIP' }>;

export interface WorkspaceError {
  code: 'capture_expired' | 'file_access_disabled';
  message: string;
}

export type WorkspaceToBackgroundMessage =
  | {
      type: 'SNAPSCREEN_WORKSPACE_CLAIM';
      sessionId: string;
      needsInitialState: boolean;
      nonce?: string;
      reconnectToken?: string;
    }
  | {
      type: 'SNAPSCREEN_WORKSPACE_REQUEST';
      sessionId: string;
      requestId: string;
      message: CsToBgMessage;
    }
  | {
      type: 'SNAPSCREEN_WORKSPACE_CLOSE';
      sessionId: string;
    };

export type BackgroundToWorkspaceMessage =
  | {
      type: 'SNAPSCREEN_WORKSPACE_READY';
      sessionId: string;
      reconnectToken: string;
      initialMessage?: WorkspaceInitialMessage;
      error?: WorkspaceError;
    }
  | {
      type: 'SNAPSCREEN_WORKSPACE_EVENT';
      sessionId: string;
      message: BgToCsMessage;
    }
  | {
      type: 'SNAPSCREEN_WORKSPACE_RESPONSE';
      sessionId: string;
      requestId: string;
      response: unknown;
    };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isId(value: unknown): value is string {
  return typeof value === 'string' && value.length > 0 && value.length <= MAX_ID_LENGTH;
}

function isNonce(value: unknown): value is string {
  return typeof value === 'string' && /^[A-Za-z0-9_-]{43}$/u.test(value);
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value);
}

function isRect(value: unknown, normalized = false): boolean {
  if (!isRecord(value)) return false;
  if (
    !isFiniteNumber(value.x)
    || !isFiniteNumber(value.y)
    || !isFiniteNumber(value.width)
    || !isFiniteNumber(value.height)
    || value.width <= 0
    || value.height <= 0
  ) return false;
  return !normalized || (
    value.x >= 0
    && value.y >= 0
    && value.x + value.width <= 1
    && value.y + value.height <= 1
  );
}

function isLimits(value: unknown): boolean {
  return isRecord(value)
    && isFiniteNumber(value.maxInputCharacters)
    && isFiniteNumber(value.maxScreenshotBytes)
    && isFiniteNumber(value.maxScreenshotDimension)
    && isFiniteNumber(value.maxConversationTurns);
}

function isSessionSettings(value: unknown): boolean {
  return isRecord(value)
    && typeof value.defaultPrompt === 'string'
    && isLimits(value.limits);
}

function isImageDataUrl(value: unknown): value is string {
  return typeof value === 'string' && value.startsWith('data:image/');
}

function isHistory(value: unknown): boolean {
  return Array.isArray(value) && value.every((entry) => (
    isRecord(entry)
    && (entry.role === 'user' || entry.role === 'assistant')
    && (typeof entry.content === 'string' || Array.isArray(entry.content))
  ));
}

function isControllerMessage(value: unknown): boolean {
  if (!isRecord(value)) return false;
  switch (value.type) {
    case 'CAPTURE_REGION':
      return isId(value.captureId)
        && isImageDataUrl(value.dataUrl)
        && isRecord(value.selection)
        && isRect(value.selection.viewportRect)
        && isRect(value.selection.normalizedRect, true);
    case 'REQUEST_SNIP':
      return isSessionSettings(value.sessionSettings);
    case 'ANALYZE':
      return isId(value.captureId)
        && isId(value.requestId)
        && isId(value.screenshotId)
        && isImageDataUrl(value.dataUrl)
        && isSessionSettings(value.sessionSettings)
        && (value.question === undefined || typeof value.question === 'string');
    case 'FOLLOW_UP':
      return isId(value.captureId)
        && isId(value.requestId)
        && isId(value.screenshotId)
        && typeof value.text === 'string'
        && isHistory(value.history)
        && isSessionSettings(value.sessionSettings);
    case 'CANCEL_GENERATION':
      return isId(value.captureId) && isId(value.requestId);
    case 'SNIP_CANCELLED':
      return isId(value.captureId);
    case 'UI_UNAVAILABLE':
    case 'OPEN_SETTINGS':
      return true;
    default:
      return false;
  }
}

function isInitialMessage(value: unknown): value is WorkspaceInitialMessage {
  return isRecord(value)
    && value.type === 'START_SNIP'
    && isId(value.captureId)
    && isImageDataUrl(value.dataUrl)
    && typeof value.hasApiKey === 'boolean'
    && typeof value.defaultPrompt === 'string'
    && isLimits(value.limits);
}

function isControllerEvent(value: unknown): boolean {
  if (!isRecord(value)) return false;
  if (value.type === 'START_SNIP') return isInitialMessage(value);
  switch (value.type) {
    case 'PREPARE_SNIP_CAPTURE':
      return true;
    case 'CROPPED_IMAGE':
      return isId(value.captureId) && isImageDataUrl(value.dataUrl);
    case 'CAPTURE_ERROR':
      return isId(value.captureId)
        && typeof value.code === 'string'
        && typeof value.message === 'string';
    case 'ANALYZE_CHUNK':
      return isId(value.captureId)
        && isId(value.requestId)
        && isId(value.screenshotId)
        && typeof value.text === 'string';
    case 'ANALYZE_RESULT':
      return isId(value.captureId)
        && isId(value.requestId)
        && isId(value.screenshotId)
        && typeof value.text === 'string'
        && (value.history === undefined || isHistory(value.history));
    case 'ANALYZE_ERROR':
      return isId(value.captureId)
        && isId(value.requestId)
        && isId(value.screenshotId)
        && typeof value.code === 'string'
        && typeof value.message === 'string';
    case 'RESNIP_UNAVAILABLE':
    case 'SHOW_ERROR':
      return typeof value.message === 'string';
    default:
      return false;
  }
}

function isWorkspaceError(value: unknown): value is WorkspaceError {
  return isRecord(value)
    && (value.code === 'capture_expired' || value.code === 'file_access_disabled')
    && typeof value.message === 'string';
}

export function isWorkspaceToBackgroundMessage(
  value: unknown,
): value is WorkspaceToBackgroundMessage {
  if (!isRecord(value) || !isId(value.sessionId)) return false;
  switch (value.type) {
    case 'SNAPSCREEN_WORKSPACE_CLAIM':
      return typeof value.needsInitialState === 'boolean'
        && (
          (isNonce(value.nonce) && value.reconnectToken === undefined)
          || (isNonce(value.reconnectToken) && value.nonce === undefined)
        );
    case 'SNAPSCREEN_WORKSPACE_REQUEST':
      return isId(value.requestId) && isControllerMessage(value.message);
    case 'SNAPSCREEN_WORKSPACE_CLOSE':
      return true;
    default:
      return false;
  }
}

export function isBackgroundToWorkspaceMessage(
  value: unknown,
): value is BackgroundToWorkspaceMessage {
  if (!isRecord(value) || !isId(value.sessionId)) return false;
  switch (value.type) {
    case 'SNAPSCREEN_WORKSPACE_READY':
      return isNonce(value.reconnectToken)
        && (value.initialMessage === undefined || isInitialMessage(value.initialMessage))
        && (value.error === undefined || isWorkspaceError(value.error));
    case 'SNAPSCREEN_WORKSPACE_EVENT':
      return isControllerEvent(value.message);
    case 'SNAPSCREEN_WORKSPACE_RESPONSE':
      return isId(value.requestId);
    default:
      return false;
  }
}
