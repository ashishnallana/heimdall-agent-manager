/**
 * Button — the one clickable action with a text label.
 * ------------------------------------------------------------------
 * Purpose: a single primitive for text actions, folding the ~8 inline
 * primary/secondary/ghost/danger button recipes scattered across the app (see
 * `docs/ui-audit/00-findings-memo.md` #1/#6) into four semantic `variant`s so
 * call sites state intent, not colour.
 *
 * NOT for: navigation-only controls (use a link/`<a>`) or icon-only actions
 * (that is a separate `IconButton` primitive). If none of the four variants fit,
 * you want a different component, not a fifth variant.
 *
 * Layer: primitive. Spec: `docs/ui-audit/04-component-catalogue.md` › Button.
 * Prop names follow the shared vocabulary in `../types` (`variant`, `size`,
 * `loading`, `width`, `leading`/`trailing`, `className`).
 *
 * Accessibility (built in, not a prop):
 *   - Renders a real `<button>`; Enter/Space activation is native.
 *   - `focus-visible` shows a token focus ring (`shadow-focus`) — never removed.
 *   - `loading` sets `aria-busy` and disables interaction while keeping the label.
 *   - The caller supplies the label text (native attrs like `aria-label`,
 *     `title`, `type`, `data-*`, `onClick` pass straight through via `rest`).
 *
 * Tokens only: colour/radius/spacing/type/motion all resolve to tokens
 * (`src/ui/tokens.css` / the Tailwind token aliases). No raw hex or px.
 *
 * Escape hatch: `className` merges onto the root only — an escape hatch with a
 * cost (it can break the token guarantees), not a styling API.
 */
import React from 'react';
import { Icon } from './Icon';
import type {
  ButtonVariant,
  ContentProps,
  DisableableProps,
  LoadableProps,
  RootClassNameProps,
  Size,
  Width,
} from '../types';

const BASE =
  'inline-flex items-center justify-center gap-1.5 rounded-[var(--radius-md)] font-semibold ' +
  'transition duration-fast focus-visible:outline-none focus-visible:shadow-focus ' +
  'disabled:opacity-50 disabled:cursor-not-allowed';

const VARIANT_CLASSES: Record<ButtonVariant, string> = {
  primary: 'bg-accent text-accent-fg hover:brightness-110',
  secondary: 'bg-strong text-primary hover:brightness-110',
  ghost: 'text-primary hover:bg-surface-raised',
  danger: 'bg-danger-soft text-danger hover:brightness-125',
};

/**
 * Semantic-color actions whose meaning the 4 variants don't carry (a green
 * "Approve", an amber "Nudge"/"Run", a soft-red "Request changes"). `tone` paints
 * a SOFT tinted button and overrides the variant's coloring; leave it unset for
 * ordinary actions. (Distinct from `variant="danger"`, the destructive
 * button — `tone="danger"` is the low-emphasis soft-red variant.)
 */
export type ButtonTone = 'success' | 'warning' | 'danger';

const TONE_CLASSES: Record<ButtonTone, string> = {
  success: 'border border-success-soft bg-success-soft text-success hover:brightness-110',
  warning: 'border border-warning-soft bg-warning-soft text-warning hover:brightness-110',
  danger: 'border border-danger-soft bg-danger-soft text-danger hover:brightness-110',
};

const SIZE_CLASSES: Record<Size, string> = {
  sm: 'px-2.5 py-1 text-[length:var(--text-label-size)]',
  md: 'px-4 py-2 text-[length:var(--text-body-sm-size)]',
  lg: 'px-5 py-2.5 text-[length:var(--text-body-size)]',
};

const SPINNER_SIZE: Record<Size, number> = { sm: 12, md: 14, lg: 16 };

export interface ButtonProps
  extends Omit<React.ButtonHTMLAttributes<HTMLButtonElement>, 'className'>,
    DisableableProps,
    LoadableProps,
    RootClassNameProps,
    Pick<ContentProps, 'leading' | 'trailing'> {
  /** Visual weight + intent. Never a raw colour. Default `secondary`. */
  variant?: ButtonVariant;
  /** Semantic-color action (soft green/amber). Overrides `variant` coloring. */
  tone?: ButtonTone;
  /** Maps to spacing + type tokens. Default `md`. */
  size?: Size;
  /** `full` = block button (stretches to the container). Default `content`. */
  width?: Width;
}

// Ref-forwarding: `Menu` clones its trigger and attaches a ref to it (focus
// restoration on Esc depends on reaching the real element), so any button that can
// be a menu trigger has to pass one through. `IconButton` already forwards.
export const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  {
    variant = 'secondary',
    tone,
    size = 'md',
    loading = false,
    width = 'content',
    leading,
    trailing,
    disabled,
    className,
    type = 'button',
    children,
    ...rest
  },
  ref,
) {
  // A spinner replaces the leading slot while loading, so the label stays put
  // and the control keeps its width.
  const lead = loading ? (
    <Icon name="refresh" size={SPINNER_SIZE[size]} className="animate-spin" />
  ) : (
    leading
  );

  const rootClassName = [
    BASE,
    tone ? TONE_CLASSES[tone] : VARIANT_CLASSES[variant],
    SIZE_CLASSES[size],
    width === 'full' ? 'w-full' : '',
    className ?? '',
  ]
    .filter(Boolean)
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();

  return (
    <button
      ref={ref}
      type={type}
      disabled={disabled || loading}
      aria-busy={loading || undefined}
      className={rootClassName}
      {...rest}
    >
      {lead}
      {children}
      {trailing}
    </button>
  );
});

export default Button;
