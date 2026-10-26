# HTML bundle navigation report: diagnosis checkpoint (task_18e2091aa2499a48)

Status: **in progress, parked** (the coordinator put it on hold for a demo artifact task). No product code was changed.

## 1. Fixture and screenshot (verified)
- Fixture `art_18e20011e3795118` (ZIP at `/tmp/heimdall-html-artifact-preview/artifact_faec67a66b4ced81.zip`):
  - `assets/chart.png` is a 73-byte **4x4 px** RGB PNG (IHDR read directly).
  - `assets/style.css` = `body{font-family:system-ui,sans-serif;max-width:48rem;margin:0 auto;padding:1rem}img{max-width:100%}`.
  - `index.html`: nav `index.html` / `docs/details.html` / `#s2`, then `h1 Overview`, `img`, `h2#s2 Section`. `docs/details.html`: `../index.html` "Back".
- Screenshot `art_18e208a848657038` (2778x1940, Safari on iPad, heimdall.mundus.in): centered narrow column, system-ui font, a tiny red square, page selector `index.html (entry)`.
- **Conclusion:** the render matches the source. CSS and the nested image ARE loaded (the centered 48rem column and the 4px image are what the source says). The "tiny image" and plain look are the minimal fixture, not a viewer defect.

## 2. Link mechanism in production path (read from code at 1c75ee44)
- `src/ui/components/ArtifactViewer.tsx:491` -> `src/ui/components/HtmlBundlePreview.tsx`.
- iframe: `sandbox="allow-same-origin"` (no `allow-scripts`), `srcDoc` = compiled page (`HtmlBundlePreview.tsx:164-175`).
- `src/ui/utils/htmlBundle.ts` `rewriteLink` (~l.612-630): page links get `href="about:srcdoc#<frag>"` + `data-hb-page`/`data-hb-fragment`. Fragment-only links get `href="about:srcdoc#<frag>"`.
- Navigation between pages depends ENTIRELY on `handleLoad` (`HtmlBundlePreview.tsx:87-109`): the PARENT calls `doc.addEventListener('click', ...)` on the sandboxed iframe document, then `preventDefault` + `setLocation`.

## 3. Fixture-specific confounders (verified by reading the source, behaviour inferred)
- "Home" on index.html is a same-page link -> it scrolls to the top, so nothing visibly changes in any browser.
- "Jump" (#s2): the page is shorter than the iframe (65% viewport height), so `Section` is already visible and there is nothing to scroll. It looks broken in every browser.
- Only "Details" (and "Back" on details.html) are real tests of page navigation.

## 4. Leading hypothesis (INFERRED, NOT yet reproduced on WebKit)
In WebKit, `JSEventListener::handleEvent` (as far as I recall the source) checks `canExecuteScripts(AboutToExecuteScript)` for the frame of the event target's ScriptExecutionContext. The iframe is sandboxed without `allow-scripts`, so a listener registered by the parent on the iframe document would be **silently skipped** in Safari/iOS. The default action then navigates to `about:srcdoc#` (empty fragment = same-document), so "Details" does nothing. That matches the report. Chromium invokes the listener (the existing Chromium e2e tests pass), which would explain why our checks didn't catch it.
- Not verified: no WebKit on this bridge. I started `nix build nixpkgs#playwright-driver.browsers nixpkgs#playwright-driver` to get Playwright WebKit, then killed it at the checkpoint. Firefox/Gecko behaviour is also not verified.
- Not yet done: reproduce in Chromium with the real compiler (`tests/e2e/html_bundle/run.cjs`, `page_entry.ts`) using the fixture ZIP.

## 5. Candidate fix directions (not decided; do not implement before plan approval)
Each keeps the REQ-BUNDLE-3 rules: no `allow-scripts`, no network, CSP unchanged.
- A. **Navigate frame-natively and read the result in the host.** Make page links real in-frame navigations to a target the host can recognise (for example `about:srcdoc#hb-page=<encoded path>|<frag>`). This is same-document fragment navigation and needs no script. Then the host detects it via the iframe window's `hashchange`/`load`, or by polling `contentWindow.location.hash`. Risk: that event listener is subject to the same WebKit check. Polling from the parent's realm (reading a property, no listener) does not depend on it.
- B. **Host-side hit-testing.** Put a transparent overlay or a parent-level `pointerdown` over the iframe, then use `contentDocument.elementFromPoint`, which runs in the parent's realm, to find `a[data-hb-page]`. That costs some fidelity with text selection and scrolling.
- C. Per-page blob/data documents. Rejected for now because they lose `allow-same-origin` reachability and have CSP/opaque-origin trade-offs.

## 6. Next steps when resumed
1. Build Playwright WebKit (command above) and run a minimal sandbox test: parent `addEventListener('click')` on an `allow-same-origin`, no-scripts `srcdoc` iframe, then `element.click()` or a real mouse click. Record fired/not fired for Chromium, WebKit and Firefox.
2. Run the fixture through the real `HtmlBundleRenderer` + `HtmlBundlePreview` in the e2e harness (`tests/e2e/html_bundle/run.cjs`) on Chromium and WebKit.
3. Prototype detection options A and B in a scratch harness only, on WebKit and Chromium.
4. Write the final plan: affected paths, REQ-BUNDLE-3 mapping, retained security, regression strategy (add a WebKit project to the html_bundle e2e plus a taller fixture so #frag scrolling is observable), and remaining uncertainty (real iOS Safari vs Playwright WebKit on Linux).
