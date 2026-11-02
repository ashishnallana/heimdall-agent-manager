# PageShell

The frame every route renders into: `<PageShell title breadcrumbs eyebrow description actions width loading error>`.

| Prop | Values | Notes |
|---|---|---|
| `title` | node — required | The page's single h1, `display` style (serif 32/38). |
| `breadcrumbs` | `Crumb[]` | Pass the full trail; only ancestors render (the title is the last crumb). |
| `eyebrow` | string | `overline` style above the title (type · updated). |
| `description` | node | `body`, `ink-muted`, max 600px. |
| `actions` | node | Right-aligned, bottom-aligned to the title: IconButtons then one primary Button. |
| `width` | `content` 960 · `wide` 1200 · `full` | content for detail and settings pages, wide for boards and lists. |
| `loading · error` |  | Shows a Spinner or an Alert in place of the body. |

Header ends with a `border` hairline and `space-6` gap; page padding `space-8` (desktop), sections inside the body `space-6` apart.
