---
version: alpha
name: Ninjy
description: "The Ninjy (Heimdall) agent workspace: quiet neutral-grey dark surfaces, one gold accent taken from the logo for action and focus, serif for page titles, headings and agent replies, IBM Plex for the interface, and status colours that always come with a word. Borders, not shadows; one radius per role; every value is a token in src/ui/tokens.css."

colors:
  bg-000: "#0f0f0f"
  bg-100: "#191919"
  bg-200: "#1f1f1f"
  bg-300: "#252525"
  bg-400: "#303030"
  bg-500: "#3b3b3b"
  border: "#303030"
  border-strong: "#3b3b3b"
  ink: "#efefef"
  ink-muted: "#9c9c9c"
  ink-subtle: "#8a8a8a"
  accent: "#e8ba5a"
  brand-gold: "#e8ba5a"
  brand-teal: "#36c6b7"
  on-brand: "#0b0b0d"
  on-accent: "#121212"
  accent-tint: "#363022"
  success: "#9dcd6a"
  success-tint: "#2b3224"
  info: "#7cceff"
  info-tint: "#252f35"
  warning: "#f28c4f"
  warning-tint: "#372921"
  danger: "#ef8a80"
  danger-tint: "#372927"
  focus: "#e8ba5a"

typography:
  display:
    fontFamily: Source Serif 4
    fontSize: 32px
    fontWeight: 400
    lineHeight: 38px
    letterSpacing: -0.01em
  heading:
    fontFamily: Source Serif 4
    fontSize: 20px
    fontWeight: 500
    lineHeight: 28px
  reading:
    fontFamily: Source Serif 4
    fontSize: 16px
    fontWeight: 400
    lineHeight: 26px
  title:
    fontFamily: IBM Plex Sans
    fontSize: 15px
    fontWeight: 600
    lineHeight: 22px
  body:
    fontFamily: IBM Plex Sans
    fontSize: 14px
    fontWeight: 400
    lineHeight: 20px
  body-sm:
    fontFamily: IBM Plex Sans
    fontSize: 13px
    fontWeight: 400
    lineHeight: 18px
  label:
    fontFamily: IBM Plex Sans
    fontSize: 12px
    fontWeight: 500
    lineHeight: 16px
  caption:
    fontFamily: IBM Plex Sans
    fontSize: 11px
    fontWeight: 500
    lineHeight: 16px
  overline:
    fontFamily: IBM Plex Sans
    fontSize: 11px
    fontWeight: 600
    lineHeight: 16px
    letterSpacing: 0.06em
  code:
    fontFamily: IBM Plex Mono
    fontSize: 13px
    fontWeight: 400
    lineHeight: 20px
  code-sm:
    fontFamily: IBM Plex Mono
    fontSize: 12px
    fontWeight: 400
    lineHeight: 16px

rounded:
  sm: 6px
  md: 8px
  lg: 12px
  xl: 16px
  full: 9999px

spacing:
  s1: 4px
  s2: 8px
  s3: 12px
  s4: 16px
  s6: 24px
  s8: 32px
  s12: 48px

