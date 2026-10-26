---
name: artifact-authoring
description: How to produce a deliverable the user will read or view in Heimdall (a report, a diagram or screenshot, a multi-page static site) as an artifact. Covers choosing Markdown vs image vs html-bundle, writing each well, uploading it with `ham-ctl artifact create`, checking the upload, and delivering it in chat or a task comment as an `artifact://<id>` link. Load whenever the user asks for a document, report, image or page, or when a result is too long or too visual for a chat message.
---

# Author artifacts for the user

An artifact is a file stored in the Hub (sealed with your vault key) that the user opens in
the **Artifact Viewer**. Use one when a result is too long, too structured or too visual for a
chat message, or when the user asks for a document, image or page. Exact flags: `ham-ctl
artifact --help` or the `ham-ctl-reference` skill. Bundle format and viewer rules:
`docs/html-bundle-artifacts.md` in the Heimdall repository.

## 1. Choose the format

| The user needs | Use | `create` flags |
|---|---|---|
| A report, summary, plan, runbook, review, table of results | **Markdown** (the default) | `--kind markdown --file report.md` |
| A screenshot, chart, diagram or photo that already exists as a file | **Image** | `--kind image --content-type image/png --file chart.png` |
| Several linked pages, a styled layout, a document with images inline | **HTML bundle** | `--kind html-bundle --directory site` |
| A short answer, a status, a question | No artifact: a chat message | `ham-ctl chat send --to user --body …` |

Prefer the simplest format that works. Markdown renders headings, tables, code and Mermaid in
the viewer; reach for an HTML bundle only when layout, several pages or inline images matter.
`--kind` defaults to `markdown`, so **always pass `--kind` for anything else**: the viewer
picks its renderer from `kind` first, and an image uploaded without `--kind image` is shown
as text. JSON (`--kind json`) and diffs (`--kind diff`) also have viewers.

## 2. Write it well

**Markdown**
- A standalone document: a `#` title, a one-paragraph summary first, then `##` sections. The
  reader has not seen your session; define terms, name files and ids in full.
- Tables for comparisons and results; fenced code blocks with a language for commands, code
  and logs; normal links for URLs.
- End-user content only. Leave out tool chatter, "I ran…", scratch paths and attempt logs
  unless the reader asked for them.

**Images**
- Upload a file that already exists: a screenshot you captured, a chart rendered by a
  plotting tool you actually have, an asset from the repository. If no image generator is
  available, say so and offer Markdown (a Mermaid diagram or a table) instead; never claim to
  have generated an image you did not.
- Match `--content-type` to the real format (`image/png`, `image/jpeg`, `image/gif`,
  `image/webp`, `image/svg+xml`) and use a descriptive `--name` with that extension
  (`latency-p95-by-region.png`, not `image1.png`).
- Make it legible at phone width: large labels, no tiny text, sensible pixel size. Crop
  screenshots to the part that matters.

**HTML bundles** (static site viewed in a sandboxed iframe)
- Local HTML, CSS, images and fonts only. **No JavaScript** (scripts, `on*` handlers and
  `javascript:` URLs are removed), **no remote URLs** (CDN stylesheets, web fonts, remote
  images are dropped and listed as warnings), no forms, iframes, objects or `<base>`.
  Inline all styling you need; use system font stacks or bundle font files.
- Relative paths everywhere (`assets/style.css`, `../index.html`, `#section`). `/x` means
  the bundle root. Paths are case-sensitive.
- Entry page: a root `index.html`, or pass `--entry docs/index.html`. With several pages and
  no root `index.html`, `--entry` is required.
- Responsive and readable: `<meta name="viewport" content="width=device-width,
  initial-scale=1">`, a max content width, `img { max-width: 100% }`, a nav linking every page.
- Limits: 10 MiB archive, 50 MiB expanded, 1000 files, 10 MiB per file; symlinks are skipped.

Before uploading a bundle, check every local reference resolves (run from the site root;
prints nothing when all links are fine):

```bash
cd site && find . -name '*.html' -o -name '*.htm' -o -name '*.css' | while read -r f; do
  d=$(dirname "$f")
  grep -oE '(href|src)="[^"]+"|url\([^)]+\)' "$f" | sed -E 's/^(href|src)="//; s/"$//; s/^url\(["'"'"']?//; s/["'"'"']?\)$//' |
  grep -vE '^(#|data:|mailto:)' | sed 's/#.*//' | while read -r p; do
    case "$p" in http*|//*) echo "REMOTE (will be dropped): $f -> $p"; continue;; /*) t=".$p";; *) t="$d/$p";; esac
    [ -e "$t" ] || echo "MISSING: $f -> $p"
  done
done
```

## 3. Upload

```bash
# Markdown report, linked to your task so it shows up with the task's artifacts
ham-ctl artifact create --name auth-review.md --kind markdown --file auth-review.md \
  --task task_123

# Existing image file
ham-ctl artifact create --name latency-p95-by-region.png --kind image \
  --content-type image/png --file out/latency.png

# Static site from a directory (index.html at its root)
ham-ctl artifact create --name release-notes --kind html-bundle --directory ./site

# Site whose landing page is not the root index.html
ham-ctl artifact create --name design-doc --kind html-bundle --directory ./site --entry docs/index.html

# Prepared ZIP: zip from INSIDE the site so pages sit at the archive root
(cd site && zip -r ../site.zip .) && ham-ctl artifact create --name design-doc --kind html-bundle --file site.zip
```

Optional context flags: `--task <id>`, `--chain <id>`, `--project <id>`, `--description <t>`.
The JSON reply carries `data.artifact_id` (`art_…`); keep it. Uploads are capped at 50 MiB.
Never use `--content` for large or binary payloads; use `--file`.

## 4. Verify before you deliver

- Read the reply: `ok:true`, the expected `kind` and `content_type` (`text/markdown`,
  `image/png`, `application/zip` for bundles). For bundles, read stderr: skipped symlinks are
  reported there.
- Round-trip it: `ham-ctl artifact content <art-id>` for text, or
  `ham-ctl artifact download <art-id> --dir <scratch-dir>` and compare with the source
  (`cmp`), or list a bundle's ZIP members to confirm `heimdall-artifact.json` and the entry.
- If the upload is wrong, fix the source and create a new artifact; deliver only the good id.

## 5. Deliver it

Put an `artifact://<art-id>` link in your message. The chat and task-comment renderers turn it
into a chip that opens the Artifact Viewer; `[label](artifact://<art-id>)` gives the chip a
label. There is no separate attachment flag on `chat send`.

```bash
ham-ctl chat send --to user --body "### Auth review ready

Summary: 2 blockers, 5 suggestions. Full report: [Auth review](artifact://art_18e2abc123)"

ham-ctl task comment task_123 --body "Report uploaded: artifact://art_18e2abc123"
```

In the message, say in one or two lines what the artifact contains and what you want from the
user (read, decide, approve). For task work, also reference the id in your
`lease submit --summary` so reviewers and later tasks find it.
