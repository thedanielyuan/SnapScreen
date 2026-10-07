import contentScript from '../content/index.ts?script&iife';
import {
  cropImage,
  fitHistoryScreenshotsToLimits,
  fitScreenshotToLimits,
} from '../lib/crop';
import { analyzeImage, followUp, AnthropicError } from '../lib/anthropic';
import {
  getSettings,
  getInterfaceMode,
  initializeStorageAccess,
  normalizeLimits,
  type SnapScreenSessionSettings,
} from '../lib/storage';
import type { BgToCsMessage, CsToBgMessage } from '../lib/messages';
import {
  UI_CLAIM_CAPABILITY,
  UI_FRAME_PATH,
  UI_REGISTER_CAPABILITY,
  UI_REVOKE_CAPABILITY,
  isUiAttestationMessage,
  type UiAttestationMessage,
  type UiAttestationResponse,
} from '../lib/ui-protocol';
import {
  WORKSPACE_PATH,
  WORKSPACE_PORT_NAME,
  isWorkspaceToBackgroundMessage,
  type BackgroundToWorkspaceMessage,
  type WorkspaceError,
  type WorkspaceInitialMessage,
} from '../lib/workspace-protocol';
import { ActiveTabChangedError } from './capture-session';
import { ActionFeedback } from './action-feedback';
import { CaptureSourceTracker, getActiveTab } from './capture-source';
import { GenerationRegistry, type ActiveGeneration } from './generation-registry';
import { getDocumentMessageOptions, type DocumentTarget } from './document-target';
import { UiCapabilityRegistry } from './ui-capability-registry';
import { keepAliveUntilSettled } from './worker-keepalive';
import { NativeCaptureController } from './native-capture';

const generations = new GenerationRegistry();
const uiCapabilities = new UiCapabilityRegistry();

interface ContentEndpoint extends DocumentTarget {
  kind: 'content';
}

interface WorkspaceEndpoint {
  kind: 'workspace';
  sessionId: string;
  tabId: number;
}

type SessionEndpoint = ContentEndpoint | WorkspaceEndpoint;

interface FrozenCapture {
  dataUrl: string;
  endpointKey: string;
}

interface WorkspaceMetadata {
  claimed: boolean;
  initialNonce?: string;
  reconnectToken?: string;
  sessionId: string;
  sourceDocumentVersion: number;
  sourceRecaptureAvailable: boolean;
  sourceTabId: number;
  sourceUrl?: string;
  sourceWindowId: number;
  workspaceTabId: number;
}

interface WorkspaceRecord extends WorkspaceMetadata {
  acceptingInitialStart?: boolean;
  awaitingInitialClaim?: boolean;
  claimTimer?: ReturnType<typeof setTimeout>;
  disconnectTimer?: ReturnType<typeof setTimeout>;
  pendingError?: WorkspaceError;
  pendingStart?: WorkspaceInitialMessage;
  port?: chrome.runtime.Port;
  requestIds?: Set<string>;
}

const captureIdByEndpoint = new Map<string, string>();
const frozenCaptureById = new Map<string, FrozenCapture>();
const workspaceBySession = new Map<string, WorkspaceRecord>();
const workspaceSessionBySourceTab = new Map<number, string>();
const workspaceSessionByTab = new Map<number, string>();
const captureSources = new CaptureSourceTracker();
const actionFeedback = new ActionFeedback();

const GENERIC_CAPTURE_ERROR =
  'SnapScreen could not capture that region. Please try again.';
const GENERIC_GENERATION_ERROR =
  'SnapScreen could not complete this request. Please try again.';
const SNIP_START_TIMEOUT_MS = 5_000;
const WORKSPACE_CLAIM_TIMEOUT_MS = 30_000;
const WORKSPACE_DISCONNECT_TIMEOUT_MS = 5_000;
const WORKSPACE_STORAGE_PREFIX = 'snapscreenWorkspace:';
const nativeSessions = new NativeCaptureController(captureSources, showActionBadge);

void initializeStorageAccess();

function isAbortError(err: unknown): boolean {
  return err instanceof DOMException && err.name === 'AbortError';
}

function getPublicGenerationError(err: unknown): { code: string; message: string } {
  if (err instanceof AnthropicError) {
    return { code: err.code, message: err.message };
  }
  return { code: 'unknown', message: GENERIC_GENERATION_ERROR };
}

function endpointKey(endpoint: SessionEndpoint): string {
  return endpoint.kind === 'content'
    ? `content:${endpoint.tabId}:${endpoint.documentId ?? 'unknown'}`
    : `workspace:${endpoint.tabId}:${endpoint.sessionId}`;
}

function endpointDocumentId(endpoint: SessionEndpoint): string | undefined {
  return endpoint.kind === 'content'
    ? endpoint.documentId
    : `workspace:${endpoint.sessionId}`;
}

function beginCapture(endpoint: SessionEndpoint, captureId: string): boolean {
  const key = endpointKey(endpoint);
  if (captureIdByEndpoint.get(key) === captureId) return false;
  captureIdByEndpoint.set(key, captureId);
  return true;
}

function isCurrentCapture(endpoint: SessionEndpoint, captureId: string): boolean {
  return captureIdByEndpoint.get(endpointKey(endpoint)) === captureId;
}

function clearTabState(tabId: number): void {
  generations.clearTab(tabId);
  uiCapabilities.clearTab(tabId);
  actionFeedback.clear(tabId);
  for (const key of captureIdByEndpoint.keys()) {
    if (key.startsWith(`content:${tabId}:`) || key.startsWith(`workspace:${tabId}:`)) {
      captureIdByEndpoint.delete(key);
    }
  }
  for (const [captureId, capture] of frozenCaptureById) {
    if (
      capture.endpointKey.startsWith(`content:${tabId}:`)
      || capture.endpointKey.startsWith(`workspace:${tabId}:`)
    ) {
      frozenCaptureById.delete(captureId);
    }
  }
}

