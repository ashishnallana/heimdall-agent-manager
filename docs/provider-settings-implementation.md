# Bridge-first provider settings implementation

Settings → Providers now starts with all enrolled, non-revoked bridges. Each card shows the bridge connection/vault state and its reported provider summary. Opening a bridge shows its provider profiles; opening or adding a profile replaces that list with a full-width editor and a back action. The existing sealed provider APIs, runtime fields, validation, enablement, discovery, profile tests, and extension actions remain in use.

## Source and design

- Checkout: `/var/home/tanmay/provider-settings-implementation`
- Branch: `heimdall/provider-settings-implementation`
- Base: `55e1eed71f7eecb043acd80fe9b2d103c552680c`, verified against remote main before creating the worktree.
- Approved design: `artifact://art_18e3e65aabaf47de`; Ninjy `DESIGN.md` at `984fa8631ccacff10efe14c51a1f5c25805b733e`.
- Original checkout `/var/home/tanmay/heimdall-agent-manager` remains on its original branch; its source files and existing work are preserved.

Bridge URLs use stable bridge IDs, with bridge names shown in the page. Existing `#/settings/providers?bridge=…` bookmarks remain supported. No bridge is implicitly selected. Revoked/missing bridges cannot silently redirect editing to another bridge. Provider recipe editor bookmarks retain their existing compatibility surface.

## Preserved coverage

| Area | Behavior retained / checked |
| --- | --- |
| Identity | Provider wizard, generated/collision-checked IDs, encrypted labels, accent and launch enablement |
| Claude | Inherit/random/custom config directory, empty-custom validation, stable generated directory across save/reopen |
| Codex | Home and shadow home, binary override, arguments, environment and custom model IDs |
| Antigravity | Authentication method, API key keep/replace/clear, Google Cloud project/location; no unsupported argument/model controls |
| Other drivers | Existing binary, literal argument, environment and model controls remain available |
| Secrets | Sensitive/redacted values, replacement, explicit clear and row removal; redacted refetch after saving |
| Actions | Default reset, custom deletion confirmation and in-use error, check provider, refresh models, saved exact-profile/model test, existing supported extension lifecycle |
| Connectivity | Device vault + bridge vault + connection gating, last-reported overview summary, error/loading/empty states |
| Accessibility | Native labeled controls, keyboard bridge links, visible focus, named status labels, focus transfer when entering/leaving editor |
| Responsive | One provider content tree in SettingsModal across breakpoints; resizing preserves unsaved drafts, full-width editor, no adjacent provider switcher |

No backend/schema changes or new provider capabilities were introduced. Nearby fixes clear stale directory validation on leaving an editor, prevent late get/save replies from reopening an editor after vault/connection locking, deduplicate driver summary counts, and remove toggle semantics from provider navigation buttons.

## Verification

From the checkout:

```bash
npm run build
node --import ./tests/helpers/vaultEndpointHarness.ts --test \
  tests/ui_provider_bridge_navigation_test.ts \
  tests/ui_provider_profiles_test.ts \
  tests/ui_settings_modal_test.ts \
  tests/ui_provider_setup_collapse_test.ts \
  tests/ui_extension_install_test.ts
git diff --check
```

The build passes, including TypeScript, Vite and Electron compilation. Vite reports existing login/logout environment placeholders, circular Toast chunk and large chunk warnings. The focused test selection passes 18/18; the new navigation test is included in `npm test`.

Browser checks use separately installed Playwright, without changing application dependencies:

```bash
PLAYWRIGHT_MODULE=/tmp/provider-layout-browser/node_modules/playwright \
PROVIDER_FONT_DIR=/tmp/approved-provider-mockup/site/assets \
node tests/e2e/provider_layout_browser_check.mjs
```

This starts and closes an isolated Vite server. The actual SettingsModal, provider components, Redux API and sealed client operate against an in-page fixture backend; all nonlocal requests are blocked. It verifies 24 states at 1440, 768 and 390 pixels, keyboard navigation/focus, no horizontal overflow, full editor width, driver-specific fields, validation, save/refetch, secret redaction, deletion guard, locked/offline states, and draft preservation across resize. The screenshots and `results.json` are written to `/tmp/provider-layout-evidence` (override with `PROVIDER_LAYOUT_EVIDENCE`). `PROVIDER_FONT_DIR` optionally loads the approved mockup's exact local font files; production retains its existing Google Fonts setup.

