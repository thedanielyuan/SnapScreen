import type { SnapScreenLimits, SnapScreenSessionSettings } from './storage';

export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface CaptureSelection {
  /** Rectangle in the selector viewport, used to position the result panel. */
  viewportRect: Rect;
  /** Rectangle relative to the frozen screenshot, with every value in [0, 1]. */
  normalizedRect: Rect;
}

export type AnthropicContentBlock =
  | { type: 'text'; text: string }
  | {
      type: 'image';
      source: { type: 'base64'; media_type: 'image/png'; data: string };
    };

export type AnthropicMessage = {
  role: 'user' | 'assistant';
  content: string | AnthropicContentBlock[];
};

export type DisplayMessage = {
  role: 'user' | 'assistant';
  content: string;
  status?: 'failed';
};

export type BgToCsMessage =
  | { type: 'PREPARE_SNIP_CAPTURE' }
  | {
      type: 'START_SNIP';
      captureId: string;
      dataUrl: string;
      defaultPrompt: string;
      limits: SnapScreenLimits;
    }
  | { type: 'CROPPED_IMAGE'; dataUrl: string; captureId: string }
  | { type: 'CAPTURE_ERROR'; code: string; message: string; captureId: string }
  | {
      type: 'ANALYZE_THINKING';
      captureId: string;
      requestId: string;
      screenshotId: string;
    }
  | {
      type: 'ANALYZE_CHUNK';
      text: string;
      captureId: string;
      requestId: string;
      screenshotId: string;
    }
  | {
      type: 'ANALYZE_RESULT';
      text: string;
      captureId: string;
      requestId: string;
      screenshotId: string;
      history?: AnthropicMessage[];
    }
  | {
      type: 'ANALYZE_ERROR';
      code: string;
      message: string;
      captureId: string;
      requestId: string;
      screenshotId: string;
    }
  | { type: 'RESNIP_UNAVAILABLE'; message: string }
  | { type: 'SHOW_ERROR'; message: string };

export type CsToBgMessage =
  | {
      type: 'CAPTURE_REGION';
      selection: CaptureSelection;
      captureId: string;
      dataUrl: string;
    }
  | { type: 'REQUEST_SNIP'; sessionSettings: SnapScreenSessionSettings }
  | {
      type: 'ANALYZE';
      dataUrl: string;
      captureId: string;
      requestId: string;
      screenshotId: string;
      sessionSettings: SnapScreenSessionSettings;
      question?: string;
    }
  | {
      type: 'FOLLOW_UP';
      text: string;
      history: AnthropicMessage[];
      captureId: string;
      requestId: string;
      screenshotId: string;
      sessionSettings: SnapScreenSessionSettings;
    }
  | { type: 'CANCEL_GENERATION'; captureId: string; requestId: string }
  | { type: 'SNIP_CANCELLED'; captureId: string }
  | { type: 'UI_UNAVAILABLE' }
  | { type: 'OPEN_SETTINGS' };
