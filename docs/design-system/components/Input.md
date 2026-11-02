# Input

Single-line text: `<Input value onChange type size width invalid />`, styled `nj-input`. Wrap in FormField for a label.

| Prop | Values | Notes |
|---|---|---|
| `value / onChange` | string / (value) => void | Controlled. |
| `type` | `text` · `search` · `email` · `password` · `number` · `tel` · `url` |  |
| `size` | `sm` 28 · `md` 36 · `lg` 40 | md default. |
| `width` | `full` · `content` | `full` default; `content` = 240px for filters. |
| `invalid` | boolean | `danger` border; set by FormField `error`. |
| `leading / trailing` | Icon, Kbd | Search icon + ⌘K for search fields. |

**Look:** `bg-400` fill, no visible border until hover (`bg-500`) or focus (`focus` gold, 1px + 1px glow). Placeholder `ink-muted`. Paths, IDs and commands use `nj-input--mono`.

**Don't** place an Input on a `bg-400` surface, or use outlined fields.
