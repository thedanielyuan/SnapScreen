import { describe, expect, it } from 'vitest';
import {
  appendAssistantMessage,
  appendGenerationStoppedMessage,
  appendUserMessage,
  settleStoppedGeneration,
  settleStoppedConversation,
  settleFailedFirstAnswer,
  settleFailedFollowUp,
  restoreBeforeFailedFollowUp,
  settleSuccessfulConversation,
  settleSuccessfulFollowUp,
  prepareAlignedConversationForNewestTurn,
  clearIncompleteInitialFailure,
  createInitialDisplay,
} from './conversation-state';
import type { AnthropicContentBlock, AnthropicMessage, DisplayMessage } from '../lib/messages';

describe('conversation display state', () => {
  it('starts automatic screenshot analysis without a visible prompt', () => {
    const hiddenPrompt = 'What does this show? Answer accurately and concisely.';
    const messages = createInitialDisplay();

    expect(messages).toEqual([]);
    expect(JSON.stringify(messages)).not.toContain(hiddenPrompt);
  });

  it('shows only the assistant answer for automatic screenshot analysis', () => {
    const messages = appendAssistantMessage([], 'B. Photosynthesis');

    expect(messages).toEqual([
      { role: 'assistant', content: 'B. Photosynthesis' },
    ]);
  });

  it('starts a resnip with a fresh empty visible conversation', () => {
    const firstCapture = appendAssistantMessage(createInitialDisplay(), 'First answer');
    const resnipped = createInitialDisplay();

    expect(firstCapture).toHaveLength(1);
    expect(resnipped).toEqual([]);
  });

  it('keeps manually typed follow-ups visible in the thread', () => {
    const initial: DisplayMessage[] = [
      { role: 'assistant', content: 'B. Photosynthesis' },
    ];

    const withQuestion = appendUserMessage(initial, 'Why?');
    const withAnswer = appendAssistantMessage(withQuestion, 'It converts light energy into chemical energy.');

    expect(withAnswer).toEqual([
      { role: 'assistant', content: 'B. Photosynthesis' },
      { role: 'user', content: 'Why?' },
      { role: 'assistant', content: 'It converts light energy into chemical energy.' },
    ]);
  });

  it('shows a clean stopped message without partial reasoning', () => {
    const messages = appendGenerationStoppedMessage([]);

    expect(messages).toEqual([
      { role: 'assistant', content: 'Generation stopped.' },
    ]);
    expect(messages[0].content).not.toContain('reasoning');
    expect(messages[0].content).not.toContain('scratchpad');
  });

  it('shows stopped message when stopped before clean final text streams', () => {
    expect(settleStoppedGeneration([], '')).toEqual([
      { role: 'assistant', content: 'Generation stopped.' },
    ]);
  });

  it('keeps partial clean final text when stopped after answer streaming starts', () => {
    expect(settleStoppedGeneration([], '  The answer is 42.  ')).toEqual([
      { role: 'assistant', content: 'The answer is 42.' },
    ]);
  });
});

describe('successful conversation state', () => {
  it('reconstructs hidden screenshot history when a completed initial result omits it', () => {
    const state = settleSuccessfulConversation({
      kind: 'initial',
      baseDisplayMessages: [],
      baseHistory: [],
      assistantText: 'Initial answer',
      dataUrl: 'data:image/png;base64,QUJD',
      sessionInstruction: 'What does this show? Answer accurately and concisely.',
    });

    expect(state.displayMessages).toEqual([
      { role: 'assistant', content: 'Initial answer' },
    ]);
    expect(state.conversationHistory).toHaveLength(2);
    expect((state.conversationHistory[0].content as AnthropicContentBlock[])[0])
      .toMatchObject({ type: 'image', source: { data: 'QUJD' } });
    expect(JSON.stringify(state.conversationHistory[0])).toContain(
      'What does this show? Answer accurately and concisely.',
    );
  });

  it('reconstructs an aligned manual follow-up when provider history is omitted', () => {
    const baseDisplay: DisplayMessage[] = [
      { role: 'assistant', content: 'Initial answer' },
    ];
    const baseHistory: AnthropicMessage[] = [
      { role: 'user', content: 'Hidden screenshot turn' },
      { role: 'assistant', content: 'Initial answer' },
    ];
    const state = settleSuccessfulConversation({
      kind: 'follow-up',
      baseDisplayMessages: baseDisplay,
      baseHistory,
      assistantText: 'Because.',
      dataUrl: 'data:image/png;base64,QUJD',
      userText: 'Why?',
    });

    expect(state.displayMessages).toEqual([
      ...baseDisplay,
      { role: 'user', content: 'Why?' },
      { role: 'assistant', content: 'Because.' },
    ]);
    expect(state.conversationHistory).toEqual([
      ...baseHistory,
      { role: 'user', content: 'Why?' },
      { role: 'assistant', content: 'Because.' },
    ]);
  });
});

