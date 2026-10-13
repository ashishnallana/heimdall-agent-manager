import { SplitDirection } from './types';

export interface OverlayPosition {
  top: number;
  left: number;
  width: number;
  height: number;
}

export interface RectLike {
  left: number;
  top: number;
  width: number;
  height: number;
  right?: number;
  bottom?: number;
}

export const PANE_SELECTOR = '[data-pane-id]';

export interface PaneTarget {
  paneId: string;
  direction: SplitDirection;
  rect: DOMRect;
}

/**
 * Finds the first HTMLElement matching `selector` whose bounding client rect
 * contains `(x, y)` and whose computed `pointerEvents` is not `'none'`.
 */
export function rectHitTest(
  selector: string,
  x: number,
  y: number,
): HTMLElement | null {
  if (typeof document === 'undefined') return null;
  const els = document.querySelectorAll<HTMLElement>(selector);
  for (const el of Array.from(els)) {
    const r = el.getBoundingClientRect();
    const right = typeof r.right === 'number' ? r.right : r.left + r.width;
    const bottom = typeof r.bottom === 'number' ? r.bottom : r.top + r.height;
    const pointerEvents =
      typeof window !== 'undefined' && typeof window.getComputedStyle === 'function'
        ? window.getComputedStyle(el).pointerEvents
        : el.style?.pointerEvents;
    if (
      r.width > 0 &&
      r.height > 0 &&
      x >= r.left &&
      x <= right &&
      y >= r.top &&
      y <= bottom &&
      pointerEvents !== 'none'
    ) {
      return el;
    }
  }
  return null;
}

/**
 * Resolves the pane under `(x, y)` and the 4-quadrant split direction for that point.
 */
export function resolvePaneTarget(
  x: number,
  y: number,
  selector: string = PANE_SELECTOR,
): PaneTarget | null {
  const pane = rectHitTest(selector, x, y);
  if (!pane) return null;
  const paneId =
    pane.getAttribute('data-pane-id') ||
    pane.getAttribute('data-window-pane-id') ||
    pane.dataset?.paneId ||
    pane.dataset?.windowPaneId;
  if (!paneId) return null;
  const rect = pane.getBoundingClientRect();
  return {
    paneId,
    direction: getSplitDirection(rect, { x, y }),
    rect,
  };
}

/**
 * Determines the 4-quadrant split direction ('top' | 'bottom' | 'left' | 'right')
 * based on pointer coordinates relative to the target element's bounding box.
 */
export function getSplitDirection(
  targetElementRect: RectLike,
  mousePosition: { x: number; y: number },
): SplitDirection {
  const width = targetElementRect.width || 1;
  const height = targetElementRect.height || 1;
  const centerX = targetElementRect.left + width / 2;
  const centerY = targetElementRect.top + height / 2;

  const deltaX = mousePosition.x - centerX;
  const deltaY = mousePosition.y - centerY;

  const xRatio = Math.abs(deltaX) / (width / 2);
  const yRatio = Math.abs(deltaY) / (height / 2);

  if (xRatio > yRatio) {
    return deltaX > 0 ? 'right' : 'left';
  }
  return deltaY > 0 ? 'bottom' : 'top';
}

/**
 * Computes the half-pane highlight overlay rectangle for a target pane rect and split direction.
 */
export function getOverlayPosition(
  targetElementRect: RectLike,
  splitDirection: SplitDirection,
): OverlayPosition {
  const width = Math.max(0, targetElementRect.width);
  const height = Math.max(0, targetElementRect.height);
  switch (splitDirection) {
    case 'top':
      return {
        top: 0,
        left: 0,
        width,
        height: Math.floor(height / 2),
      };
    case 'bottom':
      return {
        top: Math.floor(height / 2),
        left: 0,
        width,
        height: Math.floor(height / 2),
      };
    case 'left':
      return {
        top: 0,
        left: 0,
        width: Math.floor(width / 2),
        height,
      };
    case 'right':
    default:
      return {
        top: 0,
        left: Math.floor(width / 2),
        width: Math.floor(width / 2),
        height,
      };
  }
}
