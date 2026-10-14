import React, { useCallback, useEffect, useRef } from 'react';
import { Icon } from '@ui';
import type { PaneTreeState, RenderPaneProps } from '../../tiling/types';
import { getContentPaneIds } from '../../tiling/paneTreeState';
import { useMobileSwipe } from '../mobileSwipe';

/**
 * Mobile Main layout: every Main pane (in tree order) becomes a full-width page
 * of a horizontal, scroll-snapping pager. Splits are not shown; "New Pane"
 * appends a page. The focused pane is scrolled into view, and swiping to a page
 * focuses it.
 */
export function MobileMainPager<T>({
  tree,
  renderPane,
  onFocusPane,
  onSwipeLeftBoundary,
  onSwipeRightBoundary,
}: {
  tree: PaneTreeState<T>;
  renderPane: (props: RenderPaneProps<T>) => React.ReactNode;
  onFocusPane: (paneId: string) => void;
  /** Physical left swipe after the final Main page. */
  onSwipeLeftBoundary?: () => void;
  /** Physical right swipe before the first Main page. */
  onSwipeRightBoundary?: () => void;
}) {
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const paneIds = getContentPaneIds(tree);
  const focusedPaneId = tree.focusedPaneId;
  const focusedIndex = Math.max(0, paneIds.indexOf(focusedPaneId));
  const paneKey = paneIds.join('|');

  useEffect(() => {
    const el = scrollRef.current;
    if (!el || el.clientWidth === 0) return;
    const currentIndex = Math.round(el.scrollLeft / el.clientWidth);
    if (currentIndex !== focusedIndex) {
      el.scrollTo({ left: focusedIndex * el.clientWidth, behavior: 'smooth' });
    }
  }, [focusedIndex, paneKey]);

  const settleTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(
    () => () => {
      if (settleTimer.current) clearTimeout(settleTimer.current);
    },
    [],
  );
  const handleScroll = useCallback(() => {
    if (settleTimer.current) clearTimeout(settleTimer.current);
    settleTimer.current = setTimeout(() => {
      const el = scrollRef.current;
      if (!el || el.clientWidth === 0) return;
      const index = Math.round(el.scrollLeft / el.clientWidth);
      const paneId = paneIds[index];
      if (paneId && paneId !== focusedPaneId) onFocusPane(paneId);
    }, 120);
  }, [focusedPaneId, onFocusPane, paneIds]);

  const isSinglePane = paneIds.length <= 1;
  const canSwipeLeftBoundary = useCallback(() => {
    const element = scrollRef.current;
    return Boolean(element && element.scrollWidth - element.clientWidth - element.scrollLeft <= 2);
  }, []);
  const canSwipeRightBoundary = useCallback(() => {
    const element = scrollRef.current;
    return Boolean(element && element.scrollLeft <= 2);
  }, []);
  const swipeHandlers = useMobileSwipe({
    enabled: true,
    onSwipeLeft: onSwipeLeftBoundary,
    onSwipeRight: onSwipeRightBoundary,
    canSwipeLeft: canSwipeLeftBoundary,
    canSwipeRight: canSwipeRightBoundary,
  });
  const isFirstPage = focusedIndex === 0;
  const isLastPage = focusedIndex === paneIds.length - 1;

  return (
    <div className="relative flex h-full min-h-0 w-full flex-1 flex-col">
      <div
        ref={scrollRef}
        data-debug-id="workspace-mobile-pager"
        onScroll={handleScroll}
        {...swipeHandlers}
        className="no-scrollbar flex h-full min-h-0 w-full flex-1 snap-x snap-mandatory overflow-x-auto overflow-y-hidden overscroll-x-contain"
      >
        {paneIds.map((paneId) => {
          const pane = tree.panes[paneId];
          if (!pane || pane.kind !== 'content') return null;
          return (
            <div
              key={paneId}
              data-main-pane-id={paneId}
              data-debug-id={`workspace-mobile-page-${paneId}`}
              className="flex h-full min-h-0 w-full min-w-full shrink-0 snap-start snap-always flex-col overflow-hidden"
            >
              {renderPane({
                paneId,
                value: pane.value,
                isFocused: paneId === focusedPaneId,
                isMaximized: false,
                isSinglePane,
                // Every page is full width: it is both the top-left and top-right pane.
                isTopLeftMost: true,
                isTopRightMost: true,
              })}
            </div>
          );
        })}
      </div>
      <div
        data-debug-id="workspace-mobile-swipe-indicators"
        aria-hidden="true"
        className="pointer-events-none absolute inset-x-0 z-30 flex items-center justify-center gap-1.5 px-3"
        style={{ bottom: 'max(0.25rem, env(safe-area-inset-bottom))' }}
      >
        {isLastPage && onSwipeLeftBoundary ? (
          <span
            data-debug-id="workspace-mobile-open-nav-indicator"
            className="absolute left-3 inline-flex h-6 items-center gap-0.5 rounded-full border border-subtle bg-surface-overlay/90 px-1.5 text-muted shadow-sm backdrop-blur"
          >
            <Icon name="chevron-left" size={11} />
            <Icon name="panel-left" size={13} />
          </span>
        ) : null}
        {!isSinglePane ? paneIds.map((paneId, i) => (
          <span
            key={paneId}
            className={`h-1.5 rounded-full transition-all ${
              i === focusedIndex ? 'w-4 bg-accent' : 'w-1.5 bg-current text-muted opacity-40'
            }`}
          />
        )) : <span className="h-1.5 w-4 rounded-full bg-accent" />}
        {isFirstPage && onSwipeRightBoundary ? (
          <span
            data-debug-id="workspace-mobile-open-aux-indicator"
            className="absolute right-3 inline-flex h-6 items-center gap-0.5 rounded-full border border-subtle bg-surface-overlay/90 px-1.5 text-muted shadow-sm backdrop-blur"
          >
            <Icon name="panel-right" size={13} />
            <Icon name="chevron-right" size={11} />
          </span>
        ) : null}
      </div>
    </div>
  );
}

export default MobileMainPager;
