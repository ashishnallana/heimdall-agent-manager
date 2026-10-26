# HTML bundle navigation report: diagnosis and correction plan (task_18e2091aa2499a48)

Status: **diagnosis complete; plan approved and implemented as approach A in
task_18e20a349ba8ab15** (see `docs/html-bundle-artifacts.md` and
`tests/e2e/html_bundle/engines.cjs`). The text below is the diagnosis as approved: no product
code was changed by it. All probes and the prototype were built in a scratch directory outside the
repo, from copies of the production files.

Report: user message `msg_18e208abc55c86ac` says navigation links do not work in the deployed
viewer. Screenshot `art_18e208a848657038` shows Safari on iPad. Fixture: `art_18e20011e3795118`.
Code inspected at `1c75ee44` (main, which contains the accepted feature merge `09eb0d2f`).

## Summary

| Question | Answer | Evidence level |
|---|---|---|
| Does the screenshot's look (plain page, tiny red image) show a defect? | No. It is what the fixture contains. | Verified |
| Are page links broken in Safari/WebKit? | Yes. Clicking "Details" does nothing, and cross-page `page.html#frag` links stay on the current page. | Reproduced in Playwright WebKit 26.6 (Linux) with the real component and the user's fixture |
| Root cause | The viewer follows page links only through a `click` listener that the **host** registers on the sandboxed iframe's document. WebKit never runs listeners on a document whose frame cannot execute script (`sandbox` without `allow-scripts`). Chromium and Gecko do run them. | Reproduced (listener-level probe in 3 engines) |
| Real iOS Safari | Not tested. No Apple device or simulator is reachable from this bridge. | Inferred (see §6) |
| Minimal fix | Make page links navigate the frame natively to `about:srcdoc#hb-page=…`, and have the host read `contentWindow.location.hash` by polling. Remove the click listener. | Prototype passes all checks on Chromium 155, WebKit 26.6 and Firefox 155 |

## 1. Fixture vs screenshot (verified)

- Fixture ZIP (`/tmp/heimdall-html-artifact-preview/artifact_faec67a66b4ced81.zip`):
  - `assets/chart.png` is a 73-byte **4x4 px** PNG. Its IHDR was read directly.
  - `assets/style.css` is `body{font-family:system-ui,sans-serif;max-width:48rem;margin:0 auto;padding:1rem}img{max-width:100%}`.
  - `index.html`: a nav with `index.html` "Home", `docs/details.html` "Details" and `#s2` "Jump", then `h1 Overview`, the image, and `h2#s2 Section`.
  - `docs/details.html` links to `../index.html` "Back".
- The screenshot (2778x1940, Safari on iPad) shows a centered column in a system font, a tiny red square, and the page selector reading `index.html (entry)`. That is exactly what the source produces. The centered 48rem column shows the stylesheet was applied, and the red square shows the nested image loaded.
- **Conclusion:** the appearance is the minimal fixture, not a viewer or CSS/asset defect. I make no claim about the deployment itself beyond what the screenshot shows.

### Fixture confounders (any browser)
- "Home" on `index.html` links to the page it is already on, so the only possible effect is scrolling to the top. Nothing visibly changes.
- "Jump" (`#s2`) points at a heading that is already visible, because the page is shorter than the iframe (65% of the viewport height). There is nothing to scroll.
- Only "Details" and "Back" actually test page navigation. The repro below uses the original fixture for those two, and a taller variant (`tall.zip`) to test fragments.

## 2. Production link mechanism (code at 1c75ee44)

- `src/ui/components/ArtifactViewer.tsx` renders `src/ui/components/HtmlBundlePreview.tsx` for `html-bundle` artifacts.
- The iframe has `sandbox="allow-same-origin"` with no `allow-scripts`, and `srcDoc` set to the compiled page (`HtmlBundlePreview.tsx:164-175`).
- `src/ui/utils/htmlBundle.ts` `rewriteLink` (l.612-630):
  - Fragment links become `href="about:srcdoc#<frag>"`.
  - Links to another bundle page become `href="about:srcdoc#<frag or empty>"` plus `data-hb-page` / `data-hb-fragment`.
