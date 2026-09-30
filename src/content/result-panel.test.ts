// @vitest-environment happy-dom

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  disposeResultPanel,
  showErrorToast,
  showResultPanel,
  updateStreamingAnswer,
} from './result-panel';
import type { ResultPanelOptions } from './result-panel';
import {
  disposeUiRootForTesting,
  getUiHostForTesting,
  getUiRootForTesting,
} from './ui-root';

function options(
  overrides: Partial<ResultPanelOptions> = {},
): ResultPanelOptions {
  return {
    onClose: vi.fn(),
    onFollowUp: vi.fn(),
    ...overrides,
  };
}

function uiQuery<T extends Element = HTMLElement>(selector: string): T | null {
  return getUiRootForTesting()?.querySelector<T>(selector) ?? null;
}

function uiQueryAll(selector: string): Element[] {
  return Array.from(getUiRootForTesting()?.querySelectorAll(selector) ?? []);
}

async function flushAsyncListener(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
}

beforeEach(() => {
  document.body.innerHTML = '';
  document.documentElement.className = '';
  document.documentElement.style.cursor = '';
  document.body.style.cursor = '';
  vi.stubGlobal('chrome', {
    runtime: {
      getURL: (path: string) => `chrome-extension://test/${path}`,
      openOptionsPage: vi.fn(),
    },
  });
});

