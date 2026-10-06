import { analyzeImage, followUp, AnthropicError } from '../lib/anthropic';
import { cropImage, fitScreenshotToLimits } from '../lib/crop';
import {
  prepareAlignedConversationForNewestTurn,
  settleFailedFirstAnswer,
  settleFailedFollowUp,
  settleStoppedConversation,
  settleSuccessfulConversation,
} from '../lib/conversation-state';
import type { AnthropicMessage, DisplayMessage } from '../lib/messages';
import {
  MAX_NATIVE_ANSWER_LENGTH,
  NATIVE_PROTOCOL_VERSION,
  type ExtensionToNativeMessage,
  type NativeToExtensionMessage,
} from '../lib/native-protocol';
import { getSettings, type SnapScreenSessionSettings } from '../lib/storage';
import { NativeBridge } from './native-bridge';
import { keepAliveUntilSettled } from './worker-keepalive';

export interface NativeSource {
  tabId: number;
  windowId: number;
  documentVersion: number;
}

interface Generation {
  requestId: string;
  controller: AbortController;
  kind: 'initial' | 'follow-up';
  userText?: string;
  baseHistory: AnthropicMessage[];
  baseDisplayMessages: DisplayMessage[];
  partialAnswer: string;
  relayTimer?: ReturnType<typeof setTimeout>;
}

interface Session {
  source: NativeSource;
  connectionId: string;
  sessionId: string;
  requestId: string;
  bridge: NativeBridge;
  phase: 'opening' | 'selecting' | 'cropping' | 'ready' | 'running' | 'failed' | 'stopped';
  frozen?: string;
  crop?: string;
  settings?: SnapScreenSessionSettings;
  history: AnthropicMessage[];
  display: DisplayMessage[];
  generation?: Generation;
  retry?: Generation;
  timer?: ReturnType<typeof setTimeout>;
}

interface Dependencies {
  capture: (source: NativeSource, isCurrent: () => boolean) => Promise<string>;
  isSourceCurrent: (source: NativeSource) => boolean;
  report: (tabId: number, message: string) => Promise<void>;
}

const INTERRUPTED = 'The native session ended. Invoke SnapScreen in Chrome to start a new capture.';
const MAX_SESSIONS = 4;
const SELECTION_TIMEOUT_MS = 120_000;

/** Memory belongs to a native connection, never to the source tab's UI generation. */
export class NativeSessionController {
  private sessions = new Map<string, Session>();

  constructor(private deps: Dependencies) {}

  async start(source: NativeSource): Promise<void> {
    // A newer invocation supersedes only an unfinished selection on the same tab.
    for (const session of this.sessions.values()) {
      if (session.source.tabId === source.tabId && !session.crop) this.expire(session);
    }
    if (this.sessions.size >= MAX_SESSIONS) {
      await this.deps.report(source.tabId, 'Close a native SnapScreen window before starting another capture.');
      return;
    }
    const connectionId = crypto.randomUUID();
    const sessionId = crypto.randomUUID();
    const bridge = new NativeBridge(connectionId,
      (message) => { void this.receive(session, message); },
      () => {
        if (!this.current(session)) return;
        this.dispose(session);
        void this.deps.report(source.tabId, INTERRUPTED);
      });
    const session: Session = {
      source, connectionId, sessionId, requestId: crypto.randomUUID(), bridge,
      phase: 'opening', history: [], display: [],
    };
    this.sessions.set(sessionId, session);
    session.timer = setTimeout(() => this.expire(session), SELECTION_TIMEOUT_MS);
    try {
      await bridge.connect();
      if (!this.captureCurrent(session)) return this.expire(session);
      const settings = await getSettings();
      if (!this.captureCurrent(session)) return this.expire(session);
      session.settings = { defaultPrompt: settings.defaultPrompt, limits: settings.limits };
      session.frozen = await this.deps.capture(source, () => this.captureCurrent(session));
      if (!this.captureCurrent(session)) return this.expire(session);
      session.phase = 'selecting';
      this.send(session, { type: 'capture', imageDataUrl: session.frozen });
    } catch {
      if (!this.current(session)) return;
      this.dispose(session);
      await this.deps.report(source.tabId,
        'Native capture could not start. Check the companion installation and source tab, then invoke SnapScreen again.');
    }
  }

