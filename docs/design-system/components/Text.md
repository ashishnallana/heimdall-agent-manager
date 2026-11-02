# Text

All typography through one `role`: `<Text role="…" tone="…" as="…">`. Each role maps to the type style of the same name in this system.

| Role | Style | Use for |
|---|---|---|
| `display` | serif 32/38 | The page's single h1 (PageShell sets it) and empty-state headlines |
| `heading` | serif 20/28, 500 | Section headings, Panel/Modal titles in detail panes |
| `title` | sans 15/22, 600 | Card, ticket and row titles; Alert/Toast titles |
| `body` | sans 14/20 | Default UI text |
| `body-sm` | sans 13/18 | Metadata, descriptions, hints |
| `label` | sans 12/16, 500 | Form labels, badge text, counts |
| `caption` | sans 11/16, 500 | Timestamps, status bar |
| `overline` | sans 11/16, 600, +0.06em, uppercase | Section labels (UP NEXT, FINISHED), eyebrows |
| `code` | mono 13/20 | Paths, branches, commands, IDs |

Agent replies are not a Text role: wrap the chat markdown in the `reading` style (serif 16/26, 72ch).

| Prop | Values | Notes |
|---|---|---|
| `role` | see table | Never use raw size classes. |
| `tone` | `primary` · `muted` · `faint` · `accent` · `success` · `warning` · `danger` | → `ink` · `ink-muted` · `ink-subtle` · `accent` · status colours. `faint` only on `bg-000`–`bg-200`. |
| `as` | `h1`–`h6` · `p` · `span` · `div` · `label` | Semantic element; independent of role. |
| `truncate` | boolean | Single-line ellipsis. |

**Don't** set controls in serif or prose replies in sans. **Don't** put `accent` on non-interactive text except inline code.
