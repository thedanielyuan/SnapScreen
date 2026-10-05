import { clampToViewport, VIEWPORT_MARGIN } from '../lib/clamp-to-viewport';
import { splitAnswerSegments, type AnswerSegment } from '../lib/code-blocks';
import { countTextCharacters } from '../lib/request-limits';
import { getComposerButtonState } from './composer-button-state';
import {
  getUiRoot,
  queryUiElement,
  removeUiHostIfEmpty,
} from './ui-root';
import type { DisplayMessage, Rect } from '../lib/messages';

const PANEL_ID = 'snapscreen-panel-root';
const BACKDROP_ID = 'snapscreen-panel-backdrop';
const TOAST_ID = 'snapscreen-toast-root';
const LIGHTBOX_ID = 'snapscreen-lightbox-root';
const MARGIN = VIEWPORT_MARGIN;
// A reader this close to the end of the answer still has new text followed.
const FOLLOW_END_THRESHOLD_PX = 24;

const CLOSE_ICON_SVG = `<svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M18 6L6 18M6 6l12 12"/></svg>`;
const RESNIP_ICON_SVG = `<svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 2v14a2 2 0 0 0 2 2h14"/><path d="M18 22V8a2 2 0 0 0-2-2H2"/></svg>`;
const COPY_ICON_SVG = `<svg viewBox="0 0 24 24" width="14" height="14" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>`;
const CHECK_ICON_SVG = `<svg viewBox="0 0 24 24" width="14" height="14" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6L9 17l-5-5"/></svg>`;
const SEND_ICON_SVG = `<svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 19V5M5 12l7-7 7 7"/></svg>`;
const STOP_ICON_SVG = `<svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true" fill="currentColor"><circle cx="12" cy="12" r="9" opacity="0.22"/><rect x="8" y="8" width="8" height="8" rx="1.5"/></svg>`;

interface CopyButtonConfig {
  className: string;
  label: string;
  idleHtml: string;
  copiedHtml: string;
  failureMessage: string;
}

const ANSWER_COPY_BUTTON: CopyButtonConfig = {
  className: 'snapscreen-copy-btn',
  label: 'Copy answer',
  idleHtml: COPY_ICON_SVG,
  copiedHtml: CHECK_ICON_SVG,
  failureMessage: 'Could not copy the answer.',
};

let panelPosition: { top: number; left: number } | null = null;
let panelPositioningAbort: AbortController | null = null;
let panelDragAbort: AbortController | null = null;
// An answer can rerender the panel between Escape keydown and keyup.
let panelEscapePressed = false;
let lightboxAbort: AbortController | null = null;
let lightboxReturnFocus: HTMLElement | null = null;
let toastTimeout: ReturnType<typeof setTimeout> | null = null;
let draggingPanel: HTMLElement | null = null;
let lightboxBackgroundPanel: HTMLElement | null = null;
let lightboxBackgroundAriaHidden: string | null = null;
const panelAnimationFrames = new Set<number>();

function schedulePanelFrame(callback: FrameRequestCallback): number {
  const frame = requestAnimationFrame((time) => {
    panelAnimationFrames.delete(frame);
    callback(time);
  });
  panelAnimationFrames.add(frame);
  return frame;
}

function cancelPanelFrames(): void {
  for (const frame of panelAnimationFrames) cancelAnimationFrame(frame);
  panelAnimationFrames.clear();
}

export interface ResultPanelOptions {
  dataUrl?: string;
  messages?: DisplayMessage[];
  error?: string;
  errorCode?: string;
  pending?: boolean;
  anchorRect?: Rect;
  onClose: () => void;
  onFollowUp: (text: string) => void;
  onOpenSettings?: () => void;
  onStop?: () => void;
  onRetry?: () => void;
  onResnip?: () => void;
  maxInputCharacters?: number;
  /**
   * Buttons under the newest failed answer. A failed follow-up can be retried
   * or removed; a failed first answer can only be tried again.
   */
  failedAnswerActions?: {
    onRetry: () => void;
    onRemove?: () => void;
  };
}

