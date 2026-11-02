# Modal

A focus-managed centred dialog: `<Modal open onOpenChange title size><Modal.Body>…</Modal.Body><Modal.Footer>…</Modal.Footer></Modal>`.

| Prop | Values | Notes |
|---|---|---|
| `open / onOpenChange` | boolean / (open) => void | Controlled. Esc, backdrop click and the close button all call onOpenChange(false). |
| `title` | node — required | `heading` style (serif 20/28), labels the dialog. |
| `size` | `sm` 448 · `md` 560 · `lg` 720 · `xl` 960 | sm for confirmations, md for forms, lg/xl for settings-like content. |
| `Modal.Body / Modal.Footer` | composition | Footer right-aligns buttons: secondary/ghost first, primary or danger last. |

**Look:** `scrim` backdrop; dialog `bg-200`, `radius-xl`, `shadow-modal`; header and footer separated by `border` hairlines; body padding `space-6`.

**Don't** open a modal from a modal, or use one for something a Menu or inline edit could do.
