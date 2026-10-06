import {
  appendUserMessage,
  createInitialDisplay,
  describeRemovedTurns,
  prepareAlignedConversationForNewestTurn,
  restoreBeforeFailedFollowUp,
  settleFailedFirstAnswer,
  settleFailedFollowUp,
  settleSuccessfulConversation,
  settleStoppedConversation,
  type FailedFollowUpState,
} from './conversation-state';
import {
  matchesActiveGeneration,
  matchesPendingCapture,
} from './session-correlation';
import { SessionDisposalGuard } from './session-disposal';
import { getRuntimeResponseFailure } from './runtime-response';
import type { ResultPanelOptions } from './result-panel';
import type { SnipOverlayDisposer, SnipOverlayOptions } from './snip-overlay';
import {
  RequestLimitError,
  assertUserInputWithinLimit,
} from '../lib/request-limits';
import {
  DEFAULT_LIMITS,
  DEFAULT_PROMPT,
  normalizeLimits,
  type SnapScreenLimits,
  type SnapScreenSessionSettings,
} from '../lib/storage';
import type {
  AnthropicMessage,
  BgToCsMessage,
  CsToBgMessage,
  DisplayMessage,
  Rect,
} from '../lib/messages';

export interface CaptureControllerUi {
  disposeResultPanel: () => void;
  disposeSnipOverlay: () => void;
  showErrorToast: (message: string) => void;
  showResultPanel: (options: ResultPanelOptions) => void;
  showThinking: () => void;
  startSnipOverlay: (options: SnipOverlayOptions) => SnipOverlayDisposer;
  updateStreamingAnswer: (text: string) => void;
}

export interface CaptureControllerOptions {
  imageFit?: 'contain' | 'fill';
  onSessionEnded?: (reason: 'cancel' | 'close') => void;
  sendMessage: (message: CsToBgMessage) => Promise<unknown>;
  ui: CaptureControllerUi;
}

interface ActiveGenerationState {
  baseDisplayMessages: DisplayMessage[];
  baseHistory: AnthropicMessage[];
  captureId: string;
  kind: 'initial' | 'follow-up';
  requestId: string;
  screenshotId: string;
  startedAt: number;
  thinking: boolean;
  userText?: string;
  transport: 'analyze' | 'follow-up';
}

interface FailedGenerationState extends FailedFollowUpState {
  transport: 'analyze' | 'follow-up';
}

interface GenerationInput {
  baseDisplayMessages: DisplayMessage[];
  baseHistory: AnthropicMessage[];
  kind: 'initial' | 'follow-up';
  userText?: string;
  transport: 'analyze' | 'follow-up';
}

export interface CaptureController {
  dispose: () => void;
  handleMessage: (message: BgToCsMessage) => void;
  prepareForCapture: () => void;
}

