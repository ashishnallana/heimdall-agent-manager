# Static HTML bundle artifacts

An agent or user can publish a multi-page static site (HTML, CSS, local images and fonts,
plus inert JavaScript and data files) as one artifact. The user opens it in the Artifact
Viewer, which renders it in an isolated iframe with no server running and no script
execution.

## Upload paths

| Path | How | Validation |
|---|---|---|
| ham-ctl | `artifact create --kind html-bundle --directory … \| --file …` (below) | `src/lib/html_bundle` (format core shared with MCP) via `src/ctl/html_bundle.odin`, before sealing |
| UI | Artifact upload button / composer: pick a `.zip` | `readHtmlBundle` in the browser before upload; a ZIP that is not a valid bundle (e.g. no manifest) is refused with the reason |
| HTTP API | `POST /api/v1/artifacts` with `kind: "html-bundle"`, `mime: "application/zip"`, `content_base64` | The Hub stores the (usually vault-sealed) bytes opaquely; it cannot inspect sealed content, so validation happens in the producing client and again in the viewer |
| MCP | `artifacts.create` with `entry` + `files` (`{"path":{"text"|"base64","type"?}}`), see `docs/mcp-capabilities.md`; `list`/`get` return bundle metadata (`kind`, `content_type: application/zip`, `size_bytes`) | The Hub validates and packs with `html_bundle_from_entry_files` (`src/lib/html_bundle`), the sealing device/hosted vault re-validates the archive before sealing its exact bytes, and the viewer validates again |

Both ham-ctl and the UI seal the exact archive bytes when the vault is available
(`encryptVaultBytes` in the UI), so **Download** returns the byte-identical ZIP.

## CLI

```bash
# Pack a directory (relative paths kept, symlinks skipped and reported on stderr)
ham-ctl artifact create --name report --kind html-bundle --directory ./site [--entry docs/index.html]

# Upload a prepared ZIP (validated; a manifest is appended if it has none).
# Zip from inside the site so its pages sit at the archive root: (cd site && zip -r ../site.zip .)
ham-ctl artifact create --name report --kind html-bundle --file ./site.zip [--entry index.html]
```

The entry page is resolved in this order:
1. `--entry`. If the bundle already has a manifest, `--entry` must match it; a mismatch is an error.
2. The manifest `entrypoint`.
3. A root `index.html`.
4. The only `.html`/`.htm` file in the bundle.
5. Otherwise the command fails, lists the candidate pages and asks for `--entry`.

The entry must be an existing HTML member. Paths are case-sensitive. Without `--kind
html-bundle`, a ZIP is still uploaded as an ordinary file artifact, and `--directory` or
`--entry` is rejected.

## Format (format_version 1)

- A ZIP whose members use the stored (0) or deflate (8) method. Directories are packed as
  stored entries, because Odin core has no deflate encoder.
- `heimdall-artifact.json` sits at the archive root and contains exactly
  `{"format_version": 1, "entrypoint": "<relative path>.html"}`. Unknown fields, other
  versions and trailing data are rejected.
- Artifact metadata: `kind = html-bundle`, `content_type = application/zip`. The archive
  bytes are vault-sealed as-is, so **Download** returns the byte-identical ZIP.

### Rejected archives (CLI and viewer)

- Paths: absolute, `..`/`.`/empty segments, backslashes, drive letters, control characters,
  non-UTF-8, and duplicate or file/directory-clashing paths.
- Members: symlinks, nested archives (by extension or `PK\x03\x04` magic), encrypted entries,
  Zip64, multi-disk archives, other compression methods, overlapping members, and CRC or
  size mismatches.
- Member types (case-insensitive extension allowlist, `HTML_BUNDLE_ALLOWED_EXTENSIONS` in
  both layers): pages `.html .htm`; stylesheets `.css`; images `.png .jpg .jpeg .gif .webp
  .avif .bmp .ico .svg`; fonts `.woff .woff2 .ttf .otf .eot`; **inert** `.js .mjs .json .map
  .txt .md .xml .csv .webmanifest`. Anything else, including files without an extension
  (`LICENSE`, `.DS_Store`), `.wasm`, `.php`, executables and media, is rejected.
