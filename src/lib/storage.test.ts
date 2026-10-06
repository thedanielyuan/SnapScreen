import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  DEFAULT_LIMITS,
  LIMIT_CONSTRAINTS,
  getInterfaceMode,
  getSettings,
  initializeStorageAccess,
  normalizeLimits,
  removeApiKey,
  saveSettings,
} from './storage';

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('settings limits', () => {
  it('migrates missing limits to evidence-based defaults', async () => {
    const get = vi.fn().mockResolvedValue({
      apiKey: 'key',
      defaultPrompt: 'Prompt',
    });
    vi.stubGlobal('chrome', { storage: { local: { get } } });

    await expect(getSettings()).resolves.toEqual({
      apiKey: 'key',
      defaultPrompt: 'Prompt',
      limits: DEFAULT_LIMITS,
    });
    expect(get).toHaveBeenCalledWith(['apiKey', 'defaultPrompt', 'limits']);
  });

  it('normalizes stored text and rejects whitespace-only credentials and prompts', async () => {
    const get = vi.fn().mockResolvedValue({
      apiKey: '   ',
      defaultPrompt: '\n\t',
    });
    vi.stubGlobal('chrome', { storage: { local: { get } } });

    await expect(getSettings()).resolves.toEqual({
      apiKey: '',
      defaultPrompt: 'Answer the question shown in this screenshot.',
      limits: DEFAULT_LIMITS,
    });

    get.mockResolvedValue({
      apiKey: '  sk-ant-test  ',
      defaultPrompt: '  Be concise.  ',
    });
    await expect(getSettings()).resolves.toMatchObject({
      apiKey: 'sk-ant-test',
      defaultPrompt: 'Be concise.',
    });
  });

  it('clamps corrupted and out-of-range stored values', () => {
    expect(normalizeLimits({
      maxInputCharacters: -1,
      maxScreenshotBytes: Number.POSITIVE_INFINITY,
      maxScreenshotDimension: 99_999,
      maxConversationTurns: 3.7,
    })).toEqual({
      maxInputCharacters: LIMIT_CONSTRAINTS.maxInputCharacters.min,
      maxScreenshotBytes: LIMIT_CONSTRAINTS.maxScreenshotBytes.default,
      maxScreenshotDimension: LIMIT_CONSTRAINTS.maxScreenshotDimension.max,
      maxConversationTurns: 4,
    });
  });
});

describe('interface mode', () => {
  it.each([undefined, null, '', 'extension', 'unknown', true, {}])(
    'defaults unsupported stored value %s to the extension interface',
    async (interfaceMode) => {
      const get = vi.fn().mockResolvedValue({ interfaceMode });
      vi.stubGlobal('chrome', { storage: { local: { get } } });

      await expect(getInterfaceMode()).resolves.toBe('extension');
      expect(get).toHaveBeenCalledWith('interfaceMode');
    },
  );

  it('loads explicit native mode without adding it to session settings', async () => {
    const get = vi.fn().mockResolvedValue({ interfaceMode: 'native' });
    vi.stubGlobal('chrome', { storage: { local: { get } } });

    await expect(getInterfaceMode()).resolves.toBe('native');
    expect(await getSettings()).not.toHaveProperty('interfaceMode');
  });

  it('saves the interface independently without replacing the stored key or limits', async () => {
    const set = vi.fn().mockResolvedValue(undefined);
    vi.stubGlobal('chrome', { storage: { local: { set } } });

    await saveSettings({ interfaceMode: 'native' });

    expect(set).toHaveBeenCalledWith({ interfaceMode: 'native' });
  });
});

describe('removeApiKey', () => {
  it('removes only the stored API key', async () => {
    const remove = vi.fn().mockResolvedValue(undefined);
    vi.stubGlobal('chrome', {
      storage: { local: { remove } },
    });

    await removeApiKey();

    expect(remove).toHaveBeenCalledWith('apiKey');
  });
});

describe('initializeStorageAccess', () => {
  it('limits local storage to trusted extension contexts when supported', async () => {
    const setAccessLevel = vi.fn().mockResolvedValue(undefined);
    vi.stubGlobal('chrome', {
      storage: { local: { setAccessLevel } },
    });

    await initializeStorageAccess();

    expect(setAccessLevel).toHaveBeenCalledWith({
      accessLevel: 'TRUSTED_CONTEXTS',
    });
  });

  it('is compatible with browsers that do not support access levels', async () => {
    vi.stubGlobal('chrome', {
      storage: { local: {} },
    });

    await expect(initializeStorageAccess()).resolves.toBeUndefined();
  });

  it('does not prevent startup when Chrome rejects the access level', async () => {
    vi.stubGlobal('chrome', {
      storage: {
        local: {
          setAccessLevel: vi.fn().mockRejectedValue(new Error('unsupported')),
        },
      },
    });

    await expect(initializeStorageAccess()).resolves.toBeUndefined();
  });
});
