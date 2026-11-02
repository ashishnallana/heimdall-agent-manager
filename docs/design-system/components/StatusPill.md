# StatusPill

A labelled state the user reads as status — Running, Offline, Completed: `<StatusPill tone emphasis>Running</StatusPill>`. Fully rounded (`radius-full`) to set it apart from the square Badge.

| Prop | Values | Notes |
|---|---|---|
| `tone` | `neutral` · `info` · `success` · `warning` · `danger` · `pending` | Same tone map as Badge: info/pending = running, success = done, warning = needs a person, danger = failed, neutral = idle/offline. |
| `emphasis` | `soft` · `outline` · `solid` | `soft` default. |
| `children` | string — required | The state word. |

For live states, compose a leading StatusDot (6px) inside the pill — with `pulse` only while running.

**Don't** put a StatusPill and a Badge with the same tone next to each other; one state, one pill.
