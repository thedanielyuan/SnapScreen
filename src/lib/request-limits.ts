import type { AnthropicMessage, DisplayMessage } from './messages';
import type { SnapScreenLimits } from './storage';

export const MEGABYTE = 1_000_000;

// Wall-clock limit for one Anthropic API request, including the whole
// streamed answer (up to 4,096 tokens at high effort).
export const API_REQUEST_TIMEOUT_MS = 120_000;

export type RequestLimitCode =
  | 'input_empty'
  | 'input_too_long'
  | 'screenshot_invalid'
  | 'screenshot_too_large'
  | 'screenshot_dimensions_too_large'
  | 'conversation_incomplete';

export class RequestLimitError extends Error {
  constructor(
    public readonly code: RequestLimitCode,
    message: string,
  ) {
    super(message);
    this.name = 'RequestLimitError';
  }
}

export function countTextCharacters(text: string): number {
  let count = 0;
  for (const _character of text) count += 1;
  return count;
}

export function assertUserInputWithinLimit(
  text: string,
  maxCharacters: number,
  label = 'Question',
): void {
  if (!text.trim()) {
    throw new RequestLimitError('input_empty', `${label} cannot be empty.`);
  }

  const characterCount = countTextCharacters(text);
  if (characterCount > maxCharacters) {
    throw new RequestLimitError(
      'input_too_long',
      `${label} is ${characterCount.toLocaleString()} characters. The current limit is ${maxCharacters.toLocaleString()}. Shorten it or raise the limit in Settings.`,
    );
  }
}

export interface ScreenshotMetadata {
  bytes: number;
  width: number;
  height: number;
}

export function inspectPngDataUrl(dataUrl: string): ScreenshotMetadata {
  const match = /^data:image\/png;base64,([A-Za-z0-9+/]*={0,2})$/i.exec(dataUrl);
  if (!match) {
    throw new RequestLimitError(
      'screenshot_invalid',
      'The captured screenshot is not a valid PNG. Take a new snip and try again.',
    );
  }

  const payload = match[1];
  if (payload.length === 0 || payload.length % 4 === 1) {
    throw new RequestLimitError(
      'screenshot_invalid',
      'The captured screenshot is incomplete. Take a new snip and try again.',
    );
  }

  const padding = payload.endsWith('==') ? 2 : payload.endsWith('=') ? 1 : 0;
  const bytes = Math.floor((payload.length * 3) / 4) - padding;

  let header: string;
  try {
    header = atob(payload.slice(0, 32));
  } catch {
    throw new RequestLimitError(
      'screenshot_invalid',
      'The captured screenshot is incomplete. Take a new snip and try again.',
    );
  }

  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  const hasPngSignature = signature.every((byte, index) => header.charCodeAt(index) === byte);
  const hasIhdr = header.slice(12, 16) === 'IHDR';
  if (header.length < 24 || !hasPngSignature || !hasIhdr) {
    throw new RequestLimitError(
      'screenshot_invalid',
      'The captured screenshot is not a valid PNG. Take a new snip and try again.',
    );
  }

  const width = readUint32(header, 16);
  const height = readUint32(header, 20);
  if (width <= 0 || height <= 0) {
    throw new RequestLimitError(
      'screenshot_invalid',
      'The captured screenshot has invalid dimensions. Take a new snip and try again.',
    );
  }

  return { bytes, width, height };
}

export function assertScreenshotWithinLimits(
  dataUrl: string,
  limits: SnapScreenLimits,
): ScreenshotMetadata {
  const metadata = inspectPngDataUrl(dataUrl);
  if (metadata.bytes > limits.maxScreenshotBytes) {
    throw new RequestLimitError(
      'screenshot_too_large',
      `The screenshot is ${formatMegabytes(metadata.bytes)} MB. The current limit is ${formatMegabytes(limits.maxScreenshotBytes)} MB. Select a smaller region or raise the limit in Settings.`,
    );
  }

  const longestEdge = Math.max(metadata.width, metadata.height);
  if (longestEdge > limits.maxScreenshotDimension) {
    throw new RequestLimitError(
      'screenshot_dimensions_too_large',
      `The screenshot is ${metadata.width.toLocaleString()} × ${metadata.height.toLocaleString()} px. The current edge limit is ${limits.maxScreenshotDimension.toLocaleString()} px. Select a smaller region or raise the limit in Settings.`,
    );
  }

  return metadata;
}

