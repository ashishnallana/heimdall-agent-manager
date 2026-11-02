# IconButton

An icon-only action — close, edit, overflow, refresh, send. Styled as `nj-iconbtn`.

**Not for** an action with visible text (Button with `leading`) or a decorative glyph (Icon).

| Prop | Values | Notes |
|---|---|---|
| `icon` | an icon name | From the app icon set (see `assets/brand/icons/`). |
| `label` | string — required | Becomes `aria-label` and the hover tooltip. |
| `variant` | `ghost` · `solid` · `danger` | `ghost` default: `ink-muted`, `bg-300` on hover. `solid`: `bg-500` fill. `danger`: `danger` icon, `danger-tint` hover. |
| `size` | `sm` 28 · `md` 32 · `lg` 40 | Icon 14 / 16 / 20px. Keep a 44px hit area on touch. |
| `loading · disabled` | boolean |  |

**Do** use `ghost` in toolbars, card headers and panel tabs; `solid` for the composer's send. **Don't** colour an icon button gold — gold belongs to the one primary Button.
