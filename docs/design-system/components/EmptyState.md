# EmptyState

"Nothing here yet" / "No matches": `<EmptyState icon title description action />`.

| Prop | Values | Notes |
|---|---|---|
| `icon` | icon name | Shown at 20px in a 40px `bg-300` well. |
| `title` | node | `heading` style (serif). |
| `description` | node | One or two sentences, `ink-muted`, max 400px. |
| `action` | a Button or Link | Usually the primary action that fills the space. |
| `children` | node | Free body when title/description don't fit. |
| `variant` | `card` · `page` | `card` (default) is the dashed placeholder. `page` is a whole-page blocked state (e.g. the launcher's "No bridge is online"): no card, centred column max 560px, 24px rhythm, `children` laid out as full-width blocks (panels, action rows, notes). |
| `media` | node | Replaces `icon`, e.g. a 56px `IconWell` with a status tone. |

Dashed `bg-500` border, `radius-lg`, `space-12` vertical padding. For "no search results", drop the action and suggest what to change. **Not for** loading (Spinner) or errors (Alert).