components:
  button-primary:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.on-accent}"
    typography: "{typography.body}"
    rounded: "{rounded.md}"
    height: 32px
    padding: 0 12px
  button-secondary:
    backgroundColor: "{colors.bg-500}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.md}"
    height: 32px
    padding: 0 12px
  button-ghost:
    textColor: "{colors.ink-muted}"
    typography: "{typography.body}"
    rounded: "{rounded.md}"
    height: 32px
  button-danger:
    backgroundColor: "{colors.danger-tint}"
    textColor: "{colors.danger}"
    typography: "{typography.body}"
    rounded: "{rounded.md}"
    height: 32px
  input:
    backgroundColor: "{colors.bg-400}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.md}"
    height: 36px
    padding: 0 12px
  badge:
    backgroundColor: "{colors.bg-500}"
    textColor: "{colors.ink-muted}"
    typography: "{typography.label}"
    rounded: "{rounded.sm}"
    height: 20px
    padding: 0 8px
  status-pill:
    backgroundColor: "{colors.success-tint}"
    textColor: "{colors.success}"
    typography: "{typography.label}"
    rounded: "{rounded.full}"
    height: 20px
    padding: 0 10px
  panel:
    backgroundColor: "{colors.bg-200}"
    textColor: "{colors.ink}"
    rounded: "{rounded.lg}"
    padding: 16px
  panel-needs-you:
    backgroundColor: "{colors.accent-tint}"
    textColor: "{colors.ink}"
    rounded: "{rounded.lg}"
    padding: 16px
  alert-success:
    backgroundColor: "{colors.success-tint}"
    textColor: "{colors.ink}"
    rounded: "{rounded.lg}"
    padding: 12px 16px
  menu:
    backgroundColor: "{colors.bg-200}"
    textColor: "{colors.ink}"
    rounded: "{rounded.lg}"
    padding: 4px
  modal:
    backgroundColor: "{colors.bg-200}"
    textColor: "{colors.ink}"
    typography: "{typography.heading}"
    rounded: "{rounded.xl}"
  page-title:
    textColor: "{colors.ink}"
    typography: "{typography.display}"
---

## Overview

Ninjy is a workspace for running and reviewing coding agents: chains, tickets, bridges and long agent replies. The interface stays quiet so the work reads first — neutral grey surfaces, one gold accent for action, and status colors that always come with a word.

This file is the source of truth for the product UI (`src/ui`). The marketing site keeps its own `landing-page/DESIGN.md`. The same system is published as a Claude design system; if the two disagree, this file and `src/ui/tokens.css` win.

## Tokens in code

Every colour, radius and type role above is a CSS variable in `src/ui/tokens.css` (exposed to Tailwind in `tailwind.config.js`). Components never use raw values.

| Design token | CSS variable | Tailwind |
|---|---|---|
| `bg-000` | `--color-canvas` | `bg-canvas` |
| `bg-100` | `--color-surface` | `bg-surface` |
| `bg-200` | `--color-surface-raised` | `bg-surface-raised` |
| `bg-300` | ≈ `--color-neutral-soft` on the canvas | `bg-neutral-soft` |
| `bg-400` / `border` | `--color-border-subtle` | `border-subtle` |
| `bg-500` / `border-strong` | `--color-border-strong` | `bg-strong`, `border-strong` |
| `ink` · `ink-muted` · `ink-subtle` | `--color-text-primary` · `-muted` · `-faint` | `text-primary` · `text-muted` · `text-faint` |
| `accent` · `on-accent` | `--color-accent` · `--color-accent-fg` | `bg-accent`, `text-accent`, `text-accent-fg` |
| `accent-tint` | `--color-accent-soft` | `bg-accent-soft` |
| `success` · `info` · `warning` · `danger` | `--color-<tone>` | `text-<tone>`, `bg-<tone>` |
| `<tone>-tint` | `--color-<tone>-soft` | `bg-<tone>-soft` |
| `focus` | `--color-focus-ring` | `shadow-focus` |
| `radius-sm/md/lg/xl/full` | `--radius-sm/md/lg/xl/pill` | `rounded-[var(--radius-md)]` |
| type styles | `--text-<role>-*` | `text-<role>` via `<Text role>` |

The `default-dark` theme carries these values; the Catppuccin and Tokyo Night themes keep their own palettes.

## Principles

- **Neutral surfaces, one accent.** Greys do the structure; `accent` marks the one thing to do next. If two things on a screen are gold and neither is a link, one is wrong.
- **Borders, not shadows.** Cards and panels separate with a 1px `border` hairline. Only things that float (menus, modals) get a shadow.
- **Serif to read, sans to operate.** Agent replies, titles and headings are serif; controls, rows and metadata are sans; anything a machine produced (paths, IDs, branches, commands) is mono.
- **Status is a word first.** Color reinforces a label; it never replaces one.
- **Fewer steps, used the same way everywhere.** Six surface steps, three text inks, seven spacing steps, five radii. No one-off values.

## Content fundamentals

