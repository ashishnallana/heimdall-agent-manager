# Bridges settings implementation

Bridges now has an account overview and dedicated bridge management views. Settings and first-run setup use the same local detector, install, identity and operation presentation. Global Configuration contains the inline Enable telemetry control; bridge overrides remain independent and unsupported bridge defaults stay disabled.

## Source and integration

- Approved checkout: `/var/home/tanmay/provider-settings-main`, branch `main`.
- Base: `a0d0494558b92646cd5dfe66a08a1e7e9da33a81`, including the reviewed provider changes.
- Design: independently approved Bridges revision `421d8f80309e9b157f933012d5723e015bd88f9a`; HTML `art_18e3eae65fca1140` and reuse note `art_18e3ea19574e1765`. Its historical `fc39983a/608b79f0` mapping was reconciled against the approved application base.
- Recovered uncommitted edits in ThisMachineCard, SetupWizardPage, useThisMachineBridge and LocalBridgeFlow were explicitly authorized for continuation and ownership. Their original authorship remains uncertain. A tracked binary patch and copies of the untracked files were preserved before changes in `/var/home/tanmay/bridges-recovery-20261101`.
- Implementation is directly in the approved application checkout. The unrelated original application checkout, Nix configuration, production services and isolated live-preview sessions were not changed. There was no push, install, enrollment, update, uninstall or restart of a real bridge. Preview refresh is a separate reviewed follow-up.

## Shared owners

| Owner | Responsibility |
| --- | --- |
| `src/ui/bridge/useThisMachineBridge.ts` | Configuration, account inventory, local profiles, exact profile/Hub/account bridge-ID match, verified status, idle refresh and post-operation revalidation. Unknown, unsupported, error and missing/uncommitted status never become installable absence or a local badge. |
| `src/ui/components/bridge/LocalBridgeFlow.tsx` | Moved MachineSteps, IdentityStep, step heading and install log from the first-run wizard. Both wizard and Settings consume these exports. Profile selection, separate-account setup, capacity/reuse/sunset approval and cancellation retain their existing helpers. |
| `src/ui/bridge/useBridgeIdentityState.ts` | In-memory identity review/controller state scoped to the operation and signed-in account. Choices, pending attempt and approval wait survive host unmount without cancelling the enrollment or storing pairing codes/keys in routes or browser storage. |
| `src/ui/bridge/desktopBridgeSession.ts` | Existing application-lifetime event stream, reducer, bounded log, exact retry target/options and pending-code handoff. A synchronous one-operation guard now prevents a second action from overwriting the active run. Refused starts remain distinct from streamed terminal failure. |
| `src/ui/components/bridge/BridgeOperationRail.tsx` | Shared operation presentation for wizard, Settings setup and local/remote update review. These are interface steps, not new backend pipeline stages. |
| `src/ui/components/bridge/BridgeOperationFeedback.tsx` | Shared local update/re-enrollment/uninstall progress, failure, result, exact retry, cancellation, copy and log-file controls. Remote updates never use this controller or the local installer. |

The Electron preload/main manager, signed approval, vault-key delivery and rollback-before-abort services are unchanged. Settings completion returns to Bridges; it does not mark first-run setup seen or visit Agents/Projects. The wizard retains its original completion destination.

## Settings behavior

- Overview lists bridge cards with status, version, OS/architecture, active agents, reported vault status and update availability. Only an exact verified bridge receives the This machine badge.
- Dedicated management preserves rename, provider configuration links/availability, automatic updates, version/catalog/status details, recent errors, per-bridge telemetry and supported remote uninstall/revoke controls. Browser clients gain no local lifecycle controls.
- Remote updates retain the existing mutation, readiness/busy gates, version/status helpers, force/drain and extension preferences. The fixture browser check verifies the exact request body.
- Global Configuration uses the existing telemetry query/mutation. Its existing legacy-session preference persistence and browser-storage fallback are preserved; this change does not invent another global backend API. Per-bridge inherit/enabled/disabled overrides still use the bridge mutation.
- Default provider/model remain disabled with an explanation that bridge-wide defaults cannot be saved.
- Settings owns one visible heading for bridge/provider content and focuses it when changing detail context. Mobile uses one mounted content tree, a full-width back row and nonoverlapping local actions.

## Verification

All commands ran in `/var/home/tanmay/provider-settings-main` through managed shell runs.

