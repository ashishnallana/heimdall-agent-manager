# Static HTML bundle artifacts

An agent can publish a multi-page static site (HTML, CSS, local images and fonts) as one
artifact. The user opens it in the Artifact Viewer, which renders it in an isolated iframe
with no server running.

## CLI

```bash
# Pack a directory (relative paths kept, symlinks skipped and reported on stderr)
ham-ctl artifact create --name report --kind html-bundle --directory ./site [--entry docs/index.html]

# Upload a prepared ZIP (validated; a manifest is appended if it has none)
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
- Limits: 10 MiB archive, 50 MiB expanded (declared **and** actual; inflation stops once a
  member passes its declared size), 1000 entries, 10 MiB per member, 64 KiB manifest.

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
  - A CSP meta allows only `blob:`/`data:` images and fonts plus inline styles.
- **Navigation**:
  - Fragment links are rewritten to `about:srcdoc#frag`. A bare `#frag` in a `srcdoc`
    document resolves against the *parent* URL and would navigate the frame away.
  - Links to other pages carry `data-hb-page`. The host follows them and keeps the
    page selector in sync.
- **Isolation**: the iframe uses `sandbox="allow-same-origin"` without `allow-scripts`,
  forms, popups or top navigation. Without script, the frame cannot reach the app's DOM,
  storage or credentials. `allow-same-origin` exists only so the host can attach its link
  handler. Never combine it with `allow-scripts`.
- **Backstop**: if a loaded frame is not a same-origin `about:srcdoc` document, the viewer
  remounts it on the current page and shows a warning.
- **Lifecycle**: on close, version change and vault lock, the decrypted blob is dropped and
  every object URL is revoked.
- **States shown**: loading, locked, malformed/rejected/too large, missing entry, and
  per-page resource warnings.

## Verification

- `src/ctl/html_bundle_test.odin`: packaging, entry resolution and unsafe-archive rejection.
- `tests/ui_html_bundle_test.ts`: viewer-side reader, limits, reference resolution and URL
  cleanup.
- `tests/ui_artifact_bytes_vault_test.ts` with `tests/fixtures/artifact_binary_vault_v2.json`:
  a binary payload sealed by ham-ctl and opened byte-exact by the UI.
- `tests/e2e/html_bundle/run.cjs`: Chromium (Electron) check of rendering, navigation and
  isolation:
  ```bash
  env -u LD_LIBRARY_PATH <nix electron>/bin/electron --ozone-platform=wayland tests/e2e/html_bundle/run.cjs
  ```