afterEach(() => {
  disposeResultPanel();
  disposeUiRootForTesting();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe('result panel isolation and focus', () => {
  it('never renders automatic screenshot guidance during loading, streaming, or completion', () => {
    const hiddenPrompt = 'What does this show? Answer accurately and concisely.';

    showResultPanel(options({ messages: [], pending: true, onStop: vi.fn() }));
    expect(getUiRootForTesting()?.textContent).not.toContain(hiddenPrompt);
    expect(uiQueryAll('.snapscreen-msg')).toHaveLength(0);

    updateStreamingAnswer('The screenshot shows a calendar.');
    expect(uiQueryAll('.snapscreen-msg-user')).toHaveLength(0);
    expect(uiQuery('.snapscreen-msg-streaming')?.textContent).toBe(
      'The screenshot shows a calendar.',
    );
    expect(getUiRootForTesting()?.textContent).not.toContain(hiddenPrompt);

    showResultPanel(options({
      messages: [{ role: 'assistant', content: 'The screenshot shows a calendar.' }],
    }));
    expect(uiQueryAll('.snapscreen-msg')).toHaveLength(1);
    expect(uiQueryAll('.snapscreen-msg-user')).toHaveLength(0);
    expect(getUiRootForTesting()?.textContent).not.toContain(hiddenPrompt);
  });

  it('keeps sensitive UI in a closed shadow root', () => {
    showResultPanel(
      options({
        dataUrl: 'data:image/png;base64,AA==',
        messages: [{ role: 'assistant', content: 'Private answer' }],
      }),
    );

    const host = getUiHostForTesting();
    expect(host?.id).toBe('snapscreen-ui-host');
    expect(host?.shadowRoot).toBeNull();
    expect(document.querySelector('.snapscreen-panel')).toBeNull();
    expect(document.querySelector('.snapscreen-panel-image')).toBeNull();
    expect(document.body.textContent).not.toContain('Private answer');
    expect(uiQuery('.snapscreen-panel')).not.toBeNull();
  });

  it('focuses the composer when idle', () => {
    showResultPanel(options());

    expect(getUiRootForTesting()?.activeElement).toBe(
      uiQuery('.snapscreen-input'),
    );
  });

  it('focuses Stop while generation is pending', () => {
    showResultPanel(options({ pending: true, onStop: vi.fn() }));

    expect(getUiRootForTesting()?.activeElement).toBe(
      uiQuery('.snapscreen-send-btn-stop'),
    );
  });

  it('focuses the recovery action after a fatal error rerender', () => {
    showResultPanel(options());
    showResultPanel(
      options({ error: 'Network failed.', onRetry: vi.fn() }),
    );

    const retry = uiQuery<HTMLButtonElement>(
      '.snapscreen-error .snapscreen-btn-primary',
    );
    expect(retry?.textContent).toBe('Try again');
    expect(getUiRootForTesting()?.activeElement).toBe(retry);
  });

  it('proxies the Settings action when the UI runs in a privileged frame', () => {
    const onOpenSettings = vi.fn();
    showResultPanel(options({
      error: 'No API key configured.',
      errorCode: 'no_api_key',
      onOpenSettings,
    }));

    uiQuery<HTMLButtonElement>('.snapscreen-btn-primary')!.click();

    expect(onOpenSettings).toHaveBeenCalledTimes(1);
    expect(chrome.runtime.openOptionsPage).not.toHaveBeenCalled();
  });

  it('focuses Close when a fatal error has no recovery action', () => {
    showResultPanel(
      options({ error: 'Request refused.', errorCode: 'refusal' }),
    );

    expect(getUiRootForTesting()?.activeElement).toBe(
      uiQuery('.snapscreen-close-btn[aria-label="Close"]'),
    );
  });

  it('keeps focus inside the panel until its Escape press is released', () => {
    const onClose = vi.fn();
    showResultPanel(options({ onClose }));

    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
    window.dispatchEvent(new KeyboardEvent('keyup', { key: 'Escape' }));
    expect(onClose).not.toHaveBeenCalled();

    const composer = uiQuery<HTMLTextAreaElement>('.snapscreen-input')!;
    composer.dispatchEvent(
      new KeyboardEvent('keyup', { bubbles: true, key: 'Escape' }),
    );
    expect(onClose).not.toHaveBeenCalled();

    for (const repeat of [false, true]) {
      const event = new KeyboardEvent('keydown', {
        bubbles: true, cancelable: true, key: 'Escape', repeat,
      });
      composer.dispatchEvent(event);
      expect(event.defaultPrevented).toBe(true);
      expect(onClose).not.toHaveBeenCalled();
      expect(getUiRootForTesting()?.activeElement).toBe(composer);
    }

    const release = new KeyboardEvent('keyup', {
      bubbles: true, cancelable: true, key: 'Escape',
    });
    composer.dispatchEvent(release);
    expect(release.defaultPrevented).toBe(true);
    expect(onClose).toHaveBeenCalledTimes(1);
    expect(getUiHostForTesting()).toBeNull();
  });

  it('closes only the screenshot lightbox when Escape is released', () => {
    const onClose = vi.fn();
    showResultPanel(options({ dataUrl: 'data:image/png;base64,AA==', onClose }));
    const imageButton = uiQuery<HTMLButtonElement>('.snapscreen-panel-image-btn')!;
    imageButton.click();
    const closeButton = uiQuery<HTMLButtonElement>('.snapscreen-lightbox-close')!;

    for (const repeat of [false, true]) {
      closeButton.dispatchEvent(new KeyboardEvent('keydown', {
        bubbles: true, key: 'Escape', repeat,
      }));
      expect(uiQuery('.snapscreen-lightbox')).not.toBeNull();
      expect(getUiRootForTesting()?.activeElement).toBe(closeButton);
    }
    closeButton.dispatchEvent(new KeyboardEvent('keyup', {
      bubbles: true, key: 'Escape',
    }));

    expect(uiQuery('.snapscreen-lightbox')).toBeNull();
    expect(uiQuery<HTMLElement>('.snapscreen-panel')?.inert).toBe(false);
    expect(getUiRootForTesting()?.activeElement).toBe(imageButton);
    expect(onClose).not.toHaveBeenCalled();
  });

  it('honors Escape release when a pending answer rerenders the panel', () => {
    const onClose = vi.fn();
    showResultPanel(options({ pending: true, onStop: vi.fn(), onClose }));
    uiQuery('.snapscreen-send-btn-stop')?.dispatchEvent(
      new KeyboardEvent('keydown', { bubbles: true, key: 'Escape' }),
    );

    showResultPanel(options({
      messages: [{ role: 'assistant', content: 'Answer' }], onClose,
    }));
    expect(onClose).not.toHaveBeenCalled();
    uiQuery('.snapscreen-input')?.dispatchEvent(
      new KeyboardEvent('keyup', { bubbles: true, key: 'Escape' }),
    );

    expect(onClose).toHaveBeenCalledTimes(1);
    expect(getUiHostForTesting()).toBeNull();
  });

  it('does not carry an Escape press across panel disposal', () => {
    const onClose = vi.fn();
    showResultPanel(options({ onClose }));
    uiQuery('.snapscreen-input')?.dispatchEvent(
      new KeyboardEvent('keydown', { bubbles: true, key: 'Escape' }),
    );
    disposeResultPanel();
    showResultPanel(options({ onClose }));

    uiQuery('.snapscreen-input')?.dispatchEvent(
      new KeyboardEvent('keyup', { bubbles: true, key: 'Escape' }),
    );

    expect(onClose).not.toHaveBeenCalled();
    expect(uiQuery('.snapscreen-panel')).not.toBeNull();
  });

  it('makes the underlying panel inert while the screenshot lightbox is open', () => {
    showResultPanel(options({ dataUrl: 'data:image/png;base64,AA==' }));
    const panel = uiQuery<HTMLElement>('.snapscreen-panel')!;

    uiQuery<HTMLButtonElement>('.snapscreen-panel-image-btn')!.click();

    expect(panel.inert).toBe(true);
    expect(panel.getAttribute('aria-hidden')).toBe('true');
    uiQuery<HTMLButtonElement>('.snapscreen-lightbox-close')!.click();
    expect(panel.inert).toBe(false);
    expect(panel.hasAttribute('aria-hidden')).toBe(false);
  });
});

describe('copy feedback', () => {
  it('uses the isolated fallback and reports success when execCommand succeeds', async () => {
    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: undefined,
    });
    const execCommand = vi.fn().mockReturnValue(true);
    Object.defineProperty(document, 'execCommand', {
      configurable: true,
      value: execCommand,
    });
    showResultPanel(
      options({ messages: [{ role: 'assistant', content: 'Answer' }] }),
    );
    const copy = uiQuery<HTMLButtonElement>('.snapscreen-copy-btn')!;

    copy.click();
    await flushAsyncListener();

    expect(execCommand).toHaveBeenCalledWith('copy');
    expect(copy.getAttribute('aria-label')).toBe('Copied');
    expect(uiQuery('textarea:not(.snapscreen-input)')).toBeNull();
    expect(document.querySelector('textarea')).toBeNull();
    expect(getUiRootForTesting()?.activeElement).toBe(copy);
  });

  it('reports one failure toast when neither clipboard method succeeds', async () => {
    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: { writeText: vi.fn().mockRejectedValue(new Error('denied')) },
    });
    Object.defineProperty(document, 'execCommand', {
      configurable: true,
      value: vi.fn().mockReturnValue(false),
    });
    showResultPanel(
      options({ messages: [{ role: 'assistant', content: 'Answer' }] }),
    );
    const copy = uiQuery<HTMLButtonElement>('.snapscreen-copy-btn')!;

    copy.click();
    await flushAsyncListener();
    copy.click();
    await flushAsyncListener();

    expect(copy.getAttribute('aria-label')).toBe('Copy answer');
    expect(getUiRootForTesting()?.querySelectorAll('#snapscreen-toast-root'))
      .toHaveLength(1);
    expect(uiQuery('#snapscreen-toast-root')?.textContent).toBe(
      'Could not copy the answer.',
    );
    expect(document.getElementById('snapscreen-toast-root')).toBeNull();
  });
});

