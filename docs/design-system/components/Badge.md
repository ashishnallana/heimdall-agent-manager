# Badge

Inert metadata — a count, a tag, a kind: `<Badge tone emphasis>`. Square-cornered (`radius-sm`) so it reads differently from a StatusPill.

**Not for** a state the user reads as status (StatusPill), liveness (StatusDot) or anything clickable.

| Prop | Values | Notes |
|---|---|---|
| `tone` | `neutral` · `info` · `success` · `warning` · `danger` · `pending` | Classes `nj-tone-<tone>`. `pending` uses the `info` blue (in progress), no longer the warning amber. |
| `emphasis` | `soft` · `outline` · `solid` | `soft` default (tint fill + tone text). `outline` (`nj-em-outline`) only on busy surfaces; `solid` (`nj-em-solid`) only for a count that must shout. |

Text is `label` (12/16, 500), 20px tall. An extra **accent** tone (`nj-tone-accent`) marks Default / Current.

**Do** keep it to one or two words. **Don't** use more than two badges on one line or rely on colour alone.
