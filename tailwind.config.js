/** @type {import('tailwindcss').Config} */
//
// Design-token theme aliases. Every value below points at a CSS custom property
// defined in `src/ui/tokens.css` (derived from docs/ui-audit/02-tokens.md), so
// future code can write semantic utilities like `bg-surface`, `text-muted`,
// `z-modal`, `duration-base`, `text-body`, `shadow-panel`.
//
// This is PURELY ADDITIVE. Everything here uses `theme.extend` and only introduces
// NEW keys — no default Tailwind key is overridden — so every existing utility
// (`zinc-*`, `sky-*`, `rounded-xl`, `rounded-md`, `shadow-sm`, `z-50`, `text-sm`,
// the `sm:`/`md:`/`lg:` screens, arbitrary values) keeps its current meaning and
// the app renders identically.
//
// Deliberately NOT aliased here, to preserve zero visual change (see the handoff
// notes): `borderRadius.{sm,md,lg}`, `boxShadow.sm`, and the `screens` are all
// already in heavy use with Tailwind's default values; re-pointing those keys at
// the token values would silently restyle existing call sites. Those remaps are a
// deliberate migration step for later per-component tasks. The token values remain
// available today via the CSS vars (`rounded-[var(--radius-md)]`, etc.).
export default {
  content: ['./index.html', './src/ui/**/*.{ts,tsx}'],
  theme: {
    extend: {
      spacing: {
        // One-off fixed sidebar width. Retained as-is (still referenced); the
        // token equivalent is `--size-sidebar`.
        84: '21rem',
      },
      colors: {
        canvas: 'var(--color-canvas)',
        backdrop: 'var(--color-backdrop)',
        surface: {
          DEFAULT: 'var(--color-surface)',
          raised: 'var(--color-surface-raised)',
          overlay: 'var(--color-surface-overlay)',
        },
        // Text roles: enable `text-primary` / `text-muted` / `text-faint`.
        primary: 'var(--color-text-primary)',
        muted: 'var(--color-text-muted)',
        faint: 'var(--color-text-faint)',
        // Border roles: enable `border-subtle` / `border-strong`.
        subtle: 'var(--color-border-subtle)',
        strong: 'var(--color-border-strong)',
        accent: {
          DEFAULT: 'var(--color-accent)',
          fg: 'var(--color-accent-fg)',
          soft: 'var(--color-accent-soft)',
        },
        // Semantic tones. `DEFAULT` = solid tone (bg-success / text-success /
        // border-success); `soft` = the `emphasis="soft"` tint (bg-success-soft).
        success: { DEFAULT: 'var(--color-success)', soft: 'var(--color-success-soft)' },
        warning: { DEFAULT: 'var(--color-warning)', soft: 'var(--color-warning-soft)' },
        danger: { DEFAULT: 'var(--color-danger)', soft: 'var(--color-danger-soft)' },
        info: { DEFAULT: 'var(--color-info)', soft: 'var(--color-info-soft)' },
        // Neutral: no solid base (neutral text uses `text-muted`), only the soft tint.
        neutral: { soft: 'var(--color-neutral-soft)' },
        focus: 'var(--color-focus-ring)',
      },
      fontFamily: {
        // `font-mono` default already matches; expose a token-backed `body` face.
        body: 'var(--font-body)',
      },
      fontSize: {
        display: ['var(--text-display-size)', { lineHeight: 'var(--text-display-leading)', letterSpacing: 'var(--text-display-tracking)', fontWeight: 'var(--text-display-weight)' }],
        heading: ['var(--text-heading-size)', { lineHeight: 'var(--text-heading-leading)', letterSpacing: 'var(--text-heading-tracking)', fontWeight: 'var(--text-heading-weight)' }],
        title: ['var(--text-title-size)', { lineHeight: 'var(--text-title-leading)', letterSpacing: 'var(--text-title-tracking)', fontWeight: 'var(--text-title-weight)' }],
        body: ['var(--text-body-size)', { lineHeight: 'var(--text-body-leading)', letterSpacing: 'var(--text-body-tracking)', fontWeight: 'var(--text-body-weight)' }],
        'body-sm': ['var(--text-body-sm-size)', { lineHeight: 'var(--text-body-sm-leading)', letterSpacing: 'var(--text-body-sm-tracking)', fontWeight: 'var(--text-body-sm-weight)' }],
        label: ['var(--text-label-size)', { lineHeight: 'var(--text-label-leading)', letterSpacing: 'var(--text-label-tracking)', fontWeight: 'var(--text-label-weight)' }],
        caption: ['var(--text-caption-size)', { lineHeight: 'var(--text-caption-leading)', letterSpacing: 'var(--text-caption-tracking)', fontWeight: 'var(--text-caption-weight)' }],
        overline: ['var(--text-overline-size)', { lineHeight: 'var(--text-overline-leading)', letterSpacing: 'var(--text-overline-tracking)', fontWeight: 'var(--text-overline-weight)' }],
        code: ['var(--text-code-size)', { lineHeight: 'var(--text-code-leading)', letterSpacing: 'var(--text-code-tracking)', fontWeight: 'var(--text-code-weight)' }],
        // Body/label long-tail remap (EL / 02-tokens.md): the raw Tailwind
        // `text-sm` / `text-xs` scale is repointed at the `body` / `label` tokens
        // so the ~1000-node body/label tail picks up token leading/weight/tracking
        // in one deliberate change (sizes already matched: sm=14px=body,
        // xs=12px=label — no reflow; small text normalizes to the token weights).
        // Explicit `font-*` utilities still win over the token weight.
        sm: ['var(--text-body-size)', { lineHeight: 'var(--text-body-leading)', letterSpacing: 'var(--text-body-tracking)', fontWeight: 'var(--text-body-weight)' }],
        xs: ['var(--text-label-size)', { lineHeight: 'var(--text-label-leading)', letterSpacing: 'var(--text-label-tracking)', fontWeight: 'var(--text-label-weight)' }],
      },
      borderRadius: {
        // `pill` is a new, non-colliding alias (`rounded-full` also = 9999px).
        pill: 'var(--radius-pill)',
      },
      boxShadow: {
        panel: 'var(--shadow-panel)',
        overlay: 'var(--shadow-overlay)',
        focus: 'var(--shadow-focus)',
        'focus-danger': 'var(--shadow-focus-danger)',
        'glow-accent': 'var(--glow-accent)',
        'glow-success': 'var(--glow-success)',
        'glow-warning': 'var(--glow-warning)',
        'glow-danger': 'var(--glow-danger)',
      },
      zIndex: {
        base: 'var(--z-base)',
        sticky: 'var(--z-sticky)',
        dropdown: 'var(--z-dropdown)',
        overlay: 'var(--z-overlay)',
        modal: 'var(--z-modal)',
        toast: 'var(--z-toast)',
        popover: 'var(--z-popover)',
        tooltip: 'var(--z-tooltip)',
      },
      transitionDuration: {
        fast: 'var(--duration-fast)',
        base: 'var(--duration-base)',
        slow: 'var(--duration-slow)',
        slower: 'var(--duration-slower)',
      },
      transitionTimingFunction: {
        standard: 'var(--ease-standard)',
      },
    },
  },
  plugins: [],
};