  invalidateSource(tabId: number): void {
    for (const session of this.sessions.values()) {
      if (session.source.tabId === tabId && !session.crop) this.expire(session);
    }
  }

  private current(session: Session): boolean {
    return this.sessions.get(session.sessionId) === session;
  }

  private captureCurrent(session: Session): boolean {
    return this.current(session) && this.deps.isSourceCurrent(session.source);
  }

  private send(session: Session, payload: NativeEvent): boolean {
    if (!this.current(session)) return false;
    try {
      session.bridge.send({
        version: NATIVE_PROTOCOL_VERSION,
        connectionId: session.connectionId,
        sessionId: session.sessionId,
        requestId: session.requestId,
        ...payload,
      } as ExtensionToNativeMessage);
      return true;
    } catch {
      const shouldReport = this.current(session);
      this.dispose(session);
      if (shouldReport) void this.deps.report(session.source.tabId,
        'The native session could not be delivered. Try a smaller capture or check the companion installation.');
      return false;
    }
  }

  private expire(session: Session): void {
    this.send(session, { type: 'expired', message: INTERRUPTED });
    this.dispose(session);
  }

  private dispose(session: Session): void {
    this.sessions.delete(session.sessionId);
    clearTimeout(session.timer);
    session.generation?.controller.abort();
    clearTimeout(session.generation?.relayTimer);
    session.bridge.disconnect();
    session.frozen = session.crop = undefined;
    session.generation = session.retry = undefined;
    session.history = [];
    session.display = [];
    session.settings = undefined;
  }

  private async receive(session: Session, message: NativeToExtensionMessage): Promise<void> {
    if (!this.current(session) || message.type === 'ready'
      || message.connectionId !== session.connectionId
      || message.sessionId !== session.sessionId || message.requestId !== session.requestId) return;
    switch (message.type) {
      case 'close':
      case 'cancelled':
        this.dispose(session);
        return;
      case 'selected':
        if (session.phase !== 'selecting' || !session.frozen) return;
        session.phase = 'cropping';
        try {
          const cropped = await cropImage(session.frozen, message.rect);
          if (!this.captureCurrent(session)) return this.expire(session);
          const fitted = await fitScreenshotToLimits(cropped, session.settings!.limits);
          if (!this.captureCurrent(session)) return this.expire(session);
          // Commit acceptance before yielding again. Navigation now leaves the conversation intact.
          session.crop = fitted;
          session.frozen = undefined;
          clearTimeout(session.timer);
          session.phase = 'ready';
          if (this.send(session, { type: 'accepted', imageDataUrl: fitted,
            maxInputCharacters: session.settings!.limits.maxInputCharacters })) {
            void this.generate(session);
          }
        } catch {
          this.expire(session);
        }
        return;
      case 'followup':
        if (!['ready', 'failed', 'stopped'].includes(session.phase)) return;
        void this.generate(session, message.text);
        return;
      case 'retry':
        if (!['failed', 'stopped'].includes(session.phase) || !session.retry) return;
        void this.generate(session, session.retry.userText, session.retry);
        return;
      case 'stop': {
        const generation = session.generation;
        if (session.phase !== 'running' || !generation || !session.crop) return;
        session.generation = undefined;
        generation.controller.abort();
        clearTimeout(generation.relayTimer);
        const stopped = settleStoppedConversation({ ...generation,
          dataUrl: session.crop, sessionInstruction: session.settings!.defaultPrompt });
        session.history = stopped.conversationHistory;
        session.display = stopped.displayMessages;
        session.retry = generation;
        session.phase = 'stopped';
        this.send(session, { type: 'answer', text: generation.partialAnswer, status: 'stopped' });
        return;
      }
    }
  }

