import { describe, expect, it } from 'vitest';
import {
  SCREENSHOT_QA_SYSTEM_PROMPT,
  buildScreenshotQaSystemPrompt,
} from './screenshot-qa-prompt';

describe('screenshot QA prompt', () => {
  it('guides careful screenshot question answering', () => {
    expect(SCREENSHOT_QA_SYSTEM_PROMPT).toContain('Carefully inspect the screenshot');
    expect(SCREENSHOT_QA_SYSTEM_PROMPT).toContain('Identify the main question');
    expect(SCREENSHOT_QA_SYSTEM_PROMPT).toContain('Ignore irrelevant UI');
    expect(SCREENSHOT_QA_SYSTEM_PROMPT).toContain('briefly explain why');
    expect(SCREENSHOT_QA_SYSTEM_PROMPT).toContain('answer each one in order');
    expect(SCREENSHOT_QA_SYSTEM_PROMPT).toContain('unclear, unreadable, cropped');
    expect(SCREENSHOT_QA_SYSTEM_PROMPT).toContain('Do not guess');
    expect(SCREENSHOT_QA_SYSTEM_PROMPT).toContain('solve the problem carefully');
    expect(SCREENSHOT_QA_SYSTEM_PROMPT).toContain('rather than using Markdown for styling');
    expect(SCREENSHOT_QA_SYSTEM_PROMPT).toContain('rather than LaTeX');
    expect(SCREENSHOT_QA_SYSTEM_PROMPT).toContain('whenever they are part of the correct answer');
    expect(SCREENSHOT_QA_SYSTEM_PROMPT).not.toContain(
      'no asterisks, hashtags, underscores, backticks',
    );
  });

  it('leaves reasoning to adaptive thinking instead of rules about hiding it', () => {
    expect(SCREENSHOT_QA_SYSTEM_PROMPT).not.toMatch(/chain-of-thought|hidden reasoning|internally/i);
  });

  it('includes follow-up rules so first answers and follow-ups share one prompt', () => {
    expect(SCREENSHOT_QA_SYSTEM_PROMPT).toContain('Follow-up rules');
    expect(SCREENSHOT_QA_SYSTEM_PROMPT).toContain('1–3 sentences unless they ask for more detail');
    expect(SCREENSHOT_QA_SYSTEM_PROMPT).toContain('Do not re-summarize or re-describe the screenshot');
  });

  it('appends saved default prompt as hidden extra guidance', () => {
    const prompt = buildScreenshotQaSystemPrompt('Prefer concise answers.');

    expect(prompt).toContain(SCREENSHOT_QA_SYSTEM_PROMPT);
    expect(prompt).toContain('Additional hidden user guidance:');
    expect(prompt).toContain('Prefer concise answers.');
  });

  it('does not append empty extra guidance', () => {
    expect(buildScreenshotQaSystemPrompt('   ')).toBe(SCREENSHOT_QA_SYSTEM_PROMPT);
  });

});