describe('follow-up validation and recovery', () => {
  it('retains an over-limit Unicode question and shows inline feedback', () => {
    const onFollowUp = vi.fn();
    showResultPanel(options({ maxInputCharacters: 2, onFollowUp }));
    const textarea = uiQuery<HTMLTextAreaElement>('.snapscreen-input')!;
    textarea.value = '  🙂🙂🙂  ';
    textarea.dispatchEvent(new Event('input', { bubbles: true }));

    textarea.dispatchEvent(
      new KeyboardEvent('keydown', { bubbles: true, key: 'Enter' }),
    );

    expect(onFollowUp).not.toHaveBeenCalled();
    expect(textarea.value).toBe('  🙂🙂🙂  ');
    expect(textarea.maxLength).toBe(-1);
    expect(textarea.getAttribute('aria-invalid')).toBe('true');
    expect(uiQuery('.snapscreen-input-error')?.textContent).toBe(
      'Question is 3 characters. The current limit is 2. '
      + 'Shorten it or raise the limit in Settings.',
    );
  });

  it('submits a shortened question and clears limit feedback', () => {
    const onFollowUp = vi.fn();
    showResultPanel(options({ maxInputCharacters: 2, onFollowUp }));
    const textarea = uiQuery<HTMLTextAreaElement>('.snapscreen-input')!;
    textarea.value = '🙂🙂🙂';
    textarea.dispatchEvent(new Event('input', { bubbles: true }));
    textarea.dispatchEvent(
      new KeyboardEvent('keydown', { bubbles: true, key: 'Enter' }),
    );

    textarea.value = 'OK';
    textarea.dispatchEvent(new Event('input', { bubbles: true }));
    textarea.dispatchEvent(
      new KeyboardEvent('keydown', { bubbles: true, key: 'Enter' }),
    );

    expect(onFollowUp).toHaveBeenCalledWith('OK');
    expect(textarea.value).toBe('');
    expect(uiQuery<HTMLDivElement>('.snapscreen-input-error')?.hidden).toBe(true);
  });

  it('renders accessible actions on only the latest failed response', () => {
    const onRetry = vi.fn();
    const onRemove = vi.fn();
    showResultPanel(
      options({
        messages: [
          { role: 'user', content: 'First question' },
          { role: 'assistant', content: 'First failed', status: 'failed' },
          { role: 'user', content: 'Second question' },
          { role: 'assistant', content: 'Second failed', status: 'failed' },
        ],
        failedFollowUpActions: { onRetry, onRemove },
      }),
    );

    expect(getUiRootForTesting()?.querySelectorAll('.snapscreen-msg-failed'))
      .toHaveLength(2);
    expect(getUiRootForTesting()?.querySelectorAll('.snapscreen-failed-actions'))
      .toHaveLength(1);
    const failed = getUiRootForTesting()?.querySelectorAll('.snapscreen-msg-failed')[1];
    expect(failed?.getAttribute('role')).toBe('alert');
    expect(failed?.getAttribute('aria-label')).toBe(
      'Failed response: Second failed',
    );

    uiQuery<HTMLButtonElement>('[aria-label="Retry failed question"]')!.click();
    uiQuery<HTMLButtonElement>('[aria-label="Remove failed question and response"]')!
      .click();
    expect(onRetry).toHaveBeenCalledTimes(1);
    expect(onRemove).toHaveBeenCalledTimes(1);
    expect(uiQuery<HTMLTextAreaElement>('.snapscreen-input')?.disabled).toBe(false);
  });
});

