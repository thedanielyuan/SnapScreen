import { describe, expect, it } from 'vitest';
import { analyzeImage, verifyApiKey } from './anthropic';
import { DEFAULT_LIMITS } from './storage';

// Sends real requests with the production settings, so a retired model, beta
// header, or request field fails here before it fails for users. Runs only
// when SNAPSCREEN_LIVE_API_KEY is set; see .github/workflows/live-api.yml.
// Vitest exposes environment variables on import.meta.env.
const apiKey: string = import.meta.env.SNAPSCREEN_LIVE_API_KEY ?? '';

const PIXEL_PNG =
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

describe.skipIf(!apiKey)('live Anthropic API', () => {
  it('accepts the options page key check', async () => {
    await expect(verifyApiKey(apiKey)).resolves.toBeUndefined();
  }, 60_000);

  it('answers a screenshot question with the production request', async () => {
    const result = await analyzeImage(apiKey, PIXEL_PNG, {
      userQuestion: 'Reply with the single word OK.',
      limits: DEFAULT_LIMITS,
    });

    expect(result.text.trim()).not.toBe('');
  }, 240_000);
});