- Page navigation depends **only** on `handleLoad` (`HtmlBundlePreview.tsx:87-109`): the host calls `doc.addEventListener('click', …)` on the iframe document, then calls `preventDefault()` and `setLocation({page, fragment})`.
- If that listener does not run, the browser's default action navigates to `about:srcdoc#`. That is an empty-fragment, same-document navigation, so nothing happens. This matches the report.

## 3. Reproduction evidence

The tools were `playwright-core` 1.63.0 plus Nix-built browsers:
- Chromium 155.0.8059.39 (`nixpkgs` chromium)
- Playwright WebKit 26.6 (WPE MiniBrowser, Linux)
- Playwright Firefox 155.0

The WebKit and Firefox builds came from the `playwright-webkit` / `playwright-firefox` derivations already in the store (`nix build …playwright-webkit.drv^out …playwright-firefox.drv^out nixpkgs#playwright-driver`). All runs used a headless browser through `ham-ctl shell run`. Scratch directory: `/tmp/claude-1000/…/2afff7de-…/scratchpad/{probe,real,protoA}`.

### 3a. Listener-level probe (`probe/probe.cjs`)
The host page has an `<iframe sandbox="allow-same-origin">` with a `srcdoc` document. The host registers `click` and `pointerdown` on `contentDocument`, and `hashchange` and `scroll` on `contentWindow`.

| Action | Chromium 155 | Firefox 155 | WebKit 26.6 |
|---|---|---|---|
| Real mouse click on page link | `pointerdown` and `click` fire | fire | **nothing fires**; frame URL becomes `about:srcdoc#` |
| `element.click()` from host realm | `click` fires | fires | **nothing fires** |
| Real click `about:srcdoc#s2` (tall page) | scrolls to y≈1793, `hashchange` fires | scrolls, fires | **scrolls to y≈1795**, no host listener fires |
| Real click `about:srcdoc#hb-page=docs%2Fdetails.html` | `location.hash` readable by host | readable | **readable** by host |

So WebKit performs the frame-native navigation and lets the same-origin host *read* the frame's state, but it never invokes the host's listeners for that document.

### 3b. Real component plus user fixture (`real/run.cjs`)
`real/entry.tsx` is bundled with esbuild. It imports the **unmodified** worktree `src/ui/components/HtmlBundlePreview.tsx`, along with `htmlBundle.ts` and the `@ui` `Select`. It mounts the component with the fixture ZIP as a `Blob`. Clicks are real Playwright mouse clicks inside the frame.

| Engine / variant | Details → details page | Back → index | `#s2` scrolls (tall) | `details.html#end` cross-page fragment | External requests |
|---|---|---|---|---|---|
| Chromium 155 / production | ✅ | ✅ | ✅ | ✅ | 0 |
| Firefox 155 / production | ✅ | ✅ | ✅ | ✅ | 0 |
| **WebKit 26.6 / production** | ❌ frame URL `about:srcdoc#`, selector stays `index.html (entry)` | n/a | ✅ | ❌ stays on index; URL `about:srcdoc#end`, scrollY 50 | 0 |
| Chromium 155 / prototype A | ✅ | ✅ | ✅ | ✅ (scrollY 3003) | 0 |
| Firefox 155 / prototype A | ✅ | ✅ | ✅ | ✅ | 0 |
| WebKit 26.6 / prototype A | ✅ selector → `docs/details.html` | ✅ | ✅ | ✅ (scrollY 3003) | 0 |

None of the runs showed the "navigation blocked" banner or a page error.

Why earlier checks missed it: the accepted e2e (`tests/e2e/html_bundle/run.cjs`) runs only in Electron (Chromium), where the host listener works.

## 4. Correction plan (proposed; not implemented)

