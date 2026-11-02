# FormField

Label + control + hint + error, wired for you: `<FormField label hint error required><Input … /></FormField>`.

| Prop | Values | Notes |
|---|---|---|
| `label` | node — required | `label` style, `ink-muted`. |
| `hint` | node | `ink-subtle` 12/16 under the control. |
| `error` | node | Replaces the hint in `danger` with an `alert` icon and sets the control `invalid`. |
| `required` | boolean | Adds a gold asterisk. |
| `children` | one @ui control | Input, Textarea, Select, Combobox, Checkbox… |

Stack fields with `space-4` between them; label-to-control gap 6px. Write errors as the fix ("Enter owner/repo…"), not the fault.
