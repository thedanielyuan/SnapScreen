// Golden fixtures for the Swift port of this code (Phase 1 of docs/standalone-app-plan.md). Each
// scenario runs the client and conversation state against a scripted fetch, and must match the
// JSON committed in Tests/SnapScreenCoreTests/Fixtures, which `swift test` replays against
// SnapScreenCore. After an intended change here, rewrite the fixtures, then update the Swift core
// until `swift test` passes again:
//
//   npx vitest run src/lib/core-fixtures.test.ts -u
//
// Delete this file with the rest of the extension in Phase 5.
import { afterEach, describe, expect, it, vi } from 'vitest';
import { analyzeImage, followUp, verifyApiKey, AnthropicError } from './anthropic';
import {
  describeRemovedTurns,
  prepareAlignedConversationForNewestTurn,
  settleFailedFirstAnswer,
  settleFailedFollowUp,
  settleStoppedConversation,
  settleSuccessfulConversation,
} from './conversation-state';
import type { AnthropicMessage, DisplayMessage } from './messages';
import { SCREENSHOT_QA_SYSTEM_PROMPT } from './screenshot-qa-prompt';
import { DEFAULT_LIMITS, DEFAULT_PROMPT, type SnapScreenLimits } from './storage';

const FIXTURES = '../../Tests/SnapScreenCoreTests/Fixtures';
const API_KEY = 'test-key';
// Request bodies name the prompt instead of repeating it; system-prompt.txt holds it once.
const SYSTEM_PROMPT_REFERENCE = '(system-prompt.txt)';
// A real 1 × 1 PNG, because the app always checks screenshots against its limits.
const IMAGE = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
const IMAGE_DATA = IMAGE.slice(IMAGE.indexOf(',') + 1);

interface ScriptedResponse {
  status?: number;
  statusText?: string;
  headers?: Record<string, string>;
  body?: string;
  /** Splits the body's UTF-8 bytes into chunks of this many bytes. One chunk by default. */
  chunkSize?: number;
  /**
   * After the last chunk: `close` ends the body, `error` interrupts it, and `stop` is the user
   * pressing Stop when the client asks for more.
   */
  end?: 'close' | 'error' | 'stop';
  /** fetch rejects before any response arrives. */
  networkError?: boolean;
}

type Outcome =
  | { type: 'answer'; text: string; history: AnthropicMessage[] }
  | { type: 'verified' }
  | { type: 'stopped' }
  | { type: 'error'; code: string; message: string };

type Step = Record<string, unknown>;

interface CallResult {
  outcome: Outcome;
  /** The text streamed before the call ended, which a stopped or failed answer keeps. */
  partialAnswer: string;
}

interface StreamOptions {
  signal: AbortSignal;
  onThinking: () => void;
  onDelta: (text: string) => void;
}

class Recorder {
  readonly steps: Step[] = [];

  async analyzeImage(
    note: string,
    input: { image: string; hiddenInstruction?: string; userQuestion?: string; limits: SnapScreenLimits },
    response: ScriptedResponse,
  ): Promise<CallResult> {
    return this.call(note, 'analyzeImage', { apiKey: API_KEY, ...input }, response, (options) =>
      analyzeImage(API_KEY, input.image, { ...options, ...input }));
  }

  async followUp(
    note: string,
    input: { text: string; history: AnthropicMessage[]; sessionInstruction?: string; limits: SnapScreenLimits },
    response: ScriptedResponse,
  ): Promise<CallResult> {
    return this.call(note, 'followUp', { apiKey: API_KEY, ...input }, response, (options) =>
      followUp(API_KEY, input.text, input.history, { ...options, ...input }));
  }

  async verifyApiKey(note: string, response: ScriptedResponse): Promise<CallResult> {
    return this.call(note, 'verifyApiKey', { apiKey: API_KEY }, response, (options) =>
      verifyApiKey(API_KEY, options.signal));
  }

  /** Records a conversation-state function's input and output for the Swift port to reproduce. */
  settle<T>(op: string, input: object, run: () => T): T {
    const output = run();
    this.steps.push({ op, input, output });
    return output;
  }

