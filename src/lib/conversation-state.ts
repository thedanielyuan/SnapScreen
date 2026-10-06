import type {
  AnthropicMessage,
  DisplayMessage,
} from './messages';
import { createScreenshotUserContent } from './session-history';
import {
  RequestLimitError,
  pruneApiHistoryForNewestTurn,
  pruneDisplayHistoryForNewestTurn,
} from './request-limits';

export function appendAssistantMessage(
  messages: DisplayMessage[],
  text: string,
): DisplayMessage[] {
  return [...messages, { role: 'assistant', content: text }];
}

export function createInitialDisplay(): DisplayMessage[] {
  return [];
}

export function appendUserMessage(
  messages: DisplayMessage[],
  text: string,
): DisplayMessage[] {
  return [...messages, { role: 'user', content: text }];
}

export function appendGenerationStoppedMessage(
  messages: DisplayMessage[],
): DisplayMessage[] {
  return appendAssistantMessage(messages, 'Generation stopped.');
}

export function settleStoppedGeneration(
  messages: DisplayMessage[],
  partialAnswer: string,
): DisplayMessage[] {
  const cleanPartial = partialAnswer.trim();
  if (cleanPartial) {
    return appendAssistantMessage(messages, cleanPartial);
  }

  return appendGenerationStoppedMessage(messages);
}

export interface StoppedConversationInput {
  kind: 'initial' | 'follow-up';
  baseDisplayMessages: DisplayMessage[];
  baseHistory: AnthropicMessage[];
  partialAnswer: string;
  dataUrl: string;
  userText?: string;
  sessionInstruction?: string;
}

export interface StoppedConversationState {
  displayMessages: DisplayMessage[];
  conversationHistory: AnthropicMessage[];
}

export interface SuccessfulConversationInput {
  kind: 'initial' | 'follow-up';
  baseDisplayMessages: DisplayMessage[];
  baseHistory: AnthropicMessage[];
  assistantText: string;
  dataUrl: string;
  providerHistory?: AnthropicMessage[];
  userText?: string;
  sessionInstruction?: string;
}

function buildImageTurn(
  dataUrl: string,
  sessionInstruction: string | undefined,
  userText: string | undefined,
  assistantText: string,
): AnthropicMessage[] {
  return [
    {
      role: 'user',
      content: createScreenshotUserContent(dataUrl, sessionInstruction, userText),
    },
    { role: 'assistant', content: assistantText },
  ];
}

export function settleSuccessfulConversation(
  input: SuccessfulConversationInput,
): StoppedConversationState {
  const displayMessages = input.kind === 'follow-up' && input.userText
    ? settleSuccessfulFollowUp(
        input.baseDisplayMessages,
        input.userText,
        input.assistantText,
      )
    : appendAssistantMessage(input.baseDisplayMessages, input.assistantText);

  if (input.providerHistory && input.providerHistory.length > 0) {
    return {
      displayMessages,
      conversationHistory: [...input.providerHistory],
    };
  }

  const conversationHistory = input.baseHistory.length > 0 && input.userText
    ? [
        ...input.baseHistory,
        { role: 'user' as const, content: input.userText },
        { role: 'assistant' as const, content: input.assistantText },
      ]
    : buildImageTurn(
        input.dataUrl,
        input.sessionInstruction,
        input.userText,
        input.assistantText,
      );

  return { displayMessages, conversationHistory };
}

export function settleStoppedConversation(
  input: StoppedConversationInput,
): StoppedConversationState {
  const partialAnswer = input.partialAnswer.trim();

  if (!partialAnswer) {
    if (input.kind === 'follow-up') {
      return {
        displayMessages: [...input.baseDisplayMessages],
        conversationHistory: [...input.baseHistory],
      };
    }

    return {
      displayMessages: appendGenerationStoppedMessage(input.baseDisplayMessages),
      conversationHistory: buildImageTurn(
        input.dataUrl,
        input.sessionInstruction,
        input.userText,
        'Generation stopped.',
      ),
    };
  }

  const withUser = input.kind === 'follow-up' && input.userText
    ? appendUserMessage(input.baseDisplayMessages, input.userText)
    : [...input.baseDisplayMessages];
  const displayMessages = appendAssistantMessage(withUser, partialAnswer);

  const conversationHistory = input.baseHistory.length > 0 && input.userText
    ? [
        ...input.baseHistory,
        { role: 'user' as const, content: input.userText },
        { role: 'assistant' as const, content: partialAnswer },
      ]
    : buildImageTurn(
        input.dataUrl,
        input.sessionInstruction,
        input.userText,
        partialAnswer,
      );

  return { displayMessages, conversationHistory };
}

function failedAnswerText(partialAnswer: string, errorMessage: string): string {
  const partial = partialAnswer.trim();
  const failure = errorMessage.trim() || 'The response could not be completed.';
  return partial
    ? `${partial}\n\nResponse interrupted: ${failure}`
    : `Response failed: ${failure}`;
}

export interface FailedFirstAnswerInput {
  partialAnswer: string;
  errorMessage: string;
  dataUrl: string;
  sessionInstruction?: string;
  userText?: string;
}

