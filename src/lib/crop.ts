import type { AnthropicMessage, Rect } from './messages';
import { inspectPngDataUrl, type ScreenshotMetadata } from './request-limits';
import type { SnapScreenLimits } from './storage';

// PNG size tracks pixel count only roughly, so an image over the byte limit
// can need a second, smaller pass.
const MAX_FIT_PASSES = 4;

export async function cropImage(
  dataUrl: string,
  normalizedRect: Rect,
): Promise<string> {
  validateCropRequest(normalizedRect);

  const response = await fetch(dataUrl);
  const blob = await response.blob();
  const bitmap = await createImageBitmap(blob);

  try {
    const requestedLeft = Math.round(normalizedRect.x * bitmap.width);
    const requestedTop = Math.round(normalizedRect.y * bitmap.height);
    const requestedRight = Math.round(
      (normalizedRect.x + normalizedRect.width) * bitmap.width,
    );
    const requestedBottom = Math.round(
      (normalizedRect.y + normalizedRect.height) * bitmap.height,
    );
    if (
      ![requestedLeft, requestedTop, requestedRight, requestedBottom].every(Number.isFinite)
    ) {
      throw new RangeError('Crop rectangle is outside the supported coordinate range.');
    }

    const sx = clamp(requestedLeft, 0, bitmap.width);
    const sy = clamp(requestedTop, 0, bitmap.height);
    const right = clamp(requestedRight, 0, bitmap.width);
    const bottom = clamp(requestedBottom, 0, bitmap.height);
    const sw = right - sx;
    const sh = bottom - sy;
    if (sw <= 0 || sh <= 0) {
      throw new RangeError('Crop rectangle does not intersect the captured image.');
    }

    const canvas = new OffscreenCanvas(sw, sh);
    const ctx = canvas.getContext('2d');
    if (!ctx) throw new Error('Failed to get canvas context');

    ctx.drawImage(bitmap, sx, sy, sw, sh, 0, 0, sw, sh);

    const cropped = await canvas.convertToBlob({ type: 'image/png' });
    return await blobToDataUrl(cropped);
  } finally {
    bitmap.close();
  }
}

/**
 * Downscales a PNG screenshot that exceeds the edge or byte limit, so large
 * selections on high-DPI screens are sent at a lower resolution instead of
 * being rejected. An image that already fits, can't be decoded, or stays too
 * large is returned unchanged, so request validation still reports it.
 */
export async function fitScreenshotToLimits(
  dataUrl: string,
  limits: Pick<SnapScreenLimits, 'maxScreenshotBytes' | 'maxScreenshotDimension'>,
): Promise<string> {
  let metadata: ScreenshotMetadata;
  try {
    metadata = inspectPngDataUrl(dataUrl);
  } catch {
    return dataUrl;
  }
  const longestEdge = Math.max(metadata.width, metadata.height);
  if (
    metadata.bytes <= limits.maxScreenshotBytes
    && longestEdge <= limits.maxScreenshotDimension
  ) {
    return dataUrl;
  }

  let scale = Math.min(
    1,
    limits.maxScreenshotDimension / longestEdge,
    byteScale(metadata.bytes, limits.maxScreenshotBytes),
  );
  try {
    const bitmap = await createImageBitmap(await (await fetch(dataUrl)).blob());
    try {
      for (let pass = 0; pass < MAX_FIT_PASSES; pass += 1) {
        const blob = await encodeScaled(bitmap, scale);
        if (blob.size <= limits.maxScreenshotBytes) return await blobToDataUrl(blob);
        scale *= byteScale(blob.size, limits.maxScreenshotBytes);
      }
    } finally {
      bitmap.close();
    }
  } catch {
    // Validation reports the original image's size or format instead.
  }
  return dataUrl;
}

function byteScale(bytes: number, maxBytes: number): number {
  // Aims 10% under the limit, because PNG size isn't proportional to area.
  return bytes > maxBytes ? Math.sqrt(maxBytes / bytes) * 0.9 : 1;
}

/**
 * Fits every screenshot in a conversation, like `fitScreenshotToLimits`. History
 * rebuilt after a first answer is stopped or interrupted holds the full-size
 * capture. History from a completed answer already holds the fitted one, which
 * passes through unchanged.
 */
export async function fitHistoryScreenshotsToLimits(
  history: AnthropicMessage[],
  limits: Pick<SnapScreenLimits, 'maxScreenshotBytes' | 'maxScreenshotDimension'>,
): Promise<AnthropicMessage[]> {
  return Promise.all(history.map(async (message) => {
    if (!Array.isArray(message.content)) return message;
    const content = await Promise.all(message.content.map(async (block) => {
      if (block.type !== 'image') return block;
      const dataUrl = `data:${block.source.media_type};base64,${block.source.data}`;
      const fitted = await fitScreenshotToLimits(dataUrl, limits);
      if (fitted === dataUrl) return block;
      return { ...block, source: { ...block.source, data: dataUrlToBase64(fitted) } };
    }));
    return { ...message, content };
  }));
}

async function encodeScaled(bitmap: ImageBitmap, scale: number): Promise<Blob> {
  // Rounding keeps the longest edge exactly at the limit when scaling by edge.
  const width = Math.max(1, Math.round(bitmap.width * scale));
  const height = Math.max(1, Math.round(bitmap.height * scale));
  const canvas = new OffscreenCanvas(width, height);
  const ctx = canvas.getContext('2d');
  if (!ctx) throw new Error('Failed to get canvas context');

  ctx.imageSmoothingQuality = 'high';
  ctx.drawImage(bitmap, 0, 0, width, height);
  return canvas.convertToBlob({ type: 'image/png' });
}

function validateCropRequest(rect: Rect): void {
  const right = rect.x + rect.width;
  const bottom = rect.y + rect.height;
  if (
    !Number.isFinite(rect.x) ||
    !Number.isFinite(rect.y) ||
    !Number.isFinite(rect.width) ||
    !Number.isFinite(rect.height) ||
    rect.x < 0 ||
    rect.y < 0 ||
    rect.width <= 0 ||
    rect.height <= 0 ||
    right > 1 ||
    bottom > 1
  ) {
    throw new RangeError('Normalized crop rectangle must be finite and contained in the image.');
  }
}

function clamp(value: number, minimum: number, maximum: number): number {
  return Math.min(Math.max(value, minimum), maximum);
}

function blobToDataUrl(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result as string);
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(blob);
  });
}

export function dataUrlToBase64(dataUrl: string): string {
  const comma = dataUrl.indexOf(',');
  return comma >= 0 ? dataUrl.slice(comma + 1) : dataUrl;
}