describe('stopped conversation state', () => {
  const priorDisplay: DisplayMessage[] = [
    { role: 'assistant', content: 'Original answer' },
  ];
  const priorHistory: AnthropicMessage[] = [
    { role: 'user', content: 'Original question' },
    { role: 'assistant', content: 'Original answer' },
  ];

  it('commits a stopped follow-up with partial text to both histories', () => {
    const state = settleStoppedConversation({
      kind: 'follow-up',
      baseDisplayMessages: priorDisplay,
      baseHistory: priorHistory,
      partialAnswer: '  Partial reply  ',
      dataUrl: 'data:image/png;base64,QUJD',
      userText: 'Why?',
    });

    expect(state.displayMessages.slice(-2)).toEqual([
      { role: 'user', content: 'Why?' },
      { role: 'assistant', content: 'Partial reply' },
    ]);
    expect(state.conversationHistory.slice(-2)).toEqual([
      { role: 'user', content: 'Why?' },
      { role: 'assistant', content: 'Partial reply' },
    ]);
  });

  it('removes an unfinished follow-up when stopped before text arrives', () => {
    const state = settleStoppedConversation({
      kind: 'follow-up',
      baseDisplayMessages: priorDisplay,
      baseHistory: priorHistory,
      partialAnswer: '',
      dataUrl: 'data:image/png;base64,QUJD',
      userText: 'Why?',
    });

    expect(state.displayMessages).toEqual(priorDisplay);
    expect(state.conversationHistory).toEqual(priorHistory);
  });

  it('keeps the current stopped marker for an initial request with no text', () => {
    const state = settleStoppedConversation({
      kind: 'initial',
      baseDisplayMessages: [],
      baseHistory: [],
      partialAnswer: '',
      dataUrl: 'data:image/png;base64,QUJD',
      sessionInstruction: 'Initial prompt',
    });

    expect(state.displayMessages).toEqual([
      { role: 'assistant', content: 'Generation stopped.' },
    ]);
    expect(state.conversationHistory).toEqual([
      {
        role: 'user',
        content: [
          {
            type: 'image',
            source: { type: 'base64', media_type: 'image/png', data: 'QUJD' },
          },
          {
            type: 'text',
            text: 'Screenshot task guidance:\nInitial prompt',
          },
        ],
      },
      { role: 'assistant', content: 'Generation stopped.' },
    ]);
  });

  it('retains image context when initial analysis is stopped with partial text', () => {
    const state = settleStoppedConversation({
      kind: 'initial',
      baseDisplayMessages: [],
      baseHistory: [],
      partialAnswer: 'Partial answer',
      dataUrl: 'data:image/png;base64,QUJD',
      sessionInstruction: 'Answer the screenshot.',
    });

    const content = state.conversationHistory[0].content as AnthropicContentBlock[];
    expect(content[0]).toMatchObject({
      type: 'image',
      source: { data: 'QUJD' },
    });
    expect(content[1]).toEqual({
      type: 'text',
      text: 'Screenshot task guidance:\nAnswer the screenshot.',
    });
    expect(state.conversationHistory[1]).toEqual({
      role: 'assistant',
      content: 'Partial answer',
    });
  });
});

