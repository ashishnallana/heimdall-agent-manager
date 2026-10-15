import React from 'react';

export interface MobileSwipeDotsProps {
  total: number;
  activeIndex: number;
  debugId: string;
}

/** Compact, non-interactive position indicator for the mobile swipe continuum. */
export function MobileSwipeDots({ total, activeIndex, debugId }: MobileSwipeDotsProps) {
  if (total <= 1) return null;
  const current = Math.min(total - 1, Math.max(0, activeIndex));
  return (
    <div
      data-debug-id={debugId}
      role="status"
      aria-label={`Swipe page ${current + 1} of ${total}`}
      className="pointer-events-none flex h-4 shrink-0 items-center justify-center overflow-hidden bg-canvas px-3"
    >
      <div className="no-scrollbar flex max-w-full items-center gap-1 overflow-x-auto" aria-hidden="true">
        {Array.from({ length: total }, (_, index) => (
          <span
            key={index}
            data-active={index === current ? 'true' : 'false'}
            className={`block shrink-0 rounded-full transition-[width,background-color] duration-150 ${
              index === current ? 'h-1.5 w-3 bg-accent' : 'h-1 w-1 bg-muted'
            }`}
          />
        ))}
      </div>
    </div>
  );
}

export default MobileSwipeDots;
