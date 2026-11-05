/**
 * Text — all typography through one role prop.
 * ------------------------------------------------------------------
 * Purpose: the single primitive for every piece of text, headings included. It
 * folds the ~2000 raw `text-sm` / `text-xs` / `text-caption` + heading-class
 * recipes (EL-042 and the type scale in `docs/ui-audit/02-tokens.md` §2) into a
 * fixed set of named roles, each binding size + weight + line-height + tracking
 * from tokens. Pick the ROLE (what the text is) and, for headings, the ELEMENT
 * (`as`) — never a raw size class.
 *
 * NOT for: layout (margins, flex, grid — that is a `Box`/`Stack`/page concern),
 * or interactive text (use `Link` / `Button`).
 *
 * Layer: primitive. Spec: `docs/ui-audit/04-component-catalogue.md` › Text.
 * Prop names follow the shared vocabulary in `../types` (`tone`, `truncate`,
 * `className`). Common element attributes (`id`, `title`, `aria-*`, `data-*`,
 * `onClick`, `ref`, …) pass straight through via `rest`.
 *
 * Role vs. element: `role` sets the *type treatment*; `as` sets the *semantic
 * element*. They are independent on purpose — that is what fixes the heading
 * hierarchy defects (e.g. a page title styled as a heading must still be the
 * page's single `<h1>`): write `<Text as="h1" role="display">`. When `as` is
 * omitted a sensible non-heading default is used (see `DEFAULT_AS`), so a heading
 * element is only ever produced when the caller asks for one.
 *
 * The 11px floor: the smallest role is 11px (`caption` / `overline`). Sub-11px
 * body text is a readability defect and has no role — snap `text-[10px]` up to
 * `caption`. `overline` also applies `uppercase` (its tracking lives in the
 * token), so eyebrow labels stop hand-rolling `uppercase tracking-[0.16em]`.
 *
 * Tokens only: every role maps to a `text-<role>` font token and every tone to a
 * `text-<tone>` color token (`src/ui/tokens.css` / the Tailwind token aliases).
 * No raw hex, px, or ad-hoc size class.
 *
 * Escape hatch: `className` merges onto the rendered element — an escape hatch
 * with a cost (it can break the token guarantees), not a styling API. Use it for
 * layout spacing at the call site, never to re-set size/weight/color.
 */
import React from 'react';
import type { RootClassNameProps } from '../types';

/** The type roles (size + weight + line-height + tracking), 11px floor enforced. */
export type TextRole =
  | 'display'
  | 'headline'
  | 'heading'
  | 'title'
  | 'body'
  | 'body-sm'
  | 'label'
  | 'caption'
  | 'overline'
  | 'code'
  | 'code-sm';

/** Semantic text color. Never a raw color. */
export type TextTone =
  | 'primary'
  | 'muted'
  | 'faint'
  | 'accent'
  | 'danger'
  | 'success'
  | 'warning';

/** The elements Text may render as. Headings are opt-in via `as`. */
export type TextElement =
  | 'h1'
  | 'h2'
  | 'h3'
  | 'h4'
  | 'h5'
  | 'h6'
  | 'p'
  | 'span'
  | 'div'
  | 'label'
  | 'code'
  | 'strong'
  | 'em';

/** Role → font-size token alias (each binds size/weight/line-height/tracking). */
const ROLE_CLASS: Record<TextRole, string> = {
  display: 'text-display',
  // Responsive: 22/36 below md (768px, the app's mobile breakpoint), 32/52 from md.
  headline: 'text-headline-sm md:text-headline',
  heading: 'text-heading',
  title: 'text-title',
  body: 'text-body',
  'body-sm': 'text-body-sm',
  label: 'text-label',
  caption: 'text-caption',
  overline: 'text-overline uppercase',
  code: 'text-code font-mono',
  'code-sm': 'text-code-sm font-mono',
};

/** Tone → color token. */
const TONE_CLASS: Record<TextTone, string> = {
  primary: 'text-primary',
  muted: 'text-muted',
  faint: 'text-faint',
  accent: 'text-accent',
  danger: 'text-danger',
  success: 'text-success',
  warning: 'text-warning',
};

/**
 * Default element per role when `as` is omitted. Heading roles default to a
 * non-heading block (`div`) so a real `<h#>` is only ever emitted when the caller
 * chooses one — keeping heading hierarchy the caller's explicit decision.
 */
const DEFAULT_AS: Record<TextRole, TextElement> = {
  display: 'div',
  headline: 'div',
  heading: 'div',
  title: 'div',
  body: 'p',
  'body-sm': 'p',
  label: 'span',
  caption: 'span',
  overline: 'span',
  code: 'code',
  'code-sm': 'code',
};

export interface TextProps
  extends React.HTMLAttributes<HTMLElement>,
    RootClassNameProps {
  /** The semantic element to render. Defaults per role (see notes). */
  as?: TextElement;
  /** The type treatment. Default `body`. */
  role?: TextRole;
  /** Semantic color. Default `primary`. */
  tone?: TextTone;
  /** Truncate to a single line with an ellipsis. Default `false`. */
  truncate?: boolean;
  children?: React.ReactNode;
}

export const Text = React.forwardRef<HTMLElement, TextProps>(function Text(
  { as, role = 'body', tone = 'primary', truncate = false, className, children, ...rest },
  ref,
) {
  const element = as ?? DEFAULT_AS[role];

  const classes = [ROLE_CLASS[role], TONE_CLASS[tone], truncate ? 'truncate' : '', className ?? '']
    .filter(Boolean)
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();

  return React.createElement(element, { ref, className: classes, ...rest }, children);
});

export default Text;
