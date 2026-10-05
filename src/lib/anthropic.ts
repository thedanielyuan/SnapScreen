import { closeOpenCodeFence } from './code-blocks';
import type { AnthropicMessage } from './messages';
import { normalizePlainText } from './plain-text';
import { buildScreenshotQaSystemPrompt } from './screenshot-qa-prompt';
import {
  API_REQUEST_TIMEOUT_MS,
  RequestLimitError,
  assertHistoryScreenshotsWithinLimits,
  assertScreenshotWithinLimits,
  assertUserInputWithinLimit,
  pruneApiHistoryForNewestTurn,
} from './request-limits';
import {
  DEFAULT_LIMITS,
  normalizeLimits,
  type SnapScreenLimits,
} from './storage';
import {
  createScreenshotUserContent,
  retainSessionGuidance,
} from './session-history';

const API_URL = 'https://api.anthropic.com/v1/messages';
const MODEL = 'claude-sonnet-5-5';
// Server-side refusal fallback: when a safety classifier declines (on Sonnet
// 5.5, the cyber and frontier_llm categories), the API reruns the request on
// Anthropic's recommended fallback model within the same stream.
const REFUSAL_FALLBACK_BETA = 'server-side-fallback-2026-07-01';
const MAX_PROVIDER_ERROR_BYTES = 16_384;
const MAX_PROVIDER_ERROR_CHARACTERS = 240;

export class AnthropicError extends Error {
  constructor(
    public code: string,
    message: string,
  ) {
    super(message);
    this.name = 'AnthropicError';
  }
}

export type DeltaHandler = (textSoFar: string) => void;

export interface StreamHandlers {
  onDelta?: DeltaHandler;
  /** Called once, when the stream starts the first thinking block. */
  onThinking?: () => void;
}

export interface AnalyzeImageOptions extends StreamHandlers {
  hiddenInstruction?: string;
  userQuestion?: string;
  signal?: AbortSignal;
  limits?: SnapScreenLimits;
}

export interface FollowUpOptions extends StreamHandlers {
  signal?: AbortSignal;
  sessionInstruction?: string;
  limits?: SnapScreenLimits;
}

export async function analyzeImage(
  apiKey: string,
  dataUrl: string,
  options: AnalyzeImageOptions = {},
): Promise<{ text: string; history: AnthropicMessage[] }> {
  const limits = normalizeLimits(options.limits ?? DEFAULT_LIMITS);
  try {
    // Production callers pass limits explicitly so image validation follows the
    // user's settings. Keeping the option optional preserves the small public
    // helper surface used by key/API unit tests.
    if (options.limits) assertScreenshotWithinLimits(dataUrl, limits);
    if (options.hiddenInstruction?.trim()) {
      assertUserInputWithinLimit(
        options.hiddenInstruction,
        limits.maxInputCharacters,
        'Default Prompt',
      );
    }
    if (options.userQuestion?.trim()) {
      assertUserInputWithinLimit(options.userQuestion, limits.maxInputCharacters);
    }
  } catch (error) {
    throw mapRequestLimitError(error);
  }

  const userQuestion = options.userQuestion?.trim();
  const hiddenInstruction = options.hiddenInstruction?.trim();
  const userContent = createScreenshotUserContent(
    dataUrl,
    hiddenInstruction,
    userQuestion,
  );

  const messages: AnthropicMessage[] = [{ role: 'user', content: userContent }];
  const text = await callApi(apiKey, messages, options.signal, options);

  return {
    text,
    history: [...messages, { role: 'assistant', content: text }],
  };
}

export async function followUp(
  apiKey: string,
  text: string,
  history: AnthropicMessage[],
  options: FollowUpOptions = {},
): Promise<{ text: string; history: AnthropicMessage[] }> {
  const limits = normalizeLimits(options.limits ?? DEFAULT_LIMITS);
  let retainedHistory: AnthropicMessage[];
  try {
    assertUserInputWithinLimit(text, limits.maxInputCharacters);
    assertHistoryScreenshotsWithinLimits(history, limits);
    if (options.sessionInstruction?.trim()) {
      assertUserInputWithinLimit(
        options.sessionInstruction,
        limits.maxInputCharacters,
        'Default Prompt',
      );
    }
    retainedHistory = retainSessionGuidance(history, options.sessionInstruction);
    retainedHistory = pruneApiHistoryForNewestTurn(
      retainedHistory,
      limits.maxConversationTurns,
    ).messages;
  } catch (error) {
    throw mapRequestLimitError(error);
  }

  const messages: AnthropicMessage[] = [
    ...retainedHistory,
    { role: 'user', content: text },
  ];

  const answer = await callApi(apiKey, messages, options.signal, options);

  return {
    text: answer,
    history: [...messages, { role: 'assistant', content: answer }],
  };
}