  private async call(
    note: string,
    op: string,
    input: object,
    response: ScriptedResponse,
    run: (options: StreamOptions) => Promise<{ text: string; history: AnthropicMessage[] } | void>,
  ): Promise<CallResult> {
    const controller = new AbortController();
    const events: Array<Record<string, string>> = [];
    let partialAnswer = '';
    let request: Record<string, unknown> | null = null;
    let systemPrompt: unknown;
    vi.stubGlobal('fetch', vi.fn(async (url: string, init: RequestInit) => {
      const body = JSON.parse(init.body as string) as Record<string, unknown>;
      if ('system' in body) {
        systemPrompt = body.system;
        body.system = SYSTEM_PROMPT_REFERENCE;
      }
      request = { url, method: init.method, headers: init.headers, body };
      if (response.networkError) throw new TypeError('fetch failed');
      return new Response(scriptedBody(response, () => controller.abort()), {
        status: response.status ?? 200,
        statusText: response.statusText ?? '',
        headers: response.headers,
      });
    }));

    let outcome: Outcome;
    try {
      const result = await run({
        signal: controller.signal,
        onThinking: () => events.push({ type: 'thinking' }),
        onDelta: (text) => {
          partialAnswer = text;
          events.push({ type: 'delta', text });
        },
      });
      outcome = result ? { type: 'answer', ...result } : { type: 'verified' };
    } catch (error) {
      if (controller.signal.aborted) {
        outcome = { type: 'stopped' };
      } else if (error instanceof AnthropicError) {
        outcome = { type: 'error', code: error.code, message: error.message };
      } else {
        throw error;
      }
    }
    if (systemPrompt !== undefined) expect(systemPrompt).toBe(SCREENSHOT_QA_SYSTEM_PROMPT);
    this.steps.push({ note, op, input, response, request, events, outcome });
    return { outcome, partialAnswer };
  }
}

function scriptedBody(response: ScriptedResponse, stop: () => void): ReadableStream<Uint8Array> {
  const bytes = new TextEncoder().encode(response.body ?? '');
  const size = response.chunkSize ?? Math.max(bytes.length, 1);
  const chunks: Uint8Array[] = [];
  for (let start = 0; start < bytes.length; start += size) chunks.push(bytes.slice(start, start + size));
  let next = 0;
  // A high-water mark of 0 pulls only when the client reads, so `stop` waits for the client.
  return new ReadableStream<Uint8Array>({
    pull(controller) {
      if (next < chunks.length) {
        controller.enqueue(chunks[next++]);
      } else if (response.end === 'error') {
        controller.error(new TypeError('network error'));
      } else if (response.end === 'stop') {
        stop();
      } else {
        controller.close();
      }
    },
  }, { highWaterMark: 0 });
}

interface Generation {
  kind: 'initial' | 'follow-up';
  userText?: string;
  baseHistory: AnthropicMessage[];
  baseDisplayMessages: DisplayMessage[];
}

/**
 * Drives a conversation the way NativeSessionController.generate does in
 * src/background/native-session.ts, recording every client call and state change.
 */
class Session {
  private history: AnthropicMessage[] = [];
  private display: DisplayMessage[] = [];
  private retryGeneration?: Generation;

  constructor(
    private recorder: Recorder,
    private defaultPrompt = DEFAULT_PROMPT,
    private limits = DEFAULT_LIMITS,
  ) {}

  answer(note: string, response: ScriptedResponse): Promise<void> {
    return this.generate(note, response);
  }

  ask(note: string, text: string, response: ScriptedResponse): Promise<void> {
    return this.generate(note, response, text);
  }

  retry(note: string, response: ScriptedResponse): Promise<void> {
    const retry = this.retryGeneration!;
    return this.generate(note, response, retry.userText, retry);
  }