Screenshot gallery: [24 implementation screenshots](artifact://art_18e3e791456bc742).

These are fixture integration checks, not tests against live Hub/Bridge services or installed provider CLIs. No production provider profiles, runtime directories, credentials, extension registrations, or test sessions were mutated. Authenticated live integration, native provider execution, Safari/iPad and packaged Electron interaction were not exercised. Backend suites were skipped because backend code is unchanged; the entire unrelated UI suite was not rerun.

## Integration after independent approval

This task chain has no application repository directory configured for automatic merge-back. The commit is available locally on the branch above, in the original repository's shared object database. After independent review, the coordinator/operator should inspect the committed diff, then integrate that exact commit into the intended current main branch using the normal merge/cherry-pick process. Reconcile any intervening main changes and repeat affected checks. Do not reset or overwrite the original checkout's unrelated branch or uncommitted work. No remote push, deployment, service restart or release publication is part of this task.


## Settings heading ownership correction

The Settings shell now owns the provider page title, subtitle and contextual breadcrumb. Overview, selected bridge, existing profile and add-provider views publish their current context through a small heading callback; provider content retains back actions and meaningful form section headings. Heading updates occur before paint, and focus moves to the Settings heading when navigating between contexts without interrupting label editing. Provider APIs and form behavior are unchanged.

This correction was made directly in `/var/home/tanmay/provider-settings-main` on local `main`, starting at `fc39983a7d2fe8c60104801fec8d986d19281b4b`. The original checkout and remote main remain unchanged. No further integration is required after independent review of this correction.

Verification: `npm run build` passed; `node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_provider_bridge_navigation_test.ts tests/ui_provider_profiles_test.ts tests/ui_settings_modal_test.ts` passed 11/11; the browser command above with `PROVIDER_LAYOUT_EVIDENCE=/tmp/provider-heading-evidence` passed 24 integrated responsive states. Existing navigation and browser checks now assert Settings heading ownership and route/editor context changes. Desktop/narrow overview, bridge list and editor screenshots were visually inspected. [Heading verification gallery](artifact://art_18e3e8e5d4479adc).

## Wizard and alignment polish

The follow-up starts from approved main `608b79f00ebf927cffd1bda3e77073b32077f0f1` in
`/var/home/tanmay/provider-settings-main`. Bridge cards now span the content width.
The add wizard has numbered Provider/Identity/Config steps, explicit completed/current/upcoming
labels, one `aria-current="step"`, and a stable Back control (disabled on the first step).
The native accent picker aligns with its label. Extension actions use an editor layout without
the provider-row indentation; the setup-row caller retains its existing layout.

A prominent Profile availability panel near the editor heading contains an Enabled/Disabled
pill and an explicit Disable profile / Enable profile button. Changes remain drafts until
Save profile; Pending save appears beside the state/action when appropriate. Permission,
connectivity, save and sealed API behavior remain unchanged.

Verification on final source:

- `npm run typecheck`: pass.
- `npm run build`: pass, including Vite/Electron; existing environment/chunk warnings remain.
- `node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_provider_bridge_navigation_test.ts tests/ui_provider_profiles_test.ts tests/ui_settings_modal_test.ts tests/ui_provider_setup_collapse_test.ts tests/ui_extension_install_test.ts`: 18/18 pass. Includes disable/save and enable/save through the sealed API.
- `PLAYWRIGHT_MODULE=/tmp/provider-layout-browser/node_modules/playwright PROVIDER_FONT_DIR=/tmp/approved-provider-mockup/site/assets PROVIDER_LAYOUT_EVIDENCE=/tmp/provider-polish-evidence node tests/e2e/provider_layout_browser_check.mjs`: 39 states pass at 1440/768/390 widths, zero browser exceptions.
- `git diff --check`: pass.
- Representative screenshots: `artifact://art_18e3eb47e4bc30c2`; seven images plus HTML round-trip byte-identically. Desktop overview/extension, tablet wizard and phone wizard/availability/extension inspected directly.

Backend-wide tests and real-account mutations are outside this presentation-only patch.
Original checkout HEAD `79065f209c8ab582c73a4efd8703a49b6033fa49` and index SHA256
`7d8738e48e6f7a05cd0511689e49aa47433219acd4d55145155c4a372270ebaa` remain unchanged.
Independent review precedes isolated preview refresh; production services are untouched.
