# EmptyState

"Nothing here yet" / "No matches": `<EmptyState icon title description action />`.

| Prop | Values | Notes |
|---|---|---|
| `icon` | icon name | Shown at 20px in a 40px `bg-300` well. |
| `title` | node | `heading` style (serif). |
| `description` | node | One or two sentences, `ink-muted`, max 400px. |
| `action` | a Button or Link | Usually the primary action that fills the space. |
| `children` | node | Free body when title/description don't fit. |

Dashed `bg-500` border, `radius-lg`, `space-12` vertical padding. For "no search results", drop the action and suggest what to change. **Not for** loading (Spinner) or errors (Alert).