### Approach A: frame-native page navigation, read by the host
1. **`src/ui/utils/htmlBundle.ts`**
   - Add exported `htmlBundleNavHash(page, fragment)` and `parseHtmlBundleNavHash(hash)`. They use the reserved form `hb-page=<encodeURIComponent(page)>[&hb-fragment=<encodeURIComponent(frag)>]`.
   - In `rewriteLink`, a link to a **different** bundle page gets `href="about:srcdoc#hb-page=…"`. A link to the **same** page gets a plain `about:srcdoc#<frag>`, which scrolls natively in all three engines.
   - Keep `data-hb-page` / `data-hb-fragment` as inert metadata and for tests. Update the header comment (l.17-18).
   - Collision safety: authored fragments are already `encodeURIComponent`-encoded, so an authored `#hb-page=x` becomes `hb-page%3Dx` and cannot match the prefix. Even a forged match can only select a page the host already checks with `hasPage`.
2. **`src/ui/components/HtmlBundlePreview.tsx`**
   - Remove the `doc.addEventListener('click', …)` block.
   - Add an effect that, while `status.kind === 'ready'`, polls `iframeRef.current.contentWindow.location.hash` every ~100 ms. Wrap each read in try/catch.
   - The poll parses with `parseHtmlBundleNavHash` and calls `setLocation(target)` only when `hasPage(target.page)` is true and the target differs from the current location. Without that guard, the old document can be re-read until the new `srcdoc` loads.
   - The poll is cleared on unmount, blob change and lock.
   - `handleLoad` keeps the escape backstop and `scrollToFragment(location.fragment)`. These are host-realm DOM calls, not listeners, and the prototype confirmed they work in WebKit.
   - Update the isolation comment (l.7-13): `allow-same-origin` now exists so the host can read the frame's location, scroll it and check its URL. It is no longer about attaching a listener.
   - The prototype diff is about 15 lines. It is reproduced in §8.
3. **`docs/html-bundle-artifacts.md`**: update the Navigation and Isolation bullets, plus Verification (WebKit coverage).
4. **No change** to `ArtifactViewer.tsx`, `src/ctl/html_bundle.odin`, the CLI, the archive format, limits, the sanitizer rules or the CSP.

### Alternatives considered
- **B. Host hit-testing.** A transparent overlay over the frame plus `contentDocument.elementFromPoint`. Rejected: it breaks in-frame scrolling, text selection and keyboard focus, and it is more code.
- **C. Separate blob/data documents per page.** Rejected: it changes the origin model and CSP trade-offs that REQ-BUNDLE-5 accepted.
- **D. Keep the click listener as a fast path alongside polling.** Rejected: two mechanisms, with WebKit-only behavior that is hard to test. Polling alone passes in all three engines.

### REQ-BUNDLE-3 mapping
| REQ-BUNDLE-3 clause | Today | After fix |
|---|---|---|
| "HTML page links and fragments" resolved | Fragments OK everywhere. Page links broken in WebKit. | Page links work through native fragment navigation in all tested engines. |
| "Navigation mechanism must be verified" | Verified only in Chromium/Electron | Verified in Chromium, Firefox and WebKit (Playwright) |
| Host-side page selector reachability | Unchanged. The selector is host UI. | Unchanged. Link navigation also keeps it in sync on WebKit (prototype: selector shows `docs/details.html`). |
| Nested relative CSS/assets, `/` = bundle root | Working (fixture verified) | Untouched |

### Security constraints retained (REQ-BUNDLE-5)
- `sandbox="allow-same-origin"` with **no** `allow-scripts`, forms, popups or top navigation. Unchanged.
- CSP meta, sanitizer, reparse check and blob-only assets are unchanged. The reparse check already only allows `<a>/<area href>` starting with `about:srcdoc#`, and the new hrefs satisfy it.
- The escape backstop on `load` is unchanged.
- New surface: the host reads a string from the frame's same-origin `location.hash`. The only action it can trigger is choosing a page that `hasPage` already validated, which a user can already do with the selector.
- Both production and prototype runs made zero external requests.