export function showResultPanel(options: ResultPanelOptions): void {
  cancelPanelFrames();
  queryUiElement('#snapscreen-overlay-root')?.remove();
  closeScreenshotLightbox();
  const uiRoot = getUiRoot();
  panelDragAbort?.abort();
  panelDragAbort = null;
  resetPanelCursor();

  let backdrop = queryUiElement<HTMLDivElement>(`#${BACKDROP_ID}`);
  if (!backdrop) {
    backdrop = document.createElement('div');
    backdrop.id = BACKDROP_ID;
    backdrop.className = 'snapscreen-panel-backdrop';
    uiRoot.append(backdrop);
  }

  let root = queryUiElement<HTMLDivElement>(`#${PANEL_ID}`);
  if (!root) {
    panelEscapePressed = false;
    root = document.createElement('div');
    root.id = PANEL_ID;
    uiRoot.append(root);
  } else if (root.getBoundingClientRect().width > 0) {
    const rect = root.getBoundingClientRect();
    panelPosition = { top: rect.top, left: rect.left };
  }

  const previousBody = root.querySelector('.snapscreen-panel-body');
  const previousScroll = previousBody && {
    top: previousBody.scrollTop,
    followsEnd: isScrolledToEnd(previousBody),
    questionCount: previousBody.querySelectorAll('.snapscreen-msg-user').length,
  };

  root.className = 'snapscreen-panel';
  root.setAttribute('role', 'dialog');
  root.setAttribute('aria-modal', 'true');
  root.setAttribute('aria-label', 'SnapScreen AI');
  root.innerHTML = '';

  const header = document.createElement('header');
  header.className = 'snapscreen-panel-header';

  const titleWrap = document.createElement('div');
  titleWrap.className = 'snapscreen-panel-title-wrap';

  const icon = document.createElement('img');
  icon.className = 'snapscreen-panel-icon';
  icon.src = chrome.runtime.getURL('src/assets/icons/icon16.png');
  icon.alt = '';
  icon.width = 16;
  icon.height = 16;
  icon.draggable = false;

  const title = document.createElement('span');
  title.className = 'snapscreen-panel-title';
  title.textContent = 'SnapScreen AI';

  titleWrap.append(icon, title);

  const headerActions = document.createElement('div');
  headerActions.className = 'snapscreen-header-actions';

  if (options.onResnip) {
    const onResnip = options.onResnip;
    const resnipBtn = document.createElement('button');
    resnipBtn.type = 'button';
    resnipBtn.className = 'snapscreen-close-btn';
    resnipBtn.setAttribute('aria-label', 'New snip');
    resnipBtn.title = 'New snip';
    resnipBtn.innerHTML = RESNIP_ICON_SVG;
    resnipBtn.addEventListener('pointerdown', (e) => {
      e.stopPropagation();
    });
    resnipBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      disposeResultPanel();
      onResnip();
    });
    headerActions.append(resnipBtn);
  }

  const closeBtn = document.createElement('button');
  closeBtn.type = 'button';
  closeBtn.className = 'snapscreen-close-btn';
  closeBtn.setAttribute('aria-label', 'Close');
  closeBtn.title = 'Close';
  closeBtn.innerHTML = CLOSE_ICON_SVG;
  closeBtn.addEventListener('pointerdown', (e) => {
    e.stopPropagation();
  });
  closeBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    closePanel(options.onClose);
  });
  headerActions.append(closeBtn);

  header.append(titleWrap, headerActions);
  root.append(header);

  let panelImage: HTMLImageElement | null = null;
  if (options.dataUrl) {
    const thumbBtn = document.createElement('button');
    thumbBtn.type = 'button';
    thumbBtn.className = 'snapscreen-panel-image-btn';
    thumbBtn.setAttribute('aria-label', 'View full-size screenshot');

    const img = document.createElement('img');
    img.className = 'snapscreen-panel-image';
    img.src = options.dataUrl;
    img.alt = 'Captured region screenshot';
    img.draggable = false;

    thumbBtn.append(img);
    thumbBtn.addEventListener('click', () => {
      openScreenshotLightbox(options.dataUrl!, thumbBtn);
    });
    root.append(thumbBtn);
    panelImage = img;
  }

  const body = document.createElement('div');
  body.className = 'snapscreen-panel-body';

  const messages = options.messages ?? [];
  const hasMessages = messages.length > 0;
  const isFatalError = !!options.error && !hasMessages;
  let latestFailedMessageIndex = -1;
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    if (messages[index].role === 'assistant' && messages[index].status === 'failed') {
      latestFailedMessageIndex = index;
      break;
    }
  }
  let fatalFocusTarget: HTMLElement | null = null;
  let hasCode = false;

  if (isFatalError) {
    fatalFocusTarget = appendError(
      body,
      options.error!,
      options.errorCode,
      options.onRetry,
      options.onOpenSettings,
    );
  } else {
    if (hasMessages) {
      const thread = document.createElement('div');
      thread.className = 'snapscreen-chat-thread';

      messages.forEach((msg, index) => {
        const bubble = document.createElement('div');
        bubble.className = `snapscreen-msg snapscreen-msg-${msg.role}`;
        bubble.classList.toggle('snapscreen-msg-failed', msg.status === 'failed');
        if (msg.role === 'assistant' && msg.status !== 'failed') {
          hasCode = renderAnswerContent(bubble, msg.content, true) || hasCode;
        } else {
          bubble.textContent = msg.content;
        }
        if (msg.status === 'failed') {
          bubble.setAttribute('aria-label', `Failed response: ${msg.content}`);
          if (index === latestFailedMessageIndex) {
            bubble.setAttribute('role', 'alert');
          }
        }

        if (msg.role === 'assistant') {
          const wrap = document.createElement('div');
          wrap.className = 'snapscreen-msg-assistant-wrap';
          wrap.append(bubble, createCopyButton(msg.content, ANSWER_COPY_BUTTON));
          if (
            index === latestFailedMessageIndex
            && options.failedAnswerActions
          ) {
            wrap.append(createFailedAnswerActions(options.failedAnswerActions));
          }
          thread.append(wrap);
        } else {
          thread.append(bubble);
        }
      });

      body.append(thread);
    }

    if (options.pending) {
      body.append(createPendingIndicator());
    }

    if (options.error && hasMessages) {
      appendError(
        body,
        options.error,
        options.errorCode,
        options.onRetry,
        options.onOpenSettings,
      );
    }

    // A reader who scrolled up keeps their place, unless they just asked a
    // question, which should come into view.
    const questionCount = messages.filter((message) => message.role === 'user').length;
    const keptTop = previousScroll
      && !previousScroll.followsEnd
      && questionCount <= previousScroll.questionCount
      ? previousScroll.top
      : null;
    schedulePanelFrame(() => {
      body.scrollTop = keptTop ?? body.scrollHeight;
    });
  }

  root.classList.toggle('snapscreen-panel-has-code', hasCode);
  root.append(body);

  const footer = document.createElement('div');
  footer.className = 'snapscreen-panel-footer';

  const composer = document.createElement('div');
  composer.className = 'snapscreen-composer';

  const textarea = document.createElement('textarea');
  textarea.rows = 1;
  textarea.className = 'snapscreen-input';
  textarea.placeholder = 'Ask about this answer...';
  textarea.setAttribute('aria-label', 'Ask a follow-up question');
  textarea.disabled = !!options.pending || isFatalError;

  const MAX_TEXTAREA_HEIGHT = 200;
  let singleLineScrollHeight = 0;

  function adjustTextareaHeight(): void {
    textarea.style.height = 'auto';
    const scrollHeight = textarea.scrollHeight;
    if (!singleLineScrollHeight) {
      singleLineScrollHeight = scrollHeight;
    }
    textarea.style.height = `${Math.min(scrollHeight, MAX_TEXTAREA_HEIGHT)}px`;
    textarea.style.overflowY =
      scrollHeight > MAX_TEXTAREA_HEIGHT ? 'auto' : 'hidden';
    composer.classList.toggle(
      'snapscreen-composer-multiline',
      scrollHeight > singleLineScrollHeight,
    );
  }

  const sendBtn = document.createElement('button');
  sendBtn.type = 'button';
  sendBtn.className = 'snapscreen-send-btn';

  const inputError = document.createElement('div');
  inputError.id = 'snapscreen-input-error';
  inputError.className = 'snapscreen-input-error';
  inputError.setAttribute('role', 'alert');
  inputError.hidden = true;

  function clearInputError(): void {
    inputError.hidden = true;
    inputError.textContent = '';
    textarea.removeAttribute('aria-invalid');
    textarea.removeAttribute('aria-describedby');
  }

  function updateSendState(): void {
    const state = getComposerButtonState({
      pending: !!options.pending,
      hasText: textarea.value.trim().length > 0,
      isFatalError,
      canStop: typeof options.onStop === 'function',
    });

    sendBtn.innerHTML = state.mode === 'stop' ? STOP_ICON_SVG : SEND_ICON_SVG;
    sendBtn.setAttribute('aria-label', state.ariaLabel);
    sendBtn.disabled = state.disabled;
    sendBtn.classList.toggle('snapscreen-send-btn-active', state.active);
    sendBtn.classList.toggle('snapscreen-send-btn-stop', state.mode === 'stop');
  }

  function submitFollowUp(): void {
    const text = textarea.value.trim();
    if (!text || options.pending) return;

    if (options.maxInputCharacters !== undefined) {
      const characterCount = countTextCharacters(text);
      if (characterCount > options.maxInputCharacters) {
        inputError.textContent =
          `Question is ${characterCount.toLocaleString()} characters. `
          + `The current limit is ${options.maxInputCharacters.toLocaleString()}. `
          + 'Shorten it or raise the limit in Settings.';
        inputError.hidden = false;
        textarea.setAttribute('aria-invalid', 'true');
        textarea.setAttribute('aria-describedby', inputError.id);
        textarea.focus({ preventScroll: true });
        return;
      }
    }

    clearInputError();
    textarea.value = '';
    textarea.style.height = 'auto';
    adjustTextareaHeight();
    updateSendState();
    options.onFollowUp(text);
  }

  sendBtn.addEventListener('click', () => {
    if (options.pending) {
      options.onStop?.();
      return;
    }

    submitFollowUp();
  });
  textarea.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      submitFollowUp();
    }
  });
  textarea.addEventListener('input', () => {
    clearInputError();
    updateSendState();
    adjustTextareaHeight();
  });

  composer.append(textarea, sendBtn);
  footer.append(composer, inputError);
  root.append(footer);

  updateSendState();
  adjustTextareaHeight();
  schedulePanelFrame(adjustTextareaHeight);

  setupDrag(titleWrap, root);
  positionPanel(root, options.anchorRect);
  setupPanelPositioningListeners(root, panelImage, options.onClose);

  backdrop.onclick = () => closePanel(options.onClose);

  const focusTarget = !textarea.disabled
    ? textarea
    : options.pending && !sendBtn.disabled
      ? sendBtn
      : isFatalError
        ? fatalFocusTarget ?? closeBtn
        : closeBtn;
  focusTarget.focus({ preventScroll: true });
}

