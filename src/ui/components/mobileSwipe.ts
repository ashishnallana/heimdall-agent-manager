import { useCallback, useRef, type TouchEventHandler } from 'react';

const EXCLUDED_SWIPE_ORIGINS = [
  'a[href]',
  'button',
  'input',
  'select',
  'textarea',
  'iframe',
  '[contenteditable="true"]',
  '[data-mobile-swipe-ignore="true"]',
  '[role="slider"]',
  '[role="textbox"]',
  '.monaco-editor',
  '.xterm',
].join(',');

const MIN_SWIPE_DISTANCE = 56;
const AXIS_INTENT_RATIO = 1.35;
const INTENT_SLOP = 10;

type Gesture = {
  identifier: number;
  startX: number;
  startY: number;
  currentX: number;
  currentY: number;
  allowLeft: boolean;
  allowRight: boolean;
};

function hasHorizontalScroller(target: Element, boundary: Element): boolean {
  let element: Element | null = target;
  while (element && element !== boundary) {
    if (element instanceof HTMLElement && element.scrollWidth > element.clientWidth + 4) {
      const overflowX = window.getComputedStyle(element).overflowX;
      if (overflowX === 'auto' || overflowX === 'scroll' || overflowX === 'overlay') return true;
    }
    element = element.parentElement;
  }
  return false;
}

function isExcludedOrigin(target: EventTarget | null, boundary: Element): boolean {
  if (!(target instanceof Element)) return true;
  const excluded = target.closest(EXCLUDED_SWIPE_ORIGINS);
  if (excluded && excluded !== boundary && boundary.contains(excluded)) return true;
  return hasHorizontalScroller(target, boundary);
}

function findTouch(touches: React.TouchList, identifier: number): React.Touch | null {
  for (let index = 0; index < touches.length; index += 1) {
    const touch = touches.item(index);
    if (touch?.identifier === identifier) return touch;
  }
  return null;
}

export interface MobileSwipeHandlers {
  onTouchStartCapture: TouchEventHandler<HTMLElement>;
  onTouchMoveCapture: TouchEventHandler<HTMLElement>;
  onTouchEndCapture: TouchEventHandler<HTMLElement>;
  onTouchCancelCapture: TouchEventHandler<HTMLElement>;
}

/**
 * Recognises one deliberate, touch-only horizontal swipe without preventing the
 * browser's native scrolling. Interactive controls, embedded terminals/editors,
 * iframes and nested horizontal scrollers retain their own gestures.
 */
export function useMobileSwipe({
  enabled,
  onSwipeLeft,
  onSwipeRight,
  canSwipeLeft,
  canSwipeRight,
}: {
  enabled: boolean;
  onSwipeLeft?: () => void;
  onSwipeRight?: () => void;
  /** Evaluated at touch start so reaching a boundary cannot trigger it in the same swipe. */
  canSwipeLeft?: () => boolean;
  canSwipeRight?: () => boolean;
}): MobileSwipeHandlers {
  const gestureRef = useRef<Gesture | null>(null);

  const onTouchStartCapture = useCallback<TouchEventHandler<HTMLElement>>(
    (event) => {
      gestureRef.current = null;
      if (!enabled || event.touches.length !== 1 || isExcludedOrigin(event.target, event.currentTarget)) return;
      const touch = event.touches.item(0);
      if (!touch) return;
      gestureRef.current = {
        identifier: touch.identifier,
        startX: touch.clientX,
        startY: touch.clientY,
        currentX: touch.clientX,
        currentY: touch.clientY,
        allowLeft: canSwipeLeft?.() ?? true,
        allowRight: canSwipeRight?.() ?? true,
      };
    },
    [canSwipeLeft, canSwipeRight, enabled],
  );

  const onTouchMoveCapture = useCallback<TouchEventHandler<HTMLElement>>((event) => {
    const gesture = gestureRef.current;
    if (!gesture || event.touches.length !== 1) {
      gestureRef.current = null;
      return;
    }
    const touch = findTouch(event.touches, gesture.identifier);
    if (!touch) {
      gestureRef.current = null;
      return;
    }
    gesture.currentX = touch.clientX;
    gesture.currentY = touch.clientY;
    const deltaX = Math.abs(gesture.currentX - gesture.startX);
    const deltaY = Math.abs(gesture.currentY - gesture.startY);
    if (deltaY >= INTENT_SLOP && deltaY > deltaX * AXIS_INTENT_RATIO) gestureRef.current = null;
  }, []);

  const onTouchEndCapture = useCallback<TouchEventHandler<HTMLElement>>(
    (event) => {
      const gesture = gestureRef.current;
      gestureRef.current = null;
      if (!gesture) return;
      const touch = findTouch(event.changedTouches, gesture.identifier);
      const endX = touch?.clientX ?? gesture.currentX;
      const endY = touch?.clientY ?? gesture.currentY;
      const deltaX = endX - gesture.startX;
      const deltaY = endY - gesture.startY;
      if (Math.abs(deltaX) < MIN_SWIPE_DISTANCE) return;
      if (Math.abs(deltaX) < Math.abs(deltaY) * AXIS_INTENT_RATIO) return;
      if (deltaX < 0 && gesture.allowLeft) onSwipeLeft?.();
      else if (deltaX > 0 && gesture.allowRight) onSwipeRight?.();
    },
    [onSwipeLeft, onSwipeRight],
  );

  const onTouchCancelCapture = useCallback<TouchEventHandler<HTMLElement>>(() => {
    gestureRef.current = null;
  }, []);

  return { onTouchStartCapture, onTouchMoveCapture, onTouchEndCapture, onTouchCancelCapture };
}