## 5. Verification strategy for the fix
1. **Unit tests** (`tests/ui_html_bundle_test.ts`, run through `npm test` or `node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_html_bundle_test.ts`):
   - A link to another page compiles to `about:srcdoc#hb-page=…`, with and without a fragment.
   - A link to the same page compiles to a plain fragment.
   - The `htmlBundleNavHash` and `parseHtmlBundleNavHash` round-trip survives `/`, spaces, `#`, `&`, unicode and malformed `%`.
   - An authored `#hb-page=x` cannot be parsed as navigation.
   - The existing `^about:srcdoc#` assertions still hold.
2. **Browser e2e:**
   - Update `tests/e2e/html_bundle/page_entry.ts` to use the same polling mechanism instead of its own click listener, so the Electron run exercises production behavior.
   - Add a small multi-engine runner, `tests/e2e/html_bundle/engines.cjs`, modeled on the scratch `real/run.cjs`. It mounts the real `HtmlBundlePreview` and runs Details/Back, a taller page for `#frag`, a cross-page `#frag`, a zero-external-requests check and a no-banner check, on Chromium, WebKit and Firefox.
   - Run it manually with the Nix-built browsers above; it is not part of `npm test`, because it needs those browsers.
3. **Manual acceptance:** after deploy, the user re-opens `art_18e20011e3795118` (or the richer demo `art_18e20970cc8382b8`) on the iPad and clicks Details, Back and a cross-page anchor.

## 6. Remaining uncertainty
- **Real iOS/iPadOS Safari is untested.** Playwright WebKit on Linux (WPE) shares WebCore with Safari, and the failure matches the user's report exactly, but this is not a test on Apple hardware. Final confirmation needs the user's iPad (step 5.3).
- The exact WebKit rule (skipping listeners in a script-disabled frame) is observed behavior. I have not cited it from WebKit source or a spec.
- Polling adds a 100 ms timer while a bundle preview is open. The cost is negligible but non-zero; an alternative is to poll only while the frame is visible.
- Frame fragment navigations add entries to session history, which is already true for `#frag` links today. How the browser Back button interacts with them was not examined.
- Not tested: keyboard activation (Enter on a focused link), `<area>` links, and choosing a page from the host selector on WebKit. These are expected to work (native navigation and host UI respectively) but were not exercised.
- The harness renders the component without the app's Tailwind styles. Layout fidelity was not part of this check.

## 7. Commands run
- `unzip -p …artifact_faec67a66b4ced81.zip index.html docs/details.html` and a PNG IHDR read (fixture).
- `nix build --no-link --print-out-paths /nix/store/…-playwright-webkit.drv^out /nix/store/…-playwright-firefox.drv^out nixpkgs#playwright-driver`: exit 0.
- `node probe.cjs` (scratch `probe/`): exit 0. Results in §3a.
- `bash build.sh` (esbuild bundle of `real/entry.tsx`): exit 0, with only `import.meta` warnings from `apiBase.ts`.
- `node run.cjs` (scratch `real/`): exit 0. Results in §3b, raw output in `real/result.json`, WebKit screenshot in `real/webkit-prod-entry.png`.

## 8. Prototype diff (scratch only, for reference)
```diff
// htmlBundle.ts: rewriteLink, page links
-      el.setAttribute('href', `about:srcdoc#${encodeURIComponent(resolved.fragment)}`);
+      el.setAttribute('href', resolved.path === page
+        ? `about:srcdoc#${encodeURIComponent(resolved.fragment)}`
+        : `about:srcdoc#${htmlBundleNavHash(resolved.path, resolved.fragment)}`);
// + htmlBundleNavHash / parseHtmlBundleNavHash helpers ('hb-page=' prefix)

// HtmlBundlePreview.tsx
-    doc.addEventListener('click', (event) => { … setLocation({ page, fragment }) });
+  useEffect(() => {
+    if (status.kind !== 'ready') return;
+    const timer = window.setInterval(() => {
+      let hash = '';
+      try { hash = iframeRef.current?.contentWindow?.location.hash || ''; } catch { return; }
+      const target = parseHtmlBundleNavHash(hash);
+      if (target && status.renderer.hasPage(target.page)) setLocation(target);
+    }, 100);
+    return () => window.clearInterval(timer);
+  }, [status]);
```
The final implementation should also skip `setLocation` when the target equals the current location (see §4.2).
