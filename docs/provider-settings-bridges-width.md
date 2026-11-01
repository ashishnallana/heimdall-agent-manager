# Full-width Bridges overview cards

The Bridges overview keeps one bridge per row at every viewport width. Removing the
extra-large two-column override lets each card fill the available Settings content
width while preserving the shell margins. The verified local machine card already
fills that width; its actions and all bridge behavior are unchanged.

## Verification

- `npm run typecheck`: passed.
- `node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_bridges_panel_update_test.ts tests/ui_bridges_shared_flow_test.ts`: 27 passed, zero failures.
- `npx vite build --outDir /var/home/tanmay/bridges-width-evidence/build`: passed; existing chunk-size warning remains.
- `node /var/home/tanmay/bridges-width-evidence/check.cjs`: 20 browser scenarios passed: 1440, 1024, 768, 390 and 320px; one and three bridges; web and verified local manager.
- Geometry checks verify each overview card equals panel width, rows stack, page/cards do not overflow horizontally, and four local actions do not overlap. Detail/back navigation and overview-only global telemetry remain available.
- Visually inspected desktop and 320px screenshots, including long remote labels and verified local identity.
- Gallery upload round-trip verified its index, manifest and all 12 screenshots.

[Representative screenshots](artifact://art_18e3efb7f261063e)

The isolated browser fixture renders the actual React components and existing CSS
with deterministic bridge records and a fake desktop manager. It does not connect
to production or run bridge lifecycle operations. Harness, result metrics and logs
are retained under `/var/home/tanmay/bridges-width-evidence/`. No new source-mirroring
CSS tests were added. Full application and native lifecycle suites were not rerun
for this single-class layout change; existing focused behavior tests passed.

The running live preview remains unchanged. Updating it requires the independent
review of this source change to finish first.
