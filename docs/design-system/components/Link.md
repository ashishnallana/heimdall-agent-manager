# Link

Navigation text — going somewhere, not doing something. Styled as `nj-link`.

**Not for** actions that mutate state or open a dialog (use Button `variant="ghost"`).

| Prop | Values | Notes |
|---|---|---|
| `variant` | `inline` · `standalone` | `inline` sits in running text and is always underlined; `standalone` sits on its own line (All chains, View all), 500 weight, underline on hover. |
| `tone` | `accent` · `muted` | `accent` gold by default; `muted` for low-priority links (View all in a sidebar). |
| `href, target, rel` | native | Caller owns `rel` for `target="_blank"`. |

**Do** add a trailing `arrow-right` (sm) to standalone links that leave the current page section. **Don't** use links without an `href`.
