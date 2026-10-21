import { useEffect } from 'react';
// UI-13: responsive/mobile primitives shared across the shell.
// Breakpoints (approx, per arch doc §6D): <768px mobile, 768–1024px tablet,
// >1024px desktop. The desktop "two panes side-by-side" collapses to mobile
// screens/sheets: sidebar = off-canvas drawer; main = full-width; a bottom tab
// bar with a command-palette center button replaces sidebar chrome; the right
// inspector becomes a bottom sheet; chain list/detail become a drill-down.

// UI-13: the breakpoint primitives now live in `@ui/hooks/useViewport` — `@ui`'s own
// responsive components (DataList, BulkActionBar) need them, and an `@ui` component
// importing from this app-level module would invert the layering and close an import
// cycle. Re-exported here so every existing call site keeps importing them from
// `shell/responsive` unchanged, with one implementation behind both paths.
export {
  MOBILE_MAX,
  TABLET_MAX,
  TAILWIND_SM_MIN,
  useViewport,
  useIsMobile,
  useIsBelowTailwindSm,
  TOUCH_TARGET_CLASS,
} from '@ui/hooks/useViewport';
export type { Viewport } from '@ui/hooks/useViewport';

/**
 * `--ui-bottom-chrome` — how much persistent chrome the app keeps pinned to the
 * bottom edge. Published on the document root from the tab bar's REAL measured
 * height (padding and safe-area inset included), so anything that docks at the
 * bottom — `@ui`'s `BulkActionBar`, today — can sit above it instead of under it.
 *
 * It lives here rather than in `AppShell` because the bar itself is the thing whose
 * height it reports, and it is a CSS variable rather than a prop because `@ui`
 * components must not import the shell and no page should have to remember to pass
 * a shell measurement down. Cleared on unmount: when the tab bar is gone (desktop,
 * or a chrome-suppressed route) the variable is absent and consumers fall back to 0.
 */
export function useBottomChromeVar(ref: { current: HTMLElement | null }) {
  useEffect(() => {
    const node = ref.current;
    if (!node || typeof window === 'undefined') return undefined;
    const root = document.documentElement;
    const publish = () => {
      // offsetHeight, not the transform-aware bounding box: the bar is translated
      // out of view while scrolling (`scrollChromeSuppressed`) but still occupies
      // the same space the moment it comes back, and a bar that re-docked under the
      // tab bar on every scroll would be worse than one that never moved.
      root.style.setProperty('--ui-bottom-chrome', `${node.offsetHeight}px`);
    };
    publish();
    const observer = new ResizeObserver(publish);
    observer.observe(node);
    return () => {
      observer.disconnect();
      root.style.removeProperty('--ui-bottom-chrome');
    };
  }, [ref]);
}