function isScrolledToEnd(element: Element): boolean {
  return element.scrollHeight - element.clientHeight - element.scrollTop
    <= FOLLOW_END_THRESHOLD_PX;
}

function createPendingIndicator(): HTMLElement {
  const pending = document.createElement('div');
  pending.className = 'snapscreen-pending';
  pending.setAttribute('role', 'status');
  pending.setAttribute('aria-label', 'Loading');
  pending.innerHTML = '<div class="snapscreen-spinner"></div>';

  return pending;
}

/**
 * Renders answer text into a message bubble. Fenced code becomes a code block,
 * with its own Copy button when `copyable`; everything else stays plain text.
 * Returns whether any code block was rendered.
 */
function renderAnswerContent(
  bubble: Element,
  text: string,
  copyable: boolean,
): boolean {
  const segments = splitAnswerSegments(text);
  const hasCode = segments.some((segment) => segment.type === 'code');
  bubble.classList.toggle('snapscreen-msg-has-code', hasCode);
  if (!hasCode) {
    bubble.textContent = text;
    return false;
  }

  bubble.replaceChildren(...segments.map((segment) => {
    if (segment.type === 'code') return createCodeBlock(segment, copyable);
    const prose = document.createElement('div');
    prose.className = 'snapscreen-msg-text';
    prose.textContent = segment.text;
    return prose;
  }));
  return true;
}

