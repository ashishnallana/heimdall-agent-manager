/**
 * Badge — compact, inert status/metadata.
 * ------------------------------------------------------------------
 * Purpose: the small pill for a count, tag, or metadata label (EL-047/049/054).
 * It is the canonical home for the neutral count/tag pill that was duplicated
 * across the Memory pages, now with a semantic `tone` + `emphasis` so
 * the ~10 ad-hoc dot colors and the `/10`,`/15`,`/20` opacity forks collapse into
 * one token-driven control.
 *
 * NOT for: a semantic STATE with a label that a user acts on / reads as status
 * (use `StatusPill`), a liveness dot (`StatusDot`), or anything clickable (that
 * is a `Button`/`IconButton`). Badge is decorative/inert — it carries no role and
 * no interaction.
 *
 * Layer: primitive. Spec: `docs/ui-audit/04-component-catalogue.md` › Badge · StatusPill · StatusDot.
 * Prop names follow the shared vocabulary in `../types` (`tone`, `emphasis`,
 * `className`). Native `<span>` attributes (`title`, `data-*`, `id`, …) pass
 * through via `rest`.
 *
 * Accessibility: a decorative badge is inert — it adds no ARIA. If the count/tag
 * conveys meaning not already in the surrounding text, the caller supplies that
 * text (a Badge is not a substitute for a visible/【SR】label).
 *
 * Tokens only: `tone` + `emphasis` resolve to the semantic color tokens and the
 * soft-tint tokens (`--color-*-soft`) added for this exact purpose. No raw hex,
 * px, or `/opacity` forks.
 *
 * Escape hatch: `className` merges onto the root `<span>` — an escape hatch with
 * a cost, not a styling API.
 */
import React from 'react';
import type { Emphasis, RootClassNameProps, Tone } from '../types';
import { toneClasses } from './toneStyles';

const BASE =
  'inline-flex items-center gap-1 rounded-[var(--radius-sm)] px-2 py-0.5 ' +
  'text-[length:var(--text-caption-size)] font-medium leading-none whitespace-nowrap';

export interface BadgeProps
  extends Omit<React.HTMLAttributes<HTMLSpanElement>, 'className'>,
    RootClassNameProps {
  /** Semantic intent. Default `neutral`. */
  tone?: Tone;
  /** How strongly the tone is painted. Default `soft`. */
  emphasis?: Emphasis;
  children?: React.ReactNode;
}

export const Badge = React.forwardRef<HTMLSpanElement, BadgeProps>(function Badge(
  { tone = 'neutral', emphasis = 'soft', className, children, ...rest },
  ref,
) {
  const rootClassName = [BASE, toneClasses(tone, emphasis), className ?? '']
    .filter(Boolean)
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();

  return (
    <span ref={ref} className={rootClassName} {...rest}>
      {children}
    </span>
  );
});

export default Badge;