export function assertHistoryScreenshotsWithinLimits(
  history: readonly AnthropicMessage[],
  limits: SnapScreenLimits,
): void {
  for (const message of history) {
    if (!Array.isArray(message.content)) continue;
    for (const block of message.content) {
      if (block.type !== 'image') continue;
      assertScreenshotWithinLimits(
        `data:image/png;base64,${block.source.data}`,
        limits,
      );
    }
  }
}

export interface PrunedTurns<T> {
  messages: T[];
  removedTurns: number;
}

/**
 * Keeps the pinned first turn and newest complete turns, reserving one turn for
 * the request about to be appended. It never returns an unmatched message.
 */
export function pruneForNewestTurn<T extends { role: 'user' | 'assistant' }>(
  messages: readonly T[],
  maxConversationTurns: number,
): PrunedTurns<T> {
  const pairs = toCompletePairs(messages);
  const existingBudget = Math.max(1, maxConversationTurns - 1);
  if (pairs.length <= existingBudget) {
    return { messages: [...messages], removedTurns: 0 };
  }

  const newestPairCount = existingBudget - 1;
  const keptPairs = newestPairCount > 0
    ? [pairs[0], ...pairs.slice(-newestPairCount)]
    : [pairs[0]];

  return {
    messages: keptPairs.flatMap(([user, assistant]) => [user, assistant]),
    removedTurns: pairs.length - keptPairs.length,
  };
}

export function pruneApiHistoryForNewestTurn(
  history: readonly AnthropicMessage[],
  maxConversationTurns: number,
): PrunedTurns<AnthropicMessage> {
  return pruneForNewestTurn(history, maxConversationTurns);
}

export function pruneDisplayHistoryForNewestTurn(
  history: readonly DisplayMessage[],
  maxConversationTurns: number,
): PrunedTurns<DisplayMessage> {
  if (history.length === 0) return { messages: [], removedTurns: 0 };
  if (history[0].role !== 'assistant') {
    throw incompleteConversationError();
  }

  const followUps = toCompletePairs(history.slice(1));
  const turns: DisplayMessage[][] = [[history[0]], ...followUps];
  const existingBudget = Math.max(1, maxConversationTurns - 1);
  if (turns.length <= existingBudget) {
    return { messages: [...history], removedTurns: 0 };
  }

  const newestTurnCount = existingBudget - 1;
  const keptTurns = newestTurnCount > 0
    ? [turns[0], ...turns.slice(-newestTurnCount)]
    : [turns[0]];

  return {
    messages: keptTurns.flat(),
    removedTurns: turns.length - keptTurns.length,
  };
}

function toCompletePairs<T extends { role: 'user' | 'assistant' }>(
  messages: readonly T[],
): Array<[T, T]> {
  if (messages.length % 2 !== 0) {
    throw incompleteConversationError();
  }

  const pairs: Array<[T, T]> = [];
  for (let index = 0; index < messages.length; index += 2) {
    const user = messages[index];
    const assistant = messages[index + 1];
    if (user.role !== 'user' || assistant.role !== 'assistant') {
      throw incompleteConversationError();
    }
    pairs.push([user, assistant]);
  }
  return pairs;
}

function incompleteConversationError(): RequestLimitError {
  return new RequestLimitError(
    'conversation_incomplete',
    'The conversation contains an unfinished turn. Retry or remove it before continuing.',
  );
}

function readUint32(value: string, offset: number): number {
  return (
    value.charCodeAt(offset) * 0x1000000
    + value.charCodeAt(offset + 1) * 0x10000
    + value.charCodeAt(offset + 2) * 0x100
    + value.charCodeAt(offset + 3)
  );
}

function formatMegabytes(bytes: number): string {
  return (bytes / MEGABYTE).toFixed(bytes % MEGABYTE === 0 ? 0 : 1);
}