function createCodeBlock(
  segment: Extract<AnswerSegment, { type: 'code' }>,
  copyable: boolean,
): HTMLElement {
  const block = document.createElement('div');
  block.className = 'snapscreen-code-block';

  const header = document.createElement('div');
  header.className = 'snapscreen-code-header';

  const language = document.createElement('span');
  language.className = 'snapscreen-code-language';
  language.textContent = segment.language || 'code';
  header.append(language);

  // Streaming blocks are rebuilt on every delta, so the button only appears
  // once the answer is final.
  if (copyable) {
    const label = segment.language ? `Copy ${segment.language} code` : 'Copy code';
    header.append(createCopyButton(segment.code, {
      className: 'snapscreen-code-copy-btn',
      label,
      idleHtml: `${COPY_ICON_SVG}<span>Copy</span>`,
      copiedHtml: `${CHECK_ICON_SVG}<span>Copied</span>`,
      failureMessage: 'Could not copy the code.',
    }));
  }

  const pre = document.createElement('pre');
  pre.className = 'snapscreen-code';
  const code = document.createElement('code');
  code.textContent = segment.code;
  pre.append(code);

  block.append(header, pre);
  return block;
}

function createCopyButton(text: string, config: CopyButtonConfig): HTMLButtonElement {
  const btn = document.createElement('button');
  btn.type = 'button';
  btn.className = config.className;
  btn.setAttribute('aria-label', config.label);
  btn.title = config.label;
  btn.innerHTML = config.idleHtml;

  btn.addEventListener('click', async () => {
    if (!await copyToClipboard(text, btn)) {
      showErrorToast(config.failureMessage);
      return;
    }

    btn.innerHTML = config.copiedHtml;
    btn.setAttribute('aria-label', 'Copied');
    btn.classList.add('snapscreen-copy-btn-copied');
    setTimeout(() => {
      btn.innerHTML = config.idleHtml;
      btn.setAttribute('aria-label', config.label);
      btn.classList.remove('snapscreen-copy-btn-copied');
    }, 1500);
  });

  return btn;
}