describe('result UI lifecycle', () => {
  it('replaces an existing toast', () => {
    showErrorToast('First');
    showErrorToast('Second');

    expect(getUiRootForTesting()?.querySelectorAll('#snapscreen-toast-root'))
      .toHaveLength(1);
    expect(uiQuery('#snapscreen-toast-root')?.textContent).toBe('Second');
    expect(uiQuery('#snapscreen-toast-root')?.getAttribute('role')).toBe('alert');
  });

  it('disposes all result UI without invoking content callbacks', () => {
    const onClose = vi.fn();
    showResultPanel(options({ dataUrl: 'data:image/png;base64,AA==', onClose }));
    uiQuery<HTMLButtonElement>('.snapscreen-panel-image-btn')!.click();
    showErrorToast('Error');

    disposeResultPanel();
    disposeResultPanel();

    expect(getUiHostForTesting()).toBeNull();
    expect(document.getElementById('snapscreen-panel-root')).toBeNull();
    expect(document.getElementById('snapscreen-panel-backdrop')).toBeNull();
    expect(document.getElementById('snapscreen-lightbox-root')).toBeNull();
    expect(document.getElementById('snapscreen-toast-root')).toBeNull();
    expect(onClose).not.toHaveBeenCalled();
  });

  it('does not mutate host-page cursor styles', () => {
    document.documentElement.style.cursor = 'wait';
    document.body.style.cursor = 'crosshair';

    showResultPanel(options());
    disposeResultPanel();

    expect(document.documentElement.style.cursor).toBe('wait');
    expect(document.body.style.cursor).toBe('crosshair');
  });
});
