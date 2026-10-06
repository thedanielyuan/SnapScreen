// @vitest-environment happy-dom

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { initializeOptionsPage } from './options';

const OPTIONS_MARKUP = `
  <form id="settings-form">
    <input type="password" id="api-key" />
    <button type="button" id="toggle-key">Show</button>
    <button type="button" id="test-key">Test key</button>
    <button type="button" id="remove-key" disabled>Remove key</button>
    <textarea id="default-prompt"></textarea>
    <select id="interface-mode">
      <option value="extension">In Chrome</option>
      <option value="native">macOS companion</option>
    </select>
    <button type="button" id="check-companion">Check companion</button>
    <p id="companion-status" role="status" aria-live="polite">Companion availability has not been checked.</p>
    <details id="advanced-settings">
      <summary>Advanced</summary>
      <input id="max-input-characters" type="number" />
      <input id="max-screenshot-megabytes" type="number" />
      <input id="max-screenshot-dimension" type="number" />
      <input id="max-conversation-turns" type="number" />
    </details>
    <button type="submit" id="save-settings">Save</button>
    <span id="status" role="status" aria-live="polite" hidden></span>
  </form>
  <span id="shortcut-display"></span>
  <button type="button" id="open-shortcuts">Open shortcuts</button>
`;

let setSettings: ReturnType<typeof vi.fn>;
let removeSetting: ReturnType<typeof vi.fn>;
let getStoredSettings: ReturnType<typeof vi.fn>;

