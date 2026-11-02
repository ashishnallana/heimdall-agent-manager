# Panel

The one content container — and the card: `<Panel title actions padding tone href onClick>`.

| Prop | Values | Notes |
|---|---|---|
| `title` | node | `title` style header with a hairline under it. |
| `actions` | node | Right side of the header: sm Buttons or IconButtons. |
| `padding` | `none` · `sm` 12 · `md` 16 · `lg` 24 | md default. `none` when the body is a list with its own rows. |
| `tone` | `raised` · `sunken` | raised = `bg-200` (default); sunken = `bg-000`, for code, IDs and nested read-only blocks. |
| `href / onClick` |  | Makes the whole panel an `<a>`/`<button>` with `bg-300` hover and a focus ring — this is the ticket/project card. |
| `disabled` | boolean |  |

Always `border` + `radius-lg`, never a shadow, never a coloured left edge. The ticket board's "needs you" card is a Panel with `accent-tint` fill (`nj-panel--needs-you`).

**Don't** put a Panel inside a Panel — separate parts inside one with hairlines.
