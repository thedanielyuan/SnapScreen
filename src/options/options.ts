import { verifyApiKey } from '../lib/anthropic';
import {
  DEFAULT_LIMITS,
  DEFAULT_PROMPT,
  LIMIT_CONSTRAINTS,
  getInterfaceMode,
  getSettings,
  removeApiKey,
  saveSettings,
} from '../lib/storage';
import { MEGABYTE, countTextCharacters } from '../lib/request-limits';

export async function initializeOptionsPage(doc: Document = document): Promise<void> {
  const form = doc.getElementById('settings-form') as HTMLFormElement;
  const apiKeyInput = doc.getElementById('api-key') as HTMLInputElement;
  const toggleKeyBtn = doc.getElementById('toggle-key') as HTMLButtonElement;
  const testKeyBtn = doc.getElementById('test-key') as HTMLButtonElement;
  const removeKeyBtn = doc.getElementById('remove-key') as HTMLButtonElement;
  const saveBtn = doc.getElementById('save-settings') as HTMLButtonElement;
  const promptInput = doc.getElementById('default-prompt') as HTMLTextAreaElement;
  const interfaceModeInput = doc.getElementById('interface-mode') as HTMLSelectElement;
  const maxInputCharactersInput = doc.getElementById('max-input-characters') as HTMLInputElement;
  const maxScreenshotMegabytesInput = doc.getElementById('max-screenshot-megabytes') as HTMLInputElement;
  const maxScreenshotDimensionInput = doc.getElementById('max-screenshot-dimension') as HTMLInputElement;
  const maxConversationTurnsInput = doc.getElementById('max-conversation-turns') as HTMLInputElement;
  const advancedSettings = doc.getElementById('advanced-settings') as HTMLDetailsElement;
  const status = doc.getElementById('status') as HTMLSpanElement;
  const shortcutDisplay = doc.getElementById('shortcut-display') as HTMLElement;
  const openShortcutsBtn = doc.getElementById('open-shortcuts') as HTMLButtonElement;

  let statusTimeout: ReturnType<typeof setTimeout> | undefined;
  let hasStoredApiKey = false;
  let hydrationPending = true;
  let removalPending = false;
  let savePending = false;
  let testPending = false;
  let pendingSave: Promise<void> | null = null;
  let removalEpoch = 0;
  let settingsEpoch = 0;
  const limitInputs = [
    maxInputCharactersInput,
    maxScreenshotMegabytesInput,
    maxScreenshotDimensionInput,
    maxConversationTurnsInput,
  ];

  function updateRemoveKeyState(): void {
    removeKeyBtn.disabled = hydrationPending || removalPending || !hasStoredApiKey;
  }

  function updateControlStates(): void {
    saveBtn.disabled = hydrationPending || removalPending || savePending;
    testKeyBtn.disabled = hydrationPending || removalPending || testPending;
    toggleKeyBtn.disabled = hydrationPending || removalPending;
    apiKeyInput.disabled = hydrationPending || removalPending;
    promptInput.disabled = hydrationPending;
    interfaceModeInput.disabled = hydrationPending;
    for (const input of limitInputs) input.disabled = hydrationPending;
    updateRemoveKeyState();
  }

  function setRemovalPending(pending: boolean): void {
    removalPending = pending;
    updateControlStates();
  }

  function resetKeyVisibility(): void {
    apiKeyInput.type = 'password';
    toggleKeyBtn.textContent = 'Show';
    toggleKeyBtn.setAttribute('aria-label', 'Show API key');
    toggleKeyBtn.setAttribute('aria-pressed', 'false');
  }

  function showStatus(
    message: string,
    isError = false,
    opts?: { sticky?: boolean },
  ): void {
    clearTimeout(statusTimeout);
    status.textContent = message;
    status.hidden = false;
    status.classList.toggle('error', isError);
    status.setAttribute('role', isError ? 'alert' : 'status');
    status.setAttribute('aria-live', isError ? 'assertive' : 'polite');

    if (!opts?.sticky) {
      statusTimeout = setTimeout(() => {
        status.hidden = true;
      }, 3000);
    }
  }

  // The limits sit in the collapsed Advanced section. Chrome can't focus an
  // invalid control inside a closed <details>, so Save would silently do
  // nothing; open the section before the browser reports the problem.
  form.addEventListener('invalid', (event) => {
    if (advancedSettings.contains(event.target as Node)) advancedSettings.open = true;
  }, true);

  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (hydrationPending || removalPending || savePending) return;

    const apiKey = apiKeyInput.value.trim();
    const defaultPrompt = promptInput.value.trim() || DEFAULT_PROMPT;
    const interfaceMode = interfaceModeInput.value === 'native' ? 'native' : 'extension';
    const limits = readLimits();
    if (!limits) return;
    if (countTextCharacters(defaultPrompt) > limits.maxInputCharacters) {
      showStatus(
        `Default Prompt exceeds the ${limits.maxInputCharacters.toLocaleString()} character limit.`,
        true,
      );
      return;
    }
    const operationEpoch = removalEpoch;
    settingsEpoch += 1;
    const settings = apiKey
      ? { apiKey, defaultPrompt, limits, interfaceMode } as const
      : { defaultPrompt, limits, interfaceMode } as const;
    const save = saveSettings(settings);
    pendingSave = save;
    savePending = true;
    updateControlStates();

    try {
      await save;
      if (operationEpoch !== removalEpoch) return;

      if (apiKey) {
        hasStoredApiKey = true;
        updateControlStates();
        showStatus('Settings saved.');
      } else {
        showStatus(
          hasStoredApiKey
            ? 'Settings saved. Existing API key unchanged.'
            : 'Settings saved. Add an API key to analyze screenshots.',
        );
      }
    } catch (error) {
      if (operationEpoch !== removalEpoch) return;
      showStatus(
        error instanceof Error ? error.message : 'Could not save settings.',
        true,
      );
    } finally {
      if (pendingSave === save) pendingSave = null;
      savePending = false;
      updateControlStates();
    }
  });

  toggleKeyBtn.addEventListener('click', () => {
    if (hydrationPending || removalPending) return;
    const show = apiKeyInput.type === 'password';
    apiKeyInput.type = show ? 'text' : 'password';
    toggleKeyBtn.textContent = show ? 'Hide' : 'Show';
    toggleKeyBtn.setAttribute('aria-label', show ? 'Hide API key' : 'Show API key');
    toggleKeyBtn.setAttribute('aria-pressed', String(show));
  });

  testKeyBtn.addEventListener('click', async () => {
    if (hydrationPending || removalPending || testPending) return;
    const apiKey = apiKeyInput.value.trim();
    if (!apiKey) {
      showStatus('Enter an API key to test.', true);
      return;
    }

    const operationEpoch = removalEpoch;
    testPending = true;
    updateControlStates();
    showStatus('Testing…', false, { sticky: true });
    try {
      await verifyApiKey(apiKey);
      if (operationEpoch === removalEpoch) showStatus('API key works.');
    } catch (error) {
      if (operationEpoch === removalEpoch) {
        showStatus(error instanceof Error ? error.message : 'Test failed.', true);
      }
    } finally {
      testPending = false;
      updateControlStates();
    }
  });

  removeKeyBtn.addEventListener('click', async () => {
    if (hydrationPending || !hasStoredApiKey || removalPending) return;

    removalEpoch += 1;
    settingsEpoch += 1;
    setRemovalPending(true);
    try {
      await pendingSave?.catch(() => undefined);
      await removeApiKey();
      hasStoredApiKey = false;
      apiKeyInput.value = '';
      resetKeyVisibility();
      showStatus('API key removed.');
    } catch (error) {
      showStatus(
        error instanceof Error ? error.message : 'Could not remove API key.',
        true,
      );
    } finally {
      setRemovalPending(false);
    }
  });

  openShortcutsBtn.addEventListener('click', () => {
    void chrome.tabs.create({ url: 'chrome://extensions/shortcuts' });
  });

  promptInput.value = DEFAULT_PROMPT;
  interfaceModeInput.value = 'extension';
  setLimitInputs(DEFAULT_LIMITS);
  updateControlStates();

  function readLimits() {
    const maxInputCharacters = readInteger(
      maxInputCharactersInput,
      LIMIT_CONSTRAINTS.maxInputCharacters,
      'Question character limit',
    );
    const maxScreenshotMegabytes = readInteger(
      maxScreenshotMegabytesInput,
      {
        min: LIMIT_CONSTRAINTS.maxScreenshotBytes.min / MEGABYTE,
        max: LIMIT_CONSTRAINTS.maxScreenshotBytes.max / MEGABYTE,
        default: LIMIT_CONSTRAINTS.maxScreenshotBytes.default / MEGABYTE,
      },
      'Screenshot size limit',
    );
    const maxScreenshotDimension = readInteger(
      maxScreenshotDimensionInput,
      LIMIT_CONSTRAINTS.maxScreenshotDimension,
      'Screenshot edge limit',
    );
    const maxConversationTurns = readInteger(
      maxConversationTurnsInput,
      LIMIT_CONSTRAINTS.maxConversationTurns,
      'Conversation turn limit',
    );

    if (
      maxInputCharacters === null
      || maxScreenshotMegabytes === null
      || maxScreenshotDimension === null
      || maxConversationTurns === null
    ) {
      return null;
    }

    return {
      maxInputCharacters,
      maxScreenshotBytes: maxScreenshotMegabytes * MEGABYTE,
      maxScreenshotDimension,
      maxConversationTurns,
    };
  }

  function readInteger(
    input: HTMLInputElement,
    constraints: { min: number; max: number; default: number },
    label: string,
  ): number | null {
    const value = Number(input.value);
    if (!Number.isInteger(value) || value < constraints.min || value > constraints.max) {
      showStatus(
        `${label} must be a whole number from ${constraints.min.toLocaleString()} to ${constraints.max.toLocaleString()}.`,
        true,
      );
      advancedSettings.open = true;
      input.focus();
      return null;
    }
    return value;
  }

  function setLimitInputs(limits: typeof DEFAULT_LIMITS): void {
    maxInputCharactersInput.value = String(limits.maxInputCharacters);
    maxScreenshotMegabytesInput.value = String(limits.maxScreenshotBytes / MEGABYTE);
    maxScreenshotDimensionInput.value = String(limits.maxScreenshotDimension);
    maxConversationTurnsInput.value = String(limits.maxConversationTurns);
  }

  const loadSettings = async (): Promise<void> => {
    const loadEpoch = settingsEpoch;
    try {
      const [settings, interfaceMode] = await Promise.all([getSettings(), getInterfaceMode()]);
      if (loadEpoch !== settingsEpoch) return;
      apiKeyInput.value = settings.apiKey;
      promptInput.value = settings.defaultPrompt || DEFAULT_PROMPT;
      interfaceModeInput.value = interfaceMode;
      setLimitInputs(settings.limits);
      hasStoredApiKey = !!settings.apiKey;
    } catch (error) {
      if (loadEpoch !== settingsEpoch) return;
      showStatus(
        error instanceof Error ? error.message : 'Could not load settings.',
        true,
        { sticky: true },
      );
    } finally {
      hydrationPending = false;
      updateControlStates();
    }
  };

  const loadShortcut = async (): Promise<void> => {
    try {
      const commands = await chrome.commands.getAll();
      const snip = commands.find((command) => command.name === 'snip');
      shortcutDisplay.textContent = snip?.shortcut || 'no shortcut set';
    } catch {
      shortcutDisplay.textContent = 'no shortcut set';
    }
  };

  await Promise.all([loadSettings(), loadShortcut()]);
}

if (
  typeof document !== 'undefined' &&
  document.getElementById('settings-form')
) {
  void initializeOptionsPage(document).catch(() => undefined);
}
