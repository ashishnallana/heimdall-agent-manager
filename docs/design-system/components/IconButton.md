# IconButton

An icon-only action — close, edit, overflow, refresh, send. Styled as `nj-iconbtn`.

**Not for** an action with visible text (Button with `leading`) or a decorative glyph (Icon).

| Prop | Values | Notes |
|---|---|---|
| `icon` | an icon name | From the app icon set (see `assets/brand/icons/`). |
| `label` | string — required | Becomes `aria-label` and the hover tooltip. |
| `variant` | `ghost` · `solid` · `danger` · `primary` | `ghost` default: `ink-muted`, `bg-300` on hover. `solid`: `bg-500` fill. `danger`: `danger` icon, `danger-tint` hover. `primary`: `accent` fill, `on-accent` glyph, brightens on hover and scales to .96 on press (no scale under reduced motion). |
| `size` | `sm` 28 · `md` 32 · `lg` 40 | Icon 14 / 16 / 20px. Keep a 44px hit area on touch. |
| `loading · disabled` | boolean |  |

**Do** use `ghost` in toolbars, card headers and panel tabs; `solid` for the conversation pane composer's send. **Don't** colour an icon button gold — gold belongs to the one primary action. The one exception is `primary`, for a page whose single primary action is icon-only: the new conversation composer's send (`arrow-up`).