describe('failed first answer', () => {
  function fail(partialAnswer: string) {
    return settleFailedFirstAnswer({
      partialAnswer,
      errorMessage: 'Request timed out.',
      dataUrl: 'data:image/png;base64,QUJD',
      sessionInstruction: 'Answer the screenshot.',
    });
  }

  it('keeps streamed text, marked interrupted, in both histories', () => {
    const failed = fail('  Partial answer  ');
    const assistantText = 'Partial answer\n\nResponse interrupted: Request timed out.';

    expect(failed.displayMessages).toEqual([
      { role: 'assistant', content: assistantText, status: 'failed' },
    ]);
    expect(failed.conversationHistory).toEqual([
      {
        role: 'user',
        content: [
          {
            type: 'image',
            source: { type: 'base64', media_type: 'image/png', data: 'QUJD' },
          },
          { type: 'text', text: 'Screenshot task guidance:\nAnswer the screenshot.' },
        ],
      },
      { role: 'assistant', content: assistantText },
    ]);
  });

  it('keeps nothing when no text streamed', () => {
    expect(fail('  ')).toEqual({ displayMessages: [], conversationHistory: [] });
  });

  it('stays aligned for a follow-up', () => {
    const failed = fail('Partial answer');
    const followUpDisplay = settleSuccessfulFollowUp(
      failed.displayMessages,
      'Go on',
      'The rest.',
    );
    const followUpHistory: AnthropicMessage[] = [
      ...failed.conversationHistory,
      { role: 'user', content: 'Go on' },
      { role: 'assistant', content: 'The rest.' },
    ];

    expect(() => prepareAlignedConversationForNewestTurn(
      followUpDisplay,
      followUpHistory,
      2,
    )).not.toThrow();
  });
});

describe('failed follow-up consistency', () => {
  const priorDisplay: DisplayMessage[] = [
    { role: 'assistant', content: 'Initial answer' },
  ];
  const priorHistory: AnthropicMessage[] = [
    { role: 'user', content: 'Initial prompt' },
    { role: 'assistant', content: 'Initial answer' },
  ];

  function fail(partialAnswer = '') {
    return settleFailedFollowUp({
      baseDisplayMessages: priorDisplay,
      baseHistory: priorHistory,
      partialAnswer,
      errorMessage: 'Network disconnected.',
      dataUrl: 'data:image/png;base64,QUJD',
      userText: 'Why?',
    });
  }

  it('records a non-stop failure as the same complete pair in visible and model history', () => {
    const failed = fail();

    expect(failed.displayMessages.slice(-2)).toEqual([
      { role: 'user', content: 'Why?' },
      {
        role: 'assistant',
        content: 'Response failed: Network disconnected.',
        status: 'failed',
      },
    ]);
    expect(failed.conversationHistory.slice(-2)).toEqual([
      { role: 'user', content: 'Why?' },
      { role: 'assistant', content: 'Response failed: Network disconnected.' },
    ]);
  });

  it('retains partial streamed text and marks it interrupted in both histories', () => {
    const failed = fail('Partial answer');
    expect(failed.displayMessages.at(-1)?.content).toBe(
      'Partial answer\n\nResponse interrupted: Network disconnected.',
    );
    expect(failed.conversationHistory.at(-1)?.content).toBe(
      'Partial answer\n\nResponse interrupted: Network disconnected.',
    );
  });

  it('failure then retry restores the saved bases before resubmitting once', () => {
    const restored = restoreBeforeFailedFollowUp(fail());
    expect(restored).toEqual({
      displayMessages: priorDisplay,
      conversationHistory: priorHistory,
    });
    expect(settleSuccessfulFollowUp(restored.displayMessages, 'Why?', 'Because.')).toEqual([
      ...priorDisplay,
      { role: 'user', content: 'Why?' },
      { role: 'assistant', content: 'Because.' },
    ]);
  });

  it('failure then remove restores both histories exactly', () => {
    expect(restoreBeforeFailedFollowUp(fail())).toEqual({
      displayMessages: priorDisplay,
      conversationHistory: priorHistory,
    });
  });

  it('failure then later message keeps the complete marked pair as aligned context', () => {
    const failed = fail();
    const laterDisplay = settleSuccessfulFollowUp(
      failed.displayMessages,
      'Different question',
      'Later answer',
    );
    const laterHistory = [
      ...failed.conversationHistory,
      { role: 'user' as const, content: 'Different question' },
      { role: 'assistant' as const, content: 'Later answer' },
    ];

    expect(laterDisplay.map(({ role, content }) => ({ role, content }))).toEqual(
      laterHistory.slice(1),
    );
  });

  it('keeps the screenshot in model history when an imageless fallback request fails', () => {
    const failed = settleFailedFollowUp({
      baseDisplayMessages: [],
      baseHistory: [],
      partialAnswer: '',
      errorMessage: 'Request failed.',
      dataUrl: 'data:image/png;base64,QUJD',
      sessionInstruction: 'Answer the screenshot.',
      userText: 'Can you answer it?',
    });
    const content = failed.conversationHistory[0].content as AnthropicContentBlock[];

    expect(content[0]).toMatchObject({ type: 'image', source: { data: 'QUJD' } });
    expect(content.at(-1)).toEqual({ type: 'text', text: 'Can you answer it?' });
    expect(failed.conversationHistory).toHaveLength(2);
  });

  it('preserves a prior stopped marker before a failed fallback so a later turn stays aligned', () => {
    const stoppedDisplay: DisplayMessage[] = [
      { role: 'assistant', content: 'Generation stopped.' },
    ];
    const failed = settleFailedFollowUp({
      baseDisplayMessages: stoppedDisplay,
      baseHistory: [],
      partialAnswer: '',
      errorMessage: 'Request failed.',
      dataUrl: 'data:image/png;base64,QUJD',
      sessionInstruction: 'Initial prompt',
      userText: 'Can you answer it?',
    });

    expect(failed.displayMessages).toHaveLength(3);
    expect(failed.conversationHistory).toHaveLength(4);
    expect((failed.conversationHistory[0].content as AnthropicContentBlock[])[0])
      .toMatchObject({ type: 'image' });
    expect(failed.conversationHistory[1]).toEqual({
      role: 'assistant',
      content: 'Generation stopped.',
    });
  });
});

