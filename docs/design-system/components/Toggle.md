# Toggle

A switch for a setting that takes effect immediately: `<Toggle checked onChange size aria-label />`, `role="switch"`.

| Prop | Values | Notes |
|---|---|---|
| `checked / onChange` | boolean |  |
| `size` | `sm` 26×14 · `md` 32×18 |  |
| `disabled` | boolean |  |

On = `accent` track with an `on-accent` knob; off = `bg-500` track, `ink-muted` knob. Place it at the right end of a settings row (`nj-toggle-row`) with the label on the left.

**Don't** use it inside a form that has a Save button — that's a Checkbox.