function getSenderUrl(sender: chrome.runtime.MessageSender): URL | null {
  if (!sender.url) return null;
  try {
    return new URL(sender.url);
  } catch {
    return null;
  }
}

function isTrustedTopFrameContentSender(
  sender: chrome.runtime.MessageSender,
): boolean {
  const url = getSenderUrl(sender);
  const originMatches = url?.protocol === 'file:'
    ? sender.origin === 'file://' || sender.origin === 'null'
    : !!url && sender.origin === url.origin;
  return sender.id === chrome.runtime.id
    && sender.frameId === 0
    && !!sender.tab
    && typeof sender.tab.id === 'number'
    && !!url
    && (
      url.protocol === 'http:'
      || url.protocol === 'https:'
      || url.protocol === 'file:'
    )
    && originMatches;
}

function isTrustedWorkspaceSender(sender: chrome.runtime.MessageSender): boolean {
  const url = getSenderUrl(sender);
  const extensionOrigin = `chrome-extension://${chrome.runtime.id}`;
  return sender.id === chrome.runtime.id
    && sender.frameId === 0
    && !!sender.tab
    && typeof sender.tab.id === 'number'
    && !!url
    && url.protocol === 'chrome-extension:'
    && url.host === chrome.runtime.id
    && url.pathname === `/${WORKSPACE_PATH}`
    && sender.origin === extensionOrigin;
}

function isWorkspaceUrl(value?: string): boolean {
  if (!value) return false;
  try {
    const url = new URL(value);
    return url.protocol === 'chrome-extension:'
      && url.host === chrome.runtime.id
      && url.pathname === `/${WORKSPACE_PATH}`;
  } catch {
    return false;
  }
}

function isTrustedUiFrameSender(sender: chrome.runtime.MessageSender): boolean {
  const url = getSenderUrl(sender);
  const extensionOrigin = `chrome-extension://${chrome.runtime.id}`;
  return sender.id === chrome.runtime.id
    && typeof sender.frameId === 'number'
    && sender.frameId > 0
    && !!sender.tab
    && typeof sender.tab.id === 'number'
    && !!url
    && url.protocol === 'chrome-extension:'
    && url.host === chrome.runtime.id
    && url.pathname === `/${UI_FRAME_PATH}`
    && sender.origin === extensionOrigin;
}

function handleUiAttestation(
  message: UiAttestationMessage,
  sender: chrome.runtime.MessageSender,
): UiAttestationResponse {
  const tabId = sender.tab?.id;
  if (typeof tabId !== 'number') return { ok: false, error: 'ui_auth_failed' };

  let ok = false;
  switch (message.type) {
    case UI_REGISTER_CAPABILITY:
      if (isTrustedTopFrameContentSender(sender)) {
        ok = uiCapabilities.register(
          { tabId, documentId: sender.documentId },
          message.sessionId,
          message.nonce,
        );
      }
      break;
    case UI_CLAIM_CAPABILITY:
      if (isTrustedUiFrameSender(sender)) {
        ok = uiCapabilities.claim(tabId, message.sessionId, message.nonce);
      }
      break;
    case UI_REVOKE_CAPABILITY:
      if (isTrustedTopFrameContentSender(sender)) {
        ok = uiCapabilities.revoke(
          { tabId, documentId: sender.documentId },
          message.sessionId,
        );
      }
      break;
  }
  return ok ? { ok: true } : { ok: false, error: 'ui_auth_failed' };
}

function getContentEndpoint(
  tabId: number,
  documentId: string | undefined,
): ContentEndpoint {
  return { kind: 'content', tabId, documentId };
}

function getRequestSessionSettings(
  value: SnapScreenSessionSettings | undefined,
  fallback: SnapScreenSessionSettings,
): SnapScreenSessionSettings {
  return {
    defaultPrompt: value?.defaultPrompt.trim() || fallback.defaultPrompt,
    limits: normalizeLimits(value?.limits ?? fallback.limits),
  };
}

function sendToEndpoint(
  endpoint: SessionEndpoint,
  message: BgToCsMessage,
): Promise<unknown> {
  if (endpoint.kind === 'content') {
    return chrome.tabs.sendMessage(
      endpoint.tabId,
      message,
      getDocumentMessageOptions(endpoint),
    );
  }

  const record = workspaceBySession.get(endpoint.sessionId);
  if (!record?.port || record.workspaceTabId !== endpoint.tabId) {
    return Promise.reject(new Error('The SnapScreen workspace is disconnected.'));
  }
  try {
    record.port.postMessage({
      type: 'SNAPSCREEN_WORKSPACE_EVENT',
      sessionId: endpoint.sessionId,
      message,
    } satisfies BackgroundToWorkspaceMessage);
    return Promise.resolve();
  } catch (error) {
    return Promise.reject(error);
  }
}

async function safeSendToEndpoint(
  endpoint: SessionEndpoint,
  message: BgToCsMessage,
): Promise<boolean> {
  try {
    await sendToEndpoint(endpoint, message);
    return true;
  } catch {
    return false;
  }
}

function makeDeltaRelay(
  endpoint: SessionEndpoint,
  ids: { captureId: string; requestId: string; screenshotId: string },
  generation: ActiveGeneration,
): (textSoFar: string) => void {
  return (textSoFar) => {
    if (!generations.isCurrent(endpoint.tabId, ids.requestId)) return;
    sendToEndpoint(endpoint, { type: 'ANALYZE_CHUNK', text: textSoFar, ...ids })
      .catch(() => {
        generations.cancel(endpoint.tabId, generation.requestId);
      });
  };
}

