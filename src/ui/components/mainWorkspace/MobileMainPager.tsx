import React, { useCallback, useEffect, useRef } from 'react';
import { PaneVisibilityProvider } from '../workbench/paneVisibility';
import type { PaneTreeState, RenderPaneProps } from '../../tiling/types';
import { getContentPaneIds } from '../../tiling/paneTreeState';
import { useMobileSwipe } from '../mobileSwipe';
import { MobileSwipeDots } from '../MobileSwipeDots';

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
  totalPageCount,
}: {
  tree: PaneTreeState<T>;
  renderPane: (props: RenderPaneProps<T>) => React.ReactNode;
  onFocusPane: (paneId: string) => void;
  /** Physical left swipe after the final Main page. */
  onSwipeLeftBoundary?: () => void;
  /** Physical right swipe before the first Main page. */
  onSwipeRightBoundary?: () => void;
  /** Main pages plus the reachable aux-tab/New Tab pages to their right. */
  totalPageCount: number;
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
  return (
    <div className="flex h-full min-h-0 w-full flex-1 flex-col">
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
              <PaneVisibilityProvider visible={paneId === paneIds[focusedIndex]}>
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
              </PaneVisibilityProvider>
            </div>
          );
        })}
      </div>
      <MobileSwipeDots
        total={totalPageCount}
        activeIndex={focusedIndex}
        debugId="workspace-mobile-swipe-indicators"
      />
    </div>
  );
}

export default MobileMainPager;
