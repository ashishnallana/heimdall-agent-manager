/**
 * BulkActionBar — the selection bar for a multi-select list.
 * ------------------------------------------------------------------
 * Purpose: REQ-UI-7's bulk destructive action, reachable on every viewport. Docked to
 * the bottom edge, clear of any persistent bottom chrome via `--ui-bottom-chrome` and
 * clear of any PERSISTENT bottom chrome by `--ui-bottom-chrome`. It carries the
 * count, the verbs and Cancel — nothing else.
 *
 * **Why fixed on desktop too, rather than `sticky bottom-0`.** Sticky was the
 * original desktop treatment and it never worked: the bar is the last child of the
 * list column, so its containing block ENDS where the bar ends and sticky has zero
 * travel to move it within. The bar therefore rendered at its static position — the
 * bottom of a long list, far below the fold — so on desktop you ticked a row and the
 * verbs appeared somewhere off screen. Measured through the live app: Projects put
 * the bar at y=1084 in an 814px viewport, Memory at y=7050. Type-clean, invisible in
 * a short list, and caught only by measuring the bar's rect after a real click
 * (predicate "bulk bar sits above the bottom chrome"). Fixed positioning has no such dependency on an ancestor's height.
 *
 * Because a fixed bar is out of flow, the component also renders an in-flow SPACER
 * of its own measured height, so the last row of a list is never hidden underneath
 * the verbs that act on it.
 *
 * Bottom chrome (the app's mobile tab bar) — the bar docks above it, not under it.
 * The offset is read from the `--ui-bottom-chrome` CSS variable, which the app shell
 * publishes on the document root from the real measured height of its tab bar
 * (`shell/responsive.tsx` › `MobileTabBar`). It is the component's own responsibility
 * and no caller passes anything: a prop would have to be remembered by every list
 * page on all five resources, and the height is the SHELL's fact, not the page's.
 * Absent the variable the fallback is `0px`, so `@ui` keeps zero knowledge of the
 * shell and the bar still docks correctly in a bare host (Storybook, tests).
 * The software keyboard wins while it is open: it covers the tab bar too, so the bar sits
 * on the keyboard rather than stacking both insets. REQ-VIEWPORT-SWEEP-1: that is now true
 * because the offset says so (`--app-viewport-bottom-offset`); it was previously asserted
 * by a comment and was false, because this bar is portaled out of the shell and a fixed box
 * takes `bottom` from the layout viewport, which no keyboard shrinks.
 *
 * NOT for: per-row actions (they belong in the row), or a page-level toolbar.
 *
 * Layer: composite. Product-agnostic: the verbs are `children`, so the bar knows
 * nothing about what is being archived, rejected or killed.
 *
 * The count label is the part that must not drift, so it is built in rather than left
 * to each caller: **"12 selected (of the 50 loaded)"**. Never "of all", and never a
 * total — the list APIs are keyset-paged and return no count, so any total would be a
 * promise the API cannot keep. `loadedCount` is the rows currently in hand.
 *
 * Touch (REQ-UI-19): multi-select must be reachable without hover, so the entry point
 * ships with the bar as `BulkActionBar.SelectToggle` — the header button that turns
 * select mode on and off. Nothing anywhere is hover-revealed.
 *
 * Accessibility (built in): the bar is a labelled `role="region"` with
 * `aria-live="polite"` on the count, so a screen reader hears the selection change
 * without the bar stealing focus.
 *
 * Tokens only. Escape hatch: `className` merges onto the root.
 */
import React from 'react';
import ReactDOM from 'react-dom';
import { Button } from '../primitives/Button';
import { Text } from '../primitives/Text';
import { useIsMobile, TOUCH_TARGET_CLASS } from '../hooks/useViewport';
import type { ChangeHandler, RootClassNameProps } from '../types';

export interface BulkActionBarProps extends RootClassNameProps {
  /** How many rows are selected. The bar hides itself at 0 unless `open` is set. */
  selectedCount: number;
  /** How many rows are loaded — the honest denominator. */
  loadedCount: number;
  /** The verbs, as `Button`s. Rendered trailing on desktop, full-width-ish on mobile. */
  children?: React.ReactNode;
  /** Clears the selection (and leaves select mode). Required — there is always a way out. */
  onCancel: () => void;
  /** Force the bar visible at a zero count (e.g. the moment select mode is entered). */
  open?: boolean;
  /** Accessible name for the region. Default `'Bulk actions'`. */
  label?: string;
}

export interface BulkSelectToggleProps
  extends Omit<React.ButtonHTMLAttributes<HTMLButtonElement>, 'className' | 'children' | 'onChange'>,
    RootClassNameProps {
  /** Whether select mode is on. */
  active: boolean;
  /** Fired with the next select-mode state. */
  onChange: ChangeHandler<boolean>;
  /** Label when select mode is off. Default `'Select'`. */
  label?: string;
  /** Label when select mode is on. Default `'Done'`. */
  activeLabel?: string;
}

/**
 * The touch entry point into select mode. Lives in the page header next to the Add
 * button; it is a plain toggle button, not a hover affordance.
 */
