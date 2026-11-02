# Combobox

A searchable picker for long lists, single or `multiple`: `<Combobox options value onChange multiple placeholder searchPlaceholder emptyLabel />`.

| Prop | Values | Notes |
|---|---|---|
| `options` | `{value, label, …}[]` |  |
| `multiple` | boolean | Multi mode renders chosen values as removable chips (`nj-chip`). |
| `value / onChange` | string, or string[] when multiple | Controlled. |
| `placeholder · searchPlaceholder · emptyLabel` | string | emptyLabel shows in `nj-listbox__empty` ("No projects match"). |
| `loading · invalid · disabled` | boolean |  |

Shares the Select listbox. Chips are `bg-500`, `radius-sm`, with a ghost `close` button. **Use Select** for short fixed lists.
