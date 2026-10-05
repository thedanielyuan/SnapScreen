export const DEFAULT_PROMPT =
  'Answer the question shown in this screenshot.';

export interface SnapScreenLimits {
  maxInputCharacters: number;
  maxScreenshotBytes: number;
  maxScreenshotDimension: number;
  maxConversationTurns: number;
}

export interface SnapScreenSessionSettings {
  defaultPrompt: string;
  limits: SnapScreenLimits;
}

export const LIMIT_CONSTRAINTS = {
  maxInputCharacters: { min: 100, max: 50_000, default: 4_000 },
  // Anthropic's direct API accepts at most 10 MB per base64 image.
  maxScreenshotBytes: { min: 1_000_000, max: 10_000_000, default: 5_000_000 },
  // 2,576 px is Opus 5.5's native long edge; 8,000 px is the API ceiling.
  maxScreenshotDimension: { min: 512, max: 8_000, default: 2_576 },
  maxConversationTurns: { min: 2, max: 50, default: 12 },
} as const;

export const DEFAULT_LIMITS: SnapScreenLimits = {
  maxInputCharacters: LIMIT_CONSTRAINTS.maxInputCharacters.default,
  maxScreenshotBytes: LIMIT_CONSTRAINTS.maxScreenshotBytes.default,
  maxScreenshotDimension: LIMIT_CONSTRAINTS.maxScreenshotDimension.default,
  maxConversationTurns: LIMIT_CONSTRAINTS.maxConversationTurns.default,
};

export interface SnapScreenSettings extends SnapScreenSessionSettings {
  apiKey: string;
}

const DEFAULTS: SnapScreenSettings = {
  apiKey: '',
  defaultPrompt: DEFAULT_PROMPT,
  limits: DEFAULT_LIMITS,
};

export async function getSettings(): Promise<SnapScreenSettings> {
  const stored = await chrome.storage.local.get(['apiKey', 'defaultPrompt', 'limits']);
  const apiKey = typeof stored.apiKey === 'string' ? stored.apiKey.trim() : '';
  const defaultPrompt = typeof stored.defaultPrompt === 'string'
    ? stored.defaultPrompt.trim()
    : '';
  return {
    apiKey: apiKey || DEFAULTS.apiKey,
    defaultPrompt: defaultPrompt || DEFAULTS.defaultPrompt,
    limits: normalizeLimits(stored.limits),
  };
}

export async function saveSettings(settings: Partial<SnapScreenSettings>): Promise<void> {
  await chrome.storage.local.set({
    ...settings,
    ...(settings.limits ? { limits: normalizeLimits(settings.limits) } : {}),
  });
}

export function normalizeLimits(value: unknown): SnapScreenLimits {
  const stored = isRecord(value) ? value : {};
  return {
    maxInputCharacters: normalizeInteger(
      stored.maxInputCharacters,
      LIMIT_CONSTRAINTS.maxInputCharacters,
    ),
    maxScreenshotBytes: normalizeInteger(
      stored.maxScreenshotBytes,
      LIMIT_CONSTRAINTS.maxScreenshotBytes,
    ),
    maxScreenshotDimension: normalizeInteger(
      stored.maxScreenshotDimension,
      LIMIT_CONSTRAINTS.maxScreenshotDimension,
    ),
    maxConversationTurns: normalizeInteger(
      stored.maxConversationTurns,
      LIMIT_CONSTRAINTS.maxConversationTurns,
    ),
  };
}

function normalizeInteger(
  value: unknown,
  constraints: { min: number; max: number; default: number },
): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) return constraints.default;
  return Math.min(constraints.max, Math.max(constraints.min, Math.round(value)));
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

export async function removeApiKey(): Promise<void> {
  await chrome.storage.local.remove('apiKey');
}

export async function initializeStorageAccess(): Promise<void> {
  const storage = chrome.storage?.local;
  if (!storage || typeof storage.setAccessLevel !== 'function') {
    return;
  }

  try {
    await storage.setAccessLevel({ accessLevel: 'TRUSTED_CONTEXTS' });
  } catch {
    // Older Chrome versions can expose the method without supporting this level.
  }
}
