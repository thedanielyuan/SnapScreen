// @vitest-environment happy-dom

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { NATIVE_HOST_NAME, NATIVE_PROTOCOL_VERSION } from '../lib/native-protocol';
import { initializeNativeOptionsPage } from './options-native';
import nativeMarkup from './options-native.html?raw';

let storedSettings: Record<string, unknown>;
let getStoredSettings: ReturnType<typeof vi.fn>;
let setSettings: ReturnType<typeof vi.fn>;
let removeSetting: ReturnType<typeof vi.fn>;

beforeEach(() => {
  // Use the shipped controls without loading CSS in the DOM test environment.
  const page = new DOMParser().parseFromString(nativeMarkup.replace(/<link\b[^>]*>/g, ''), 'text/html');
  page.querySelector('script')?.remove();
  document.body.innerHTML = page.body.innerHTML;
  storedSettings = {
    apiKey: 'sk-ant-stored',
    defaultPrompt: 'Saved prompt',
    interfaceMode: 'extension',
    limits: {
      maxInputCharacters: 2_000,
      maxScreenshotBytes: 3_000_000,
      maxScreenshotDimension: 2_048,
      maxConversationTurns: 8,
    },
  };
  getStoredSettings = vi.fn().mockImplementation((keys: string | string[]) => {
    if (keys === 'interfaceMode') throw new Error('Native Settings must ignore interfaceMode');
    return Promise.resolve(storedSettings);
  });
  setSettings = vi.fn().mockResolvedValue(undefined);
  removeSetting = vi.fn().mockResolvedValue(undefined);
  vi.stubGlobal('chrome', {
    runtime: {
      getPlatformInfo: vi.fn().mockResolvedValue({ os: 'mac' }),
      connectNative: vi.fn(),
    },
    storage: { local: { get: getStoredSettings, set: setSettings, remove: removeSetting } },
    commands: {
      getAll: vi.fn().mockResolvedValue([{ name: 'snip', shortcut: 'Alt+Shift+S' }]),
    },
    tabs: { create: vi.fn().mockResolvedValue(undefined) },
  });
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe('native-only Settings', () => {
  it('loads the bundled page without an interface selector or reading the stale preference', async () => {
    await initializeNativeOptionsPage(document);

    expect(document.getElementById('interface-mode')).toBeNull();
    expect(document.getElementById('companion-section')!.hidden).toBe(false);
    expect((document.getElementById('api-key') as HTMLInputElement).value).toBe('sk-ant-stored');
    expect((document.getElementById('default-prompt') as HTMLTextAreaElement).value).toBe('Saved prompt');
    expect((document.getElementById('max-screenshot-megabytes') as HTMLInputElement).value).toBe('3');
    expect((document.getElementById('save-settings') as HTMLButtonElement).disabled).toBe(false);
    expect(document.getElementById('shortcut-display')?.textContent).toBe('Alt+Shift+S');
    expect(getStoredSettings).toHaveBeenCalledExactlyOnceWith(['apiKey', 'defaultPrompt', 'limits']);
    expect(chrome.runtime.getPlatformInfo).not.toHaveBeenCalled();
    expect(chrome.runtime.connectNative).not.toHaveBeenCalled();
    expect(document.body.textContent).not.toContain('In Chrome');
  });

  it('saves prompt and limits, verifies a replacement key, and removes it without writing an interface mode', async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response('{}', { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);
    await initializeNativeOptionsPage(document);
    const keyInput = document.getElementById('api-key') as HTMLInputElement;
    keyInput.value = 'sk-ant-replacement';
    (document.getElementById('default-prompt') as HTMLTextAreaElement).value = 'New prompt';
    (document.getElementById('max-conversation-turns') as HTMLInputElement).value = '10';

    document.getElementById('settings-form')!.dispatchEvent(
      new Event('submit', { bubbles: true, cancelable: true }),
    );
    await vi.waitFor(() => {
      expect(setSettings).toHaveBeenCalledExactlyOnceWith({
        apiKey: 'sk-ant-replacement',
        defaultPrompt: 'New prompt',
        limits: {
          maxInputCharacters: 2_000,
          maxScreenshotBytes: 3_000_000,
          maxScreenshotDimension: 2_048,
          maxConversationTurns: 10,
        },
      });
      expect(document.getElementById('status')?.textContent).toBe('Settings saved.');
    });

    (document.getElementById('test-key') as HTMLButtonElement).click();
    await vi.waitFor(() => expect(document.getElementById('status')?.textContent).toBe('API key works.'));
    expect(fetchMock).toHaveBeenCalledTimes(1);
    (document.getElementById('toggle-key') as HTMLButtonElement).click();
    expect(keyInput.type).toBe('text');
    (document.getElementById('remove-key') as HTMLButtonElement).click();
    await vi.waitFor(() => expect(document.getElementById('status')?.textContent).toBe('API key removed.'));
    expect(removeSetting).toHaveBeenCalledExactlyOnceWith('apiKey');
    expect(keyInput.value).toBe('');
    expect(keyInput.type).toBe('password');
    expect(chrome.runtime.connectNative).not.toHaveBeenCalled();
  });

  it('checks the companion explicitly without an API key and sends only a handshake', async () => {
    storedSettings.apiKey = '';
    const messageListeners = new Set<(message: unknown) => void>();
    const port = {
      onMessage: {
        addListener: vi.fn((listener: (message: unknown) => void) => messageListeners.add(listener)),
        removeListener: vi.fn((listener: (message: unknown) => void) => messageListeners.delete(listener)),
      },
      onDisconnect: { addListener: vi.fn(), removeListener: vi.fn() },
      postMessage: vi.fn((message: unknown) => {
        for (const listener of messageListeners) listener({ ...(message as object), type: 'ready' });
      }),
      disconnect: vi.fn(),
    };
    vi.mocked(chrome.runtime.connectNative).mockReturnValue(port as unknown as chrome.runtime.Port);
    const fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    await initializeNativeOptionsPage(document);

    (document.getElementById('check-companion') as HTMLButtonElement).click();
    await vi.waitFor(() => {
      expect(document.getElementById('companion-status')?.textContent).toBe('Companion is installed and responding.');
    });
    expect(chrome.runtime.connectNative).toHaveBeenCalledExactlyOnceWith(NATIVE_HOST_NAME);
    expect(port.postMessage).toHaveBeenCalledExactlyOnceWith({
      version: NATIVE_PROTOCOL_VERSION,
      type: 'hello',
      connectionId: expect.any(String),
    });
    expect(port.disconnect).toHaveBeenCalledTimes(1);
    expect(fetchMock).not.toHaveBeenCalled();
    expect(setSettings).not.toHaveBeenCalled();
    expect(chrome.tabs.create).not.toHaveBeenCalled();
  });

  it('explains the macOS requirement without offering an unavailable interface', async () => {
    vi.mocked(chrome.runtime.getPlatformInfo).mockImplementation(() => Promise.resolve({
      os: 'linux', arch: 'x86-64', nacl_arch: 'x86-64',
    }));
    await initializeNativeOptionsPage(document);
    (document.getElementById('check-companion') as HTMLButtonElement).click();

    await vi.waitFor(() => {
      expect(document.getElementById('companion-status')?.textContent).toBe(
        'This version of SnapScreen requires the macOS companion. Use it on a Mac.',
      );
    });
    expect(document.getElementById('companion-status')?.dataset.state).toBe('error');
    expect(document.body.textContent).not.toContain('In Chrome');
    expect(chrome.runtime.connectNative).not.toHaveBeenCalled();
    expect(setSettings).not.toHaveBeenCalled();
    expect(chrome.tabs.create).not.toHaveBeenCalled();
  });
});