beforeEach(() => {
  document.body.innerHTML = OPTIONS_MARKUP;
  setSettings = vi.fn().mockResolvedValue(undefined);
  removeSetting = vi.fn().mockResolvedValue(undefined);
  getStoredSettings = vi.fn().mockResolvedValue({
    apiKey: 'sk-ant-stored',
    defaultPrompt: 'Old prompt',
  });
  vi.stubGlobal('chrome', {
    runtime: {
      getPlatformInfo: vi.fn().mockResolvedValue({ os: 'mac' }),
      connectNative: vi.fn(),
    },
    storage: {
      local: {
        get: getStoredSettings,
        set: setSettings,
        remove: removeSetting,
      },
    },
    commands: {
      getAll: vi.fn().mockResolvedValue([
        { name: 'snip', shortcut: 'Alt+Shift+S' },
      ]),
    },
    tabs: { create: vi.fn().mockResolvedValue(undefined) },
  });
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe('options API-key controls', () => {
  it('loads settings even when the shortcut query fails', async () => {
    vi.mocked(chrome.commands.getAll).mockRejectedValue(new Error('unavailable'));

    await initializeOptionsPage(document);

    expect((document.getElementById('api-key') as HTMLInputElement).value).toBe(
      'sk-ant-stored',
    );
    expect((document.getElementById('default-prompt') as HTMLTextAreaElement).value)
      .toBe('Old prompt');
    expect((document.getElementById('remove-key') as HTMLButtonElement).disabled)
      .toBe(false);
    expect(document.getElementById('shortcut-display')?.textContent).toBe(
      'no shortcut set',
    );
  });

  it('blocks edits and state-changing actions until settings hydration finishes', async () => {
    let resolveSettings!: (value: Record<string, string>) => void;
    getStoredSettings.mockReturnValue(
      new Promise((resolve) => {
        resolveSettings = resolve;
      }),
    );
    const fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);

    const initialization = initializeOptionsPage(document);
    const form = document.getElementById('settings-form')!;
    const apiKey = document.getElementById('api-key') as HTMLInputElement;
    const prompt = document.getElementById('default-prompt') as HTMLTextAreaElement;
    const interfaceMode = document.getElementById('interface-mode') as HTMLSelectElement;
    const limit = document.getElementById('max-input-characters') as HTMLInputElement;
    const saveButton = document.getElementById('save-settings') as HTMLButtonElement;
    const testButton = document.getElementById('test-key') as HTMLButtonElement;
    const toggleButton = document.getElementById('toggle-key') as HTMLButtonElement;
    const removeButton = document.getElementById('remove-key') as HTMLButtonElement;

    expect(apiKey.disabled).toBe(true);
    expect(prompt.disabled).toBe(true);
    expect(interfaceMode.disabled).toBe(true);
    expect(limit.disabled).toBe(true);
    expect(saveButton.disabled).toBe(true);
    expect(testButton.disabled).toBe(true);
    expect(toggleButton.disabled).toBe(true);
    expect(removeButton.disabled).toBe(true);
    form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
    testButton.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    toggleButton.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    removeButton.dispatchEvent(new MouseEvent('click', { bubbles: true }));

    expect(setSettings).not.toHaveBeenCalled();
    expect(fetchMock).not.toHaveBeenCalled();
    expect(removeSetting).not.toHaveBeenCalled();
    expect(apiKey.type).toBe('password');

    resolveSettings({ apiKey: 'sk-ant-stored', defaultPrompt: 'Old prompt' });
    await initialization;

    expect(apiKey.value).toBe('sk-ant-stored');
    expect(prompt.value).toBe('Old prompt');
    expect(apiKey.disabled).toBe(false);
    expect(prompt.disabled).toBe(false);
    expect(interfaceMode.disabled).toBe(false);
    expect(limit.disabled).toBe(false);
    expect(saveButton.disabled).toBe(false);
    expect(testButton.disabled).toBe(false);
    expect(toggleButton.disabled).toBe(false);
    expect(removeButton.disabled).toBe(false);
  });

  it('saves the prompt without silently deleting a blanked API key', async () => {
    await initializeOptionsPage(document);
    const apiKey = document.getElementById('api-key') as HTMLInputElement;
    const prompt = document.getElementById(
      'default-prompt',
    ) as HTMLTextAreaElement;
    apiKey.value = '';
    prompt.value = 'New prompt';

    document.getElementById('settings-form')!.dispatchEvent(
      new Event('submit', { bubbles: true, cancelable: true }),
    );

    await vi.waitFor(() => {
      expect(setSettings).toHaveBeenCalledWith({
        defaultPrompt: 'New prompt',
        interfaceMode: 'extension',
        limits: {
          maxInputCharacters: 4_000,
          maxScreenshotBytes: 5_000_000,
          maxScreenshotDimension: 2_576,
          maxConversationTurns: 12,
        },
      });
      expect(document.getElementById('status')?.textContent).toBe(
        'Settings saved. Existing API key unchanged.',
      );
    });
    expect(removeSetting).not.toHaveBeenCalled();
  });

  it('loads and saves an explicit native preference without launching a host', async () => {
    const connectNative = vi.fn();
    vi.stubGlobal('chrome', { ...chrome, runtime: { connectNative } });
    getStoredSettings.mockResolvedValue({
      apiKey: 'sk-ant-stored',
      defaultPrompt: 'Old prompt',
      interfaceMode: 'native',
    });
    await initializeOptionsPage(document);
    const interfaceMode = document.getElementById('interface-mode') as HTMLSelectElement;
    expect(interfaceMode.value).toBe('native');

    interfaceMode.value = 'extension';
    document.getElementById('settings-form')!.dispatchEvent(
      new Event('submit', { bubbles: true, cancelable: true }),
    );

    await vi.waitFor(() => {
      expect(setSettings).toHaveBeenCalledWith(expect.objectContaining({
        interfaceMode: 'extension',
      }));
    });
    expect(connectNative).not.toHaveBeenCalled();
    expect(chrome.tabs.create).not.toHaveBeenCalled();
  });

  it('keeps availability checks explicit and reports unsupported platforms without changing mode', async () => {
    vi.mocked(chrome.runtime.getPlatformInfo).mockImplementation(() => Promise.resolve({
      os: 'linux', arch: 'x86-64', nacl_arch: 'x86-64',
    }));
    await initializeOptionsPage(document);
    const interfaceMode = document.getElementById('interface-mode') as HTMLSelectElement;
    const checkButton = document.getElementById('check-companion') as HTMLButtonElement;
    interfaceMode.value = 'native';
    interfaceMode.dispatchEvent(new Event('change'));
    expect(chrome.runtime.getPlatformInfo).not.toHaveBeenCalled();
    expect(chrome.runtime.connectNative).not.toHaveBeenCalled();

    checkButton.click();
    expect(checkButton.disabled).toBe(true);
    expect(document.getElementById('companion-status')?.textContent).toBe('Checking companion…');
    await vi.waitFor(() => {
      expect(checkButton.disabled).toBe(false);
      expect(document.getElementById('companion-status')?.textContent).toContain('only on macOS');
    });
    expect(interfaceMode.value).toBe('native');
    expect(chrome.runtime.connectNative).not.toHaveBeenCalled();
    expect(setSettings).not.toHaveBeenCalled();
    expect(chrome.tabs.create).not.toHaveBeenCalled();
  });

  it('allows one explicit check at a time and keeps its failure separate from API-key status', async () => {
    let resolvePlatform!: (platform: chrome.runtime.PlatformInfo) => void;
    vi.mocked(chrome.runtime.getPlatformInfo).mockImplementation(() => new Promise((resolve) => { resolvePlatform = resolve; }));
    vi.mocked(chrome.runtime.connectNative).mockImplementation(() => { throw new Error('sk-ant-sensitive'); });
    await initializeOptionsPage(document);
    const checkButton = document.getElementById('check-companion') as HTMLButtonElement;
    const status = document.getElementById('status')!;
    status.textContent = 'API key works.';

    checkButton.click();
    checkButton.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    expect(chrome.runtime.getPlatformInfo).toHaveBeenCalledTimes(1);
    resolvePlatform({ os: 'mac', arch: 'arm64', nacl_arch: 'arm' });
    await vi.waitFor(() => {
      expect(checkButton.disabled).toBe(false);
      expect(document.getElementById('companion-status')?.textContent).toContain('Could not check the companion');
    });
    expect(status.textContent).toBe('API key works.');
    expect(document.body.textContent).not.toContain('sk-ant-sensitive');
    expect(setSettings).not.toHaveBeenCalled();
    expect(chrome.tabs.create).not.toHaveBeenCalled();
  });

  it('loads and saves configurable request limits', async () => {
    getStoredSettings.mockResolvedValue({
      apiKey: 'sk-ant-stored',
      defaultPrompt: 'Old prompt',
      limits: {
        maxInputCharacters: 2_000,
        maxScreenshotBytes: 7_000_000,
        maxScreenshotDimension: 4_096,
        maxConversationTurns: 8,
      },
    });
    await initializeOptionsPage(document);

    expect((document.getElementById('max-screenshot-megabytes') as HTMLInputElement).value)
      .toBe('7');
    (document.getElementById('max-conversation-turns') as HTMLInputElement).value = '9';
    document.getElementById('settings-form')!.dispatchEvent(
      new Event('submit', { bubbles: true, cancelable: true }),
    );

    await vi.waitFor(() => {
      expect(setSettings).toHaveBeenCalledWith(expect.objectContaining({
        limits: {
          maxInputCharacters: 2_000,
          maxScreenshotBytes: 7_000_000,
          maxScreenshotDimension: 4_096,
          maxConversationTurns: 9,
        },
      }));
    });
  });

  it('rejects out-of-range limits without silently clamping the form', async () => {
    await initializeOptionsPage(document);
    const turns = document.getElementById('max-conversation-turns') as HTMLInputElement;
    turns.value = '1';

    document.getElementById('settings-form')!.dispatchEvent(
      new Event('submit', { bubbles: true, cancelable: true }),
    );

    expect(setSettings).not.toHaveBeenCalled();
    expect(document.getElementById('status')?.textContent).toContain('2 to 50');
    expect(document.getElementById('status')?.getAttribute('role')).toBe('alert');
    expect(document.getElementById('status')?.getAttribute('aria-live')).toBe('assertive');
    expect(document.activeElement).toBe(turns);
  });

  it('opens the collapsed Advanced section to show an invalid limit', async () => {
    await initializeOptionsPage(document);
    const advanced = document.getElementById('advanced-settings') as HTMLDetailsElement;
    const turns = document.getElementById('max-conversation-turns') as HTMLInputElement;
    expect(advanced.open).toBe(false);

    // Chrome's own form validation fires this before it tries to focus the field.
    turns.dispatchEvent(new Event('invalid', { cancelable: true }));
    expect(advanced.open).toBe(true);

    advanced.open = false;
    turns.value = '1';
    document.getElementById('settings-form')!.dispatchEvent(
      new Event('submit', { bubbles: true, cancelable: true }),
    );
    expect(advanced.open).toBe(true);
    expect(document.activeElement).toBe(turns);
  });

  it('keeps an over-limit prompt intact and reports the configured boundary', async () => {
    await initializeOptionsPage(document);
    const maxInput = document.getElementById('max-input-characters') as HTMLInputElement;
    const prompt = document.getElementById('default-prompt') as HTMLTextAreaElement;
    maxInput.value = '100';
    prompt.value = 'x'.repeat(101);

    document.getElementById('settings-form')!.dispatchEvent(
      new Event('submit', { bubbles: true, cancelable: true }),
    );

    expect(setSettings).not.toHaveBeenCalled();
    expect(prompt.value).toHaveLength(101);
    expect(document.getElementById('status')?.textContent).toContain('100 character');
  });

  it('explicitly removes the stored key and resets its controls', async () => {
    await initializeOptionsPage(document);
    const removeButton = document.getElementById(
      'remove-key',
    ) as HTMLButtonElement;
    const apiKey = document.getElementById('api-key') as HTMLInputElement;
    const toggle = document.getElementById('toggle-key') as HTMLButtonElement;
    toggle.click();

    removeButton.click();

    await vi.waitFor(() => {
      expect(removeSetting).toHaveBeenCalledWith('apiKey');
      expect(apiKey.value).toBe('');
    });
    expect(apiKey.type).toBe('password');
    expect(toggle.getAttribute('aria-pressed')).toBe('false');
    expect(removeButton.disabled).toBe(true);
    expect(document.getElementById('status')?.textContent).toBe(
      'API key removed.',
    );
  });

  it('prevents saving the old key while removal is in progress', async () => {
    let resolveRemoval!: () => void;
    removeSetting.mockReturnValue(
      new Promise<void>((resolve) => {
        resolveRemoval = resolve;
      }),
    );
    await initializeOptionsPage(document);

    const removeButton = document.getElementById('remove-key') as HTMLButtonElement;
    const saveButton = document.getElementById('save-settings') as HTMLButtonElement;
    const testButton = document.getElementById('test-key') as HTMLButtonElement;
    const toggleButton = document.getElementById('toggle-key') as HTMLButtonElement;
    removeButton.click();

    expect(saveButton.disabled).toBe(true);
    expect(testButton.disabled).toBe(true);
    expect(toggleButton.disabled).toBe(true);
    document.getElementById('settings-form')!.dispatchEvent(
      new Event('submit', { bubbles: true, cancelable: true }),
    );
    expect(setSettings).not.toHaveBeenCalled();

    resolveRemoval();
    await vi.waitFor(() => expect(saveButton.disabled).toBe(false));
    expect(removeButton.disabled).toBe(true);
    expect(testButton.disabled).toBe(false);
    expect(toggleButton.disabled).toBe(false);
  });

  it('waits for an in-flight save before removing the key', async () => {
    let resolveSave!: () => void;
    setSettings.mockReturnValue(
      new Promise<void>((resolve) => {
        resolveSave = resolve;
      }),
    );
    await initializeOptionsPage(document);

    document.getElementById('settings-form')!.dispatchEvent(
      new Event('submit', { bubbles: true, cancelable: true }),
    );
    (document.getElementById('remove-key') as HTMLButtonElement).click();
    await Promise.resolve();
    expect(removeSetting).not.toHaveBeenCalled();

    resolveSave();
    await vi.waitFor(() => expect(removeSetting).toHaveBeenCalledWith('apiKey'));
    expect(document.getElementById('status')?.textContent).toBe('API key removed.');
  });

  it('ignores duplicate submissions while a save is in progress', async () => {
    let resolveSave!: () => void;
    setSettings.mockReturnValue(
      new Promise<void>((resolve) => {
        resolveSave = resolve;
      }),
    );
    await initializeOptionsPage(document);
    const form = document.getElementById('settings-form')!;

    form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
    form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));

    expect(setSettings).toHaveBeenCalledTimes(1);
    resolveSave();
    await vi.waitFor(() => {
      expect((document.getElementById('save-settings') as HTMLButtonElement).disabled)
        .toBe(false);
    });
  });

  it('ignores a stale API-key test result after removal starts', async () => {
    let resolveVerification!: (response: Response) => void;
    vi.stubGlobal(
      'fetch',
      vi.fn(
        () => new Promise<Response>((resolve) => {
          resolveVerification = resolve;
        }),
      ),
    );
    await initializeOptionsPage(document);

    const testButton = document.getElementById('test-key') as HTMLButtonElement;
    const removeButton = document.getElementById('remove-key') as HTMLButtonElement;
    testButton.click();
    removeButton.click();
    await vi.waitFor(() => {
      expect(document.getElementById('status')?.textContent).toBe('API key removed.');
    });
    expect(testButton.disabled).toBe(true);

    resolveVerification(new Response('{}', { status: 200 }));
    await vi.waitFor(() => expect(testButton.disabled).toBe(false));
    expect(document.getElementById('status')?.textContent).toBe('API key removed.');
  });
});