describe('aligned history limits', () => {
  it('prunes the same oldest complete pairs before reserving the newest turn', () => {
    const display: DisplayMessage[] = [
      { role: 'assistant', content: 'Initial answer' },
      { role: 'user', content: 'Old' },
      { role: 'assistant', content: 'Old answer' },
      { role: 'user', content: 'Recent' },
      { role: 'assistant', content: 'Recent answer' },
    ];
    const model: AnthropicMessage[] = [
      { role: 'user', content: 'Hidden screenshot prompt' },
      ...display.map(({ role, content }) => ({ role, content })),
    ];

    expect(prepareAlignedConversationForNewestTurn(display, model, 2)).toEqual({
      displayMessages: display.slice(0, 1),
      conversationHistory: model.slice(0, 2),
      removedTurns: 2,
    });
  });

  it('fails closed if visible and model pair counts diverge', () => {
    expect(() => prepareAlignedConversationForNewestTurn(
      [
        { role: 'assistant', content: 'Answer' },
      ],
      [
        { role: 'user', content: 'Prompt' },
        { role: 'assistant', content: 'Answer' },
        { role: 'user', content: 'Extra' },
        { role: 'assistant', content: 'Extra answer' },
      ],
      2,
    )).toThrow('out of sync');
  });

  it('keeps the hidden prompt out of initial failure and retry display state', () => {
    const hiddenPrompt = 'What does this show? Answer accurately and concisely.';
    const pending = createInitialDisplay();
    expect(clearIncompleteInitialFailure()).toEqual({
      displayMessages: [],
      conversationHistory: [],
    });
    const retry = createInitialDisplay();
    expect(retry).toEqual(pending);
    expect(appendAssistantMessage(retry, 'Retry succeeded.')).toEqual([
      { role: 'assistant', content: 'Retry succeeded.' },
    ]);
    expect(JSON.stringify(retry)).not.toContain(hiddenPrompt);
  });

  it('keeps initial stop then follow-up success aligned for later pruning', () => {
    const stopped = settleStoppedConversation({
      kind: 'initial',
      baseDisplayMessages: createInitialDisplay(),
      baseHistory: [],
      partialAnswer: '',
      dataUrl: 'data:image/png;base64,QUJD',
      sessionInstruction: 'Initial prompt',
    });
    const followUpDisplay = settleSuccessfulFollowUp(
      stopped.displayMessages,
      'Try this question',
      'Follow-up answer',
    );
    const followUpHistory: AnthropicMessage[] = [
      ...stopped.conversationHistory,
      { role: 'user', content: 'Try this question' },
      { role: 'assistant', content: 'Follow-up answer' },
    ];

    expect(() => prepareAlignedConversationForNewestTurn(
      followUpDisplay,
      followUpHistory,
      2,
    )).not.toThrow();
  });
});