```bash
npm run build
node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_bridges_shared_flow_test.ts tests/ui_bridges_panel_update_test.ts tests/ui_setup_wizard_test.ts tests/ui_setup_profiles_test.ts tests/ui_bridge_enrollment_test.ts tests/ui_bridge_enrollment_completion_test.ts tests/ui_bridge_enrollment_pending_test.ts tests/ui_bridge_enrollment_reuse_test.ts tests/ui_desktop_install_choice_test.ts tests/ui_provider_bridge_navigation_test.ts tests/ui_provider_profiles_test.ts tests/ui_settings_modal_test.ts
git diff --check
```

PASS: production renderer and Electron build, including typecheck; **89/89 tests**; whitespace check. Existing Vite login/logout environment-placeholder and large-chunk warnings remain. Final managed session: `sh_4865e0cd069d034828f5aa3a673276fc`.

```bash
PLAYWRIGHT_MODULE=/tmp/provider-layout-browser/node_modules/playwright BRIDGES_FONT_DIR=/var/home/tanmay/bridges-recovery-20261101/design/site/assets node tests/e2e/bridges_layout_browser_check.mjs
PLAYWRIGHT_MODULE=/tmp/provider-layout-browser/node_modules/playwright PROVIDER_FONT_DIR=/var/home/tanmay/bridges-recovery-20261101/design/site/assets PROVIDER_LAYOUT_EVIDENCE=/tmp/bridges-provider-regression node tests/e2e/provider_layout_browser_check.mjs
```

PASS: **60 Bridges states** at 1440/1024/768/390/320px, and **39 provider regression states** at 1440/768/390px. Final sessions: `sh_6227bd6bcea02b7b98f2712ec9acad77`, `sh_d233bdd665ebbc6d72e28f0e0978245a`.

Checks cover exact local identity and unknown/error gates, one heading, keyboard navigation, disabled defaults, pairwise foreground action overlap, overflow, telemetry interaction, exact remote update request, local retry/cancel and wizard/Settings host resume. The new 18-test identity/session file is included in the standard npm test command. Existing cancellation tests cover rollback-before-abort and commit-won behavior; existing enrollment tests cover signed identity/key-delivery constraints.

Final browser evidence is in `/tmp/bridges-layout-evidence` and `/tmp/bridges-provider-regression`, copied into the durable evidence directory and gallery artifact. Screenshots were visually inspected at desktop and phone widths. During implementation, tests found and verified fixes for a disappeared failure/retry view during refresh and install/header overflow. The overlap check scopes itself to the topmost active dialog, since obscured background controls are not foreground actions.

## Limits and review

This is real React UI exercised with isolated in-memory API and Electron fixtures in Chromium. Native Electron/OS installation, full signed-in production Hub use, Safari and iPad were deliberately not exercised. Backend and unrelated full UI suites were skipped because backend/native lifecycle code was unchanged. Independent source/design review remains required; passing fixture tests are not a claim of a production deployment.

## Review evidence

[Final 60-screenshot gallery](artifact://art_18e3ee4927aba581). Downloaded gallery roundtrip matched all 61 source files byte-for-byte and its entrypoint manifest. The gallery labels all screenshots as isolated API/desktop fixtures.

## Active setup resume review correction

Settings now offers an enabled **Resume setup** entry after **Back to Bridges** hides an active setup or unfinished identity review. It reopens the retained step without starting another operation, changing the target/options, or resetting the shared identity controller. Failed/cancelled setup remains reachable for its existing retry behavior.

Regression coverage in `tests/e2e/bridges_layout_browser_check.mjs` exercises install → Back → resume, Settings/wizard host switches, pending identity lookup → Back → resume without duplicate requests, preserved lookup failure, return to install, cancellation/rollback and reopening the exact retry. Identity choice, pending attempt and approval wait retention are also covered by the existing shared-controller test.

Validation: `npm run build` and `npm run typecheck` pass; focused bridge/setup/enrollment suite passes 78/78. Browser checks pass 80 responsive states across five widths (1440/1024/768/390/320) with isolated in-memory APIs and Electron operations. State screenshots reset modal scroll to the top so clipped offscreen controls are not measured as overlaps. [Resume regression screenshots](artifact://art_18e3eeecd054d3b2) contain 20 focused captures; downloaded bundle matched all 21 source files and its manifest.

No native lifecycle operation, account mutation or live preview refresh was performed. Existing full implementation evidence and limits above remain applicable.
