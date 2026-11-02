# Icon

The app's own monochrome glyphs: `<Icon name="…" size="…" />`. 59 icons on a 24px grid, ~1.8px round strokes, drawn in `currentColor`. SVG copies are in `assets/brand/icons/`.

| Prop | Values | Notes |
|---|---|---|
| `name` | one of the 59 names | No emoji and no text glyphs (×, ›, …) anywhere in the UI. |
| `size` | `sm` 14 · `md` 16 · `lg` 20 · `xl` 24 | md in buttons and rows, sm in sm controls and badges, lg in tiles and empty states, xl for hero moments. |
| `title` | string | Gives a meaningful icon an accessible name; otherwise it is decorative. |

**Colour:** icons inherit text colour — `ink-muted` beside labels, `ink` when the icon is the content, a status colour only inside a matching status component.

**Don't** mix in icons from another library; add new glyphs to `Icon.tsx` in the same stroke style.
