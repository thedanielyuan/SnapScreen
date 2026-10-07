/**
 * Normalizes transport whitespace without interpreting response text as
 * Markdown. Symbols such as backticks, underscores, hashes, and list markers
 * may be part of a technically correct answer and must remain intact.
 */
export function normalizePlainText(text: string): string {
  return text.replace(/\r\n?/g, '\n');
}
