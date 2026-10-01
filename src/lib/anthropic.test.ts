import { afterEach, describe, expect, it, vi } from 'vitest';
import { analyzeImage, followUp, verifyApiKey, AnthropicError } from './anthropic';
import { SCREENSHOT_QA_SYSTEM_PROMPT } from './screenshot-qa-prompt';
import type { AnthropicContentBlock, AnthropicMessage } from './messages';
import { DEFAULT_LIMITS } from './storage';

type SseEvent = Record<string, unknown>;

function sseBody(events: SseEvent[]): string {
  return events
    .map((event) => `event: ${event.type as string}\ndata: ${JSON.stringify(event)}\n\n`)
    .join('');
}

function stubFetch(
  body: string | unknown,
  init?: { status?: number; statusText?: string; headers?: Record<string, string> },
): ReturnType<typeof vi.fn> {
  const raw = typeof body === 'string' ? body : JSON.stringify(body);
  const mock = vi.fn(
    async () =>
      new Response(raw, {
        status: init?.status ?? 200,
        statusText: init?.statusText,
        headers: init?.headers,
      }),
  );
  vi.stubGlobal('fetch', mock);
  return mock;
}

function pngDataUrl(width: number, height: number, bytes = 24): string {
  const data = new Uint8Array(Math.max(bytes, 24));
  data.set([137, 80, 78, 71, 13, 10, 26, 10], 0);
  data.set([0, 0, 0, 13, 73, 72, 68, 82], 8);
  new DataView(data.buffer).setUint32(16, width);
  new DataView(data.buffer).setUint32(20, height);
  let binary = '';
  for (const byte of data) binary += String.fromCharCode(byte);
  return `data:image/png;base64,${btoa(binary)}`;
}

function stubStream(events: SseEvent[]): ReturnType<typeof vi.fn> {
  return stubFetch(sseBody(events), {
    headers: { 'content-type': 'text/event-stream' },
  });
}

function stubChunkedStream(chunks: Uint8Array[]): ReturnType<typeof vi.fn> {
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(chunk);
      controller.close();
    },
  });
  const mock = vi.fn(async () => new Response(stream));
  vi.stubGlobal('fetch', mock);
  return mock;
}

function stubHangingStream(): ReturnType<typeof vi.fn> {
  const stream = new ReadableStream<Uint8Array>({ start() {} });
  const mock = vi.fn(async () => new Response(stream));
  vi.stubGlobal('fetch', mock);
  return mock;
}

function lastRequestBody(mock: ReturnType<typeof vi.fn>): Record<string, unknown> {
  const [, requestInit] = mock.mock.calls[0] as [string, RequestInit];
  return JSON.parse(requestInit.body as string) as Record<string, unknown>;
}

function requestBodies(mock: ReturnType<typeof vi.fn>): Array<Record<string, unknown>> {
  return mock.mock.calls.map((call) => {
    const [, requestInit] = call as [string, RequestInit];
    return JSON.parse(requestInit.body as string) as Record<string, unknown>;
  });
}

function lastRequestHeaders(mock: ReturnType<typeof vi.fn>): Record<string, string> {
  const [, requestInit] = mock.mock.calls[0] as [string, RequestInit];
  return requestInit.headers as Record<string, string>;
}

function textDelta(text: string): SseEvent {
  return { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text } };
}

function reasoningDelta(type: string, fields: Record<string, unknown>): SseEvent {
  return { type: 'content_block_delta', index: 0, delta: { type, ...fields } };
}

function messageDelta(stopReason: string): SseEvent {
  return { type: 'message_delta', delta: { stop_reason: stopReason } };
}

function messageStop(): SseEvent {
  return { type: 'message_stop' };
}

