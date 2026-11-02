# Alert

An inline banner tied to the content around it: `<Alert tone emphasis title icon onDismiss>message</Alert>`.

**Not for** field errors (FormField `error`), transient confirmations (Toast) or a status label (StatusPill).

| Prop | Values | Notes |
|---|---|---|
| `tone` | `neutral` · `info` · `success` · `warning` · `danger` · `pending` | Sets the tint and icon colour. `danger` gets `role="alert"`. |
| `emphasis` | `soft` · `outline` · `solid` | `soft` default (tone tint) — use it for every tone so alerts look alike. `outline` = no fill and a neutral `border-strong` hairline, the tone shown only by the icon; for quiet notes inside a Panel. Avoid `solid`. |
| `title` | node | `title` weight in `ink`; the icon and tint carry the tone. |
| `icon` | icon name or null | Defaults: info→`info`, success→`check`, warning/danger→`alert`. |
| `onDismiss` | () => void | Adds a ghost close IconButton. |

Shape: `radius-lg`, `space-3`/`space-4` padding, 16px icon top-aligned. **Do** say what happened and what to do next. **Don't** stack more than two alerts.
