# Button

The one labelled action: `<Button>` from `@ui`, styled as `nj-btn`. Use one `primary` per view; everything else is `secondary` or `ghost`.

**Not for** navigation (use Link), icon-only actions (IconButton) or menus of actions (Menu).

| Prop | Values | Notes |
|---|---|---|
| `variant` | `primary` · `secondary` · `ghost` · `danger` | Default `secondary`. Class `nj-btn--<variant>`. |
| `tone` | `success` · `warning` · `danger` | Soft tinted action (Approve, Request changes). Class `nj-btn--tone-<tone>`; overrides variant colour. |
| `size` | `sm` 28px · `md` 32px · `lg` 40px | `md` default. sm inside cards/rows, lg for a page's main CTA only. |
| `width` | `content` · `full` | `full` → `nj-btn--full` (modal footers on mobile, auth forms). |
| `leading / trailing` | an `<Icon>` | 16px icon (14px at sm), `currentColor`. |
| `loading` | boolean | Shows a Spinner, sets `aria-busy`, keeps the width. |
| `disabled` | boolean | 45% opacity. |

**Look:** primary = `accent` gold with `on-accent` text; secondary = `bg-500`; ghost = no fill until hover (`bg-300`); danger = `danger-tint` fill with `danger` text — never a solid red block. Label 500 weight, sentence case, 1–3 words.

**Do** put the primary action last (rightmost) in a row. **Don't** place two primaries side by side, or use `danger` for anything reversible.
