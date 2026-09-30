import type { CaptureSelection, Rect } from '../lib/messages';
import {
  adjustKeyboardCrop,
  clampKeyboardCrop,
  createKeyboardCrop,
  MIN_CROP_SIZE,
} from './keyboard-crop';
import {
  createCaptureSelection,
  denormalizeRect,
  getContainedImageBounds,
} from './selection-geometry';
import {
  getUiRoot,
  queryUiElement,
  removeUiHostIfEmpty,
} from './ui-root';

const ROOT_ID = 'snapscreen-overlay-root';
const HINT_ID = 'snapscreen-overlay-instructions';
const SNIP_INSTRUCTION = 'Drag to select a region. Click to cancel';

export interface SnipOverlayOptions {
  dataUrl: string;
  imageFit?: 'contain' | 'fill';
  onRegionSelected: (selection: CaptureSelection) => void;
  onCancelled: () => void;
}

export type SnipOverlayDisposer = () => void;

let disposeActiveOverlay: SnipOverlayDisposer | null = null;

function getViewport(): { width: number; height: number } {
  return { width: window.innerWidth, height: window.innerHeight };
}

export function startSnipOverlay(options: SnipOverlayOptions): SnipOverlayDisposer {
  disposeSnipOverlay();

  const uiRoot = getUiRoot();
  const root = document.createElement('div');
  root.id = ROOT_ID;
  root.className = 'snapscreen-overlay';
  root.tabIndex = 0;
  root.setAttribute('role', 'dialog');
  root.setAttribute('aria-modal', 'true');
  root.setAttribute('aria-label', 'Select a screen region');
  root.setAttribute('aria-describedby', HINT_ID);

  const frozenPage = document.createElement('img');
  frozenPage.className = 'snapscreen-frozen-page';
  frozenPage.classList.toggle(
    'snapscreen-frozen-page-contain',
    options.imageFit === 'contain',
  );
  frozenPage.src = options.dataUrl;
  frozenPage.alt = '';
  frozenPage.draggable = false;
  frozenPage.setAttribute('aria-hidden', 'true');

  function getImageBounds(): Rect {
    const viewport = getViewport();
    if (options.imageFit !== 'contain') {
      return { x: 0, y: 0, ...viewport };
    }
    return getContainedImageBounds(viewport, {
      width: frozenPage.naturalWidth,
      height: frozenPage.naturalHeight,
    });
  }

  function clampPointerToImage(clientX: number, clientY: number): {
    x: number;
    y: number;
  } {
    const bounds = getImageBounds();
    return {
      x: Math.min(Math.max(clientX, bounds.x), bounds.x + bounds.width),
      y: Math.min(Math.max(clientY, bounds.y), bounds.y + bounds.height),
    };
  }

  const dim = document.createElement('div');
  dim.className = 'snapscreen-dim';

  const selection = document.createElement('div');
  selection.className = 'snapscreen-selection';
  selection.hidden = true;

  const hint = document.createElement('div');
  hint.id = HINT_ID;
  hint.className = 'snapscreen-hint';
  hint.textContent = SNIP_INSTRUCTION;

  const sizeBadge = document.createElement('div');
  sizeBadge.className = 'snapscreen-size-badge';
  sizeBadge.hidden = true;

  const liveStatus = document.createElement('div');
  liveStatus.className = 'snapscreen-sr-only';
  liveStatus.setAttribute('role', 'status');
  liveStatus.setAttribute('aria-live', 'polite');

  root.append(frozenPage, dim, selection, sizeBadge, hint, liveStatus);
  uiRoot.append(root);

  let startX = 0;
  let startY = 0;
  let currentX = 0;
  let currentY = 0;
  let dragging = false;
  let activePointerId: number | null = null;
  let keyboardRect: Rect | null = null;
  let escapePressed = false;
  let active = true;
  let firstPaintFrame: number | null = null;
  let secondPaintFrame: number | null = null;
  let lastImageBounds = getImageBounds();

  function describeSelection(rect: Rect): string {
    return `Selection at ${Math.round(rect.x)}, ${Math.round(rect.y)}, `
      + `${Math.round(rect.width)} by ${Math.round(rect.height)} pixels.`;
  }

  function updateSelection(rect: Rect, keyboard = false): void {
    const { x, y, width, height } = rect;
    selection.hidden = false;
    selection.classList.toggle('snapscreen-selection-keyboard', keyboard);
    selection.style.left = `${x}px`;
    selection.style.top = `${y}px`;
    selection.style.width = `${width}px`;
    selection.style.height = `${height}px`;

    sizeBadge.hidden = false;
    sizeBadge.textContent = `${Math.round(width)} × ${Math.round(height)}`;
    sizeBadge.style.left = `${Math.max(0, Math.min(x + width + 8, window.innerWidth - 90))}px`;
    sizeBadge.style.top = `${Math.max(0, Math.min(y + height + 8, window.innerHeight - 30))}px`;

    if (keyboard) liveStatus.textContent = describeSelection(rect);
  }

  function completeSelection(rect: Rect): void {
    if (escapePressed) return;
    if (rect.width < MIN_CROP_SIZE || rect.height < MIN_CROP_SIZE) {
      cancel();
      return;
    }

    const completedSelection = createCaptureSelection(rect, getImageBounds());
    teardown(false);
    firstPaintFrame = requestAnimationFrame(() => {
      firstPaintFrame = null;
      secondPaintFrame = requestAnimationFrame(() => {
        secondPaintFrame = null;
        if (!active) return;
        active = false;
        if (disposeActiveOverlay === dispose) disposeActiveOverlay = null;
        options.onRegionSelected(completedSelection);
      });
    });
  }

  function rectFromPointer(): Rect {
    return {
      x: Math.min(startX, currentX),
      y: Math.min(startY, currentY),
      width: Math.abs(currentX - startX),
      height: Math.abs(currentY - startY),
    };
  }

  function onPointerDown(e: PointerEvent): void {
    if (e.button !== 0 || activePointerId !== null) return;
    dragging = true;
    activePointerId = e.pointerId;
    keyboardRect = null;
    selection.classList.remove('snapscreen-selection-keyboard');
    const start = clampPointerToImage(e.clientX, e.clientY);
    startX = start.x;
    startY = start.y;
    currentX = start.x;
    currentY = start.y;
    updateSelection({ x: startX, y: startY, width: 0, height: 0 });
    root.setPointerCapture?.(e.pointerId);
    e.preventDefault();
  }

  function onPointerMove(e: PointerEvent): void {
    if (!dragging || e.pointerId !== activePointerId) return;
    const pointer = clampPointerToImage(e.clientX, e.clientY);
    currentX = pointer.x;
    currentY = pointer.y;
    updateSelection(rectFromPointer());
  }

  function cancel(): void {
    if (!active || escapePressed) return;
    teardown(true);
    options.onCancelled();
  }

  function onPointerUp(e: PointerEvent): void {
    if (!dragging || e.pointerId !== activePointerId) return;
    dragging = false;

    const pointer = clampPointerToImage(e.clientX, e.clientY);
    currentX = pointer.x;
    currentY = pointer.y;
    if (root.hasPointerCapture?.(e.pointerId)) {
      root.releasePointerCapture?.(e.pointerId);
    }
    activePointerId = null;
    completeSelection(rectFromPointer());
  }

  function onPointerCancel(e: PointerEvent): void {
    if (e.pointerId !== activePointerId) return;
    dragging = false;
    activePointerId = null;
    cancel();
  }

  function consumeKeyboardEvent(e: KeyboardEvent): void {
    e.preventDefault();
    e.stopImmediatePropagation();
  }

  function onKeyDown(e: KeyboardEvent): void {
    if (e.key === 'Tab') {
      consumeKeyboardEvent(e);
      root.focus({ preventScroll: true });
      return;
    }
    if (e.key === 'Escape') {
      consumeKeyboardEvent(e);
      // Keep the focused iframe alive until keyup, or the release can reach
      // the host page after cancellation removes the frame.
      escapePressed = true;
      return;
    }
    if (escapePressed) {
      consumeKeyboardEvent(e);
      return;
    }
    if (dragging) return;

    if (e.key === 'Enter') {
      consumeKeyboardEvent(e);
      if (e.repeat) return;
      if (!keyboardRect) {
        const bounds = getImageBounds();
        const localRect = createKeyboardCrop(bounds);
        keyboardRect = localRect
          ? { ...localRect, x: localRect.x + bounds.x, y: localRect.y + bounds.y }
          : null;
        if (keyboardRect) updateSelection(keyboardRect, true);
        return;
      }
      completeSelection(keyboardRect);
      return;
    }

    if (
      e.key !== 'ArrowLeft'
      && e.key !== 'ArrowRight'
      && e.key !== 'ArrowUp'
      && e.key !== 'ArrowDown'
    ) {
      return;
    }

    consumeKeyboardEvent(e);
    if (!keyboardRect) return;
    const bounds = getImageBounds();
    const localRect = {
      ...keyboardRect,
      x: keyboardRect.x - bounds.x,
      y: keyboardRect.y - bounds.y,
    };
    const adjusted = adjustKeyboardCrop(
      localRect,
      e.key,
      e.shiftKey,
      bounds,
    );
    keyboardRect = adjusted
      ? { ...adjusted, x: adjusted.x + bounds.x, y: adjusted.y + bounds.y }
      : null;
    if (keyboardRect) updateSelection(keyboardRect, true);
  }

  function onKeyUp(e: KeyboardEvent): void {
    if (e.key !== 'Escape') return;
    consumeKeyboardEvent(e);
    if (!escapePressed) return;
    escapePressed = false;
    cancel();
  }

  function onResize(): void {
    const previousBounds = lastImageBounds;
    const bounds = getImageBounds();
    lastImageBounds = bounds;
    if (dragging) {
      const start = clampPointerToImage(startX, startY);
      const current = clampPointerToImage(currentX, currentY);
      startX = start.x;
      startY = start.y;
      currentX = current.x;
      currentY = current.y;
      updateSelection(rectFromPointer());
    }
    if (!keyboardRect) return;
    const normalized = createCaptureSelection(keyboardRect, previousBounds).normalizedRect;
    const resizedRect = denormalizeRect(normalized, bounds);
    const localRect = {
      ...resizedRect,
      x: resizedRect.x - bounds.x,
      y: resizedRect.y - bounds.y,
    };
    const clamped = clampKeyboardCrop(localRect, bounds);
    keyboardRect = clamped
      ? { ...clamped, x: clamped.x + bounds.x, y: clamped.y + bounds.y }
      : null;
    if (keyboardRect) {
      updateSelection(keyboardRect, true);
    } else {
      selection.hidden = true;
      sizeBadge.hidden = true;
    }
  }

  function teardown(cancelPendingSelection: boolean): void {
    root.removeEventListener('pointerdown', onPointerDown);
    root.removeEventListener('pointermove', onPointerMove);
    root.removeEventListener('pointerup', onPointerUp);
    root.removeEventListener('pointercancel', onPointerCancel);
    root.removeEventListener('keydown', onKeyDown);
    root.removeEventListener('keyup', onKeyUp);
    window.removeEventListener('resize', onResize);
    root.style.display = 'none';
    root.remove();
    removeUiHostIfEmpty();

    if (cancelPendingSelection) {
      active = false;
      if (firstPaintFrame !== null) cancelAnimationFrame(firstPaintFrame);
      if (secondPaintFrame !== null) cancelAnimationFrame(secondPaintFrame);
      firstPaintFrame = null;
      secondPaintFrame = null;
      if (disposeActiveOverlay === dispose) disposeActiveOverlay = null;
    }
  }

  function dispose(): void {
    if (!active) return;
    teardown(true);
  }

  root.addEventListener('pointerdown', onPointerDown);
  root.addEventListener('pointermove', onPointerMove);
  root.addEventListener('pointerup', onPointerUp);
  root.addEventListener('pointercancel', onPointerCancel);
  root.addEventListener('keydown', onKeyDown);
  root.addEventListener('keyup', onKeyUp);
  window.addEventListener('resize', onResize);
  frozenPage.addEventListener('load', onResize);
  root.focus({ preventScroll: true });

  disposeActiveOverlay = dispose;
  return dispose;
}

export function disposeSnipOverlay(): void {
  disposeActiveOverlay?.();
  disposeActiveOverlay = null;
  queryUiElement(`#${ROOT_ID}`)?.remove();
  removeUiHostIfEmpty();
}