function mapRequestLimitError(error: unknown): unknown {
  if (error instanceof RequestLimitError) {
    return new AnthropicError(error.code, error.message);
  }
  return error;
}

export async function verifyApiKey(apiKey: string, signal?: AbortSignal): Promise<void> {
  await withRequestTimeout(signal, async (requestSignal) => {
    const response = await postToApi(
      apiKey,
      {
        model: MODEL,
        max_tokens: 1,
        // Key check only, so it skips thinking and stops after one token.
        thinking: { type: 'between_tools' },
        messages: [{ role: 'user', content: 'Hi' }],
      },
      requestSignal,
    );
    await discardResponseBody(response);
  });
}

async function callApi(
  apiKey: string,
  messages: AnthropicMessage[],
  signal?: AbortSignal,
  handlers: StreamHandlers = {},
): Promise<string> {
  return withRequestTimeout(signal, async (requestSignal) => {
    const response = await postToApi(
      apiKey,
      {
        model: MODEL,
        // Thinking counts toward max_tokens, so the budget covers reasoning
        // plus the visible answer.
        max_tokens: 32_000,
        // Adaptive thinking: the model reasons before answering, which is what
        // math, logic, and test-style questions need. Thinking text is omitted
        // by default and the stream reader skips thinking blocks, so history
        // keeps only answer text and never replays thinking.
        thinking: { type: 'adaptive' },
        output_config: { effort: 'high' },
        fallbacks: 'default',
        stream: true,
        // Automatic prompt caching: the cache breakpoint follows the newest
        // message, so follow-ups re-read the screenshot and earlier turns at the
        // cache-read rate. Any change to the system prompt or earlier messages
        // misses the cache, which is why first answers and follow-ups share one
        // system prompt.
        cache_control: { type: 'ephemeral' },
        system: buildScreenshotQaSystemPrompt(),
        messages,
      },
      requestSignal,
      [REFUSAL_FALLBACK_BETA],
    );

    const { text, stopReason } = await readSseStream(response, handlers, requestSignal);

    if (stopReason === 'refusal') {
      throw new AnthropicError('refusal', 'Claude declined to answer this question.');
    }

    const cleaned = normalizePlainText(text);
    if (!cleaned.trim()) {
      throw new AnthropicError('api', 'No response text received from the API.');
    }
    if (stopReason === 'max_tokens') {
      // A cut-off can land inside a code block; close it so the notice is not
      // rendered, or copied, as part of the code.
      return `${closeOpenCodeFence(cleaned)}\n\n(Answer was cut off — ask a follow-up to continue.)`;
    }
    return cleaned;
  });
}

