# Select

Choosing one value from a short known list: `<Select value onChange options size width placeholder />`. A custom button trigger (`nj-select`) and listbox (`nj-listbox`) — never a native popup.

| Prop | Values | Notes |
|---|---|---|
| `value / onChange` | string | Controlled. |
| `options or children` | `{value, label, text, disabled}[]` or `<option>`/`<optgroup>` | Groups render as overline headers (`nj-listbox__group`). |
| `size` | `sm` · `md` | Matches Input heights. |
| `width` | `full` · `content` |  |
| `placeholder` | string | `ink-muted` until chosen. |
| `invalid · disabled` | boolean |  |

**Look:** trigger like an Input with a trailing `chevron-down`; listbox on `bg-200`, `border-strong`, `radius-lg`, `shadow-pop`; options 32px, hover `bg-300`, selected option gold text + check.

**Use Combobox instead** when the list is long or needs type-ahead or multi-select.
