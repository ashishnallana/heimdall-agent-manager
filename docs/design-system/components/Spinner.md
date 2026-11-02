# Spinner

The one indeterminate loading glyph: `<Spinner size label />`, a ring with a gap drawn in `currentColor` (`nj-spinner`).

| Prop | Values | Notes |
|---|---|---|
| `size` | `sm` 12 · `md` 16 · `lg` 24 | sm inline with text, lg for a whole panel. |
| `label` | string | Accessible name, default "Loading…". |

Default colour `ink-muted`; use `nj-spinner--accent` only for the page's main load. Buttons show their own spinner through `loading`. Pair with words when the wait is longer than a second ("Loading chains…").