async function readSseStream(
  response: Response,
  { onDelta, onThinking }: StreamHandlers,
  signal?: AbortSignal,
): Promise<{ text: string; stopReason?: string }> {
  const reader = response.body?.getReader();
  if (!reader) {
    throw streamError('No response stream received from the API.');
  }

  const decoder = new TextDecoder();
  let buffer = '';
  let text = '';
  let stopReason: string | undefined;
  let sawMessageStop = false;
  let sawThinking = false;

  const handleEvent = (rawEvent: string): void => {
    const dataLines: string[] = [];
    let eventName = '';

    for (const line of rawEvent.replace(/\r\n?|\n/g, '\n').split('\n')) {
      if (!line || line.startsWith(':')) continue;

      const colon = line.indexOf(':');
      const field = colon === -1 ? line : line.slice(0, colon);
      let value = colon === -1 ? '' : line.slice(colon + 1);
      if (value.startsWith(' ')) value = value.slice(1);

      if (field === 'data') dataLines.push(value);
      if (field === 'event') eventName = value;
    }

    if (dataLines.length === 0) return;

    let data: unknown;
    try {
      data = JSON.parse(dataLines.join('\n')) as unknown;
    } catch {
      throw streamError('The API returned malformed streaming data. Please try again.');
    }

    if (!isRecord(data)) {
      throw streamError('The API returned malformed streaming data. Please try again.');
    }

    const type = typeof data.type === 'string' ? data.type : eventName;
    switch (type) {
      case 'content_block_start': {
        // Thinking text is omitted, but its blocks still stream, so their
        // start shows that the model is thinking before it answers.
        const blockType = isRecord(data.content_block) ? data.content_block.type : undefined;
        if (!sawThinking && (blockType === 'thinking' || blockType === 'redacted_thinking')) {
          sawThinking = true;
          onThinking?.();
        }
        break;
      }
      case 'content_block_delta':
        if (!isRecord(data.delta)) {
          throw streamError('The API returned malformed streaming data. Please try again.');
        }
        if (data.delta.type === 'text_delta') {
          if (typeof data.delta.text !== 'string') {
            throw streamError('The API returned malformed streaming data. Please try again.');
          }
          text += data.delta.text;
          onDelta?.(text);
        }
        break;
      case 'message_delta':
        if (!isRecord(data.delta)) {
          throw streamError('The API returned malformed streaming data. Please try again.');
        }
        if (data.delta.stop_reason !== null && data.delta.stop_reason !== undefined) {
          if (typeof data.delta.stop_reason !== 'string') {
            throw streamError('The API returned malformed streaming data. Please try again.');
          }
          stopReason = data.delta.stop_reason;
        }
        break;
      case 'message_stop':
        sawMessageStop = true;
        break;
      case 'error': {
        const providerMessage =
          isRecord(data.error) && typeof data.error.message === 'string'
            ? sanitizeProviderMessage(data.error.message)
            : '';
        throw new AnthropicError(
          'api',
          providerMessage || 'The API stream reported an error.',
        );
      }
    }
  };

  const processCompleteEvents = (flush = false): void => {
    let boundary = findEventBoundary(buffer, flush);
    while (boundary) {
      const rawEvent = buffer.slice(0, boundary.index);
      buffer = buffer.slice(boundary.index + boundary.length);
      handleEvent(rawEvent);
      boundary = findEventBoundary(buffer, flush);
    }
  };

  let removeAbortListener: (() => void) | undefined;
  let abortPromise: Promise<never> | undefined;
  if (signal) {
    abortPromise = new Promise((_, reject) => {
      const handleAbort = (): void => {
        void reader.cancel(signal.reason).catch(() => undefined);
        reject(abortReason(signal));
      };
      if (signal.aborted) {
        handleAbort();
        return;
      }
      signal.addEventListener('abort', handleAbort, { once: true });
      removeAbortListener = () => signal.removeEventListener('abort', handleAbort);
    });
  }

  try {
    while (true) {
      let chunk: ReadableStreamReadResult<Uint8Array>;
      try {
        chunk = abortPromise
          ? await Promise.race([reader.read(), abortPromise])
          : await reader.read();
      } catch (error) {
        if (signal?.aborted) throw error;
        throw streamError('The API response stream was interrupted. Please try again.');
      }

      if (chunk.done) break;
      buffer += decoder.decode(chunk.value, { stream: true });
      processCompleteEvents();
    }

    buffer += decoder.decode();
    processCompleteEvents(true);
    if (buffer.length > 0) {
      handleEvent(buffer);
      buffer = '';
    }
  } catch (error) {
    void reader.cancel().catch(() => undefined);
    throw error;
  } finally {
    removeAbortListener?.();
  }

  if (!sawMessageStop) {
    throw streamError('The API response ended before it was complete. Please try again.');
  }

  return { text, stopReason };
}