function makeThinkingRelay(
  endpoint: SessionEndpoint,
  ids: { captureId: string; requestId: string; screenshotId: string },
  generation: ActiveGeneration,
): () => void {
  return () => {
    if (!generations.isCurrent(endpoint.tabId, ids.requestId)) return;
    sendToEndpoint(endpoint, { type: 'ANALYZE_THINKING', ...ids })
      .catch(() => {
        generations.cancel(endpoint.tabId, generation.requestId);
      });
  };
}

function showActionBadge(tabId: number, message: string): Promise<void> {
  return actionFeedback.show(tabId, message);
}

async function showPageToast(tabId: number, message: string): Promise<void> {
  try {
    await chrome.tabs.sendMessage(tabId, { type: 'SHOW_ERROR', message } satisfies BgToCsMessage);
  } catch {
    // If the isolated UI is unavailable, keep feedback in browser chrome.
    await showActionBadge(tabId, message);
  }
}

function withTimeout<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      reject(new Error(`SnapScreen content initialization exceeded ${timeoutMs} ms.`));
    }, timeoutMs);

    promise.then(
      (value) => {
        clearTimeout(timeout);
        resolve(value);
      },
      (error: unknown) => {
        clearTimeout(timeout);
        reject(error);
      },
    );
  });
}

function createCapabilityNonce(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replace(/=+$/u, '');
}

function workspaceStorageKey(sessionId: string): string {
  return `${WORKSPACE_STORAGE_PREFIX}${sessionId}`;
}

function getWorkspaceMetadata(record: WorkspaceRecord): WorkspaceMetadata {
  return {
    claimed: record.claimed,
    initialNonce: record.initialNonce,
    reconnectToken: record.reconnectToken,
    sessionId: record.sessionId,
    sourceDocumentVersion: record.sourceDocumentVersion,
    sourceRecaptureAvailable: record.sourceRecaptureAvailable,
    sourceTabId: record.sourceTabId,
    sourceUrl: record.sourceUrl,
    sourceWindowId: record.sourceWindowId,
    workspaceTabId: record.workspaceTabId,
  };
}

async function persistWorkspace(record: WorkspaceRecord): Promise<void> {
  const storage = chrome.storage?.session;
  if (!storage) return;
  try {
    await storage.set({
      [workspaceStorageKey(record.sessionId)]: getWorkspaceMetadata(record),
    });
  } catch {
    // The live registry remains authoritative while this worker is running.
  }
}

function isWorkspaceMetadata(value: unknown): value is WorkspaceMetadata {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return false;
  const metadata = value as Partial<WorkspaceMetadata>;
  const hasInitialCredential = metadata.claimed === false
    && typeof metadata.initialNonce === 'string'
    && /^[A-Za-z0-9_-]{43}$/u.test(metadata.initialNonce)
    && metadata.reconnectToken === undefined;
  const hasReconnectCredential = metadata.claimed === true
    && metadata.initialNonce === undefined
    && typeof metadata.reconnectToken === 'string'
    && /^[A-Za-z0-9_-]{43}$/u.test(metadata.reconnectToken);
  return (hasInitialCredential || hasReconnectCredential)
    && typeof metadata.sessionId === 'string'
    && typeof metadata.sourceDocumentVersion === 'number'
    && typeof metadata.sourceRecaptureAvailable === 'boolean'
    && typeof metadata.sourceTabId === 'number'
    && (metadata.sourceUrl === undefined || typeof metadata.sourceUrl === 'string')
    && typeof metadata.sourceWindowId === 'number'
    && typeof metadata.workspaceTabId === 'number';
}

async function restoreWorkspace(sessionId: string): Promise<WorkspaceRecord | null> {
  const storage = chrome.storage?.session;
  if (!storage) return null;
  try {
    const key = workspaceStorageKey(sessionId);
    const stored = await storage.get(key);
    const metadata = stored[key];
    if (!isWorkspaceMetadata(metadata) || metadata.sessionId !== sessionId) return null;
    const record: WorkspaceRecord = { ...metadata };
    workspaceBySession.set(sessionId, record);
    workspaceSessionBySourceTab.set(record.sourceTabId, sessionId);
    workspaceSessionByTab.set(record.workspaceTabId, sessionId);
    if (!record.claimed) armWorkspaceClaimTimeout(record);
    return record;
  } catch {
    return null;
  }
}

async function removeWorkspaceMetadata(sessionId: string): Promise<void> {
  const storage = chrome.storage?.session;
  if (!storage) return;
  try {
    await storage.remove(workspaceStorageKey(sessionId));
  } catch {
    // Cleanup is best effort for an already-closed workspace.
  }
}

function getWorkspaceEndpoint(record: WorkspaceRecord): WorkspaceEndpoint {
  return {
    kind: 'workspace',
    sessionId: record.sessionId,
    tabId: record.workspaceTabId,
  };
}

function cleanupWorkspace(sessionId: string): void {
  const record = workspaceBySession.get(sessionId);
  if (!record) {
    void removeWorkspaceMetadata(sessionId);
    return;
  }
  if (record.claimTimer !== undefined) clearTimeout(record.claimTimer);
  if (record.disconnectTimer !== undefined) clearTimeout(record.disconnectTimer);
  workspaceBySession.delete(sessionId);
  if (workspaceSessionBySourceTab.get(record.sourceTabId) === sessionId) {
    workspaceSessionBySourceTab.delete(record.sourceTabId);
  }
  if (workspaceSessionByTab.get(record.workspaceTabId) === sessionId) {
    workspaceSessionByTab.delete(record.workspaceTabId);
  }
  record.port = undefined;
  clearTabState(record.workspaceTabId);
  void removeWorkspaceMetadata(sessionId);
}

