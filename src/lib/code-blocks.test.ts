import { describe, expect, it } from 'vitest';
import { closeOpenCodeFence, splitAnswerSegments } from './code-blocks';

describe('splitAnswerSegments', () => {
  it('returns plain answers as a single text segment', () => {
    expect(splitAnswerSegments('The answer is 4.')).toEqual([
      { type: 'text', text: 'The answer is 4.' },
    ]);
  });

  it('separates prose from a fenced block and keeps the language', () => {
    const answer = [
      'Here is the function:',
      '',
      '```python',
      'def add(a, b):',
      '    return a + b',
      '```',
      '',
      'It returns the sum.',
    ].join('\n');

    expect(splitAnswerSegments(answer)).toEqual([
      { type: 'text', text: 'Here is the function:' },
      {
        type: 'code',
        code: 'def add(a, b):\n    return a + b',
        language: 'python',
        complete: true,
      },
      { type: 'text', text: 'It returns the sum.' },
    ]);
  });

  it('preserves code exactly, including blank lines and Markdown-looking symbols', () => {
    const code = '# comment\n\nx = a * b  # *not* emphasis\n\tprint(`x`)\n';
    const [segment] = splitAnswerSegments(`\`\`\`\n${code}\n\`\`\``);

    expect(segment).toEqual({ type: 'code', code, language: '', complete: true });
  });

  it('uses only the first word of the info string as the language', () => {
    const [segment] = splitAnswerSegments('```js title="add.js"\nadd();\n```');

    expect(segment).toMatchObject({ type: 'code', language: 'js', code: 'add();' });
  });

  it('supports tilde fences and longer fences that contain shorter ones', () => {
    expect(splitAnswerSegments('~~~sql\nSELECT 1;\n~~~')).toEqual([
      { type: 'code', code: 'SELECT 1;', language: 'sql', complete: true },
    ]);

    const nested = '````markdown\n```python\nprint(1)\n```\n````';
    expect(splitAnswerSegments(nested)).toEqual([
      {
        type: 'code',
        code: '```python\nprint(1)\n```',
        language: 'markdown',
        complete: true,
      },
    ]);
  });

  it('removes the opening fence indentation from code lines', () => {
    const [segment] = splitAnswerSegments('  ```c\n  int x;\n    y();\n  ```');

    expect(segment).toMatchObject({ code: 'int x;\n  y();', complete: true });
  });

  it('keeps inline triple backticks and indented fences as literal text', () => {
    const inline = 'Use ```a``` here';
    const indented = '    ```python\n    x = 1\n    ```';

    expect(splitAnswerSegments(inline)).toEqual([{ type: 'text', text: inline }]);
    expect(splitAnswerSegments(indented)).toEqual([{ type: 'text', text: indented }]);
  });

  it('marks an unterminated block as incomplete while it streams', () => {
    expect(splitAnswerSegments('Sure:\n```java\nclass A {')).toEqual([
      { type: 'text', text: 'Sure:' },
      { type: 'code', code: 'class A {', language: 'java', complete: false },
    ]);
    expect(splitAnswerSegments('```py')).toEqual([
      { type: 'code', code: '', language: 'py', complete: false },
    ]);
  });

  it('splits multiple code blocks in order', () => {
    const segments = splitAnswerSegments(
      '```html\n<p id="a"></p>\n```\nThen:\n```js\nrun();\n```',
    );

    expect(segments.map((segment) => segment.type)).toEqual(['code', 'text', 'code']);
    expect(segments[0]).toMatchObject({ language: 'html', code: '<p id="a"></p>' });
    expect(segments[2]).toMatchObject({ language: 'js', code: 'run();' });
  });

  it('normalizes CRLF line endings', () => {
    expect(splitAnswerSegments('```go\r\nfmt.Println()\r\n```')).toEqual([
      { type: 'code', code: 'fmt.Println()', language: 'go', complete: true },
    ]);
  });
});

describe('closeOpenCodeFence', () => {
  it('closes a truncated block with a matching fence', () => {
    expect(closeOpenCodeFence('```python\nprint(1')).toBe('```python\nprint(1\n```');
    expect(closeOpenCodeFence('~~~~\nx\n')).toBe('~~~~\nx\n~~~~');
  });

  it('leaves answers without an open block unchanged', () => {
    const closed = '```python\nprint(1)\n```';

    expect(closeOpenCodeFence(closed)).toBe(closed);
    expect(closeOpenCodeFence('Plain answer')).toBe('Plain answer');
  });
});