- Limits (bytes are binary units; "15 MB" is the artifact limit from REQ-ART-1):

  | Limit | Value | Why |
  |---|---|---|
  | Archive (the artifact content) | **15 MB = 15 MiB = 15,728,640 bytes** | Same as `contracts.ARTIFACT_MAX_CONTENT_BYTES`; the ZIP *is* the artifact content. Vault/base64 overhead is budgeted by the Hub separately |
  | Expanded total | 50 MiB, declared **and** actual | Bounds decompression output; inflation stops once a member passes its declared size |
  | Per member | 15 MiB | No member can be larger than the archive limit |
  | Entries | 1000 | Bounds central-directory and per-member work |
  | Manifest | 64 KiB | |
  | Member path | 1024 bytes | |

  The archive limit applies to the ZIP as uploaded (with a generated manifest included);
  the expanded limit applies to the sum of decompressed members. A 15 MiB ZIP of
  compressible text may still be rejected for expanding past 50 MiB.

## Viewer

`src/ui/utils/htmlBundle.ts` and `src/ui/components/HtmlBundlePreview.tsx` handle
rendering:

- **Decrypting**: `decryptVaultBytes` decrypts the content without passing it through text
  decoding. The archive is parsed and validated in memory and never extracted to disk.
- **Compiling pages**: each page becomes a `srcdoc` document.
  - Removed: scripts, `on*` handlers, executable URLs, frames/objects/embeds, `<base>`,
    `<meta http-equiv>` and SVG animation elements (`<animate>`, `<set>`,
    `<animateMotion>`, `<animateTransform>`, `<animateColor>`, `<discard>`). SMIL runs
    without script and could otherwise retarget a link to a remote URL after compilation.
    Forms are converted to plain `<div>`s.
  - Local images and fonts become `blob:` URLs. Stylesheets are inlined, with `@import`
    inlined recursively and `url()` resolved relative to the stylesheet. `/x` means the
    bundle root.
  - Remote references are dropped and listed in a resource warning.
  - `<use>` keeps only same-document references (`#id`). An external SVG document
    would be cloned into the page outside the sanitizer, so the reference is dropped
    and listed as a resource warning. `<img>`/`<image>` load SVG in inert image mode.
  - `<style>` contents are serialized raw, so every `</` in compiled CSS is written as
    the CSS escape `\3c /`. Otherwise a `</style>` in a bundled stylesheet or a decoded
    `url("#…")` fragment would end the element and inject markup when the iframe parses
    the page. CSS `url("#…")` fragments are percent-encoded again for the same reason.
  - **Reparse check**: the compiled text is parsed again and checked for anything the
    compiler never emits: removed elements, handlers, link targets other than
    `about:srcdoc#…`, URLs other than the renderer's own `blob:` URLs or
    `data:image|font`, and `</` inside `<style>`. A page that fails is not rendered
    (`unsafe` error).
  - A CSP meta allows only `blob:`/`data:` images and fonts plus inline styles.
- **Navigation**:
  - Fragment links, and links to the page itself (`index.html#s2` on `index.html`), are
    rewritten to `about:srcdoc#frag` and scroll natively. A bare `#frag` in a `srcdoc`
    document resolves against the *parent* URL and would navigate the frame away.
  - Links to other pages are rewritten to
    `about:srcdoc#hb-page=<page>[&hb-fragment=<fragment>]`, both percent-encoded
    (`htmlBundleNavHash`). Clicking, keyboard activation and `<area>` all navigate the
    frame natively to that fragment. The viewer polls the frame's `location.hash` every
    100 ms, parses it with `parseHtmlBundleNavHash`, and switches pages, keeping the page
    selector in sync. `data-hb-page`/`data-hb-fragment` stay on the link as inert metadata.
  - Why polling: WebKit (Safari, including iPad) never runs listeners the host registers
    on a script-disabled frame (`click`, `pointerdown`, `hashchange`, `scroll`), so the
    earlier host click handler did nothing there. See
    `docs/investigations/html-bundle-navigation-diagnosis.md`.
  - Route validation: only `hb-page=` plus an optional `hb-fragment=` is accepted, with
    strict percent-decoding, a valid member path and an `.html`/`.htm` page that exists in
    the bundle being shown. Anything else is ignored. Authored fragments are always
    written encoded, so an authored `#hb-page=x` becomes `#hb-page%3Dx` and is only a
    fragment.
  - Lifecycle: the poll reads only the document loaded for the current page, and only
    while the bundle is ready. A page switch, version change, close or vault lock stops
    it reading the old document before the old renderer is released. Each page gets a
    fresh iframe element, so a stale route in the page left behind is never re-read.
