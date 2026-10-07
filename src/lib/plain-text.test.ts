import { describe, expect, it } from 'vitest';
import { normalizePlainText } from './plain-text';

describe('normalizePlainText', () => {
  it('preserves Markdown-looking characters that may be meaningful syntax', () => {
    const answer = [
      '## C_preprocessor',
      '- `user_id` = value_1',
      '1. **Do not** remove * or #',
      '```ts',
      'const snake_case = items.map((x) => x * 2);',
      '```',
    ].join('\n');

    expect(normalizePlainText(answer)).toBe(answer);
  });

  it('normalizes CRLF and CR line endings', () => {
    expect(normalizePlainText('first\r\nsecond\rthird')).toBe('first\nsecond\nthird');
  });

  it('preserves runs of blank lines', () => {
    expect(normalizePlainText('a\n\n\n\nb')).toBe('a\n\n\n\nb');
  });

  it('preserves surrounding whitespace used by code or preformatted data', () => {
    expect(normalizePlainText('  answer  \n')).toBe('  answer  \n');
  });

  it('leaves plain text untouched', () => {
    expect(normalizePlainText('2 + 2 = 4')).toBe('2 + 2 = 4');
  });
});
