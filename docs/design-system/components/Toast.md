# Toast

A transient notification card: `<Toast tone title icon duration onDismiss>detail</Toast>`. Stacks bottom-right (`nj-toast-stack`, `space-2` apart, newest at the bottom).

| Prop | Values | Notes |
|---|---|---|
| `tone` | `neutral` · `info` · `success` · `warning` · `danger` · `pending` | Colours only the icon — the card stays neutral (`bg-200`, `border-strong`, `shadow-pop`). |
| `title` | node — required | `title` weight, `ink`. |
| `children` | node | One line in `ink-muted`. |
| `duration` | ms | Auto-dismiss; leave unset for `danger`. |
| `onDismiss` | () => void | Ghost close button. |

360px wide, `radius-lg`. **Do** confirm what just happened in past tense. **Don't** put actions that matter only in a toast.