function armWorkspaceClaimTimeout(record: WorkspaceRecord): void {
  if (record.claimTimer !== undefined) clearTimeout(record.claimTimer);
  record.claimTimer = setTimeout(() => {
    if (record.claimed || workspaceBySession.get(record.sessionId) !== record) return;
    record.claimTimer = undefined;
    const shouldReportExpiredCapture = record.acceptingInitialStart
      || record.pendingStart !== undefined;
    record.acceptingInitialStart = false;
    record.awaitingInitialClaim = false;
    record.pendingStart = undefined;
    if (shouldReportExpiredCapture) {
      record.pendingError = {
        code: 'capture_expired',
        message: 'The frozen screenshot expired before the workspace opened. Return to the source tab and try again.',
      };
    }
  }, WORKSPACE_CLAIM_TIMEOUT_MS);
}

async function closeWorkspace(record: WorkspaceRecord): Promise<void> {
  cleanupWorkspace(record.sessionId);
  await chrome.tabs.update(record.sourceTabId, { active: true }).catch(() => undefined);
  await chrome.tabs.remove(record.workspaceTabId).catch(() => undefined);
}

async function getReusableWorkspace(sourceTabId: number): Promise<WorkspaceRecord | null> {
  const sessionId = workspaceSessionBySourceTab.get(sourceTabId);
  if (!sessionId) return null;
  const record = workspaceBySession.get(sessionId);
  if (!record) return null;
  try {
    const workspaceTab = await chrome.tabs.get(record.workspaceTabId);
    if (!isWorkspaceUrl(workspaceTab.url)) {
      cleanupWorkspace(sessionId);
      return null;
    }
    return record;
  } catch {
    cleanupWorkspace(sessionId);
    return null;
  }
}

async function createWorkspace(
  source: {
    documentVersion: number;
    tabId: number;
    url?: string;
    windowId: number;
  },
): Promise<WorkspaceRecord> {
  const sessionId = crypto.randomUUID();
  const nonce = createCapabilityNonce();
  const url = new URL(chrome.runtime.getURL(WORKSPACE_PATH));
  url.hash = new URLSearchParams({ session: sessionId, nonce }).toString();
  const workspaceTab = await chrome.tabs.create({
    active: true,
    url: url.href,
    windowId: source.windowId,
  });
  if (typeof workspaceTab.id !== 'number') {
    throw new Error('Chrome did not create the SnapScreen workspace tab.');
  }

  const record: WorkspaceRecord = {
    acceptingInitialStart: true,
    claimed: false,
    initialNonce: nonce,
    sessionId,
    sourceDocumentVersion: source.documentVersion,
    sourceRecaptureAvailable: true,
    sourceTabId: source.tabId,
    sourceUrl: source.url,
    sourceWindowId: source.windowId,
    workspaceTabId: workspaceTab.id,
  };
  workspaceBySession.set(sessionId, record);
  workspaceSessionBySourceTab.set(source.tabId, sessionId);
  workspaceSessionByTab.set(workspaceTab.id, sessionId);
  armWorkspaceClaimTimeout(record);
  await persistWorkspace(record);
  return record;
}

async function getOrCreateWorkspace(
  source: {
    documentVersion: number;
    tabId: number;
    url?: string;
    windowId: number;
  },
): Promise<WorkspaceRecord> {
  const existing = await getReusableWorkspace(source.tabId);
  if (existing) {
    existing.sourceDocumentVersion = source.documentVersion;
    existing.sourceRecaptureAvailable = true;
    existing.sourceUrl = source.url;
    existing.sourceWindowId = source.windowId;
    await persistWorkspace(existing);
    await chrome.tabs.update(existing.workspaceTabId, { active: true });
    return existing;
  }
  return createWorkspace(source);
}

function postWorkspaceReady(record: WorkspaceRecord): void {
  const port = record.port;
  const reconnectToken = record.reconnectToken;
  if (!port || !reconnectToken) return;
  const initialMessage = record.pendingStart;
  const error = record.pendingError;
  record.pendingStart = undefined;
  record.pendingError = undefined;
  port.postMessage({
    type: 'SNAPSCREEN_WORKSPACE_READY',
    sessionId: record.sessionId,
    reconnectToken,
    initialMessage,
    error,
  } satisfies BackgroundToWorkspaceMessage);
}

async function deliverWorkspaceStart(
  record: WorkspaceRecord,
  startMessage: WorkspaceInitialMessage,
): Promise<void> {
  const endpoint = getWorkspaceEndpoint(record);
  record.pendingStart = startMessage;
  record.pendingError = undefined;
  record.acceptingInitialStart = false;

  if (record.port) {
    if (record.awaitingInitialClaim) {
      record.awaitingInitialClaim = false;
      postWorkspaceReady(record);
    } else {
      record.pendingStart = undefined;
      await sendToEndpoint(endpoint, startMessage);
    }
  }
}

async function openWorkspaceError(
  source: {
    documentVersion: number;
    tabId: number;
    url?: string;
    windowId: number;
  },
  error: WorkspaceError,
): Promise<void> {
  const record = await getOrCreateWorkspace(source);
  record.pendingError = error;
  record.pendingStart = undefined;
  record.acceptingInitialStart = false;
  if (record.port) {
    record.awaitingInitialClaim = false;
    postWorkspaceReady(record);
  }
}

async function prepareExistingUi(tabId: number): Promise<void> {
  try {
    await withTimeout(
      chrome.tabs.sendMessage(
        tabId,
        { type: 'PREPARE_SNIP_CAPTURE' } satisfies BgToCsMessage,
        { frameId: 0 },
      ),
      SNIP_START_TIMEOUT_MS,
    );
  } catch {
    // A missing receiver is expected on cold and browser-restricted tabs.
  }
}

