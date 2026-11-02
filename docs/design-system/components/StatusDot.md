# StatusDot

A liveness dot — online, working, offline: `<StatusDot tone label pulse size />`.

| Prop | Values | Notes |
|---|---|---|
| `tone` | `neutral` · `info` · `success` · `warning` · `danger` · `pending` | neutral = idle/finished (`ink-subtle`). |
| `label` | string — required | Accessible name; colour alone is never the message. |
| `pulse` | boolean | Only for `info`/`pending` while something is actively running. Respects reduced motion. |
| `size` | `sm` 6px · `md` 8px | sm inside pills and dense lists. |

**Do** keep visible text beside every dot (sidebar chains, bridges, the Tickets summary). **Don't** enlarge it past 8px or use it as a decoration.
