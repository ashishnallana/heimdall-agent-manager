/**
 * StatusDot — a liveness indicator dot.
 * ------------------------------------------------------------------
 * Purpose: the small colored dot that signals liveness/health — online, working,
 * offline (EL-050). It collapses the ~10 ad-hoc dot colors onto the 6-value
 * `tone` set and the hand-rolled pulse animations onto one reduced-motion-aware
 * `pulse`.
 *
 * NOT for: a labeled state (use `StatusPill`), a count/tag (`Badge`), or a
 * clickable control. A dot alone is color; where the state must also be read, put
 * a `StatusPill`/`Text` beside it (the `ConnectionBadge` pattern).
 *
 * Layer: primitive. Spec: `docs/ui-audit/04-component-catalogue.md` › Badge · StatusPill · StatusDot.
 * Prop names follow the shared vocabulary in `../types` (`tone`, `className`).
 *
 * Accessibility (built in, NOT optional): a dot is color-only, so `label` is
 * REQUIRED — it renders `role="img"` + `aria-label`, giving colorblind / screen-
 * reader users the state that sighted users read from the color (fixes the
 * status-color finding). The component cannot be built without a label.
 *
 * Motion: `pulse` animates only under `motion-safe` — users with
 * `prefers-reduced-motion` see a static dot.
 *
 * Tokens only: `tone` resolves to the semantic color tokens. `pending` shares the
 * info blue (queued / in flight), so warning keeps meaning "needs a person". No raw hex / px.
 *
 * Escape hatch: `className` merges onto the root `<span>`.
 */
import React from 'react';
import type { RootClassNameProps, Tone } from '../types';

/** Dot fill per tone (solid, saturated — a dot reads as a status light). */
const DOT_COLOR: Record<Tone, string> = {
  neutral: 'bg-muted',
  info: 'bg-info',
  success: 'bg-success',
  warning: 'bg-warning',
  danger: 'bg-danger',
  pending: 'bg-info',
};

/** Dot diameter per size. */
const DOT_SIZE: Record<'sm' | 'md', string> = {
  sm: 'h-1.5 w-1.5',
  md: 'h-2 w-2',
};

export interface StatusDotProps
  extends Omit<React.HTMLAttributes<HTMLSpanElement>, 'className' | 'aria-label'>,
    RootClassNameProps {
  /** Semantic state intent. Default `neutral`. */
  tone?: Tone;
  /** Accessible name (required) — the state a sighted user reads from the color. */
  label: string;
  /** Live/working pulse. Reduced-motion aware. Default `false`. */
  pulse?: boolean;
  /** Dot size. Default `md`. */
  size?: 'sm' | 'md';
}

export const StatusDot = React.forwardRef<HTMLSpanElement, StatusDotProps>(function StatusDot(
  { tone = 'neutral', label, pulse = false, size = 'md', className, ...rest },
  ref,
) {
  const color = DOT_COLOR[tone];
  const dim = DOT_SIZE[size];

  const rootClassName = ['relative inline-flex shrink-0', dim, className ?? '']
    .filter(Boolean)
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();

  return (
    <span ref={ref} role="img" aria-label={label} className={rootClassName} {...rest}>
      {pulse ? (
        <span
          aria-hidden="true"
          className={`absolute inset-0 rounded-full ${color} opacity-75 motion-safe:animate-ping`}
        />
      ) : null}
      <span aria-hidden="true" className={`relative inline-block rounded-full ${color} ${dim}`} />
    </span>
  );
});

export default StatusDot;