const SelectToggle: React.FC<BulkSelectToggleProps> = ({
  active,
  onChange,
  label = 'Select',
  activeLabel = 'Done',
  className,
  ...rest
}) => (
  <Button
    variant={active ? 'primary' : 'secondary'}
    aria-pressed={active}
    onClick={() => onChange(!active)}
    className={[TOUCH_TARGET_CLASS, className].filter(Boolean).join(' ')}
    {...rest}
  >
    {active ? activeLabel : label}
  </Button>
);

interface BulkActionBarComponent extends React.FC<BulkActionBarProps> {
  SelectToggle: typeof SelectToggle;
}

const BulkActionBarBase: React.FC<BulkActionBarProps> = ({
  selectedCount,
  loadedCount,
  children,
  onCancel,
  open = false,
  label = 'Bulk actions',
  className,
}) => {
  const isMobile = useIsMobile();
  const barRef = React.useRef<HTMLDivElement | null>(null);
  const [barHeight, setBarHeight] = React.useState(0);

  // The spacer tracks the bar's REAL height rather than a guessed padding value —
  // the bar wraps its verbs at narrow widths, so its height is not a constant.
  React.useEffect(() => {
    const node = barRef.current;
    if (!node || typeof ResizeObserver === 'undefined') return undefined;
    const update = () => setBarHeight(node.offsetHeight);
    update();
    const observer = new ResizeObserver(update);
    observer.observe(node);
    return () => observer.disconnect();
  });

  if (selectedCount === 0 && !open) return null;

  // "12 selected (of the 50 loaded)" — the loaded count is all the API can honestly
  // supply, so the label says "loaded" rather than implying a total.
  const countLabel = `${selectedCount} selected (of the ${loadedCount} loaded)`;

  // Sit on whatever persistent bottom chrome the shell has declared.
  //
  // REQ-VIEWPORT-SWEEP-1 — THE COMMENT THAT USED TO BE HERE WAS FALSE, AND IT COST US.
  // It claimed: "the shell is sized from --app-viewport-height, so the visible region
  // already ends above the keyboard and a bar pinned to its bottom clears the keyboard
  // without measuring it." The first half is true and the conclusion does not follow. This
  // bar is PORTALED TO document.body (see below), so it is not inside the shell at all, and
  // a `position: fixed` box resolves `bottom` against the LAYOUT viewport regardless of any
  // ancestor. "Its bottom" was never the shell's bottom -- it was 812 while the visible
  // region ended at 409, putting the bar fully behind the keyboard.
  //
  // Own the consequence: REQ-KBD-3 deleted this component's keyboard branch partly on that
  // comment's reasoning. The deletion did not change behaviour (the branch was dead -- the
  // hook it depended on returned 0 forever), but we removed the code that pretended to
  // handle this while leaving a comment asserting it was handled. That is worse than a
  // stale comment: it is a comment that stops the next person from looking.
  //
  // The occluded height is an ADDEND, not an alternative: the keyboard covers the tab bar
  // too, so clear the keyboard first and then whatever chrome or safe area remains. Chrome
  // height and the device safe area stay alternatives to each other -- the tab bar already
  // sits inside the safe area -- so `max()` still picks whichever of those two is taller.
  // `--app-viewport-bottom-offset` is `0px` whenever nothing is occluding, so on desktop
  // this is exactly the expression it replaces.
  const bottomOffset =
    'calc(var(--app-viewport-bottom-offset, 0px) + max(var(--ui-bottom-chrome, 0px), env(safe-area-inset-bottom, 0px)))';

  const rootClassName = [
    'fixed inset-x-0 z-sticky flex items-center gap-3 border-t border-subtle bg-surface-raised px-4 py-3 shadow-panel',
    className,
  ]
    .filter(Boolean)
    .join(' ');

  // Portal the fixed overlay to document.body to escape any ancestor that
  // establishes a containing block (overflow scroll containers, transforms, etc.).
  // The spacer stays in-flow so the last list row is not hidden under the bar.
  const overlay = ReactDOM.createPortal(
    <div
      ref={barRef}
      role="region"
      aria-label={label}
      className={rootClassName}
      style={{ bottom: bottomOffset }}
    >
      <Text role="body-sm" tone="muted" aria-live="polite" className="min-w-0 flex-1 truncate">
        {countLabel}
      </Text>
      <div className="flex shrink-0 items-center gap-2">
        {children}
        <Button variant="ghost" onClick={onCancel} className={isMobile ? TOUCH_TARGET_CLASS : undefined}>
          Cancel
        </Button>
      </div>
    </div>,
    document.body,
  );

  return (
    <>
      {/* In-flow spacer: the bar is out of flow, and without this the last row of
          the list sits underneath the verbs that act on it. */}
      <div aria-hidden="true" style={{ height: barHeight }} />
      {overlay}
    </>
  );
};

export const BulkActionBar = BulkActionBarBase as BulkActionBarComponent;
BulkActionBar.SelectToggle = SelectToggle;

export default BulkActionBar;