const okEvents = [
  textDelta('Ans'),
  textDelta('wer'),
  messageDelta('end_turn'),
  messageStop(),
];

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe('analyzeImage', () => {
  it('builds automatic screenshot analysis with image input and hidden instructions', async () => {
    const hiddenInstruction = 'What does this show? Answer accurately and concisely.';
    const mock = stubStream(okEvents);
    const result = await analyzeImage('key', 'data:image/png;base64,QUJD', {
      hiddenInstruction,
    });

    expect(result.text).toBe('Answer');
    expect(result.history).toHaveLength(2);

    const content = result.history[0].content as AnthropicContentBlock[];
    expect(content).toHaveLength(2);
    expect(content[0]).toEqual({
      type: 'image',
      source: { type: 'base64', media_type: 'image/png', data: 'QUJD' },
    });
    expect(content[1]).toEqual({
      type: 'text',
      text: `Screenshot task guidance:\n${hiddenInstruction}`,
    });
    expect(result.history[1]).toEqual({ role: 'assistant', content: 'Answer' });

    const body = lastRequestBody(mock);
    const requestMessages = body.messages as AnthropicMessage[];
    const requestContent = requestMessages[0].content as AnthropicContentBlock[];
    expect(requestContent).toEqual(content);
    expect(JSON.stringify(body.messages)).toContain(hiddenInstruction);
    expect(body.system).toContain(SCREENSHOT_QA_SYSTEM_PROMPT);
    expect(body.system).not.toContain(hiddenInstruction);
    expect(body.model).toBe('claude-sonnet-5-5');
    expect(body.thinking).toEqual({ type: 'between_tools' });
    expect(body.output_config).toEqual({ effort: 'high' });
    expect(body.fallbacks).toBe('default');
    expect(body.stream).toBe(true);
    expect(body.cache_control).toEqual({ type: 'ephemeral' });
    expect(lastRequestHeaders(mock)['anthropic-beta']).toBe('server-side-fallback-2026-07-01');
  });

  it('adds a manual fallback question after the image when provided', async () => {
    stubStream(okEvents);
    const result = await analyzeImage('key', 'data:image/png;base64,QUJD', {
      hiddenInstruction: 'Keep it concise.',
      userQuestion: 'What is the answer?',
    });

    const content = result.history[0].content as AnthropicContentBlock[];
    expect(content[0]).toMatchObject({ type: 'image' });
    expect(content[1]).toEqual({
      type: 'text',
      text: 'Screenshot task guidance:\nKeep it concise.',
    });
    expect(content[2]).toEqual({ type: 'text', text: 'What is the answer?' });
  });

  it('rejects configured screenshot and question overflow before fetch', async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);

    await expect(analyzeImage('key', pngDataUrl(2_577, 100), {
      limits: DEFAULT_LIMITS,
    })).rejects.toMatchObject({ code: 'screenshot_dimensions_too_large' });

    await expect(analyzeImage('key', pngDataUrl(100, 100), {
      limits: { ...DEFAULT_LIMITS, maxInputCharacters: 100 },
      userQuestion: 'x'.repeat(101),
    })).rejects.toMatchObject({ code: 'input_too_long' });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('reports cumulative stream progress through onDelta', async () => {
    stubStream(okEvents);
    const seen: string[] = [];
    await analyzeImage('key', 'data:image/png;base64,QUJD', {
      onDelta: (text) => seen.push(text),
    });
    expect(seen).toEqual(['Ans', 'Answer']);
  });

  it('ignores reasoning-style stream deltas and renders only final answer text', async () => {
    stubStream([
      reasoningDelta('thinking_delta', { thinking: 'First I will reason privately.' }),
      reasoningDelta('reasoning_delta', { reasoning_content: 'Hidden chain of thought.' }),
      reasoningDelta('analysis_delta', { analysis: 'Scratch work.' }),
      textDelta('Final'),
      textDelta(' answer'),
      messageDelta('end_turn'),
      messageStop(),
    ]);
    const seen: string[] = [];

    const result = await analyzeImage('key', 'data:image/png;base64,QUJD', {
      onDelta: (text) => seen.push(text),
    });

    expect(result.text).toBe('Final answer');
    expect(seen).toEqual(['Final', 'Final answer']);
  });

  it('preserves technical and Markdown-looking syntax in final and streaming text', async () => {
    stubStream([
      textDelta('1. `user_'),
      textDelta('id` = value_1 # exact'),
      messageDelta('end_turn'),
      messageStop(),
    ]);
    const seen: string[] = [];
    const result = await analyzeImage('key', 'data:image/png;base64,QUJD');

    expect(result.text).toBe('1. `user_id` = value_1 # exact');

    stubStream([
      textDelta('**Bold**'),
      textDelta(' and `code_value`'),
      messageDelta('end_turn'),
      messageStop(),
    ]);
    const streamed = await analyzeImage('key', 'data:image/png;base64,QUJD', {
      onDelta: (text) => seen.push(text),
    });
    expect(streamed.text).toBe('**Bold** and `code_value`');
    expect(seen).toEqual(['**Bold**', '**Bold** and `code_value`']);
  });

  it('continues streamed text across a server-side refusal fallback boundary', async () => {
    stubStream([
      textDelta('Par'),
      {
        type: 'content_block_start',
        index: 1,
        content_block: {
          type: 'fallback',
          from: { model: 'claude-sonnet-5-5' },
          to: { model: 'claude-sonnet-5' },
        },
      },
      { type: 'content_block_stop', index: 1 },
      textDelta('tial answer'),
      messageDelta('end_turn'),
      messageStop(),
    ]);
    const seen: string[] = [];

    const result = await analyzeImage('key', 'data:image/png;base64,QUJD', {
      onDelta: (text) => seen.push(text),
    });

    expect(result.text).toBe('Partial answer');
    expect(seen).toEqual(['Par', 'Partial answer']);
  });

  it('appends a cut-off notice when stop_reason is max_tokens', async () => {
    stubStream([textDelta('Partial'), messageDelta('max_tokens'), messageStop()]);
    const result = await analyzeImage('key', 'data:image/png;base64,QUJD');
    expect(result.text).toContain('Partial');
    expect(result.text).toContain('cut off');
  });

  it('closes a code block interrupted by max_tokens before the cut-off notice', async () => {
    stubStream([
      textDelta('```python\ndef add(a, b):\n    return a'),
      messageDelta('max_tokens'),
      messageStop(),
    ]);
    const result = await analyzeImage('key', 'data:image/png;base64,QUJD');

    expect(result.text).toBe(
      '```python\ndef add(a, b):\n    return a\n```\n\n'
        + '(Answer was cut off — ask a follow-up to continue.)',
    );
  });

  it('rejects a whitespace-only completed response', async () => {
    stubStream([textDelta(' \n\t '), messageDelta('end_turn'), messageStop()]);

    await expect(analyzeImage('key', 'data:image/png;base64,QUJD')).rejects.toMatchObject({
      code: 'api',
      message: 'No response text received from the API.',
    });
  });

  it('throws a refusal error when stop_reason is refusal', async () => {
    stubStream([messageDelta('refusal'), messageStop()]);
    await expect(analyzeImage('key', 'data:image/png;base64,QUJD')).rejects.toMatchObject({
      code: 'refusal',
    });
  });

  it('surfaces error events from the stream', async () => {
    stubStream([
      textDelta('Par'),
      { type: 'error', error: { type: 'overloaded_error', message: 'Overloaded' } },
    ]);
    await expect(analyzeImage('key', 'data:image/png;base64,QUJD')).rejects.toMatchObject({
      code: 'api',
      message: 'Overloaded',
    });
  });

  it('redacts and caps provider messages from stream error events', async () => {
    const secret = 'sk-ant-api03-supersecretvalue123456789';
    stubStream([{
      type: 'error',
      error: {
        type: 'api_error',
        message: `Bad\u0000  key ${secret} ${'x'.repeat(500)}`,
      },
    }]);

    const promise = analyzeImage('key', 'data:image/png;base64,QUJD');
    await expect(promise).rejects.toMatchObject({ code: 'api' });
    try {
      await promise;
    } catch (error) {
      expect(error).toBeInstanceOf(AnthropicError);
      const message = (error as Error).message;
      expect(message).toHaveLength(240);
      expect(message).toContain('Bad key [REDACTED API KEY]');
      expect(message).not.toContain(secret);
      expect(message).not.toContain('\u0000');
    }
  });

  it('parses CRLF, multiline data, arbitrary byte chunks, and a trailing event', async () => {
    const body = [
      'event: content_block_delta\r\n',
      'data: {"type":\r\n',
      'data: "content_block_delta","delta":{"type":"text_delta","text":"café_#1"}}\r\n',
      '\r\n',
      `event: message_delta\r\ndata: ${JSON.stringify(messageDelta('end_turn'))}\r\n\r\n`,
      `event: message_stop\r\ndata: ${JSON.stringify(messageStop())}`,
    ].join('');
    const bytes = new TextEncoder().encode(body);
    stubChunkedStream(Array.from(bytes, (_, index) => bytes.slice(index, index + 1)));

    const result = await analyzeImage('key', 'data:image/png;base64,QUJD');

    expect(result.text).toBe('café_#1');
  });

  it('rejects malformed JSON as a typed stream error', async () => {
    stubFetch('event: content_block_delta\ndata: {not valid JSON}\n\n');

    await expect(analyzeImage('key', 'data:image/png;base64,QUJD')).rejects.toMatchObject({
      code: 'stream',
      message: expect.stringContaining('malformed'),
    });
  });

  it('rejects EOF before message_stop as a typed incomplete-stream error', async () => {
    stubStream([textDelta('Partial'), messageDelta('end_turn')]);

    await expect(analyzeImage('key', 'data:image/png;base64,QUJD')).rejects.toMatchObject({
      code: 'stream',
      message: expect.stringContaining('before it was complete'),
    });
  });

  it('maps a timeout while awaiting the initial response', async () => {
    const timeout = new AbortController();
    vi.spyOn(AbortSignal, 'timeout').mockReturnValue(timeout.signal);
    vi.stubGlobal(
      'fetch',
      vi.fn(
        async (_url: string, init?: RequestInit) =>
          new Promise<Response>((_resolve, reject) => {
            const requestSignal = init?.signal;
            if (!(requestSignal instanceof AbortSignal)) return;
            requestSignal.addEventListener('abort', () => reject(requestSignal.reason), {
              once: true,
            });
          }),
      ),
    );

    const result = analyzeImage('key', 'data:image/png;base64,QUJD');
    timeout.abort(new DOMException('Timed out', 'TimeoutError'));

    await expect(result).rejects.toMatchObject({
      code: 'timeout',
      message: 'Request timed out. Please try again.',
    });
  });

  it('maps a timeout while consuming the response body', async () => {
    const timeout = new AbortController();
    const timeoutSpy = vi.spyOn(AbortSignal, 'timeout').mockReturnValue(timeout.signal);
    stubHangingStream();

    const result = analyzeImage('key', 'data:image/png;base64,QUJD');
    await Promise.resolve();
    timeout.abort(new DOMException('Timed out', 'TimeoutError'));

    await expect(result).rejects.toMatchObject({
      code: 'timeout',
      message: 'Request timed out. Please try again.',
    });
    expect(timeoutSpy).toHaveBeenCalledWith(120_000);
  });

  it('preserves a caller AbortError while consuming the response body', async () => {
    stubHangingStream();
    const controller = new AbortController();
    const abortError = new DOMException('Stopped by user', 'AbortError');

    const result = analyzeImage('key', 'data:image/png;base64,QUJD', {
      signal: controller.signal,
    });
    await Promise.resolve();
    controller.abort(abortError);

    await expect(result).rejects.toBe(abortError);
  });

  it('maps 401 to an auth error', async () => {
    const mock = stubFetch({}, { status: 401 });
    const promise = analyzeImage('key', 'data:image/png;base64,QUJD');
    await expect(promise).rejects.toBeInstanceOf(AnthropicError);
    await expect(promise).rejects.toMatchObject({ code: 'auth' });
    const response = await mock.mock.results[0].value as Response;
    expect(response.bodyUsed).toBe(true);
  });

  it('includes retry-after timing in 429 errors', async () => {
    stubFetch({}, { status: 429, headers: { 'retry-after': '30' } });
    await expect(analyzeImage('key', 'data:image/png;base64,QUJD')).rejects.toMatchObject({
      code: 'rate_limit',
      message: expect.stringContaining('~30s'),
    });
  });

  it('maps 500 to a server error', async () => {
    stubFetch({}, { status: 500 });
    await expect(analyzeImage('key', 'data:image/png;base64,QUJD')).rejects.toMatchObject({
      code: 'server',
    });
  });

  it('exposes only a bounded, redacted provider message for other API errors', async () => {
    stubFetch(
      { error: { message: 'Bad key sk-ant-api03-supersecretvalue123456789' } },
      { status: 400, statusText: 'Bad Request' },
    );

    await expect(analyzeImage('key', 'data:image/png;base64,QUJD')).rejects.toMatchObject({
      code: 'api',
      message: 'API error (400): Bad key [REDACTED API KEY]',
    });
  });

  it('does not reflect non-JSON or oversized provider bodies', async () => {
    stubFetch('<html>secret diagnostics</html>', {
      status: 400,
      statusText: 'Bad Request',
    });
    await expect(analyzeImage('key', 'data:image/png;base64,QUJD')).rejects.toMatchObject({
      message: 'API error (400): Bad Request',
    });

    stubFetch(JSON.stringify({ error: { message: 'x'.repeat(20_000) } }), {
      status: 400,
      statusText: 'Bad Request',
    });
    await expect(analyzeImage('key', 'data:image/png;base64,QUJD')).rejects.toMatchObject({
      message: 'API error (400): Bad Request',
    });
  });

  it('redacts, normalizes, and caps status text used as an API error fallback', async () => {
    const secret = 'sk-ant-api03-supersecretvalue123456789';
    stubFetch('<html>not JSON</html>', {
      status: 400,
      statusText: `  Bad   key ${secret} ${'x'.repeat(500)}`,
    });

    const promise = analyzeImage('key', 'data:image/png;base64,QUJD');
    await expect(promise).rejects.toMatchObject({ code: 'api' });
    try {
      await promise;
    } catch (error) {
      expect(error).toBeInstanceOf(AnthropicError);
      const message = (error as Error).message;
      const detail = message.slice('API error (400): '.length);
      expect(detail).toHaveLength(240);
      expect(detail).toContain('Bad key [REDACTED API KEY]');
      expect(detail).not.toContain(secret);
      expect(detail).not.toContain('  ');
    }
  });

  it('caps a valid provider error message before displaying it', async () => {
    stubFetch({ error: { message: 'x'.repeat(500) } }, {
      status: 400,
      statusText: 'Bad Request',
    });

    const promise = analyzeImage('key', 'data:image/png;base64,QUJD');
    await expect(promise).rejects.toMatchObject({ code: 'api' });
    try {
      await promise;
    } catch (error) {
      expect(error).toBeInstanceOf(AnthropicError);
      expect((error as Error).message).toBe(`API error (400): ${'x'.repeat(240)}`);
    }
  });
});