async function copyToClipboard(text: string, returnFocus: HTMLElement): Promise<boolean> {
  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch {
    // The Clipboard API can be unavailable (e.g. insecure contexts, or a host
    // page permissions policy that blocks the injected frame) — fall back.
  }

  const helper = document.createElement('textarea');
  helper.value = text;
  helper.style.position = 'fixed';
  helper.style.opacity = '0';
  try {
    getUiRoot().append(helper);
    helper.select();
    return typeof document.execCommand === 'function'
      && document.execCommand('copy');
  } catch {
    return false;
  } finally {
    helper.remove();
    returnFocus.focus({ preventScroll: true });
  }
}

function createFailedAnswerActions(
  actions: NonNullable<ResultPanelOptions['failedAnswerActions']>,
): HTMLElement {
  const actionRow = document.createElement('div');
  actionRow.className = 'snapscreen-failed-actions';

  const retryButton = document.createElement('button');
  retryButton.type = 'button';
  retryButton.className = 'snapscreen-failed-action';
  retryButton.addEventListener('click', actions.onRetry);
  actionRow.append(retryButton);

  if (!actions.onRemove) {
    // A first answer has no question to retry; it answers the capture again.
    retryButton.textContent = 'Try again';
    return actionRow;
  }

  retryButton.textContent = 'Retry';
  retryButton.setAttribute('aria-label', 'Retry failed question');

  const removeButton = document.createElement('button');
  removeButton.type = 'button';
  removeButton.className = 'snapscreen-failed-action snapscreen-failed-action-remove';
  removeButton.textContent = 'Remove';
  removeButton.setAttribute('aria-label', 'Remove failed question and response');
  removeButton.addEventListener('click', actions.onRemove);

  actionRow.append(removeButton);
  return actionRow;
}

function appendError(
  body: HTMLElement,
  message: string,
  errorCode?: string,
  onRetry?: () => void,
  onOpenSettings?: () => void,
): HTMLButtonElement | null {
  const err = document.createElement('div');
  err.className = 'snapscreen-error';
  err.setAttribute('role', 'alert');
  err.textContent = message;
  const actions: HTMLButtonElement[] = [];

  if (errorCode === 'no_api_key') {
    actions.push(createErrorAction('Open Settings', 'primary', () => {
      if (onOpenSettings) {
        onOpenSettings();
      } else {
        void chrome.runtime.openOptionsPage();
      }
    }));
  }
  // After saving a key, Try again answers the same capture without a new snip.
  if (onRetry && errorCode !== 'refusal') {
    actions.push(createErrorAction(
      'Try again',
      actions.length === 0 ? 'primary' : 'secondary',
      onRetry,
    ));
  }

  if (actions.length > 0) {
    const actionRow = document.createElement('div');
    actionRow.className = 'snapscreen-error-actions';
    actionRow.append(...actions);
    err.append(actionRow);
  }

  body.append(err);
  return actions[0] ?? null;
}