  private async generate(
    note: string,
    response: ScriptedResponse,
    userText?: string,
    retry?: Generation,
  ): Promise<void> {
    const base = {
      baseDisplayMessages: retry?.baseDisplayMessages ?? this.display,
      baseHistory: retry?.baseHistory ?? this.history,
    };
    this.retryGeneration = undefined;
    const aligned = this.recorder.settle(
      'prepareAlignedConversationForNewestTurn',
      { displayMessages: base.baseDisplayMessages, conversationHistory: base.baseHistory,
        maxConversationTurns: this.limits.maxConversationTurns },
      () => {
        const result = prepareAlignedConversationForNewestTurn(
          base.baseDisplayMessages, base.baseHistory, this.limits.maxConversationTurns);
        return result.removedTurns > 0
          ? { ...result, notice: describeRemovedTurns(result.removedTurns) }
          : result;
      },
    );
    const generation: Generation = {
      kind: base.baseHistory.length ? 'follow-up' : 'initial',
      userText,
      baseDisplayMessages: aligned.displayMessages,
      baseHistory: aligned.conversationHistory,
    };

    const { outcome, partialAnswer } = generation.kind === 'initial'
      ? await this.recorder.analyzeImage(note, {
          image: IMAGE, hiddenInstruction: this.defaultPrompt, userQuestion: userText, limits: this.limits,
        }, response)
      : await this.recorder.followUp(note, {
          text: userText!, history: generation.baseHistory, sessionInstruction: this.defaultPrompt,
          limits: this.limits,
        }, response);

    const context = { dataUrl: IMAGE, sessionInstruction: this.defaultPrompt };
    let settled: { displayMessages: DisplayMessage[]; conversationHistory: AnthropicMessage[] };
    if (outcome.type === 'answer') {
      const input = { ...generation, ...context, assistantText: outcome.text, providerHistory: outcome.history };
      settled = this.recorder.settle('settleSuccessfulConversation', input,
        () => settleSuccessfulConversation(input));
    } else if (outcome.type === 'stopped') {
      const input = { ...generation, ...context, partialAnswer };
      settled = this.recorder.settle('settleStoppedConversation', input,
        () => settleStoppedConversation(input));
      this.retryGeneration = generation;
    } else if (outcome.type === 'error') {
      // As in the extension, refused text is never kept or sent back with a follow-up.
      const failure = {
        partialAnswer: outcome.code === 'refusal' ? '' : partialAnswer,
        errorMessage: outcome.message,
      };
      if (generation.kind === 'initial') {
        const input = { ...context, ...failure, userText };
        settled = this.recorder.settle('settleFailedFirstAnswer', input,
          () => settleFailedFirstAnswer(input));
      } else {
        const input = { ...generation, ...context, ...failure, userText: userText! };
        settled = this.recorder.settle('settleFailedFollowUp', input,
          () => settleFailedFollowUp(input));
      }
      this.retryGeneration = generation;
    } else {
      throw new Error(`Unexpected ${outcome.type} outcome in a session.`);
    }
    this.display = settled.displayMessages;
    this.history = settled.conversationHistory;
  }
}

type SseEvent = Record<string, unknown>;

function sse(events: SseEvent[]): string {
  return events.map((event) => `event: ${event.type as string}\ndata: ${JSON.stringify(event)}\n\n`).join('');
}

const messageStart: SseEvent = {
  type: 'message_start',
  message: {
    id: 'msg_fixture', type: 'message', role: 'assistant', model: 'claude-opus-5-5', content: [],
    stop_reason: null, stop_sequence: null, usage: { input_tokens: 1200, output_tokens: 1 },
  },
};

function blockStart(index: number, type: string): SseEvent {
  const content: Record<string, Record<string, unknown>> = {
    thinking: { type: 'thinking', thinking: '' },
    redacted_thinking: { type: 'redacted_thinking', data: 'opaque' },
    text: { type: 'text', text: '' },
  };
  return { type: 'content_block_start', index, content_block: content[type] };
}

function delta(index: number, value: Record<string, unknown>): SseEvent {
  return { type: 'content_block_delta', index, delta: value };
}

function textDelta(index: number, text: string): SseEvent {
  return delta(index, { type: 'text_delta', text });
}

function thinking(index: number): SseEvent[] {
  return [
    blockStart(index, 'thinking'),
    delta(index, { type: 'signature_delta', signature: 'c2lnbmF0dXJl' }),
    { type: 'content_block_stop', index },
  ];
}

function finish(stopReason: string): SseEvent[] {
  return [
    { type: 'message_delta', delta: { stop_reason: stopReason, stop_sequence: null }, usage: { output_tokens: 87 } },
    { type: 'message_stop' },
  ];
}

function stream(events: SseEvent[], options: Omit<ScriptedResponse, 'body'> = {}): ScriptedResponse {
  return { headers: { 'content-type': 'text/event-stream' }, ...options, body: sse(events) };
}

/** A complete answer: thinking, then the text parts, then end_turn. */
function answer(...parts: string[]): ScriptedResponse {
  return stream([
    messageStart, { type: 'ping' }, ...thinking(0), blockStart(1, 'text'),
    ...parts.map((part) => textDelta(1, part)), { type: 'content_block_stop', index: 1 }, ...finish('end_turn'),
  ]);
}

