/**
 * Shared tone × emphasis → token-class map.
 * ------------------------------------------------------------------
 * The single source of the status-color language, consumed by `Badge` and
 * `StatusPill` (and later `Alert`) so the tone/emphasis rendering is defined
 * once, not copied per component. All classes resolve to tokens — the semantic
 * color tokens and the `--color-*-soft` tint tokens. No raw hex / px / opacity
 * forks.
 *
 * `pending` (queued / in flight) shares the info blue, so warning keeps meaning
 * "needs a person" (design system: Status tones).
 *
 * Internal to the primitives layer — NOT re-exported from the `@ui` barrel.
 */
import type { Emphasis, Tone } from '../types';

export const TONE_STYLES: Record<Emphasis, Record<Tone, string>> = {
  soft: {
    neutral: 'bg-neutral-soft text-muted border border-subtle',
    info: 'bg-info-soft text-info border border-info-soft',
    success: 'bg-success-soft text-success border border-success-soft',
    warning: 'bg-warning-soft text-warning border border-warning-soft',
    danger: 'bg-danger-soft text-danger border border-danger-soft',
    pending: 'bg-info-soft text-info border border-info-soft',
  },
  outline: {
    neutral: 'text-muted border border-subtle',
    info: 'text-info border border-info',
    success: 'text-success border border-success',
    warning: 'text-warning border border-warning',
    danger: 'text-danger border border-danger',
    pending: 'text-info border border-info',
  },
  solid: {
    neutral: 'bg-strong text-primary',
    info: 'bg-info text-accent-fg',
    success: 'bg-success text-canvas',
    warning: 'bg-warning text-canvas',
    danger: 'bg-danger text-canvas',
    pending: 'bg-info text-canvas',
  },
};

/** The tone-class string for a given tone + emphasis. */
export function toneClasses(tone: Tone, emphasis: Emphasis): string {
  return TONE_STYLES[emphasis][tone];
}
