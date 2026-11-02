# Menu

A popover list of actions from a trigger: `<Menu trigger={<IconButton …/>} label align side><Menu.Item …/></Menu>`.

**Not for** choosing a value (Select/Combobox).

| Prop | Values | Notes |
|---|---|---|
| `trigger` | a Button or IconButton | Gets `aria-haspopup` / `aria-expanded`. |
| `label` | string | Accessible name for the menu. |
| `align` | `start` · `end` | `end` for kebab menus at the right edge. |
| `side` | `bottom` · `top` |  |
| `open / onOpenChange` | optional | Uncontrolled by default. |
| `Menu.Item` | children | Leading 16px icon, label, optional trailing Kbd; `danger` items go last after a separator. |

**Look:** `bg-200`, `border-strong`, `radius-lg`, `shadow-pop`, 4px inset; items 32px, hover `bg-300`, icons `ink-muted`.

**Do** keep labels as verbs and under ~6 items. **Don't** nest menus.
