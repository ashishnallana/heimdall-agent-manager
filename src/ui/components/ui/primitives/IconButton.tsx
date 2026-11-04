/**
 * IconButton — the one icon-only action.
 * ------------------------------------------------------------------
 * Purpose: a single primitive for icon-only actions (close, edit, overflow,
 * refresh, icon "send"), folding the many hand-rolled `<button>…<Icon/></button>`
 * recipes (EL-014, EL-015, EL-018 in `docs/ui-audit/04-component-catalogue.md` ›
 * IconButton) into one control. It fixes two recurring defects those recipes
 * shared: unlabeled icon buttons (no accessible name) and sub-44px hit targets.
 *
 * NOT for: an action with a visible text label (use `Button` — it takes
 * `leading`/`trailing` icons), or a decorative glyph (use `Icon`).
 *
 * Layer: primitive. Spec: `docs/ui-audit/04-component-catalogue.md` › IconButton.
 * Prop names follow the shared vocabulary in `../types` (`variant`, `size`,
 * `loading`, `disabled`, `className`). Native `<button>` attributes (`type`,
 * `onClick`, `data-*`, `aria-*`, `ref`, …) pass straight through via `rest`.
 *
 * Accessible name is REQUIRED, not optional: `label` becomes the button's
 * `aria-label` and its `title` (hover tooltip). The component cannot be built
 * without one — this is what fixes the unlabeled-icon-button finding.
 *
 * Accessibility (built in, not a prop):
 *   - Renders a real `<button>`; Enter/Space activation is native.
 *   - `focus-visible` shows a token focus ring (`shadow-focus`) — never removed.
 *   - `md` (the default) guarantees a ≥44px hit target. `sm` (36px) is for dense
 *     toolbars where 44px does not fit — an opt-in, not the default.
 *   - `loading` swaps the glyph for a spinner, sets `aria-busy`, and disables
 *     interaction.
 *
 * Tokens only: colour/radius/spacing/motion all resolve to tokens
 * (`src/ui/tokens.css` / the Tailwind token aliases). No raw hex or px.
 *
 * Escape hatch: `className` merges onto the root `<button>` — an escape hatch
 * with a cost, not a styling API.
 */
import React from 'react';
import { Icon, type IconName } from './Icon';
import type {
  DisableableProps,
  LoadableProps,
  RootClassNameProps,
  Size,
} from '../types';

/**
 * Visual weight of an icon action. `primary` is the accent-filled icon action (a
 * composer's send): hover brightens, press scales to .96 (no scale under reduced motion).
 */
export type IconButtonVariant = 'ghost' | 'solid' | 'danger' | 'primary';

const BASE =
  'inline-flex items-center justify-center rounded-[var(--radius-md)] ' +
  'transition duration-fast focus-visible:outline-none focus-visible:shadow-focus ' +
  'disabled:opacity-50 disabled:cursor-not-allowed';

const VARIANT_CLASSES: Record<IconButtonVariant, string> = {
  ghost: 'text-muted hover:text-primary hover:bg-surface-raised',
  solid: 'border border-subtle bg-surface-raised text-primary hover:brightness-125',
  danger: 'text-danger hover:bg-surface-raised hover:brightness-110',
  primary:
    'bg-accent text-accent-fg ease-standard hover:brightness-110 active:scale-[.96] ' +
    'motion-reduce:transition-none motion-reduce:active:scale-100',
};

/** Box size per size. `md` (44px) meets the AA touch-target minimum. */
const BOX_CLASSES: Record<Size, string> = {
  sm: 'h-9 w-9',
  md: 'h-11 w-11',
  lg: 'h-12 w-12',
};

/** Glyph size (Icon token) per button size. */
const ICON_SIZE: Record<Size, 'sm' | 'md' | 'lg' | 'xl'> = {
  sm: 'md', // 16
  md: 'lg', // 20
  lg: 'xl', // 24
};

export interface IconButtonProps
  extends Omit<
      React.ButtonHTMLAttributes<HTMLButtonElement>,
      'className' | 'children' | 'aria-label' | 'title'
    >,
    DisableableProps,
    LoadableProps,
    RootClassNameProps {
  /** The glyph to show. From the `Icon` set — never emoji/glyph. */
  icon: IconName;
  /** Accessible name (required). Becomes `aria-label` + `title`. */
  label: string;
  /** Visual weight. Default `ghost`. */
  variant?: IconButtonVariant;
  /** Maps to hit-target + glyph size. Default `md` (≥44px). */
  size?: Size;
  /**
   * Toggle state (opt-in). When set, the button is a toggle: `aria-pressed`
   * reflects it, a pressed button is accent-coloured, and `pressedIcon` (if any)
   * replaces `icon` with a `pop` as it turns on. Omit for a plain action.
   */
  pressed?: boolean;
  /** Glyph shown while `pressed` (e.g. `star-filled` for a `star` toggle). */
  pressedIcon?: IconName;
}

export const IconButton = React.forwardRef<HTMLButtonElement, IconButtonProps>(function IconButton(
  { icon, label, variant = 'ghost', size = 'md', loading = false, disabled, className, type = 'button', pressed, pressedIcon, ...rest },
  ref,
) {
  const toggle = pressed !== undefined;
  // `pop` only when the toggle turns on after mount, never on first render (a list
  // of already-starred rows must not all pop when it opens). Derived while rendering.
  const [prevPressed, setPrevPressed] = React.useState(pressed);
  const [turnedOn, setTurnedOn] = React.useState(false);
  if (prevPressed !== pressed) {
    setPrevPressed(pressed);
    setTurnedOn(Boolean(pressed));
  }
  const rootClassName = [
    BASE,
    // A pressed toggle keeps the accent through hover; colour changes at fast/standard.
    toggle && pressed ? 'text-accent hover:bg-surface-raised ease-standard motion-reduce:transition-none' : VARIANT_CLASSES[variant],
    toggle && !pressed ? 'ease-standard motion-reduce:transition-none' : '',
    BOX_CLASSES[size],
    disabled || loading ? '' : 'cursor-pointer',
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
      aria-label={label}
      title={label}
      disabled={disabled || loading}
      aria-busy={loading || undefined}
      aria-pressed={toggle ? pressed : undefined}
      className={rootClassName}
      {...rest}
    >
      {/* Keyed on the toggle state so the filled glyph mounts (and pops) only when it turns on. */}
      <Icon
        key={toggle && pressed ? 'on' : 'off'}
        name={loading ? 'refresh' : toggle && pressed && pressedIcon ? pressedIcon : icon}
        size={ICON_SIZE[size]}
        className={loading ? 'animate-spin' : toggle && pressed && turnedOn ? 'animate-pop' : undefined}
      />
    </button>
  );
});

export default IconButton;