  private async generate(session: Session, userText?: string, retry?: Generation): Promise<void> {
    if (!this.current(session) || !session.crop || !session.settings) return;
    const generation: Generation = {
      requestId: crypto.randomUUID(), controller: new AbortController(),
      kind: (retry?.baseHistory ?? session.history).length ? 'follow-up' : 'initial',
      userText,
      baseHistory: retry?.baseHistory ?? session.history,
      baseDisplayMessages: retry?.baseDisplayMessages ?? session.display,
      partialAnswer: '',
    };
    session.requestId = generation.requestId;
    session.generation = generation;
    session.retry = undefined;
    session.phase = 'running';
    const current = () => this.current(session) && session.generation === generation;
    if (!this.send(session, { type: 'started' })) return;
    try {
      const settings = await getSettings();
      if (!current()) return;
      if (!settings.apiKey) throw new AnthropicError('no_api_key',
        'Add your Anthropic API key in extension Settings, then Retry.');
      const aligned = prepareAlignedConversationForNewestTurn(
        generation.baseDisplayMessages, generation.baseHistory, session.settings.limits.maxConversationTurns);
      generation.baseHistory = aligned.conversationHistory;
      generation.baseDisplayMessages = aligned.displayMessages;
      const handlers = {
        signal: generation.controller.signal,
        limits: session.settings.limits,
        onThinking: () => { if (current()) this.send(session, { type: 'thinking' }); },
        onDelta: (text: string) => {
          if (!current()) return;
          if (text.length > MAX_NATIVE_ANSWER_LENGTH) {
            throw new AnthropicError('answer_too_large', 'The answer exceeded the native window limit. Try a shorter question.');
          }
          generation.partialAnswer = text;
          // SSE can emit many tokens per frame. Bound full-snapshot transport to 10 Hz.
          generation.relayTimer ??= setTimeout(() => {
            generation.relayTimer = undefined;
            if (current()) this.send(session, { type: 'answer',
              text: generation.partialAnswer, status: 'streaming' });
          }, 100);
        },
      };
      const result = await keepAliveUntilSettled(generation.kind === 'initial'
        ? analyzeImage(settings.apiKey, session.crop, { ...handlers,
          hiddenInstruction: session.settings.defaultPrompt, userQuestion: userText })
        : followUp(settings.apiKey, userText!, generation.baseHistory, { ...handlers,
          sessionInstruction: session.settings.defaultPrompt }));
      if (!current()) return;
      if (result.text.length > MAX_NATIVE_ANSWER_LENGTH) {
        throw new AnthropicError('answer_too_large', 'The answer exceeded the native window limit. Try a shorter question.');
      }
      const settled = settleSuccessfulConversation({ ...generation, dataUrl: session.crop,
        assistantText: result.text, providerHistory: result.history,
        sessionInstruction: session.settings.defaultPrompt });
      session.history = settled.conversationHistory;
      session.display = settled.displayMessages;
      session.phase = 'ready';
      this.send(session, { type: 'answer', text: result.text, status: 'done' });
    } catch (error) {
      if (!current()) return;
      const failure = error instanceof AnthropicError ? error
        : new AnthropicError('request_failed', 'SnapScreen could not complete this request. Try again.');
      const failed = generation.kind === 'initial'
        ? settleFailedFirstAnswer({ ...generation, errorMessage: failure.message,
          dataUrl: session.crop!, sessionInstruction: session.settings!.defaultPrompt })
        : settleFailedFollowUp({ ...generation, userText: userText!, errorMessage: failure.message,
          dataUrl: session.crop!, sessionInstruction: session.settings!.defaultPrompt });
      session.history = failed.conversationHistory;
      session.display = failed.displayMessages;
      session.retry = generation;
      session.phase = 'failed';
      this.send(session, { type: 'error', code: failure.code, message: failure.message });
    } finally {
      clearTimeout(generation.relayTimer);
      if (current()) session.generation = undefined;
    }
  }
}

type WithoutEnvelope<T> = T extends { sessionId: string }
  ? Omit<T, 'version' | 'connectionId' | 'sessionId' | 'requestId'> : never;
type NativeEvent = WithoutEnvelope<ExtensionToNativeMessage>;
