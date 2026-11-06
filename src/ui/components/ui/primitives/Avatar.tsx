/**
 * Avatar — a person/agent avatar (image or initials).
 * ------------------------------------------------------------------
 * Purpose: the standard avatar (EL-052), collapsing the two shapes (circle /
 * rounded tile) into one control with a `shape` prop and a built-in initials
 * fallback when there is no image.
 *
 * NOT for: a decorative branded tile that is deliberately accented/sized for one
 * surface (e.g. the conversation-inbox hero tile) — those are documented one-offs;
 * Avatar is the neutral, reusable default.
 *
 * Layer: primitive. Spec: `docs/ui-audit/04-component-catalogue.md` › Link · Spinner · Kbd · Avatar.
 * Prop names follow the shared vocabulary in `../types` (`size`, `className`).
 *
 * Accessibility (built in): `name` is required — it is the `<img>` alt text and,
 * for the initials fallback, the `role="img"` accessible name (the initials
 * glyph is `aria-hidden`). A broken/absent image falls back to initials.
 *
 * Tokens only: surface/border/text/radius resolve to tokens. No raw hex/px.
 *
 * Escape hatch: `className` merges onto the root — use it for ring/placement, not
 * to re-shape.
 */
import React from 'react';
import type { RootClassNameProps, Size } from '../types';

/** Box + type size per `size`. */
const BOX_SIZE: Record<Size, string> = {
  sm: 'h-8 w-8 text-[length:var(--text-caption-size)]',
  md: 'h-10 w-10 text-[length:var(--text-body-sm-size)]',
  lg: 'h-12 w-12 text-[length:var(--text-body-size)]',
};

export type AvatarShape = 'circle' | 'rounded';

const SHAPE_RADIUS: Record<AvatarShape, string> = {
  circle: 'rounded-full',
  rounded: 'rounded-[var(--radius-md)]',
};

/** First letters of the first two words, uppercased (e.g. "Ada Lovelace" -> "AL"). */
/**
 * One glyph: the first letter or digit of the name. A single character keeps
 * names like "Safety Reviewer (gpt-6.1-sol)" from rendering as "S(".
 */
export function initialsOf(name: string): string {
  const first = name.match(/[\p{L}\p{N}]/u);
  return first ? first[0].toUpperCase() : '?';
}

export interface AvatarProps extends RootClassNameProps {
  /** Person/agent name — the accessible name and the initials source (required). */
  name: string;
  /** Image URL. When absent (or it fails to load) the initials fallback renders. */
  src?: string;
  /** Box + type size. Default `md`. */
  size?: Size;
  /** `circle` (default) or `rounded` tile. */
  shape?: AvatarShape;
}

export function Avatar({ name, src, size = 'md', shape = 'circle', className }: AvatarProps) {
  const [failed, setFailed] = React.useState(false);
  const showImage = Boolean(src) && !failed;

  const rootClassName = [
    'inline-flex shrink-0 items-center justify-center overflow-hidden select-none',
    BOX_SIZE[size],
    SHAPE_RADIUS[shape],
    showImage ? '' : 'border border-subtle bg-surface-raised font-semibold text-muted',
    className ?? '',
  ]
    .filter(Boolean)
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();

  if (showImage) {
    return (
      <img
        src={src}
        alt={name}
        className={rootClassName}
        style={{ objectFit: 'cover' }}
        onError={() => setFailed(true)}
      />
    );
  }

  return (
    <span role="img" aria-label={name} className={rootClassName}>
      <span aria-hidden="true">{initialsOf(name)}</span>
    </span>
  );
}

export default Avatar;
