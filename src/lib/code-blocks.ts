/**
 * Splits an answer into prose and fenced code blocks. Answers are plain text,
 * except that the system prompt asks the model to fence code so the UI can
 * render it with a Copy button. Only CommonMark-style fences are interpreted;
 * all other Markdown-looking syntax stays literal text.
 */
export type AnswerSegment =
  | { type: 'text'; text: string }
  | {
      type: 'code';
      code: string;
      /** First word of the fence's info string, e.g. `python`; may be empty. */
      language: string;
      /** False while a streamed block is still open, or if an answer was cut off. */
      complete: boolean;
    };

interface OpeningFence {
  indent: number;
  marker: '`' | '~';
  length: number;
  language: string;
}

const OPENING_FENCE = /^( {0,3})(`{3,}|~{3,})(.*)$/;
const CLOSING_FENCE = /^ {0,3}(`{3,}|~{3,})[ \t]*$/;
const MAX_LANGUAGE_LENGTH = 24;

function parseOpeningFence(line: string): OpeningFence | null {
  const match = OPENING_FENCE.exec(line);
  if (!match) return null;
  const [, indent, fence, info] = match;
  const marker = fence[0] as OpeningFence['marker'];
  // A backtick fence's info string cannot contain backticks, so a line such
  // as ```x``` is inline code in literal text, not the start of a block.
  if (marker === '`' && info.includes('`')) return null;
  return {
    indent: indent.length,
    marker,
    length: fence.length,
    language: info.trim().split(/\s+/u)[0].slice(0, MAX_LANGUAGE_LENGTH),
  };
}

function isClosingFence(line: string, opening: OpeningFence): boolean {
  const match = CLOSING_FENCE.exec(line);
  return match !== null
    && match[1][0] === opening.marker
    && match[1].length >= opening.length;
}

function stripFenceIndent(line: string, indent: number): string {
  let removed = 0;
  while (removed < indent && line[removed] === ' ') removed += 1;
  return line.slice(removed);
}

function scanAnswer(text: string): {
  segments: AnswerSegment[];
  openFence: OpeningFence | null;
} {
  const lines = text.replace(/\r\n?/gu, '\n').split('\n');
  const segments: AnswerSegment[] = [];
  let textLines: string[] = [];
  let openFence: OpeningFence | null = null;

  const flushText = (): void => {
    // Blank lines next to a fence are spacing, not content; the rendered code
    // block already separates itself from the surrounding prose.
    const value = textLines.join('\n').replace(/^(?:[ \t]*\n)+/u, '').trimEnd();
    if (value.trim()) segments.push({ type: 'text', text: value });
    textLines = [];
  };

  for (let index = 0; index < lines.length; index += 1) {
    const opening = parseOpeningFence(lines[index]);
    if (!opening) {
      textLines.push(lines[index]);
      continue;
    }

    flushText();
    const codeLines: string[] = [];
    let complete = false;
    for (index += 1; index < lines.length; index += 1) {
      if (isClosingFence(lines[index], opening)) {
        complete = true;
        break;
      }
      codeLines.push(stripFenceIndent(lines[index], opening.indent));
    }
    if (!complete) openFence = opening;
    segments.push({
      type: 'code',
      code: codeLines.join('\n'),
      language: opening.language,
      complete,
    });
  }
  flushText();

  return { segments, openFence };
}

export function splitAnswerSegments(text: string): AnswerSegment[] {
  return scanAnswer(text).segments;
}

/**
 * Closes a code block left open by a truncated answer, so text appended after
 * it (such as a cut-off notice) renders as prose instead of being copied as code.
 */
export function closeOpenCodeFence(text: string): string {
  const { openFence } = scanAnswer(text);
  if (!openFence) return text;
  const separator = text.endsWith('\n') ? '' : '\n';
  return `${text}${separator}${openFence.marker.repeat(openFence.length)}`;
}
