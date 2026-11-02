# Moving the current app onto the system

Replace each value found in the current Ninjy screens with the token on the right. Everything on the left disappears from the codebase.

## Surfaces and borders

| Current value | Where it appears today | Use instead |
|---|---|---|
| `#20212a` | Sidebar, selected chain row | `bg-000` (sidebar), `bg-300` (selected row) |
| `#1c1c23` | Main canvas, right panel, status bar | `bg-100` |
| `#2d3244` | Ticket cards, project detail panels, search field | `bg-200` (cards, panels); `bg-400` (search) |
| `#262a37`, `#282c3e` | Bridge select, composer | `bg-400` |
| `#292a34`, `#383e53` | `git` pill, attempt chip | `bg-500` (badge) |
| `#525770` | Selected project in list | `bg-300` |
| `#2c2e3b` | Column dividers | `border` |
| `#575e87` | Active card outline | remove — show state with a badge |

## Text

| Current value | Where | Use instead |
|---|---|---|
| `#bfc9f5` | Body, titles, sidebar names | `ink` |
| `#a8b0d5` | Ticket titles, metadata, chain subtitles | `ink` for titles, `ink-muted` for metadata |
| `#767e9d`, `#787f9c` | Select text, placeholders | `ink-muted` |
| `#575f87` | Section labels (UP NEXT, FINISHED) — fails contrast today | `ink-subtle` with the `overline` style |

## Accents and status

| Current value | Where | Use instead |
|---|---|---|
| `#79a1f7` | New ticket / New project buttons, active tab, inline code | `accent` (now gold) — periwinkle is retired |
| `#284caf` | Edit button | `accent` (primary button) |
| `#9dcd6a` | Done chips, progress, status dots, Vault | `success` |
| `#7cceff` | Instances count in status bar | `info` |

## Patterns to retire

- Outlined chips (Current, Active, Default outlines) → soft `Badge` (metadata) or `StatusPill` (state) with a tone.
- Boxed selected tab → one underline style: `ink` label with a 2px `accent` underline.
- Highlighted card border on the expanded ticket → the same `Panel`, state shown by a StatusPill; a ticket that needs you uses the `accent-tint` Panel.
- Mixed title sizes across panels → `display` for the page h1 (PageShell), `heading` for panel and modal headings, `title` for card and ticket titles.

## Code tokens (`src/ui/tokens.css`)

The app already routes components through `--color-*` variables. Point each one at the system's value and most of the app follows without touching components.

| Variable in the app | Today | Set to |
|---|---|---|
| `--color-canvas` | `#090909` | `bg-000` #0f0f0f |
| `--color-surface` | `#141414` | `bg-100` #191919 |
| `--color-surface-raised` | `#1c1c1c` | `bg-200` #1f1f1f |
| `--color-border-subtle` | `#262626` | `border` #303030 |
| `--color-border-strong` | `#3a3a3a` | `border-strong` #3b3b3b |
| `--color-text-primary` | `#ffffff` | `ink` #efefef |
| `--color-text-muted` | `#999999` | `ink-muted` #9c9c9c |
| `--color-text-faint` | `#6b6b6b` — fails 4.5:1 | `ink-subtle` #8a8a8a |
| `--color-accent` | `#d2a965` | `accent` #e8ba5a (logo gold) |
| `--color-accent-fg` | `#000000` | `on-accent` #121212 |
| `--color-success` | `#22c55e` | `success` #9dcd6a |
| `--color-warning` | `#f59e0b` | `warning` #f28c4f |
| `--color-danger` | `#ef4444` | `danger` #ef8a80 |
| `--color-info` | `#0099ff` | `info` #7cceff |
| `--color-*-soft` | `color-mix` at 86% | the matching `-tint` (`success-tint`, …) |
| `--color-focus-ring` | accent at 35% | `focus` (solid gold) |
| `--radius-md` · `--radius-lg` | 10px · 16px | 8px · 12px (add `--radius-xl` 16px for Modal) |
| `--font-body` · `--font-mono` | system stacks | IBM Plex Sans · IBM Plex Mono; add a serif for `display`, `heading`, `reading` |
| `--text-display-*` | 22px bold sans | serif 32/38 400 |
| `--text-heading-*` | 18px bold sans | serif 20/28 500 |
| `--text-caption-size` · `--text-overline-tracking` | 11px · 0.16em | 11px · 0.06em |

Also in `toneStyles.ts`: map `pending` to the info tone instead of warning, and give `danger` buttons the `danger-tint` fill with `danger` text instead of a solid red.