export function createCaptureController(
  options: CaptureControllerOptions,
): CaptureController {
  const { sendMessage, ui } = options;
  let captureId: string | null = null;
  let capturePending = false;
  let screenshotId: string | null = null;
  let isPanelOpen = false;
  let displayMessages: DisplayMessage[] = [];
  let conversationHistory: AnthropicMessage[] = [];
  let currentDataUrl = '';
  let lastRect: Rect | undefined;
  let retryLastRequest: (() => void) | null = null;
  let activeGeneration: ActiveGenerationState | null = null;
  let currentStreamingText = '';
  let disposeOverlay: SnipOverlayDisposer | null = null;
  let sessionPrompt = DEFAULT_PROMPT;
  let sessionLimits: SnapScreenLimits = DEFAULT_LIMITS;
  let failedFollowUp: FailedGenerationState | null = null;
  // Set while the panel shows a first answer that failed partway through.
  let retryFailedFirstAnswer: (() => void) | null = null;
  let canResnip = true;
  const sessionDisposal = new SessionDisposalGuard();

  function resetSessionState(): void {
    captureId = null;
    capturePending = false;
    screenshotId = null;
    isPanelOpen = false;
    displayMessages = [];
    conversationHistory = [];
    currentDataUrl = '';
    lastRect = undefined;
    retryLastRequest = null;
    activeGeneration = null;
    currentStreamingText = '';
    sessionPrompt = DEFAULT_PROMPT;
    sessionLimits = DEFAULT_LIMITS;
    failedFollowUp = null;
    retryFailedFirstAnswer = null;
    canResnip = true;
  }

  function disposeSession(): void {
    disposeOverlay?.();
    disposeOverlay = null;
    ui.disposeSnipOverlay();
    ui.disposeResultPanel();

    sessionDisposal.dispose(() => {
      const generationToCancel = activeGeneration;
      const captureToCancel = capturePending ? captureId : null;

      resetSessionState();

      if (generationToCancel) {
        void sendMessage({
          type: 'CANCEL_GENERATION',
          captureId: generationToCancel.captureId,
          requestId: generationToCancel.requestId,
        }).catch(() => undefined);
      }
      if (captureToCancel) {
        void sendMessage({ type: 'SNIP_CANCELLED', captureId: captureToCancel })
          .catch(() => undefined);
      }
    });
  }

  function endSession(reason: 'cancel' | 'close'): void {
    disposeSession();
    options.onSessionEnded?.(reason);
  }

  function isActiveGeneration(message: {
    captureId: string;
    requestId: string;
    screenshotId: string;
  }): boolean {
    return matchesActiveGeneration(isPanelOpen, activeGeneration, message);
  }

  function renderPanel(state: {
    pending: boolean;
    error?: string;
    errorCode?: string;
  }): void {
    isPanelOpen = true;
    const resnipSettings = {
      defaultPrompt: sessionPrompt,
      limits: { ...sessionLimits },
    };
    ui.showResultPanel({
      dataUrl: currentDataUrl || undefined,
      messages: displayMessages,
      error: state.error,
      errorCode: state.errorCode,
      pending: state.pending,
      pendingSince: state.pending ? activeGeneration?.startedAt : undefined,
      thinking: state.pending && activeGeneration?.thinking === true,
      anchorRect: lastRect,
      onClose: () => endSession('close'),
      onFollowUp: handleFollowUp,
      onStop: stopGeneration,
      onRetry: retryLastRequest ?? undefined,
      onResnip: canResnip ? () => requestNewSnip(resnipSettings) : undefined,
      maxInputCharacters: sessionLimits.maxInputCharacters,
      failedAnswerActions: failedFollowUp
        ? { onRetry: retryFailedFollowUp, onRemove: removeFailedFollowUp }
        : retryFailedFirstAnswer
          ? { onRetry: retryFailedFirstAnswer }
          : undefined,
    });
  }

  function stopGeneration(): void {
    const generation = activeGeneration;
    if (!generation) return;

    activeGeneration = null;
    void sendMessage({
      type: 'CANCEL_GENERATION',
      captureId: generation.captureId,
      requestId: generation.requestId,
    }).catch(() => undefined);

    const stopped = settleStoppedConversation({
      kind: generation.kind,
      baseDisplayMessages: generation.baseDisplayMessages,
      baseHistory: generation.baseHistory,
      partialAnswer: currentStreamingText,
      dataUrl: currentDataUrl,
      userText: generation.userText,
      sessionInstruction: sessionPrompt,
    });
    displayMessages = stopped.displayMessages;
    conversationHistory = stopped.conversationHistory;
    currentStreamingText = '';
    renderPanel({ pending: false });
  }

  function requestNewSnip(publicSettings: SnapScreenSessionSettings): void {
    const sessionSettings = {
      defaultPrompt: publicSettings.defaultPrompt,
      limits: { ...publicSettings.limits },
    };
    void sendMessage({ type: 'REQUEST_SNIP', sessionSettings })
      .then((response) => {
        const failure = getRuntimeResponseFailure(response);
        if (failure) {
          ui.showErrorToast(
            failure.message
              ?? 'SnapScreen could not start a new capture. Please try again.',
          );
        }
      })
      .catch(() => {
        ui.showErrorToast('SnapScreen could not start a new capture. Please try again.');
      });
  }

  function handleGenerationTransportFailure(requestId: string): void {
    const generation = activeGeneration;
    if (generation?.requestId !== requestId) return;
    settleGenerationFailure(
      generation,
      'SnapScreen could not reach the extension background service. Please try again.',
      'extension_transport',
    );
  }

  function handleGenerationResponse(requestId: string, response: unknown): void {
    const generation = activeGeneration;
    if (generation?.requestId !== requestId) return;

    const failure = getRuntimeResponseFailure(response);
    if (!failure) return;

    const pageChanged = failure.kind === 'aborted' || failure.kind === 'stale';
    settleGenerationFailure(
      generation,
      pageChanged
        ? 'Analysis stopped because the page changed. Retry or take a new snip.'
        : failure.message
          ?? 'SnapScreen could not complete this request. Please try again.',
      pageChanged ? 'page_changed' : `extension_${failure.kind}`,
    );
  }

  function settleGenerationFailure(
    generation: ActiveGenerationState,
    message: string,
    errorCode: string,
  ): void {
    activeGeneration = null;
    // Refused text is dropped, so it's never kept as an answer or sent back to
    // the model with the next question.
    const partialAnswer = errorCode === 'refusal' ? '' : currentStreamingText;
    currentStreamingText = '';

    if (generation.kind === 'follow-up' && generation.userText) {
      const failed = settleFailedFollowUp({
        baseDisplayMessages: generation.baseDisplayMessages,
        baseHistory: generation.baseHistory,
        partialAnswer,
        errorMessage: message,
        dataUrl: currentDataUrl,
        sessionInstruction: sessionPrompt,
        userText: generation.userText,
      });
      failedFollowUp = { ...failed, transport: generation.transport };
      displayMessages = failed.displayMessages;
      conversationHistory = failed.conversationHistory;
      retryLastRequest = retryFailedFollowUp;
      renderPanel({ pending: false });
      return;
    }

    const failed = settleFailedFirstAnswer({
      partialAnswer,
      errorMessage: message,
      dataUrl: currentDataUrl,
      sessionInstruction: sessionPrompt,
    });
    displayMessages = failed.displayMessages;
    conversationHistory = failed.conversationHistory;
    failedFollowUp = null;
    if (displayMessages.length === 0) {
      renderPanel({ pending: false, error: message, errorCode });
      return;
    }

    // Try again answers the same capture again, replacing the partial answer.
    retryFailedFirstAnswer = retryLastRequest;
    renderPanel({ pending: false });
  }

  function retryFailedFollowUp(): void {
    const failed = failedFollowUp;
    if (!failed || activeGeneration) return;

    const restored = restoreBeforeFailedFollowUp(failed);
    displayMessages = appendUserMessage(restored.displayMessages, failed.userText);
    conversationHistory = restored.conversationHistory;
    failedFollowUp = null;
    renderPanel({ pending: true });
    startGeneration({
      baseDisplayMessages: restored.displayMessages,
      baseHistory: restored.conversationHistory,
      kind: 'follow-up',
      userText: failed.userText,
      transport: failed.transport,
    });
  }

  function removeFailedFollowUp(): void {
    const failed = failedFollowUp;
    if (!failed || activeGeneration) return;

    const restored = restoreBeforeFailedFollowUp(failed);
    displayMessages = restored.displayMessages;
    conversationHistory = restored.conversationHistory;
    failedFollowUp = null;
    retryLastRequest = null;
    renderPanel({ pending: false });
  }

  function startGeneration(input: GenerationInput): void {
    const sessionCaptureId = captureId;
    const sessionScreenshotId = screenshotId;
    if (!sessionCaptureId || !sessionScreenshotId) return;
    const requestSessionSettings: SnapScreenSessionSettings = {
      defaultPrompt: sessionPrompt,
      limits: { ...sessionLimits },
    };

    const dispatch = (): void => {
      if (captureId !== sessionCaptureId || screenshotId !== sessionScreenshotId) return;

      const requestId = crypto.randomUUID();
      activeGeneration = {
        baseDisplayMessages: [...input.baseDisplayMessages],
        baseHistory: [...input.baseHistory],
        captureId: sessionCaptureId,
        kind: input.kind,
        requestId,
        screenshotId: sessionScreenshotId,
        startedAt: Date.now(),
        thinking: false,
        userText: input.userText,
        transport: input.transport,
      };
      currentStreamingText = '';

      const request: CsToBgMessage = input.transport === 'analyze'
        ? {
            type: 'ANALYZE',
            dataUrl: currentDataUrl,
            captureId: sessionCaptureId,
            requestId,
            screenshotId: sessionScreenshotId,
            sessionSettings: requestSessionSettings,
            question: input.userText,
          }
        : {
            type: 'FOLLOW_UP',
            text: input.userText ?? '',
            history: input.baseHistory,
            captureId: sessionCaptureId,
            requestId,
            screenshotId: sessionScreenshotId,
            sessionSettings: requestSessionSettings,
          };

      void sendMessage(request)
        .then((response) => handleGenerationResponse(requestId, response))
        .catch(() => handleGenerationTransportFailure(requestId));
    };

    retryLastRequest = () => {
      failedFollowUp = null;
      retryFailedFirstAnswer = null;
      displayMessages = input.kind === 'follow-up' && input.userText
        ? appendUserMessage(input.baseDisplayMessages, input.userText)
        : [...input.baseDisplayMessages];
      conversationHistory = [...input.baseHistory];
      renderPanel({ pending: true });
      dispatch();
    };
    dispatch();
  }

  function handleFollowUp(text: string): void {
    if (!captureId || !screenshotId || activeGeneration) return;

    try {
      assertUserInputWithinLimit(text, sessionLimits.maxInputCharacters);
    } catch (error) {
      ui.showErrorToast(
        error instanceof RequestLimitError
          ? error.message
          : 'That question could not be submitted.',
      );
      return;
    }

    let baseDisplayMessages = displayMessages;
    let baseHistory = conversationHistory;
    failedFollowUp = null;
    retryFailedFirstAnswer = null;
    retryLastRequest = null;

    if (baseHistory.length > 0) {
      try {
        const prepared = prepareAlignedConversationForNewestTurn(
          baseDisplayMessages,
          baseHistory,
          sessionLimits.maxConversationTurns,
        );
        baseDisplayMessages = prepared.displayMessages;
        baseHistory = prepared.conversationHistory;
        if (prepared.removedTurns > 0) {
          ui.showErrorToast(describeRemovedTurns(prepared.removedTurns));
        }
      } catch (error) {
        ui.showErrorToast(
          error instanceof Error
            ? error.message
            : 'The conversation could not be prepared. Start a new snip.',
        );
        return;
      }
    }

    displayMessages = baseDisplayMessages;
    conversationHistory = baseHistory;
    displayMessages = appendUserMessage(baseDisplayMessages, text);
    renderPanel({ pending: true });

    startGeneration({
      baseDisplayMessages,
      baseHistory,
      kind: 'follow-up',
      userText: text,
      transport: baseHistory.length === 0 ? 'analyze' : 'follow-up',
    });
  }

  function showCaptureFailure(
    messageCaptureId: string,
    message: string,
    code: string,
  ): void {
    if (!matchesPendingCapture(captureId, capturePending, messageCaptureId)) return;

    capturePending = false;
    retryLastRequest = () => requestNewSnip({
      defaultPrompt: sessionPrompt,
      limits: { ...sessionLimits },
    });
    renderPanel({ pending: false, error: message, errorCode: code });
  }

  function beginSnip(
    nextCaptureId: string,
    frozenDataUrl: string,
    publicSettings: SnapScreenSessionSettings,
  ): void {
    disposeSession();

    sessionPrompt = publicSettings.defaultPrompt.trim() || DEFAULT_PROMPT;
    sessionLimits = normalizeLimits(publicSettings.limits);

    sessionDisposal.begin();
    captureId = nextCaptureId;
    capturePending = true;
    disposeOverlay = ui.startSnipOverlay({
      dataUrl: frozenDataUrl,
      imageFit: options.imageFit,
      onRegionSelected(selection) {
        if (!matchesPendingCapture(captureId, capturePending, nextCaptureId)) return;
        disposeOverlay = null;
        lastRect = selection.viewportRect;
        void sendMessage({
          type: 'CAPTURE_REGION',
          selection,
          captureId: nextCaptureId,
          dataUrl: frozenDataUrl,
        })
          .then((response) => {
            if (!matchesPendingCapture(captureId, capturePending, nextCaptureId)) return;
            const failure = getRuntimeResponseFailure(response);
            if (!failure) return;
            const pageChanged = failure.kind === 'aborted' || failure.kind === 'stale';
            showCaptureFailure(
              nextCaptureId,
              pageChanged
                ? 'Capture stopped because the page changed. Please try again.'
                : failure.message
                  ?? 'SnapScreen could not complete the capture. Please try again.',
              pageChanged ? 'page_changed' : `extension_${failure.kind}`,
            );
          })
          .catch(() => {
            showCaptureFailure(
              nextCaptureId,
              'SnapScreen could not start the capture. Please try again.',
              'extension_transport',
            );
          });
      },
      onCancelled() {
        if (!matchesPendingCapture(captureId, capturePending, nextCaptureId)) return;
        disposeOverlay = null;
        endSession('cancel');
      },
    });
  }

  function handleMessage(message: BgToCsMessage): void {
    switch (message.type) {
      case 'PREPARE_SNIP_CAPTURE':
        disposeSession();
        break;

      case 'START_SNIP':
        beginSnip(
          message.captureId,
          message.dataUrl,
          {
            defaultPrompt: message.defaultPrompt,
            limits: message.limits,
          },
        );
        break;

      case 'CROPPED_IMAGE':
        if (!matchesPendingCapture(captureId, capturePending, message.captureId)) return;
        capturePending = false;
        screenshotId = crypto.randomUUID();
        displayMessages = createInitialDisplay();
        conversationHistory = [];
        currentDataUrl = message.dataUrl;
        renderPanel({ pending: true });
        startGeneration({
          baseDisplayMessages: displayMessages,
          baseHistory: [],
          kind: 'initial',
          transport: 'analyze',
        });
        break;

      case 'CAPTURE_ERROR':
        showCaptureFailure(message.captureId, message.message, message.code);
        break;

      case 'ANALYZE_THINKING':
        if (!isActiveGeneration(message)) return;
        activeGeneration!.thinking = true;
        ui.showThinking();
        break;

      case 'ANALYZE_CHUNK':
        if (!isActiveGeneration(message)) return;
        currentStreamingText = message.text;
        ui.updateStreamingAnswer(message.text);
        break;

      case 'ANALYZE_RESULT': {
        if (!isActiveGeneration(message)) return;

        const generation = activeGeneration!;
        activeGeneration = null;
        currentStreamingText = '';
        failedFollowUp = null;
        retryFailedFirstAnswer = null;
        const settled = settleSuccessfulConversation({
          kind: generation.kind,
          baseDisplayMessages: generation.baseDisplayMessages,
          baseHistory: generation.baseHistory,
          assistantText: message.text,
          dataUrl: currentDataUrl,
          providerHistory: message.history,
          userText: generation.userText,
          sessionInstruction: sessionPrompt,
        });
        conversationHistory = settled.conversationHistory;
        displayMessages = settled.displayMessages;
        renderPanel({ pending: false });
        break;
      }

      case 'ANALYZE_ERROR':
        if (!isActiveGeneration(message)) return;
        settleGenerationFailure(activeGeneration!, message.message, message.code);
        break;

      case 'RESNIP_UNAVAILABLE':
        canResnip = false;
        ui.showErrorToast(message.message);
        if (isPanelOpen) renderPanel({ pending: activeGeneration !== null });
        break;

      case 'SHOW_ERROR':
        ui.showErrorToast(message.message);
        break;
    }
  }

  return {
    dispose: disposeSession,
    handleMessage,
    prepareForCapture: disposeSession,
  };
}