- **JavaScript is inert**: `.js`/`.mjs` members are accepted and kept byte-exact in the
  archive (Download returns them), but the preview never runs them: `<script>` elements
  (HTML and SVG) and `on*` handlers are removed, no `blob:` URL is ever created for a
  script, the CSP has no `script-src` (`default-src 'none'`), and the sandbox lacks
  `allow-scripts`. Pages that had scripts show a note ("JavaScript does not run in the
  preview") so missing interactivity is not mistaken for a bug. Author bundles so they
  read correctly without script.
- **Isolation**: the iframe uses `sandbox="allow-same-origin"` without `allow-scripts`,
  forms, popups or top navigation. Without script, the frame cannot reach the app's DOM,
  storage or credentials. `allow-same-origin` exists only so the host can read the
  frame's location, scroll it and check its URL. Never combine it with `allow-scripts`.
- **Backstop**: if a loaded frame is not a same-origin `about:srcdoc` document, the viewer
  remounts it on the current page and shows a warning.
- **Lifecycle**: on close, version change and vault lock, the decrypted blob is dropped and
  every object URL is revoked.
- **States shown**: loading, locked, malformed/rejected/too large, missing entry, and
  per-page resource warnings.

## Verification

- `src/ctl/html_bundle_test.odin`: packaging, entry resolution, unsafe-archive rejection,
  the 15 MiB archive boundary and the member type allowlist (ZIP and `--directory`).
  ```bash
  nix develop --command odin test src/ctl -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/ctl.bin
  ```
- `tests/ui_html_bundle_test.ts`: viewer-side reader, limits (15 MiB boundary), type
  allowlist, inert JavaScript, a hostile HTML/CSS/SVG page (scripts, handlers,
  `javascript:`/`data:` links, meta refresh, `<base>`, frames, forms, remote CSS/`@import`,
  SVG `<use>`/SMIL/`foreignObject`, `is=`), reference resolution and URL cleanup.
- `tests/ui_artifact_bytes_vault_test.ts`: `encryptVaultBytes` round-trips a binary ZIP
  (and a full 15 MiB payload) byte-for-byte, as the UI upload path seals it.
- `tests/ui_artifact_bytes_vault_test.ts` with `tests/fixtures/artifact_binary_vault_v2.json`:
  a binary payload sealed by ham-ctl and opened byte-exact by the UI.
- `tests/ui_html_bundle_test.ts` also covers page-link routes: round trips, invalid routes,
  reserved-marker collisions, and the hrefs compiled for same-page, cross-page,
  `<area>` and SVG links.
- `tests/e2e/html_bundle/run.cjs`: Chromium (Electron) check of rendering, navigation and
  isolation:
  ```bash
  env -u LD_LIBRARY_PATH <nix electron>/bin/electron --ozone-platform=wayland tests/e2e/html_bundle/run.cjs
  ```
- `tests/e2e/html_bundle/engines.cjs`: mounts the production `HtmlBundlePreview` in
  Chromium, WebKit and Firefox through `playwright-core` and uses real clicks and keys
  in the sandboxed frame. It checks Details/Back (repeated), same-page and cross-page
  fragments, root links, keyboard Enter, `<area>`, the host page selector, reserved-marker
  collisions, inert external links, poll cleanup on lock, version change and unmount, a
  stale route across a version change, no scripts, and no requests beyond the host page.
  On NixOS it finds `playwright-core` and the browsers in `/nix/store`; elsewhere set
  `HB_PLAYWRIGHT_CORE`, `HB_CHROMIUM`, `HB_WEBKIT` and `HB_FIREFOX`. It is not part of
  `npm test`.
  ```bash
  node tests/e2e/html_bundle/engines.cjs            # or: ... engines.cjs webkit
  ```
- **Limitation**: Playwright WebKit on Linux (WPE) shares WebCore with Safari, but it is
  not iOS/iPadOS Safari. Page links on a real iPad must be confirmed by hand.