async function injectContentEndpoint(
  tabId: number,
  expectedDocumentVersion: number,
): Promise<ContentEndpoint | null> {
  try {
    const injectionResults = await withTimeout(
      chrome.scripting.executeScript({
        target: { tabId },
        files: [contentScript],
      }),
      SNIP_START_TIMEOUT_MS,
    );
    if (captureSources.documentVersion(tabId) !== expectedDocumentVersion) return null;
    const topFrameResult = injectionResults.find((result) => result.frameId === 0);
    return topFrameResult?.documentId
      ? getContentEndpoint(tabId, topFrameResult.documentId)
      : null;
  } catch {
    return null;
  }
}

function captureVisibleViewport(
  tabId: number,
  windowId: number,
  expectedDocumentVersion: number,
): Promise<string> {
  return captureSources.capture({ tabId, windowId, documentVersion: expectedDocumentVersion });
}

async function ensureFileAccess(url?: string): Promise<boolean> {
  if (!url?.startsWith('file:')) return true;
  try {
    const granted = await chrome.permissions.request({ origins: ['file:///*'] });
    if (!granted) return false;
    return await chrome.extension.isAllowedFileSchemeAccess();
  } catch {
    return false;
  }
}

async function startSnip(
  tabId: number,
  windowId: number,
  expectedDocumentVersion: number,
  requestedSettings?: SnapScreenSessionSettings,
  sourceUrl?: string,
): Promise<void> {
  await prepareExistingUi(tabId);
  let dataUrl: string;
  try {
    dataUrl = await captureVisibleViewport(tabId, windowId, expectedDocumentVersion);
  } catch (error) {
    if (captureSources.documentVersion(tabId) !== expectedDocumentVersion) {
      await showActionBadge(
        tabId,
        'SnapScreen did not start because the page changed. Try again on the current page.',
      );
      return;
    }
    await showPageToast(
      tabId,
      error instanceof ActiveTabChangedError
        ? error.message
        : 'Chrome did not allow SnapScreen to capture this tab. Browser UI, protected media, and system-secured surfaces may be unavailable.',
    );
    return;
  }

  try {
    const storedSettings = await getSettings();
    const settings = getRequestSessionSettings(requestedSettings, storedSettings);
    const captureId = crypto.randomUUID();
    const startMessage: WorkspaceInitialMessage = {
      type: 'START_SNIP',
      captureId,
      dataUrl,
      defaultPrompt: settings.defaultPrompt,
      limits: settings.limits,
    };

    const contentEndpoint = await injectContentEndpoint(tabId, expectedDocumentVersion);
    if (captureSources.documentVersion(tabId) !== expectedDocumentVersion) {
      throw new ActiveTabChangedError();
    }
    if (contentEndpoint) {
      frozenCaptureById.set(captureId, {
        dataUrl,
        endpointKey: endpointKey(contentEndpoint),
      });
      try {
        await sendToEndpoint(contentEndpoint, startMessage);
        return;
      } catch {
        frozenCaptureById.delete(captureId);
      }
    }

    const workspace = await getOrCreateWorkspace({
      documentVersion: expectedDocumentVersion,
      tabId,
      url: sourceUrl,
      windowId,
    });
    await deliverWorkspaceStart(workspace, startMessage);
  } catch {
    if (captureSources.documentVersion(tabId) !== expectedDocumentVersion) {
      await showActionBadge(
        tabId,
        'SnapScreen did not start because the page changed. Try again on the current page.',
      );
      return;
    }
    await showPageToast(
      tabId,
      "SnapScreen couldn't start on this page. Reload it and try again.",
    );
  }
}

async function handleStartSnip(tab?: chrome.tabs.Tab): Promise<void> {
  const resolved = tab ?? (await getActiveTab());
  if (typeof resolved?.id !== 'number') return;

  const expectedDocumentVersion = captureSources.documentVersion(resolved.id);
  // Native mode branches before any page message, injection, permission prompt, or workspace.
  let mode: Awaited<ReturnType<typeof getInterfaceMode>>;
  try {
    mode = await getInterfaceMode();
  } catch {
    await showActionBadge(resolved.id, 'SnapScreen could not read Settings. Please try again.');
    return;
  }
  if (mode === 'native') {
    await nativeSessions.start(resolved, expectedDocumentVersion);
    return;
  }
  if (!(await ensureFileAccess(resolved.url))) {
    await openWorkspaceError(
      {
        documentVersion: expectedDocumentVersion,
        tabId: resolved.id,
        url: resolved.url,
        windowId: resolved.windowId,
      },
      {
        code: 'file_access_disabled',
        message: 'Chrome has not granted SnapScreen access to local files. Enable “Allow access to file URLs” in Manage Extension, then try again.',
      },
    ).catch(() => showActionBadge(
      resolved.id!,
      'Enable “Allow access to file URLs” for SnapScreen, then try again.',
    ));
    return;
  }

  await startSnip(
    resolved.id,
    resolved.windowId,
    expectedDocumentVersion,
    undefined,
    resolved.url,
  );
}

function getUrlOrigin(url?: string): string | null {
  if (!url) return null;
  try {
    return new URL(url).origin;
  } catch {
    return null;
  }
}