- Sentence case everywhere: "New conversation", "Bridge paths", "Add payment method". Uppercase only in `label` section headers (UP NEXT, FINISHED).
- Write to the user as "you", plainly and briefly: "Nothing needs you", "Still for you: cut a release". Lead with the outcome, then the detail.
- Name things by what the user calls them — chains, tickets, bridges, workers, reviewers — and keep those nouns fixed.
- Numbers as digits with their unit: "14 of 15 tasks done", "attempt 4/5", "8d ago".
- No emoji in interface chrome. Status uses badges and dots, not ✅.
- Machine text (hashes, paths, branches, flags) goes in the `code` style (`<Text role="code">`), never in quotes.

## Color

All surfaces come from the `bg-` scale; never introduce another grey.

- `bg-000` — sidebar and app frame. `bg-100` — main canvas and side panels. `bg-200` — cards, modals, tiles. `bg-300` — selected/hovered rows. `bg-400` — inputs, search, composer. `bg-500` — secondary buttons and neutral badges.
- Text: `ink` for primary text, `ink-muted` for descriptions and metadata, `ink-subtle` for placeholders and section labels. `ink-subtle` passes 4.5:1 only on `bg-000`–`bg-200`; on deeper fills use `ink-muted`.
- `accent` is the logo gold (#e8ba5a, `brand-gold`): the primary button, links, the selected tab underline, inline code and focus. Text on an `accent` or `success` fill is `on-accent` (near-black), never white.
- Status: `success` done/linked/online, `info` running, `warning` needs attention, `danger` failed or destructive. Each has a `-tint` ground for badges and icon wells; pair the tint with its own color as text.
- `success` and `danger` differ mostly by hue, so every status carries a word or icon.
- `brand-gold` is the source of `accent`; in UI code always reference `accent`, so the action color can change in one place. `brand-teal` is for the logo, the cover and marketing only — never in UI. `warning` is a redder orange so it never reads as the accent, and every warning carries a word.

## Typography

Families: Source Serif 4 (`serif`), IBM Plex Sans (`sans`), IBM Plex Mono (`mono`), loaded from Google Fonts.

Type styles share their names with the app's `<Text role>` values, so `role="title"` and the `title` style are the same thing.

- `display` (serif 32/38) — the page's single h1, set by PageShell; empty-state headlines.
- `heading` (serif 20/28, 500) — section, Panel-detail and Modal titles.
- `title` (sans 15/22, 600) — card, ticket and row titles; Alert and Toast titles.
- `body` (sans 14/20) — default UI text. `body-sm` (13/18) — metadata, descriptions, hints.
- `label` (12/16, 500) — form labels, badge text, counts. `caption` (11/16, 500) — timestamps, status bar.
- `overline` (11/16, 600, +0.06em, uppercase, `ink-subtle`) — section labels and page eyebrows.
- `code` (mono 13/20) and `code-sm` (mono 12/16) — paths, branches, commands, IDs.
- `reading` (serif 16/26) — agent replies and long markdown prose; cap the column at 72ch.

Never set UI controls in the serif; never set prose replies in the sans.

## Spacing and layout

- 4px base: `space-1` 4 · `space-2` 8 · `space-3` 12 · `space-4` 16 · `space-6` 24 · `space-8` 32 · `space-12` 48.
- Card and panel padding `space-4`; gaps between cards `space-3`; between sections `space-6`; page padding `space-8` (desktop), `space-4` (mobile).
- Three-column app: `bg-000` sidebar (240–260px), `bg-100` main column (reading width 720px), `bg-100` side panel separated by a `border` hairline. Modals sit on `bg-200` with `radius-xl` over `scrim`.
- Control heights: buttons 28 / 32 / 40 (sm / md / lg), inputs and selects 28 / 36 / 40, badges and pills 20, menu and list options 32.

## Shape and depth

- `radius-sm` 6 — Badge, Kbd, chips, inline code. `radius-md` 8 — Button, IconButton, Input, Select, menu items. `radius-lg` 12 — Panel, Alert, Toast, Menu, listboxes, EmptyState. `radius-xl` 16 — Modal, the composer. `radius-full` — StatusPill, StatusDot, Toggle, Spinner.
- Panels: `bg-200` + 1px `border`, no shadow. Floating layers: `shadow-pop` (Menu, Select/Combobox listbox, Toast, command palette) and `shadow-modal` (Modal).

## States

- Hover: rows and ghost controls move to `bg-300`; secondary buttons lighten to `bg-400`; primary brightens slightly.
- Selected: `bg-300` fill with `ink` text (nav rows, active menu option), gold text + check (chosen Select option), or a 2px `accent` underline (tabs). No outlines, no coloured left bars.
- Focus: 2px solid `focus` ring with 2px offset on every interactive element; fields show a gold 1px border + 1px glow instead. Passes 3:1 on every surface.
- Status tones: `neutral`, `info`, `success`, `warning`, `danger`, `pending`. `pending` (queued, in flight) shares the `info` blue so `warning` keeps meaning "needs a person".
- Disabled: 45% opacity, no hover.

## Iconography

- Use only the app's own set: 59 glyphs in `Icon.tsx` (SVG copies in `assets/brand/icons/`). 24px grid, ~1.8px round strokes, `currentColor`.
- Sizes: `sm` 14 in sm controls and badges, `md` 16 in buttons, rows and menus, `lg` 20 in empty states and tiles, `xl` 24 for hero moments.
- Icons sit in `ink-muted` beside a label and `ink` when they are the content; a status colour only inside Alert, Toast or a status component.
- No emoji, no text glyphs (×, ›, ✓) and no second icon library.

## Logo

- The mark is two interlocking rings: one in `on-brand` (dark) or white, one in `brand-gold` — the primary version — or `brand-teal`. Files are in `assets/brand/logos/`.
- On dark surfaces (`bg-000`–`bg-200`) use the dark app icon, `ninjy-icon-dark-gold.png`. On light grounds use `ninjy-icon-light-gold.png` (gold) or `ninjy-icon-light-teal.png` (teal).
- In the sidebar header, show the icon at 20–24px followed by "Ninjy" in `title`. Never recolor, crop or redraw the rings.
- The current files are glass app icons (1024px PNG). A flat SVG of the rings is still needed for small sizes and favicons.

## Components

These are the `@ui` components the app imports today (`src/ui/components/ui`), restyled to this system. Each card shows the look, and its guidelines list the real props.

- **Actions:** Button, IconButton, Link
- **Foundations:** Text, Icon, Kbd
- **Status:** Badge (inert metadata, square), StatusPill (a state, round), StatusDot (liveness), Spinner
- **Forms:** Input, Textarea, Select, Combobox, Checkbox, Radio, Toggle, FormField
- **Feedback:** Alert (inline), Toast (transient)
- **Overlays:** Modal, Menu
- **Layout:** Panel (also the clickable card), EmptyState, PageShell

Per-component guidelines and props: `docs/design-system/components/`.

## Iteration Guide

1. Reach for an `@ui` component first (`src/ui/components/ui`); its guideline in `docs/design-system/components/` lists the props.
2. Pick the surface step before anything else: `bg-100` canvas, `bg-200` Panel, `bg-300` hover/selected, `bg-400` fields.
3. Gold is for the one next action, links and focus. If a second gold thing appears and it is not a link, change it.
4. New status? Map it onto the six tones; never add a hue.
5. Run `npx @google/design.md lint DESIGN.md` after editing the token block.

## Known Gaps

- Fonts load from Google Fonts in `index.html`; offline, the app falls back to system sans, Georgia and the system monospace. Bundling the fonts (e.g. `@fontsource`) would remove that dependency.
- The logo exists only as 1024px glass app-icon PNGs; a flat SVG mark is still needed for small sizes.
- Agent replies (`.markdown-message`) still use the sans; the `reading` style (serif 16/26, 72ch) is specified but not applied yet.
- `bg-300` has no variable of its own; `--color-neutral-soft` (white at 8%) lands close to it on `bg-100`.
- Light theme is not designed yet.