function createErrorAction(
  label: string,
  variant: 'primary' | 'secondary',
  onClick: () => void,
): HTMLButtonElement {
  const btn = document.createElement('button');
  btn.type = 'button';
  btn.className = `snapscreen-btn snapscreen-btn-${variant}`;
  btn.textContent = label;
  btn.addEventListener('click', onClick);
  return btn;
}

function resetPanelCursor(): void {
  draggingPanel?.classList.remove('snapscreen-panel-dragging');
  draggingPanel = null;
}

export function disposeResultPanel(): void {
  panelEscapePressed = false;
  cancelPanelFrames();
  panelPosition = null;
  panelPositioningAbort?.abort();
  panelPositioningAbort = null;
  panelDragAbort?.abort();
  panelDragAbort = null;
  closeScreenshotLightbox(false);
  if (toastTimeout !== null) {
    clearTimeout(toastTimeout);
    toastTimeout = null;
  }
  resetPanelCursor();
  queryUiElement(`#${PANEL_ID}`)?.remove();
  queryUiElement(`#${BACKDROP_ID}`)?.remove();
  queryUiElement(`#${LIGHTBOX_ID}`)?.remove();
  queryUiElement(`#${TOAST_ID}`)?.remove();
  removeUiHostIfEmpty();

}

function closePanel(onClose: () => void): void {
  disposeResultPanel();
  onClose();
}

function getFocusableElements(container: HTMLElement): HTMLElement[] {
  return Array.from(
    container.querySelectorAll<HTMLElement>(
      'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])',
    ),
  ).filter((el) => !el.hasAttribute('disabled') && el.tabIndex !== -1);
}

function trapFocus(container: HTMLElement, event: KeyboardEvent): void {
  if (event.key !== 'Tab') return;

  const focusable = getFocusableElements(container);
  if (focusable.length === 0) return;

  if (focusable.length === 1) {
    event.preventDefault();
    focusable[0].focus();
    return;
  }

  const first = focusable[0];
  const last = focusable[focusable.length - 1];
  const root = container.getRootNode();
  const active = root instanceof ShadowRoot
    ? root.activeElement as HTMLElement | null
    : document.activeElement as HTMLElement | null;

  if (event.shiftKey) {
    if (active === first || !container.contains(active)) {
      event.preventDefault();
      last.focus();
    }
    return;
  }

  if (active === last || !container.contains(active)) {
    event.preventDefault();
    first.focus();
  }
}

function closeScreenshotLightbox(restoreFocus = true): void {
  lightboxAbort?.abort();
  lightboxAbort = null;

  const lightbox = queryUiElement(`#${LIGHTBOX_ID}`);
  lightbox?.remove();
  if (lightboxBackgroundPanel) {
    lightboxBackgroundPanel.inert = false;
    if (lightboxBackgroundAriaHidden === null) {
      lightboxBackgroundPanel.removeAttribute('aria-hidden');
    } else {
      lightboxBackgroundPanel.setAttribute(
        'aria-hidden',
        lightboxBackgroundAriaHidden,
      );
    }
  }
  lightboxBackgroundPanel = null;
  lightboxBackgroundAriaHidden = null;
  removeUiHostIfEmpty();

  const returnFocus = lightboxReturnFocus;
  lightboxReturnFocus = null;
  if (restoreFocus) {
    returnFocus?.focus();
  }
}