function findEventBoundary(
  value: string,
  flush: boolean,
): { index: number; length: number } | undefined {
  // Match two complete SSE line endings without backtracking a single CRLF
  // into separate CR and LF terminators.
  const match = /\r\n\r\n|\r\n\n|\n\r\n|\r\r\n|\r\n\r|\n\n|\r\r|\n\r/.exec(value);
  if (!match || match.index === undefined) return undefined;
  // A trailing CR may be the first byte of CRLF in the next decoded chunk.
  // Deferring avoids treating CRLFCRLF as CRLF + CR when chunks split there.
  if (!flush && match[0].endsWith('\r') && match.index + match[0].length === value.length) {
    return undefined;
  }
  return { index: match.index, length: match[0].length };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function streamError(message: string): AnthropicError {
  return new AnthropicError('stream', message);
}

function errorName(error: unknown): string | undefined {
  return isRecord(error) && typeof error.name === 'string' ? error.name : undefined;
}

function abortReason(signal: AbortSignal): unknown {
  return signal.reason ?? new DOMException('The operation was aborted.', 'AbortError');
}

async function withRequestTimeout<T>(
  callerSignal: AbortSignal | undefined,
  operation: (requestSignal: AbortSignal) => Promise<T>,
): Promise<T> {
  const timeoutSignal = AbortSignal.timeout(API_REQUEST_TIMEOUT_MS);
  const requestSignal = callerSignal
    ? AbortSignal.any([callerSignal, timeoutSignal])
    : timeoutSignal;

  try {
    return await operation(requestSignal);
  } catch (error) {
    if (callerSignal?.aborted) throw abortReason(callerSignal);
    if (timeoutSignal.aborted || errorName(error) === 'TimeoutError') {
      throw new AnthropicError('timeout', 'Request timed out. Please try again.');
    }
    if (errorName(error) === 'AbortError') {
      throw new AnthropicError('network', 'Network error. Check your connection and try again.');
    }
    throw error;
  }
}

async function postToApi(
  apiKey: string,
  body: object,
  signal: AbortSignal,
  betas: readonly string[] = [],
): Promise<Response> {
  const headers: Record<string, string> = {
    'x-api-key': apiKey,
    'anthropic-version': '2023-06-01',
    'content-type': 'application/json',
    'anthropic-dangerous-direct-browser-access': 'true',
  };
  if (betas.length > 0) headers['anthropic-beta'] = betas.join(',');

  let response: Response;
  try {
    response = await fetch(API_URL, {
      method: 'POST',
      headers,
      body: JSON.stringify(body),
      signal,
    });
  } catch (err) {
    if (errorName(err) === 'AbortError' || errorName(err) === 'TimeoutError') throw err;
    throw new AnthropicError('network', 'Network error. Check your connection and try again.');
  }

  if (!response.ok) {
    if (response.status === 401 || response.status === 403) {
      await discardResponseBody(response);
      throw new AnthropicError('auth', 'Invalid API key. Check your settings.');
    }
    if (response.status === 429) {
      const retryAfter = response.headers.get('retry-after');
      const hint =
        retryAfter && /^\d+$/.test(retryAfter)
          ? `Try again in ~${retryAfter}s.`
          : 'Please try again shortly.';
      await discardResponseBody(response);
      throw new AnthropicError('rate_limit', `Rate limit reached. ${hint}`);
    }
    if (response.status >= 500) {
      await discardResponseBody(response);
      throw new AnthropicError('server', 'Service unavailable. Please try again.');
    }
    let providerMessage = '';
    try {
      providerMessage = await readProviderErrorMessage(response);
    } catch (error) {
      if (errorName(error) === 'AbortError' || errorName(error) === 'TimeoutError') throw error;
    }
    const fallback = sanitizeProviderMessage(response.statusText) || 'Unknown error';
    throw new AnthropicError(
      'api',
      `API error (${response.status}): ${providerMessage || fallback}`,
    );
  }

  return response;
}

async function discardResponseBody(response: Response): Promise<void> {
  try {
    await response.body?.cancel();
  } catch {
    // Authentication checks and deliberately generic errors do not need the
    // provider body; cleanup failures must not replace their useful outcome.
  }
}

async function readProviderErrorMessage(response: Response): Promise<string> {
  const reader = response.body?.getReader();
  if (!reader) return '';

  const decoder = new TextDecoder();
  let remaining = MAX_PROVIDER_ERROR_BYTES;
  let raw = '';
  let truncated = false;

  try {
    while (remaining > 0) {
      const { done, value } = await reader.read();
      if (done) break;
      const slice = value.byteLength > remaining ? value.slice(0, remaining) : value;
      raw += decoder.decode(slice, { stream: true });
      remaining -= slice.byteLength;
      if (slice.byteLength < value.byteLength) {
        truncated = true;
        break;
      }
    }
    if (remaining === 0) truncated = true;
    raw += decoder.decode();
  } finally {
    if (truncated) void reader.cancel().catch(() => undefined);
  }

  if (truncated) return '';

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw) as unknown;
  } catch {
    return '';
  }

  if (!isRecord(parsed)) return '';
  const nested = isRecord(parsed.error) ? parsed.error.message : undefined;
  const candidate = typeof nested === 'string'
    ? nested
    : typeof parsed.message === 'string'
      ? parsed.message
      : '';
  return sanitizeProviderMessage(candidate);
}

function sanitizeProviderMessage(message: string): string {
  return message
    .replace(/sk-ant-[A-Za-z0-9_-]{8,}/gi, '[REDACTED API KEY]')
    .replace(/[\u0000-\u001f\u007f]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, MAX_PROVIDER_ERROR_CHARACTERS);
}