describe('followUp', () => {
  it('appends the question and answer to the existing history', async () => {
    stubStream(okEvents);
    const history: AnthropicMessage[] = [
      { role: 'user', content: 'earlier question' },
      { role: 'assistant', content: 'earlier answer' },
    ];

    const result = await followUp('key', 'And this?', history);

    expect(result.history).toHaveLength(4);
    expect(result.history[2]).toEqual({ role: 'user', content: 'And this?' });
    expect(result.history[3]).toEqual({ role: 'assistant', content: 'Answer' });
    expect(history).toHaveLength(2); // input history is not mutated
  });

  it('keeps saved prompt guidance in the initial image turn for follow-ups', async () => {
    const mock = stubStream(okEvents);
    const imageData = pngDataUrl(100, 100).split(',')[1];

    await followUp(
      'key',
      'And this?',
      [
        {
          role: 'user',
          content: [
            {
              type: 'image',
              source: { type: 'base64', media_type: 'image/png', data: imageData },
            },
          ],
        },
        { role: 'assistant', content: 'Earlier answer' },
      ],
      { sessionInstruction: 'Always answer using SI units.' },
    );

    const body = lastRequestBody(mock);
    expect(body.system).not.toContain('Always answer using SI units.');
    const messages = body.messages as AnthropicMessage[];
    expect(messages[0].content).toEqual([
      {
        type: 'image',
        source: { type: 'base64', media_type: 'image/png', data: imageData },
      },
      {
        type: 'text',
        text: 'Screenshot task guidance:\nAlways answer using SI units.',
      },
    ]);
  });

  it('does not replace pinned session guidance with changed settings', async () => {
    const mock = stubStream(okEvents);
    const imageData = pngDataUrl(100, 100).split(',')[1];
    const history: AnthropicMessage[] = [
      {
        role: 'user',
        content: [
          {
            type: 'image',
            source: { type: 'base64', media_type: 'image/png', data: imageData },
          },
          { type: 'text', text: 'Screenshot task guidance:\nOriginal guidance.' },
        ],
      },
      { role: 'assistant', content: 'Earlier answer' },
    ];

    await followUp(
      'key',
      'And this?',
      history,
      { sessionInstruction: 'Changed guidance.' },
    );

    const messages = lastRequestBody(mock).messages as AnthropicMessage[];
    expect(JSON.stringify(messages)).toContain('Original guidance.');
    expect(JSON.stringify(messages)).not.toContain('Changed guidance.');
  });

  it('prunes only complete oldest turns while preserving the pinned image and newest request', async () => {
    const mock = stubStream(okEvents);
    const imageData = pngDataUrl(100, 100).split(',')[1];
    const imageTurn: AnthropicMessage[] = [
      {
        role: 'user',
        content: [{
          type: 'image',
          source: { type: 'base64', media_type: 'image/png', data: imageData },
        }],
      },
      { role: 'assistant', content: 'initial' },
    ];
    const turn = (index: number): AnthropicMessage[] => [
      { role: 'user', content: `q${index}` },
      { role: 'assistant', content: `a${index}` },
    ];

    await followUp(
      'key',
      'newest',
      [...imageTurn, ...turn(1), ...turn(2), ...turn(3)],
      { limits: { ...DEFAULT_LIMITS, maxConversationTurns: 3 } },
    );

    expect(lastRequestBody(mock).messages).toEqual([
      ...imageTurn,
      ...turn(3),
      { role: 'user', content: 'newest' },
    ]);
  });

  it('resends the first request unchanged under the same system prompt so it can hit the cache', async () => {
    const mock = stubStream(okEvents);
    const first = await analyzeImage('key', pngDataUrl(100, 100), {
      hiddenInstruction: 'Keep it concise.',
    });
    await followUp('key', 'And this?', first.history, {
      sessionInstruction: 'Keep it concise.',
    });

    const [firstBody, followUpBody] = requestBodies(mock);
    expect(followUpBody.cache_control).toEqual({ type: 'ephemeral' });
    expect(followUpBody.system).toBe(firstBody.system);
    const firstMessages = firstBody.messages as AnthropicMessage[];
    expect(
      (followUpBody.messages as AnthropicMessage[]).slice(0, firstMessages.length),
    ).toEqual(firstMessages);
  });
});

describe('verifyApiKey', () => {
  it('resolves for a working key', async () => {
    const mock = stubFetch({ content: [{ type: 'text', text: 'Hi' }] });
    await expect(verifyApiKey('key')).resolves.toBeUndefined();
    const body = lastRequestBody(mock);
    expect(body.model).toBe('claude-sonnet-5-5');
    expect(body.max_tokens).toBe(1);
    expect(body.thinking).toEqual({ type: 'between_tools' });
    expect(body.stream).toBeUndefined();
    expect(lastRequestHeaders(mock)['anthropic-beta']).toBeUndefined();
    const response = await mock.mock.results[0].value as Response;
    expect(response.bodyUsed).toBe(true);
  });

  it('rejects with an auth error for a bad key', async () => {
    stubFetch({}, { status: 403 });
    await expect(verifyApiKey('bad')).rejects.toMatchObject({ code: 'auth' });
  });
});