async function recaptureWorkspace(
  record: WorkspaceRecord,
  requestedSettings: SnapScreenSessionSettings,
): Promise<{ ok: true } | { error: string }> {
  const pageChangedMessage =
    'The source page changed. Return to it and invoke SnapScreen again to grant access.';
  if (!record.sourceRecaptureAvailable) {
    await safeSendToEndpoint(getWorkspaceEndpoint(record), {
      type: 'RESNIP_UNAVAILABLE',
      message: pageChangedMessage,
    });
    return { error: pageChangedMessage };
  }
  let sourceTab: chrome.tabs.Tab;
  try {
    sourceTab = await chrome.tabs.get(record.sourceTabId);
  } catch {
    const message = 'The source tab was closed. Follow-up questions still work, but a new snip is unavailable.';
    await safeSendToEndpoint(getWorkspaceEndpoint(record), {
      type: 'RESNIP_UNAVAILABLE',
      message,
    });
    return { error: message };
  }

  const currentVersion = captureSources.documentVersion(record.sourceTabId);
  const storedOrigin = getUrlOrigin(record.sourceUrl);
  const currentOrigin = getUrlOrigin(sourceTab.url);
  if (
    currentVersion !== record.sourceDocumentVersion
    || (storedOrigin !== null && currentOrigin !== null && storedOrigin !== currentOrigin)
  ) {
    record.sourceRecaptureAvailable = false;
    await persistWorkspace(record);
    await safeSendToEndpoint(getWorkspaceEndpoint(record), {
      type: 'RESNIP_UNAVAILABLE',
      message: pageChangedMessage,
    });
    return { error: pageChangedMessage };
  }

  try {
    await chrome.tabs.update(record.sourceTabId, { active: true });
    await prepareExistingUi(record.sourceTabId);
    const dataUrl = await captureVisibleViewport(
      record.sourceTabId,
      record.sourceWindowId,
      currentVersion,
    );
    const storedSettings = await getSettings();
    const settings = getRequestSessionSettings(requestedSettings, storedSettings);
    const startMessage: WorkspaceInitialMessage = {
      type: 'START_SNIP',
      captureId: crypto.randomUUID(),
      dataUrl,
      defaultPrompt: settings.defaultPrompt,
      limits: settings.limits,
    };

    record.sourceDocumentVersion = currentVersion;
    record.sourceUrl = sourceTab.url;
    await persistWorkspace(record);
    await chrome.tabs.update(record.workspaceTabId, { active: true });
    await deliverWorkspaceStart(record, startMessage);
    return { ok: true };
  } catch {
    await chrome.tabs.update(record.workspaceTabId, { active: true }).catch(() => undefined);
    record.sourceRecaptureAvailable = false;
    await persistWorkspace(record);
    await safeSendToEndpoint(getWorkspaceEndpoint(record), {
      type: 'RESNIP_UNAVAILABLE',
      message: pageChangedMessage,
    });
    return { error: pageChangedMessage };
  }
}