function openScreenshotLightbox(dataUrl: string, returnFocusEl: HTMLElement): void {
  closeScreenshotLightbox();

  const lightbox = document.createElement('div');
  lightbox.id = LIGHTBOX_ID;
  lightbox.className = 'snapscreen-lightbox';
  lightbox.setAttribute('role', 'dialog');
  lightbox.setAttribute('aria-modal', 'true');
  lightbox.setAttribute('aria-label', 'Full-size screenshot');

  const backdrop = document.createElement('div');
  backdrop.className = 'snapscreen-lightbox-backdrop';

  const dialog = document.createElement('div');
  dialog.className = 'snapscreen-lightbox-dialog';
  dialog.tabIndex = -1;

  const closeBtn = document.createElement('button');
  closeBtn.type = 'button';
  closeBtn.className = 'snapscreen-lightbox-close';
  closeBtn.setAttribute('aria-label', 'Close');
  closeBtn.innerHTML = CLOSE_ICON_SVG;

  const img = document.createElement('img');
  img.className = 'snapscreen-lightbox-image';
  img.src = dataUrl;
  img.alt = 'Captured region screenshot';
  img.draggable = false;

  dialog.append(closeBtn, img);
  lightbox.append(backdrop, dialog);
  getUiRoot().append(lightbox);

  const panel = queryUiElement<HTMLElement>(`#${PANEL_ID}`);
  if (panel) {
    lightboxBackgroundPanel = panel;
    lightboxBackgroundAriaHidden = panel.getAttribute('aria-hidden');
    panel.inert = true;
    panel.setAttribute('aria-hidden', 'true');
  }

  lightboxReturnFocus = returnFocusEl;

  const abort = new AbortController();
  lightboxAbort = abort;
  const { signal } = abort;

  const close = () => closeScreenshotLightbox();
  let escapePressed = false;

  closeBtn.addEventListener('click', close, { signal });
  backdrop.addEventListener('click', close, { signal });
  lightbox.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation();
      escapePressed = true;
      return;
    }
    trapFocus(lightbox, event);
  }, { signal });
  lightbox.addEventListener('keyup', (event) => {
    if (event.key !== 'Escape') return;
    event.preventDefault();
    event.stopPropagation();
    if (!escapePressed) return;
    escapePressed = false;
    close();
  }, { signal });

  closeBtn.focus();
}

function getViewport(): { width: number; height: number } {
  return {
    width: window.innerWidth,
    height: window.innerHeight,
  };
}

function getPanelSize(panel: HTMLElement): { width: number; height: number } {
  const rect = panel.getBoundingClientRect();
  if (rect.width > 0 && rect.height > 0) {
    return { width: rect.width, height: rect.height };
  }

  return {
    width: panel.offsetWidth,
    height: panel.offsetHeight,
  };
}

function applyPanelPosition(panel: HTMLElement, top: number, left: number): void {
  const size = getPanelSize(panel);
  const clamped = clampToViewport({ top, left }, size, getViewport(), MARGIN);

  panel.style.top = `${clamped.top}px`;
  panel.style.left = `${clamped.left}px`;
  panel.style.right = 'auto';
  panel.style.bottom = 'auto';
  panelPosition = clamped;
}

function ensurePanelInViewport(
  panel: HTMLElement,
  preferred?: { top: number; left: number },
  retry = 0,
): void {
  const size = getPanelSize(panel);
  if ((size.width === 0 || size.height === 0) && retry < 2) {
    schedulePanelFrame(() => ensurePanelInViewport(panel, preferred, retry + 1));
    return;
  }

  const current = preferred ?? panelPosition ?? {
    top: panel.getBoundingClientRect().top,
    left: panel.getBoundingClientRect().left,
  };

  applyPanelPosition(panel, current.top, current.left);
}

function getPreferredPanelPosition(anchorRect?: Rect): { top: number; left: number } {
  if (panelPosition) {
    return panelPosition;
  }

  let top = MARGIN;
  let left = MARGIN;

  if (anchorRect) {
    left = anchorRect.x + anchorRect.width + MARGIN;
    top = anchorRect.y;
  }

  return { top, left };
}

