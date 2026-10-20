/**
 * Shared vocabulary — the component library's prop-name contract.
 *
 * Source of truth: `docs/ui-audit/05-shared-vocabulary.md`. One prop name means
 * one thing across the whole set: if a component needs a concept below, it uses
 * THIS name and type — never a synonym (`scale`/`kind`/`color`/`onUpdate` are banned).
 *
 * This file is type-only (no runtime code). It encodes the vocabulary so the
 * primitives, composites, and patterns can all import the same unions and prop
 * fragments as they are built out in later tasks.
 */

import type { MouseEvent, ReactNode } from 'react';

/* ------------------------------------------------------------------ *
 * Configuration props
 * ------------------------------------------------------------------ */

/** Maps to spacing + type tokens. `md` is the default everywhere. */
export type Size = 'sm' | 'md' | 'lg';

/**
 * Semantic intent + visual weight of an action control. Never a raw color.
 * Used by: Button (and IconButton).
 */
export type ButtonVariant = 'primary' | 'secondary' | 'ghost' | 'danger';

/**
 * Status semantics where there is no "weight", only meaning.
 * Used by: StatusPill, StatusDot. (Action buttons use `variant` instead.)
 */
export type Tone = 'neutral' | 'info' | 'success' | 'warning' | 'danger' | 'pending';

/**
 * How strongly a tone is painted. Replaces ad-hoc `/10`, `/20`, `/900/50` forks.
 * Used by: Badge, StatusPill, Alert.
 */
export type Emphasis = 'solid' | 'soft' | 'outline';

/** Layout width intent. Not a pixel. Used by: PageShell, Panel, Button (`full` = block). */
export type Width = 'content' | 'full';

/** Cross-axis alignment. Used by: Stack, SectionHeader, EmptyState. */
export type Align = 'start' | 'center' | 'end';

/* ------------------------------------------------------------------ *
 * State props — one boolean per state, never per style.
 * ------------------------------------------------------------------ */

/** Non-interactive + dimmed + removed from tab order. */
export interface DisableableProps {
  disabled?: boolean;
}

/** In-flight; shows spinner, keeps size, sets `aria-busy`. */
export interface LoadableProps {
  loading?: boolean;
}

/** Validation failure; error styling + `aria-invalid`. */
export interface InvalidatableProps {
  invalid?: boolean;
}

/** Disclosure open (`aria-expanded`). */
export interface ExpandableProps {
  expanded?: boolean;
}

/** Displayed, not editable. */
export interface ReadOnlyProps {
  readOnly?: boolean;
}

/* ------------------------------------------------------------------ *
 * Content / composition props — structure comes through children.
 * ------------------------------------------------------------------ */

export interface ContentProps {
  /** The primary content / composed structure. */
  children?: ReactNode;
  /** Slot before the label (icon, badge, kbd). Replaces `iconLeft` / `showIcon`. */
  leading?: ReactNode;
  /** Slot after the label (icon, badge, kbd). Replaces `iconRight`. */
  trailing?: ReactNode;
}

/** Secondary helper text. Used by: FormField, SectionHeader, EmptyState. */
export interface DescribableProps {
  description?: ReactNode;
  /** Alias used by form controls; same meaning as `description`. */
  hint?: ReactNode;
}

/* ------------------------------------------------------------------ *
 * Event props — consistent handler names across the set.
 * ------------------------------------------------------------------ */

/** Value changed (controlled). Never `onUpdate` / `onInput`. */
export type ChangeHandler<T> = (value: T) => void;

/** Overlay open state changed. Used by: Modal, Menu, Drawer, Popover. */
export type OpenChangeHandler = (open: boolean) => void;

/** Activation of a button-like control. Used by: Button, IconButton, ListRow. */
export type ClickHandler = (event: MouseEvent<HTMLElement>) => void;

/* ------------------------------------------------------------------ *
 * The one escape hatch.
 * ------------------------------------------------------------------ */

/**
 * `className` passes through to the component ROOT only, merged after internal
 * classes. It is an escape hatch with a cost (it can break token guarantees),
 * not a styling API. No per-part class props — use composition instead.
 */
export interface RootClassNameProps {
  className?: string;
}