/** Thinking, then the text parts, then the body ends as `end` says. */
function unfinished(end: 'error' | 'stop', ...parts: string[]): ScriptedResponse {
  return stream([
    messageStart, ...thinking(0), ...(parts.length ? [blockStart(1, 'text')] : []),
    ...parts.map((part) => textDelta(1, part)),
  ], { end });
}

function json(status: number, body: unknown, statusText = ''): ScriptedResponse {
  return {
    status, statusText, headers: { 'content-type': 'application/json' },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  };
}

function imageTurn(guidance?: string): AnthropicMessage {
  return {
    role: 'user',
    content: [
      { type: 'image', source: { type: 'base64', media_type: 'image/png', data: IMAGE_DATA } },
      ...(guidance ? [{ type: 'text' as const, text: `Screenshot task guidance:\n${guidance}` }] : []),
    ],
  };
}

function turn(index: number): AnthropicMessage[] {
  return [
    { role: 'user', content: `Question ${index}` },
    { role: 'assistant', content: `Answer ${index}` },
  ];
}

const SECRET = 'sk-ant-api03-fixturesecretvalue123456789';

interface Scenario {
  description: string;
  run: (recorder: Recorder) => Promise<void>;
}

const scenarios: Record<string, Scenario> = {
  'first-answers': {
    description: 'First answers with and without a Default Prompt and a question.',
    async run(recorder) {
      await recorder.analyzeImage('Default Prompt only, as the app sends it',
        { image: IMAGE, hiddenInstruction: DEFAULT_PROMPT, limits: DEFAULT_LIMITS },
        answer('The answer is ', '4.'));
      await recorder.analyzeImage('Default Prompt and question, both trimmed',
        { image: IMAGE, hiddenInstruction: '  Use SI units.\n', userQuestion: '\t How fast is it? ',
          limits: DEFAULT_LIMITS },
        answer('About 3 m/s.'));
      await recorder.analyzeImage('Question only',
        { image: IMAGE, userQuestion: 'What is 2 + 2?', limits: DEFAULT_LIMITS }, answer('4'));
      await recorder.analyzeImage('Neither, so the image is the whole request',
        { image: IMAGE, hiddenInstruction: ' ', userQuestion: '', limits: DEFAULT_LIMITS },
        answer('A cat.'));
    },
  },
  'follow-ups': {
    description: 'Follow-ups keep the pinned image turn, its guidance, and the untrimmed question.',
    async run(recorder) {
      await recorder.followUp('Pinned guidance is resent unchanged, and the question is not trimmed', {
        text: ' Why? ', history: [imageTurn(DEFAULT_PROMPT), { role: 'assistant', content: '4' }],
        sessionInstruction: DEFAULT_PROMPT, limits: DEFAULT_LIMITS,
      }, answer('Because 2 + 2 = 4.'));
      await recorder.followUp('Guidance missing from the image turn is added after the image', {
        text: 'And in feet?', history: [imageTurn(), { role: 'assistant', content: '3 m/s' }],
        sessionInstruction: 'Always answer using SI units.', limits: DEFAULT_LIMITS,
      }, answer('About 9.8 ft/s.'));
      await recorder.followUp('Changed settings never replace the pinned guidance', {
        text: 'And this?', history: [imageTurn('Original guidance.'), { role: 'assistant', content: 'Earlier' }],
        sessionInstruction: 'Changed guidance.', limits: DEFAULT_LIMITS,
      }, answer('Still the original.'));
      await recorder.followUp('Only complete oldest turns are trimmed, keeping the image turn', {
        text: 'Newest', history: [imageTurn(DEFAULT_PROMPT), { role: 'assistant', content: 'Initial' },
          ...turn(1), ...turn(2), ...turn(3)],
        sessionInstruction: DEFAULT_PROMPT, limits: { ...DEFAULT_LIMITS, maxConversationTurns: 3 },
      }, answer('Trimmed.'));
    },
  },
  'stream-parsing': {
    description: 'SSE framing, ignored events, and thinking reported once.',
    async run(recorder) {
      const limits = DEFAULT_LIMITS;
      await recorder.analyzeImage('Reasoning-style deltas and a refusal-fallback block are skipped',
        { image: IMAGE, limits }, stream([
          messageStart,
          delta(0, { type: 'thinking_delta', thinking: 'Private reasoning.' }),
          delta(0, { type: 'reasoning_delta', reasoning_content: 'Hidden.' }),
          textDelta(0, 'Par'),
          { type: 'content_block_start', index: 1,
            content_block: { type: 'fallback', from: { model: 'claude-opus-5-5' }, to: { model: 'claude-opus-4-8' } } },
          { type: 'content_block_stop', index: 1 },
          textDelta(2, 'tial answer'),
          ...finish('end_turn'),
        ]));
      await recorder.analyzeImage('Thinking and redacted thinking are reported once, before text',
        { image: IMAGE, limits }, stream([
          messageStart, ...thinking(0), blockStart(1, 'redacted_thinking'), { type: 'content_block_stop', index: 1 },
          blockStart(2, 'text'), textDelta(2, 'Answer'), ...finish('end_turn'),
        ]));
      await recorder.analyzeImage('CRLF, multiline data, one-byte chunks, and a final event with no blank line',
        { image: IMAGE, limits }, {
          body: [
            ': a comment line\r\n',
            'event: content_block_delta\r\n',
            'data: {"type":\r\n',
            'data: "content_block_delta","delta":{"type":"text_delta","text":"café_#1 ✓"}}\r\n',
            '\r\n',
            `event: message_delta\r\ndata: ${JSON.stringify(finish('end_turn')[0])}\r\n\r\n`,
            `event: message_stop\r\ndata: ${JSON.stringify({ type: 'message_stop' })}`,
          ].join(''),
          chunkSize: 1,
        });
      await recorder.analyzeImage('CR line endings split across chunks, and the type taken from the event field',
        { image: IMAGE, limits }, {
          body: [
            'event: content_block_delta\rdata: {"delta":{"type":"text_delta","text":"line one\\r\\nline two"}}\r\r',
            `event: message_delta\rdata: ${JSON.stringify(finish('end_turn')[0])}\r\n\r`,
            'data: {"type":"message_stop"}\n\r\n',
          ].join(''),
          chunkSize: 3,
        });
    },
  },
  'stream-failures': {
    description: 'Malformed, incomplete, interrupted, and error-reporting streams.',
    async run(recorder) {
      const input = { image: IMAGE, limits: DEFAULT_LIMITS };
      await recorder.analyzeImage('Data that is not JSON', input,
        { body: 'event: content_block_delta\ndata: {not valid JSON}\n\n' });
      await recorder.analyzeImage('Data that is JSON but not an object', input,
        { body: `${sse([messageStart])}data: ["content_block_delta"]\n\n` });
      await recorder.analyzeImage('A content_block_delta without a delta object', input,
        stream([messageStart, { type: 'content_block_delta', index: 0 }]));
      await recorder.analyzeImage('A text delta whose text is not a string', input,
        stream([messageStart, delta(0, { type: 'text_delta', text: 42 })]));
      await recorder.analyzeImage('A stop_reason that is not a string', input,
        stream([messageStart, textDelta(0, 'Hi'), { type: 'message_delta', delta: { stop_reason: 7 } }]));
      await recorder.analyzeImage('A body that ends before message_stop', input,
        stream([messageStart, textDelta(0, 'Partial'), finish('end_turn')[0]]));
      await recorder.analyzeImage('A body interrupted after some text', input,
        unfinished('error', 'Partial', ' answer'));
      await recorder.analyzeImage('An error event with a message', input,
        stream([messageStart, textDelta(0, 'Par'), { type: 'error', error: { type: 'overloaded_error', message: 'Overloaded' } }]));
      await recorder.analyzeImage('An error event whose message needs redacting, cleaning, and capping', input,
        stream([{ type: 'error', error: { type: 'api_error', message: `Bad\u0000\u0007 key\t${SECRET} ${'x'.repeat(500)}` } }]));
      await recorder.analyzeImage('An error event without a message', input,
        stream([{ type: 'error', error: { type: 'api_error' } }]));
    },
  },
  'answer-endings': {
    description: 'Refusals, cut-off answers, and empty answers.',
    async run(recorder) {
      const input = { image: IMAGE, limits: DEFAULT_LIMITS };
      await recorder.analyzeImage('A refusal after some text', input,
        stream([messageStart, textDelta(0, 'I can'), ...finish('refusal')]));
      await recorder.analyzeImage('A max_tokens cut-off inside a code block', input,
        stream([messageStart, textDelta(0, 'Here:\r\n```python\r\ndef add(a, b):\r\n    return a'), ...finish('max_tokens')]));
      await recorder.analyzeImage('A max_tokens cut-off in prose', input,
        stream([messageStart, textDelta(0, 'The first part'), ...finish('max_tokens')]));
      await recorder.analyzeImage('An answer of only whitespace', input,
        stream([messageStart, textDelta(0, ' \n\t '), ...finish('end_turn')]));
      await recorder.analyzeImage('Line endings normalized, other whitespace kept', input,
        stream([messageStart, textDelta(0, '  first\r\nsecond\rthird  \n'), ...finish('end_turn')]));
    },
  },
  'http-errors': {
    description: 'HTTP failures map to fixed messages; only bounded, redacted provider text is shown.',
    async run(recorder) {
      const input = { image: IMAGE, limits: DEFAULT_LIMITS };
      await recorder.analyzeImage('401', input, json(401, { error: { message: 'invalid x-api-key' } }));
      await recorder.analyzeImage('403', input, json(403, {}));
      await recorder.analyzeImage('429 with retry-after seconds', input,
        { ...json(429, {}), headers: { 'retry-after': '30' } });
      await recorder.analyzeImage('429 with a retry-after date', input,
        { ...json(429, {}), headers: { 'retry-after': 'Wed, 21 Oct 2026 07:28:00 GMT' } });
      await recorder.analyzeImage('500', input, json(500, { error: { message: 'boom' } }));
      await recorder.analyzeImage('529', input, json(529, { error: { type: 'overloaded_error' } }));
      await recorder.analyzeImage('400 with a nested provider message holding a key', input,
        json(400, { type: 'error', error: { type: 'invalid_request_error', message: `Bad key ${SECRET}` } }, 'Bad Request'));
      await recorder.analyzeImage('400 with a top-level message', input,
        json(400, { message: 'Top-level detail' }, 'Bad Request'));
      await recorder.analyzeImage('400 whose provider message is capped', input,
        json(400, { error: { message: 'y'.repeat(500) } }, 'Bad Request'));
      await recorder.analyzeImage('400 that is not JSON falls back to the status text', input,
        json(400, '<html>secret diagnostics</html>', 'Bad Request'));
      await recorder.analyzeImage('400 that is not JSON, over HTTP/2 with no status text', input,
        json(400, '<html>secret diagnostics</html>'));
      await recorder.analyzeImage('400 whose body is too large to read', input,
        json(400, { error: { message: 'z'.repeat(20_000) } }, 'Bad Request'));
      await recorder.analyzeImage('404 whose status text needs redacting and capping', input,
        json(404, 'not json', `  Not   found ${SECRET} ${'w'.repeat(500)}`));
      await recorder.analyzeImage('A network failure before any response', input, { networkError: true });
    },
  },
  'request-limits': {
    description: 'Requests rejected before anything is sent.',
    async run(recorder) {
      const limits = { ...DEFAULT_LIMITS, maxInputCharacters: 100 };
      await recorder.analyzeImage('A question over the limit',
        { image: IMAGE, userQuestion: 'x'.repeat(101), limits }, answer('unused'));
      await recorder.analyzeImage('A Default Prompt over the limit',
        { image: IMAGE, hiddenInstruction: '🙂'.repeat(101), limits }, answer('unused'));
      await recorder.analyzeImage('Code points, not UTF-16 units, are counted',
        { image: IMAGE, userQuestion: '🙂'.repeat(100), limits }, answer('Fits.'));
      await recorder.followUp('An empty follow-up',
        { text: ' \n ', history: [imageTurn(), { role: 'assistant', content: 'A' }], limits }, answer('unused'));
      await recorder.followUp('A history with an unfinished turn', {
        text: 'Why?', history: [imageTurn(), { role: 'assistant', content: 'A' }, { role: 'user', content: 'Q' }],
        limits,
      }, answer('unused'));
    },
  },
  'verify-key': {
    description: 'The Settings key check sends one token and no thinking, beta, or stream.',
    async run(recorder) {
      await recorder.verifyApiKey('A working key',
        json(200, { content: [{ type: 'text', text: 'Hi' }], stop_reason: 'max_tokens' }));
      await recorder.verifyApiKey('A rejected key', json(403, { error: { message: 'forbidden' } }));
    },
  },
  'session-follow-ups': {
    description: 'Follow-ups build on each answer until the oldest turn is trimmed, with a notice.',
    async run(recorder) {
      const session = new Session(recorder, DEFAULT_PROMPT, { ...DEFAULT_LIMITS, maxConversationTurns: 3 });
      await session.answer('First answer', answer('First.'));
      await session.ask('Second turn', 'Question 1', answer('Answer 1.'));
      await session.ask('Third turn', 'Question 2', answer('Answer 2.'));
      await session.ask('Fourth turn trims the second', 'Question 3', answer('Answer 3.'));
    },
  },
  'session-stopped-first-answer': {
    description: 'A first answer stopped after some text keeps it; a follow-up builds on it.',
    async run(recorder) {
      const session = new Session(recorder, 'Answer in one sentence.');
      await session.answer('Stopped after some text', unfinished('stop', 'Partial', ' answer'));
      await session.ask('Follow-up', 'Go on', answer('The rest.'));
    },
  },
  'session-stopped-before-text': {
    description: 'A first answer stopped before any text leaves a stopped marker.',
    async run(recorder) {
      const session = new Session(recorder);
      await session.answer('Stopped while thinking', unfinished('stop'));
      await session.ask('Follow-up', 'Answer it now', answer('Done.'));
    },
  },
  'session-stopped-follow-up-retry': {
    description: 'Retrying a stopped follow-up resends the same request.',
    async run(recorder) {
      const session = new Session(recorder);
      await session.answer('First answer', answer('First.'));
      await session.ask('Stopped follow-up', 'Why?', unfinished('stop', 'Because'));
      await session.retry('Retry', answer('Because it is.'));
    },
  },
  'session-stopped-follow-up-before-text': {
    description: 'A follow-up stopped before any text is removed.',
    async run(recorder) {
      const session = new Session(recorder);
      await session.answer('First answer', answer('First.'));
      await session.ask('Stopped follow-up', 'Why?', unfinished('stop'));
      await session.ask('Another question', 'What else?', answer('More.'));
    },
  },
  'session-failed-first-answer-retry': {
    description: 'An interrupted first answer keeps its text, marked; Retry resends the first request.',
    async run(recorder) {
      const session = new Session(recorder);
      await session.answer('Interrupted', unfinished('error', 'Partial'));
      await session.retry('Retry', answer('Complete.'));
    },
  },
  'session-failed-first-answer-question': {
    description: 'After a first answer fails with no text, a question becomes a new first request.',
    async run(recorder) {
      const session = new Session(recorder);
      await session.answer('Server error', json(500, {}));
      await session.ask('Question', 'What does it say?', answer('It says hello.'));
    },
  },
  'session-failed-follow-up-retry': {
    description: 'Retrying a failed follow-up resends the same request.',
    async run(recorder) {
      const session = new Session(recorder);
      await session.answer('First answer', answer('First.'));
      await session.ask('Rate limited', 'Why?', { ...json(429, {}), headers: { 'retry-after': '5' } });
      await session.retry('Retry', answer('Because.'));
    },
  },
  'session-failed-follow-up-continues': {
    description: 'A new question after a failed follow-up keeps the failed pair as context.',
    async run(recorder) {
      const session = new Session(recorder);
      await session.answer('First answer', answer('First.'));
      await session.ask('Interrupted', 'Why?', unfinished('error', 'Because'));
      await session.ask('Next question', 'Anything else?', answer('No.'));
    },
  },
  'session-refusal': {
    description: 'Refused text is never kept, so the next question starts a new first request.',
    async run(recorder) {
      const session = new Session(recorder);
      await session.answer('Refused', stream([messageStart, textDelta(0, 'I can'), ...finish('refusal')]));
      await session.ask('Question', 'Try a different part', answer('Sure.'));
    },
  },
};

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('Swift core fixtures', () => {
  it('records the system prompt', async () => {
    await expect(SCREENSHOT_QA_SYSTEM_PROMPT).toMatchFileSnapshot(`${FIXTURES}/system-prompt.txt`);
  });

  it.each(Object.entries(scenarios))('records %s', async (name, scenario) => {
    const recorder = new Recorder();
    await scenario.run(recorder);
    const fixture = { description: scenario.description, steps: recorder.steps };
    await expect(`${JSON.stringify(fixture, null, 2)}\n`).toMatchFileSnapshot(`${FIXTURES}/${name}.json`);
  });
});