async function handleControllerMessage(
  message: CsToBgMessage,
  endpoint: SessionEndpoint,
  senderTab?: chrome.tabs.Tab,
): Promise<unknown> {
  const ownerTabId = endpoint.tabId;
  try {
    switch (message.type) {
      case 'REQUEST_SNIP': {
        if (endpoint.kind === 'workspace') {
          const workspace = workspaceBySession.get(endpoint.sessionId);
          if (!workspace) return { error: 'The SnapScreen workspace expired.' };
          return recaptureWorkspace(workspace, message.sessionSettings);
        }

        if (senderTab?.windowId === undefined) return { error: 'No tab context' };
        await startSnip(
          ownerTabId,
          senderTab.windowId,
          captureSources.documentVersion(ownerTabId),
          message.sessionSettings,
          senderTab.url,
        );
        return { ok: true };
      }

      case 'CAPTURE_REGION': {
        if (!beginCapture(endpoint, message.captureId)) {
          return { ok: false, duplicate: true };
        }

        try {
          const frozenCapture = frozenCaptureById.get(message.captureId);
          frozenCaptureById.delete(message.captureId);
          const currentEndpointKey = endpointKey(endpoint);
          const cropped = await cropImage(
            frozenCapture?.endpointKey === currentEndpointKey
              ? frozenCapture.dataUrl
              : message.dataUrl,
            message.selection.normalizedRect,
          );

          if (!isCurrentCapture(endpoint, message.captureId)) {
            return { ok: false, stale: true };
          }

          await sendToEndpoint(endpoint, {
            type: 'CROPPED_IMAGE',
            dataUrl: cropped,
            captureId: message.captureId,
          });
          return { ok: true };
        } catch {
          await safeSendToEndpoint(endpoint, {
            type: 'CAPTURE_ERROR',
            code: 'capture',
            message: GENERIC_CAPTURE_ERROR,
            captureId: message.captureId,
          });
          return { error: GENERIC_CAPTURE_ERROR };
        }
      }

      case 'ANALYZE': {
        const generation = generations.start(
          ownerTabId,
          endpointDocumentId(endpoint),
          message.captureId,
          message.requestId,
        );
        if (!generation) return { ok: false, duplicate: true };
        const ids = {
          captureId: message.captureId,
          requestId: message.requestId,
          screenshotId: message.screenshotId,
        };

        try {
          const settings = await getSettings();
          if (!settings.apiKey) {
            await sendToEndpoint(endpoint, {
              type: 'ANALYZE_ERROR',
              code: 'no_api_key',
              message: 'No API key configured. Add your Anthropic API key in Settings, then try again.',
              ...ids,
            });
            return { ok: false };
          }
          const sessionSettings = getRequestSessionSettings(
            message.sessionSettings,
            settings,
          );
          // High-DPI captures can exceed the limits; send them downscaled.
          const screenshot = await fitScreenshotToLimits(
            message.dataUrl,
            sessionSettings.limits,
          );
          const result = await keepAliveUntilSettled(analyzeImage(
            settings.apiKey,
            screenshot,
            {
              hiddenInstruction: sessionSettings.defaultPrompt,
              userQuestion: message.question,
              signal: generation.controller.signal,
              onDelta: makeDeltaRelay(endpoint, ids, generation),
              onThinking: makeThinkingRelay(endpoint, ids, generation),
              limits: sessionSettings.limits,
            },
          ));

          if (!generations.isCurrent(ownerTabId, message.requestId)) {
            return { ok: false, aborted: true };
          }
          await sendToEndpoint(endpoint, {
            type: 'ANALYZE_RESULT',
            text: result.text,
            history: result.history,
            ...ids,
          });
          return { ok: true };
        } finally {
          generations.finish(ownerTabId, message.requestId);
        }
      }

      case 'FOLLOW_UP': {
        const generation = generations.start(
          ownerTabId,
          endpointDocumentId(endpoint),
          message.captureId,
          message.requestId,
        );
        if (!generation) return { ok: false, duplicate: true };
        const ids = {
          captureId: message.captureId,
          requestId: message.requestId,
          screenshotId: message.screenshotId,
        };

        try {
          const settings = await getSettings();
          if (!settings.apiKey) {
            await sendToEndpoint(endpoint, {
              type: 'ANALYZE_ERROR',
              code: 'no_api_key',
              message: 'No API key configured. Add your Anthropic API key in Settings, then try again.',
              ...ids,
            });
            return { ok: false };
          }
          const sessionSettings = getRequestSessionSettings(
            message.sessionSettings,
            settings,
          );
          // After a stopped or interrupted first answer, the page rebuilds
          // history with the full-size capture. Send it downscaled too.
          const history = await fitHistoryScreenshotsToLimits(
            message.history,
            sessionSettings.limits,
          );
          const result = await keepAliveUntilSettled(followUp(
            settings.apiKey,
            message.text,
            history,
            {
              signal: generation.controller.signal,
              onDelta: makeDeltaRelay(endpoint, ids, generation),
              onThinking: makeThinkingRelay(endpoint, ids, generation),
              sessionInstruction: sessionSettings.defaultPrompt,
              limits: sessionSettings.limits,
            },
          ));

          if (!generations.isCurrent(ownerTabId, message.requestId)) {
            return { ok: false, aborted: true };
          }
          await sendToEndpoint(endpoint, {
            type: 'ANALYZE_RESULT',
            text: result.text,
            history: result.history,
            ...ids,
          });
          return { ok: true };
        } finally {
          generations.finish(ownerTabId, message.requestId);
        }
      }

      case 'CANCEL_GENERATION':
        generations.cancel(ownerTabId, message.requestId);
        return { ok: true };

      case 'SNIP_CANCELLED': {
        const key = endpointKey(endpoint);
        frozenCaptureById.delete(message.captureId);
        if (isCurrentCapture(endpoint, message.captureId)) {
          captureIdByEndpoint.delete(key);
        }
        generations.cancelCapture(ownerTabId, message.captureId);
        return { ok: true };
      }

      case 'UI_UNAVAILABLE':
        if (endpoint.kind === 'content') {
          await showActionBadge(
            ownerTabId,
            'SnapScreen could not open its isolated UI on this page. Please try again.',
          );
        }
        return { ok: true };

      case 'OPEN_SETTINGS':
        await chrome.runtime.openOptionsPage();
        return { ok: true };
    }
  } catch (error) {
    if (isAbortError(error)) return { ok: false, aborted: true };

    const failure = getPublicGenerationError(error);
    if (message.type === 'ANALYZE' || message.type === 'FOLLOW_UP') {
      await safeSendToEndpoint(endpoint, {
        type: 'ANALYZE_ERROR',
        code: failure.code,
        message: failure.message,
        captureId: message.captureId,
        requestId: message.requestId,
        screenshotId: message.screenshotId,
      });
    }
    return { error: failure.message };
  }
}

chrome.runtime.onInstalled.addListener((details) => {
  if (details.reason === 'install') {
    void chrome.runtime.openOptionsPage();
  }
});

chrome.action.onClicked.addListener((tab) => {
  void handleStartSnip(tab);
});

chrome.commands.onCommand.addListener((command, tab) => {
  if (command === 'snip') {
    void handleStartSnip(tab);
  }
});

chrome.tabs.onRemoved.addListener((tabId) => {
  nativeSessions.invalidateSource(tabId);
  const workspaceSessionId = workspaceSessionByTab.get(tabId);
  if (workspaceSessionId) cleanupWorkspace(workspaceSessionId);
  const sourceWorkspaceSessionId = workspaceSessionBySourceTab.get(tabId);
  const sourceWorkspace = sourceWorkspaceSessionId
    ? workspaceBySession.get(sourceWorkspaceSessionId)
    : undefined;
  if (sourceWorkspace) {
    sourceWorkspace.sourceRecaptureAvailable = false;
    workspaceSessionBySourceTab.delete(tabId);
    void persistWorkspace(sourceWorkspace);
    void safeSendToEndpoint(getWorkspaceEndpoint(sourceWorkspace), {
      type: 'RESNIP_UNAVAILABLE',
      message: 'The source tab was closed. Follow-up questions still work, but a new snip is unavailable.',
    });
  }
  captureSources.removed(tabId);
  clearTabState(tabId);
});