function setupPanelPositioningListeners(
  panel: HTMLElement,
  panelImage: HTMLImageElement | null,
  onClose: () => void,
): void {
  panelPositioningAbort?.abort();
  const abort = new AbortController();
  panelPositioningAbort = abort;
  const { signal } = abort;

  const reclamp = () => ensurePanelInViewport(panel);

  window.addEventListener('resize', reclamp, { signal });

  panel.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation();
      // Closing on keydown can remove the iframe before the key is released,
      // sending that keyup to the host page instead of this isolated UI.
      panelEscapePressed = true;
      return;
    }
    trapFocus(panel, event);
  }, { signal });
  panel.addEventListener('keyup', (event) => {
    if (event.key !== 'Escape') return;
    event.preventDefault();
    event.stopPropagation();
    if (!panelEscapePressed) return;
    panelEscapePressed = false;
    closePanel(onClose);
  }, { signal });

  const resizeObserver = new ResizeObserver(reclamp);
  resizeObserver.observe(panel);
  signal.addEventListener('abort', () => resizeObserver.disconnect());

  if (panelImage) {
    if (panelImage.complete) {
      schedulePanelFrame(reclamp);
    } else {
      panelImage.addEventListener('load', reclamp, { signal });
      panelImage.addEventListener('error', reclamp, { signal });
    }
  }
}

function setupDrag(dragHandle: HTMLElement, panel: HTMLElement): void {
  panelDragAbort?.abort();
  const abort = new AbortController();
  panelDragAbort = abort;

  dragHandle.addEventListener('pointerdown', (e) => {
    if (e.button !== 0) return;

    e.preventDefault();
    dragHandle.setPointerCapture(e.pointerId);

    const rect = panel.getBoundingClientRect();
    const offsetX = e.clientX - rect.left;
    const offsetY = e.clientY - rect.top;
    draggingPanel = panel;
    panel.classList.add('snapscreen-panel-dragging');

    function onMove(ev: PointerEvent): void {
      applyPanelPosition(panel, ev.clientY - offsetY, ev.clientX - offsetX);
    }

    function onUp(ev: PointerEvent): void {
      if (dragHandle.hasPointerCapture(ev.pointerId)) {
        dragHandle.releasePointerCapture(ev.pointerId);
      }
      resetPanelCursor();
      dragHandle.removeEventListener('pointermove', onMove);
      dragHandle.removeEventListener('pointerup', onUp);
      dragHandle.removeEventListener('pointercancel', onUp);
    }

    dragHandle.addEventListener('pointermove', onMove, { signal: abort.signal });
    dragHandle.addEventListener('pointerup', onUp, { signal: abort.signal });
    dragHandle.addEventListener('pointercancel', onUp, { signal: abort.signal });
    onMove(e);
  }, { signal: abort.signal });
}

function positionPanel(panel: HTMLElement, anchorRect?: Rect): void {
  panel.style.position = 'fixed';
  panel.style.zIndex = '2147483647';
  panel.style.right = 'auto';
  panel.style.bottom = 'auto';

  const preferred = getPreferredPanelPosition(anchorRect);
  applyPanelPosition(panel, preferred.top, preferred.left);
  schedulePanelFrame(() => ensurePanelInViewport(panel, preferred));
}

export function updateStreamingAnswer(text: string): void {
  const root = queryUiElement(`#${PANEL_ID}`);
  const body = root?.querySelector('.snapscreen-panel-body');
  if (!body) return;
  // Follow new text only while the reader is at the end, so one who scrolled
  // up to read stays put.
  const followsEnd = isScrolledToEnd(body);

  let thread = body.querySelector('.snapscreen-chat-thread');
  if (!thread) {
    thread = document.createElement('div');
    thread.className = 'snapscreen-chat-thread';
    body.prepend(thread);
  }

  let bubble = thread.querySelector('.snapscreen-msg-streaming');
  if (!bubble) {
    bubble = document.createElement('div');
    bubble.className = 'snapscreen-msg snapscreen-msg-assistant snapscreen-msg-streaming';
    thread.append(bubble);
  }

  if (renderAnswerContent(bubble, text, false)) {
    root?.classList.add('snapscreen-panel-has-code');
  }
  if (followsEnd) body.scrollTop = body.scrollHeight;
}

export function showErrorToast(message: string): void {
  if (toastTimeout !== null) {
    clearTimeout(toastTimeout);
  }
  queryUiElement(`#${TOAST_ID}`)?.remove();

  const toast = document.createElement('div');
  toast.id = TOAST_ID;
  toast.className = 'snapscreen-toast';
  toast.setAttribute('role', 'alert');
  toast.setAttribute('aria-live', 'assertive');
  toast.textContent = message;
  getUiRoot().append(toast);

  toastTimeout = setTimeout(() => {
    toast.remove();
    toastTimeout = null;
    removeUiHostIfEmpty();
  }, 4000);
}