/**
 * Keeps the text a first answer streamed before it failed, marked as
 * interrupted the same way as a failed follow-up, so follow-ups can still build
 * on it. Without streamed text there is nothing to keep.
 */
export function settleFailedFirstAnswer(
  input: FailedFirstAnswerInput,
): StoppedConversationState {
  if (!input.partialAnswer.trim()) return clearIncompleteInitialFailure();

  const assistantText = failedAnswerText(input.partialAnswer, input.errorMessage);
  return {
    displayMessages: [{ role: 'assistant', content: assistantText, status: 'failed' }],
    conversationHistory: buildImageTurn(
      input.dataUrl,
      input.sessionInstruction,
      input.userText,
      assistantText,
    ),
  };
}

export interface FailedFollowUpInput {
  baseDisplayMessages: DisplayMessage[];
  baseHistory: AnthropicMessage[];
  partialAnswer: string;
  errorMessage: string;
  dataUrl: string;
  sessionInstruction?: string;
  userText: string;
}

export interface FailedFollowUpState extends StoppedConversationState {
  baseDisplayMessages: DisplayMessage[];
  baseHistory: AnthropicMessage[];
  userText: string;
}

export function settleFailedFollowUp(
  input: FailedFollowUpInput,
): FailedFollowUpState {
  const userText = input.userText.trim();
  const assistantText = failedAnswerText(input.partialAnswer, input.errorMessage);

  const displayMessages: DisplayMessage[] = [
    ...input.baseDisplayMessages,
    { role: 'user', content: userText },
    { role: 'assistant', content: assistantText, status: 'failed' },
  ];
  const conversationHistory = input.baseHistory.length > 0
    ? [
        ...input.baseHistory,
        { role: 'user' as const, content: userText },
        { role: 'assistant' as const, content: assistantText },
      ]
    : input.baseDisplayMessages.length > 0
      ? [
          ...modelHistoryFromDisplayWithImage(
            input.baseDisplayMessages,
            input.dataUrl,
            input.sessionInstruction,
          ),
          { role: 'user' as const, content: userText },
          { role: 'assistant' as const, content: assistantText },
        ]
      : buildImageTurn(
          input.dataUrl,
          input.sessionInstruction,
          userText,
          assistantText,
        );

  return {
    baseDisplayMessages: [...input.baseDisplayMessages],
    baseHistory: [...input.baseHistory],
    displayMessages,
    conversationHistory,
    userText,
  };
}

function modelHistoryFromDisplayWithImage(
  displayMessages: DisplayMessage[],
  dataUrl: string,
  sessionInstruction?: string,
): AnthropicMessage[] {
  // Validate the assistant-first visible shape before reconstructing the
  // intentionally longer provider history.
  pruneDisplayHistoryForNewestTurn(displayMessages, Number.MAX_SAFE_INTEGER);

  return [
    {
      role: 'user',
      content: createScreenshotUserContent(dataUrl, sessionInstruction),
    },
    ...displayMessages.map((message): AnthropicMessage => ({
      role: message.role,
      content: message.content,
    })),
  ];
}

export function restoreBeforeFailedFollowUp(
  failed: FailedFollowUpState,
): StoppedConversationState {
  return {
    displayMessages: [...failed.baseDisplayMessages],
    conversationHistory: [...failed.baseHistory],
  };
}

export function settleSuccessfulFollowUp(
  baseDisplayMessages: DisplayMessage[],
  userText: string,
  assistantText: string,
): DisplayMessage[] {
  return [
    ...baseDisplayMessages,
    { role: 'user', content: userText },
    { role: 'assistant', content: assistantText },
  ];
}

export function prepareAlignedConversationForNewestTurn(
  displayMessages: DisplayMessage[],
  conversationHistory: AnthropicMessage[],
  maxConversationTurns: number,
): {
  displayMessages: DisplayMessage[];
  conversationHistory: AnthropicMessage[];
  removedTurns: number;
} {
  const display = pruneDisplayHistoryForNewestTurn(
    displayMessages,
    maxConversationTurns,
  );
  const model = pruneApiHistoryForNewestTurn(
    conversationHistory,
    maxConversationTurns,
  );
  if (
    display.removedTurns !== model.removedTurns
    || !historiesDescribeSameConversation(display.messages, model.messages)
  ) {
    throw new RequestLimitError(
      'conversation_incomplete',
      'Visible and model conversation history are out of sync. Retry or start a new snip.',
    );
  }

  return {
    displayMessages: display.messages,
    conversationHistory: model.messages,
    removedTurns: display.removedTurns,
  };
}

function historiesDescribeSameConversation(
  displayMessages: DisplayMessage[],
  conversationHistory: AnthropicMessage[],
): boolean {
  if (displayMessages.length === 0 || conversationHistory.length === 0) {
    return displayMessages.length === 0 && conversationHistory.length === 0;
  }
  if (conversationHistory.length !== displayMessages.length + 1) return false;

  return displayMessages.every((displayMessage, index) => {
    const modelMessage = conversationHistory[index + 1];
    return modelMessage.role === displayMessage.role
      && typeof modelMessage.content === 'string'
      && modelMessage.content === displayMessage.content;
  });
}

export function clearIncompleteInitialFailure(): StoppedConversationState {
  return { displayMessages: [], conversationHistory: [] };
}
