/**
 * IconWell — a glyph on a rounded, tinted square.
 * ------------------------------------------------------------------
 * Purpose: the leading "well" in picker rows (the launcher mode menu's
 * `chat`/`terminal` rows, 32px) and the hero mark of empty or blocked states
 * (56px, e.g. a warning-tint well above "No bridge is online"). DESIGN.md:
 * each status tone has a `-tint` ground "for badges and icon wells"; pair the
 * tint with its own colour as the glyph colour.
 *
 * NOT for: a clickable control (`IconButton`), a status (`StatusPill`), or a
 * person (`Avatar`). The well is decorative, so it is `aria-hidden`; the row or
 * heading next to it carries the meaning.
 *
 * Tokens only: `tone` resolves to the soft tint + tone text (neutral = the
 * neutral tint with muted text); sizes map to fixed radius tokens.
 */
import React from 'react';
import type { RootClassNameProps, Tone } from '../types';
import { Icon, type IconName } from './Icon';

export type IconWellSize = 'md' | 'lg';

const SIZE: Record<IconWellSize, { box: string; icon: 'md' | 'xl' }> = {
  // Picker row well (reference `.well`): 32px, radius-md, 16px glyph.
  md: { box: 'h-8 w-8 rounded-[var(--radius-md)]', icon: 'md' },
  // Empty-state well (reference `.well-lg`): 56px, radius-lg, 24px glyph.
  lg: { box: 'h-14 w-14 rounded-[var(--radius-lg)]', icon: 'xl' },
};

const TONE: Record<Tone, string> = {
  neutral: 'bg-neutral-soft text-muted',
  info: 'bg-info-soft text-info',
  success: 'bg-success-soft text-success',
  warning: 'bg-warning-soft text-warning',
  danger: 'bg-danger-soft text-danger',
  pending: 'bg-info-soft text-info',
};

export interface IconWellProps
  extends Omit<React.HTMLAttributes<HTMLSpanElement>, 'className' | 'children'>,
    RootClassNameProps {
  /** Glyph from `Icon`. */
  icon: IconName;
  /** Default `md` (32px). */
  size?: IconWellSize;
  /** Default `neutral`. */
  tone?: Tone;
}

export const IconWell = React.forwardRef<HTMLSpanElement, IconWellProps>(function IconWell(
  { icon, size = 'md', tone = 'neutral', className, ...rest },
  ref,
) {
  const s = SIZE[size];
  return (
    <span
      ref={ref}
      aria-hidden="true"
      data-icon-well={size}
      className={['inline-flex flex-none items-center justify-center', s.box, TONE[tone], className ?? ''].filter(Boolean).join(' ')}
      {...rest}
    >
      <Icon name={icon} size={s.icon} />
    </span>
  );
});

export default IconWell;