chrome.tabs.onActivated.addListener(({ windowId }) => {
  captureSources.activated(windowId);
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  // A URL-only update can be a same-document hash/history change. The content
  // script and its document-scoped session remain valid in that case.
  if (changeInfo.status === 'loading') {
    nativeSessions.invalidateSource(tabId);
    const workspaceSessionId = workspaceSessionByTab.get(tabId);
    if (
      workspaceSessionId
      && !isWorkspaceUrl(changeInfo.url ?? tab.url)
    ) {
      cleanupWorkspace(workspaceSessionId);
    }
    captureSources.navigated(tabId);
    const sourceWorkspaceSessionId = workspaceSessionBySourceTab.get(tabId);
    const sourceWorkspace = sourceWorkspaceSessionId
      ? workspaceBySession.get(sourceWorkspaceSessionId)
      : undefined;
    if (sourceWorkspace) {
      sourceWorkspace.sourceRecaptureAvailable = false;
      void persistWorkspace(sourceWorkspace);
      void safeSendToEndpoint(getWorkspaceEndpoint(sourceWorkspace), {
        type: 'RESNIP_UNAVAILABLE',
        message: 'The source page changed. Return to it and invoke SnapScreen again to grant access.',
      });
    }
    clearTabState(tabId);
  }
});

chrome.runtime.onMessage.addListener((
  message: CsToBgMessage | UiAttestationMessage,
  sender,
  sendResponse,
) => {
  if (isUiAttestationMessage(message)) {
    sendResponse(handleUiAttestation(message, sender));
    return;
  }

  const senderTab = sender.tab;
  if (
    !isTrustedTopFrameContentSender(sender)
    || !senderTab
    || typeof senderTab.id !== 'number'
  ) return;

  const endpoint = getContentEndpoint(senderTab.id, sender.documentId);
  void handleControllerMessage(message, endpoint, senderTab)
    .then(sendResponse);
  return true;
});

chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== WORKSPACE_PORT_NAME) return;
  const portSender = port.sender;
  if (!portSender || !isTrustedWorkspaceSender(portSender)) {
    port.disconnect();
    return;
  }

  const workspaceTabId = portSender.tab?.id;
  if (typeof workspaceTabId !== 'number') {
    port.disconnect();
    return;
  }

  let authenticatedSessionId: string | null = null;

  port.onMessage.addListener((value: unknown) => {
    void (async () => {
      if (!isWorkspaceToBackgroundMessage(value)) return;

      if (value.type === 'SNAPSCREEN_WORKSPACE_CLAIM') {
        const record = workspaceBySession.get(value.sessionId)
          ?? await restoreWorkspace(value.sessionId);
        const isInitialClaim = value.nonce !== undefined;
        const credentialMatches = isInitialClaim
          ? !record?.claimed && record?.initialNonce === value.nonce
          : record?.claimed && record.reconnectToken === value.reconnectToken;
        if (
          !record
          || !credentialMatches
          || record.workspaceTabId !== workspaceTabId
          || (record.port !== undefined && record.port !== port)
        ) {
          port.disconnect();
          return;
        }

        if (isInitialClaim) {
          record.claimed = true;
          record.initialNonce = undefined;
          record.reconnectToken = createCapabilityNonce();
          if (record.claimTimer !== undefined) {
            clearTimeout(record.claimTimer);
            record.claimTimer = undefined;
          }
          await persistWorkspace(record);
        }
        if (record.disconnectTimer !== undefined) {
          clearTimeout(record.disconnectTimer);
          record.disconnectTimer = undefined;
        }
        authenticatedSessionId = record.sessionId;
        record.port = port;
        workspaceBySession.set(record.sessionId, record);
        workspaceSessionBySourceTab.set(record.sourceTabId, record.sessionId);
        workspaceSessionByTab.set(record.workspaceTabId, record.sessionId);
        if (
          value.needsInitialState
          && !record.pendingStart
          && !record.pendingError
        ) {
          if (record.acceptingInitialStart) {
            record.awaitingInitialClaim = true;
            return;
          }
          record.pendingError = {
            code: 'capture_expired',
            message: 'The frozen screenshot expired before the workspace opened. Return to the source tab and try again.',
          };
        }
        postWorkspaceReady(record);
        return;
      }

      if (
        authenticatedSessionId === null
        || value.sessionId !== authenticatedSessionId
      ) return;
      const record = workspaceBySession.get(authenticatedSessionId);
      if (!record || record.port !== port) return;

      if (value.type === 'SNAPSCREEN_WORKSPACE_CLOSE') {
        await closeWorkspace(record);
        return;
      }

      const requestIds = record.requestIds ??= new Set<string>();
      if (requestIds.has(value.requestId)) {
        port.postMessage({
          type: 'SNAPSCREEN_WORKSPACE_RESPONSE',
          sessionId: record.sessionId,
          requestId: value.requestId,
          response: { error: 'Duplicate workspace request.' },
        } satisfies BackgroundToWorkspaceMessage);
        return;
      }
      if (requestIds.size >= 200) {
        const oldest = requestIds.values().next().value;
        if (oldest !== undefined) requestIds.delete(oldest);
      }
      requestIds.add(value.requestId);

      const response = await handleControllerMessage(
        value.message,
        getWorkspaceEndpoint(record),
      );
      if (record.port !== port) return;
      port.postMessage({
        type: 'SNAPSCREEN_WORKSPACE_RESPONSE',
        sessionId: record.sessionId,
        requestId: value.requestId,
        response,
      } satisfies BackgroundToWorkspaceMessage);
    })().catch(() => {
      port.disconnect();
    });
  });

  port.onDisconnect.addListener(() => {
    if (!authenticatedSessionId) return;
    const record = workspaceBySession.get(authenticatedSessionId);
    if (record?.port !== port) return;
    record.port = undefined;
    record.disconnectTimer = setTimeout(() => {
      if (record.port || workspaceBySession.get(record.sessionId) !== record) return;
      record.disconnectTimer = undefined;
      generations.clearTab(record.workspaceTabId);
    }, WORKSPACE_DISCONNECT_TIMEOUT_MS);
  });
});
