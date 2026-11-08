# Documentation index

Curated index of everything under `docs/`. Start with `../AGENTS.md` for the contributor guide, then use this page to find deeper material.

Groups:

1. [Current reference](#current-reference): how things work today.
2. [Design plans](#design-plans): proposals, partly or fully implemented, some superseded.
3. [Audits and reports](#audits-and-reports): point-in-time findings, verification runs and implementation reports.
4. [Historical](#historical): superseded documents kept for context.
5. [Data and fixtures](#data-and-fixtures): `txt`, `json`, `html` and `png` files.

> **Task engine:** [fsm_task_chain_engine.md](fsm_task_chain_engine.md) is a **historical proposal** and does not describe the runtime. The current engine is `src/hub/service/taskv2` (spec and status: [plans/task-system-v2.md](plans/task-system-v2.md)).

## Current reference

### Architecture and contributor deep-dives

- [README.md](README.md): this index of everything under `docs/`.
- [architecture.md](architecture.md): verified architecture walkthrough of the hub, bridge, CLI and UI.
- [ui-debug-ids.md](ui-debug-ids.md): the UI debug-id conventions, extracted from AGENTS.md.
- [socket-lifetime.md](socket-lifetime.md): socket lifetime rules, extracted from AGENTS.md.
- [dev-preview.md](dev-preview.md): running a local dev preview, extracted from AGENTS.md.
- [runtime-registry.md](runtime-registry.md): how the hub keeps connection-scoped runtime state (connection generations, mutexes, instance lifecycle) bounded.
- [reference/heimdall_memory_system_and_bootstrap.md](reference/heimdall_memory_system_and_bootstrap.md): the federated memory system and agent run-dir bootstrap across hub, bridge and `ham-ctl`.
- [reference/db-telemetry.md](reference/db-telemetry.md): hub DB latency and lock-contention telemetry (phase 1): configuration, metrics and call-site attribution.
- [reference/task-placement-failures.md](reference/task-placement-failures.md): native placement-failure snapshots stored in `task_attempt_facets` (REQ-PLACE-1).
- [reference/task-placement-recovery.md](reference/task-placement-recovery.md): the `task_placement` attention cards and recovery APIs built on placement-failure snapshots (REQ-PLACE-2/3).
- [plans/task-system-v2.md](plans/task-system-v2.md): Task System v2 specification and implementation status; the current task engine.
- [fleet-management.md](fleet-management.md): per-chain, per-agent fleet launch settings and the `bridge_models` API field.
- [multi-question-messages.md](multi-question-messages.md): version 1 multi-question message form and the agent CLI JSON format.
- [html-bundle-artifacts.md](html-bundle-artifacts.md): publishing multi-page static HTML bundles as artifacts and viewing them in an isolated iframe.
- [quoted-context.md](quoted-context.md): the Quote feature that attaches selected message text to a coordinator message.

### Transport and streaming

- [pane-transport.md](pane-transport.md): bounded pane transport, Phase 1 wire contract and recovery bounds.
- [plans/pty-streaming-binary-wire.md](plans/pty-streaming-binary-wire.md): PTY streaming binary wire format and network optimizations, as implemented (hub↔bridge protocol 2).
- [ephemeral-tool-activity.md](ephemeral-tool-activity.md): the summary-only, demand-driven tool activity stream.
- [transient-extension-signals.md](transient-extension-signals.md): how provider extension signals are reduced locally and never queue immediate status pushes.
- [bounded-action-recovery.md](bounded-action-recovery.md): bounded retry contract and startup recovery for action synchronization.

### Auth, accounts and billing

- [auth-oidc.md](auth-oidc.md): OIDC-only user authentication (session cookie for web, bearer token for native apps).
- [account-billing.md](account-billing.md): subscriptions, entitlements and Paddle integration, with configuration variables.
- [analytics.md](analytics.md): PostHog funnel events for the marketing site and the app.

### MCP

- [mcp-capabilities.md](mcp-capabilities.md): the permission-filtered MCP capability catalog.
- [mcp-delegated-oauth.md](mcp-delegated-oauth.md): delegated MCP OAuth (U1): device-signed consent and sealed credentials.
- [mcp-hosted-vault.md](mcp-hosted-vault.md): hosted vault reads and epoch delivery (U2) for opted-in MCP grants.
- [mcp-remote-control.md](mcp-remote-control.md): the remote MCP chain-control tools.
- [mcp-oauth-spike.md](mcp-oauth-spike.md): the synthetic-data remote MCP OAuth interoperability probe (U0).
- [mcp-control-poc.md](mcp-control-poc.md): the local-stdio MCP chain control-plane proof of concept and its four tools.
- [mcp-acceptance.md](mcp-acceptance.md): the end-to-end MCP task offload acceptance harness.

### Bridge, install and providers

- [INSTALL_ANALYSIS_AND_RECOVERY.md](INSTALL_ANALYSIS_AND_RECOVERY.md): bridge install, update and recovery built around the single `ham-bridge` binary.
- [bridge-setup-progress.md](bridge-setup-progress.md): the `ham-bridge` `setup --json-progress`, `status --json` and `list --json` lifecycle CLI.
- [bridge-multi-account.md](bridge-multi-account.md): several accounts on one machine, each with its own bridge profile.
- [bridge-retirement.md](bridge-retirement.md): how the bridge parks Hub traffic on sunset or credential revocation.
- [provider-profiles.md](provider-profiles.md): provider profiles and isolated local homes.
- [release-targets.md](release-targets.md): release workflow targets and the optional Intel macOS build.

### Desktop app

- [desktop-auth.md](desktop-auth.md): Electron hosted-UI login and effective UI URL resolution.
- [desktop_auto_updates.md](desktop_auto_updates.md): desktop app updates, separate from bridge updates.
- [desktop-notifications.md](desktop-notifications.md): native desktop notifications and their privacy rules.
- [desktop-window-chrome.md](desktop-window-chrome.md): macOS and Windows window chrome behavior.

### Design system

- [design-system/README.md](design-system/README.md): overview of the Ninjy design system and where tokens, components and brand assets live.
- [design-system/migration.md](design-system/migration.md): mapping from old screen and token values to the system's tokens.
- Component guidelines (props and usage rules for each `@ui` component):
  - [Alert](design-system/components/Alert.md): inline banner tied to nearby content.
  - [Badge](design-system/components/Badge.md): inert metadata such as a count, tag or kind.
  - [Button](design-system/components/Button.md): the one labelled action, with variants and sizes.
  - [Checkbox](design-system/components/Checkbox.md): boolean form field.
  - [Combobox](design-system/components/Combobox.md): searchable single or multi picker for long lists.
  - [EmptyState](design-system/components/EmptyState.md): "nothing here yet" and "no matches" states.
  - [FormField](design-system/components/FormField.md): label, control, hint and error wiring.
  - [Icon](design-system/components/Icon.md): the app's monochrome glyph set.
  - [IconButton](design-system/components/IconButton.md): icon-only action.
  - [Input](design-system/components/Input.md): single-line text input.
  - [Kbd](design-system/components/Kbd.md): keyboard-key hint.
  - [Link](design-system/components/Link.md): navigation text.
  - [Menu](design-system/components/Menu.md): popover list of actions from a trigger.
  - [Modal](design-system/components/Modal.md): focus-managed centred dialog.
  - [PageShell](design-system/components/PageShell.md): the frame every route renders into.
  - [Panel](design-system/components/Panel.md): the content container and card.
  - [Radio](design-system/components/Radio.md): one choice of a few, all visible.
  - [Select](design-system/components/Select.md): one value from a short list.
  - [Spinner](design-system/components/Spinner.md): the indeterminate loading glyph.
  - [StatusDot](design-system/components/StatusDot.md): liveness dot.
  - [StatusPill](design-system/components/StatusPill.md): labelled state such as Running or Offline.
  - [Text](design-system/components/Text.md): all typography through one `role`.
  - [Textarea](design-system/components/Textarea.md): multi-line text input.
  - [Toast](design-system/components/Toast.md): transient notification card.
  - [Toggle](design-system/components/Toggle.md): switch for settings that apply immediately.

## Design plans

Proposals and implementation plans. Check each document's `Status:` line: some are implemented, some are proposed only, and some are superseded. The code is authoritative.

- [plans/alternate-buffer-handling-plan.md](plans/alternate-buffer-handling-plan.md): plan to support alternate terminal buffers (for example Neovim) across live streaming, late joins and reconnects; implementation not started.
- [plans/antigravity-provider-extension.md](plans/antigravity-provider-extension.md): architecture and execution plan for an Antigravity provider extension (proposed).
- [plans/bridge-auth-resume-recovery.md](plans/bridge-auth-resume-recovery.md): plan for Bridge credential recovery after laptop sleep past access-token expiry (expiry-aware acquisition, single-flight fenced refresh, wakeable scheduling); proposed, not implemented.
- [plans/db-latency-telemetry.md](plans/db-latency-telemetry.md): plan for hub DB call latency and lock-contention telemetry; phase 1 is documented in [reference/db-telemetry.md](reference/db-telemetry.md).
- [plans/favorite-conversation-launch-plan.md](plans/favorite-conversation-launch-plan.md): favorite-agent cards above the shared conversation composer (implemented in the working tree at the time).
- [plans/instance-reconfiguration-plan.md](plans/instance-reconfiguration-plan.md): reconfiguring agent instances without context handoff.
- [plans/mcp-task-chain-coordinator-agent-id.md](plans/mcp-task-chain-coordinator-agent-id.md): require an explicit durable coordinator `agent_id` when creating chains through MCP (proposed).
- [mcp-chain-coordinator-messages-plan.md](mcp-chain-coordinator-messages-plan.md): proposal for an MCP `chains.message` tool that sends text to a chain's coordinator.
- [plans/minimal-bridge-heartbeat-plan.md](plans/minimal-bridge-heartbeat-plan.md): plan for a minimal bridge heartbeat (REQ-HBP-1 to 4); plan only.
- [plans/mixed-work-task-chains.md](plans/mixed-work-task-chains.md): one task chain containing both tickets and workflow runs.
- [plans/oidc-only-auth.md](plans/oidc-only-auth.md): plan to make OIDC the only hub authentication method; current behavior is in [auth-oidc.md](auth-oidc.md).
- [plans/passwordless-vault.md](plans/passwordless-vault.md): passwordless vault with per-device keys and one approval flow.
- [plans/passwordless-vault-handoff.md](plans/passwordless-vault-handoff.md): handoff state for the passwordless vault implementation.
- [plans/placement-attention-recovery.md](plans/placement-attention-recovery.md): plan for Need Attention cards and recovery when tasks wait on offline bridges; implemented in [reference/task-placement-recovery.md](reference/task-placement-recovery.md).
- [plans/preview_per_origin_design.md](plans/preview_per_origin_design.md): design for a separate preview origin with a CSRF guard.
- [plans/sqlite-reader-pool.md](plans/sqlite-reader-pool.md): typed query layer, isolated writers and a SQLite reader pool (revision 2).
- [desktop_auto_update_design.md](desktop_auto_update_design.md): implementation design for desktop automatic updates; the shipped behavior is in [desktop_auto_updates.md](desktop_auto_updates.md).
- [ui-rebuild/00-ground-truth.md](ui-rebuild/00-ground-truth.md): ground rules and goal for rebuilding the resource pages on `@ui` (planning only).
- [ui-rebuild/memory.md](ui-rebuild/memory.md): UI plan for the Memory pages, the reference implementation for the rebuild.

## Audits and reports

Point-in-time findings. File paths, commit ids and numbers reflect the snapshot they name.

### Audits and investigations

- [audits/bridge_hub_ws_communication_audit.md](audits/bridge_hub_ws_communication_audit.md): audit of the bridge-to-hub WebSocket framing, chunking and relay layers.
- [audits/preview_origin_and_backend_audit.md](audits/preview_origin_and_backend_audit.md): static audit of the preview tunnel's origin, routing and backend requirements.
- [audits/shell_preview_memory_audit.md](audits/shell_preview_memory_audit.md): memory-leak audit of shell sessions and the preview proxy.
- [reports/json_string_manipulation_audit.md](reports/json_string_manipulation_audit.md): audit of direct JSON string manipulation in the Odin code and a refactoring roadmap.
- [investigations/html-bundle-navigation-diagnosis.md](investigations/html-bundle-navigation-diagnosis.md): diagnosis and approved correction plan for broken navigation links in HTML bundles.
- [investigations/mcp-file-transfer-patterns.md](investigations/mcp-file-transfer-patterns.md): comparative study (2026-11-02) of how other MCP servers upload and download files and how Heimdall's encryption relay fits; not an implementation plan.
- [incidents/2026-11-03-riverwood-oom-t4b.md](incidents/2026-11-03-riverwood-oom-t4b.md): riverwood `ham-bridge` out-of-memory A/B investigation (T4b) that confirmed a per-command temp-allocator leak in the dispatch workers; soak data in [incidents/t4b/soak-10m-bc.csv](incidents/t4b/soak-10m-bc.csv) and [incidents/t4b/soak-20m.csv](incidents/t4b/soak-20m.csv) (`elapsed_s,label,pid,rss_kib,threads,ops_ok`).

### Performance and call-reduction reports

- [api-fetch-dedup.md](api-fetch-dedup.md): API fetch deduplication work on a dedicated worktree.
- [call-reduction-decision-matrix.md](call-reduction-decision-matrix.md): call and write reduction baseline and decision matrix (REQ-CALL, REQ-INDEX).
- [call-reduction-baseline-results.md](call-reduction-baseline-results.md): recorded output of the baseline fixture run.
- [call-reduction-integrated-results.md](call-reduction-integrated-results.md): integrated call and write reduction results and SQLite cache sizing, from local fixtures.
- [call-reduction-integrated-replay-compare.md](call-reduction-integrated-replay-compare.md): baseline versus integrated replay comparison table.
- [hotpath-writes-report.md](hotpath-writes-report.md): hot-path write reduction decisions and counters.
- [sqlite-index-eval.md](sqlite-index-eval.md): evaluation of candidate SQLite indexes for full-scan queries.

### Implementation and verification reports

- [bridges-settings-implementation.md](bridges-settings-implementation.md): Bridges settings implementation record.
- [provider-settings-implementation.md](provider-settings-implementation.md): bridge-first provider settings implementation record.
- [provider-settings-bridges-width.md](provider-settings-bridges-width.md): full-width Bridges overview cards change and its verification.
- [provider-model-discovery-verification.md](provider-model-discovery-verification.md): final verification of on-demand provider model discovery.
- [live-tools-integration.md](live-tools-integration.md): integrated verification of subscribed tool summaries.

## Historical

Superseded or one-off records kept for context. Do not treat them as current behavior.

- [fsm_task_chain_engine.md](fsm_task_chain_engine.md): **historical proposal** for a pre-Task-v2 finite-state-machine engine, never implemented. The current engine is `src/hub/service/taskv2`; see [plans/task-system-v2.md](plans/task-system-v2.md).
- [bridge_update_pipeline_design.md](bridge_update_pipeline_design.md): superseded bridge update pipeline design; the out-of-process supervisor script was removed, and `ham-bridge update` replaces it. Kept for the hub, UI and protocol design.
- [plans/pane-streaming-network-and-compression-plan.md](plans/pane-streaming-network-and-compression-plan.md): superseded pane streaming audit and plan, kept for its numbers; see [plans/pty-streaming-binary-wire.md](plans/pty-streaming-binary-wire.md).
- [ui-rebuild/memory-redesign-spec.md](ui-rebuild/memory-redesign-spec.md): the user's verbatim Memory redesign spec, with several clauses since superseded.
- [tool-stream-main-merge.md](tool-stream-main-merge.md): merge reconciliation record for the tool integration into `origin/main`.
- [tool-stream-preview-run.md](tool-stream-preview-run.md): record of an isolated tool stream preview run on 2026-10-23.
- [plans/mcp-large-artifact-transfers.md](plans/mcp-large-artifact-transfers.md): **superseded (2026-11-02)** strict-E2EE transfer-handle design for 15 MiB MCP artifacts; large artifacts use the ordinary create path through the existing MCP relay instead, and this design's code was removed.
- [plans/claude-browser-e2ee-artifact-upload.md](plans/claude-browser-e2ee-artifact-upload.md): **superseded (2026-11-02)** feasibility study of Hub-blind HTML bundle uploads from the Claude browser agent; kept for its egress and MCP App findings.

## Data and fixtures

Raw outputs, schemas, mockups and screenshots referenced by the documents above.

- Benchmark and telemetry outputs (`txt`), produced by the performance reports above:
  - [api-fetch-dedup-baseline-after.txt](api-fetch-dedup-baseline-after.txt)
  - [cache-matrix-run1.txt](cache-matrix-run1.txt)
  - [cache-matrix-run2.txt](cache-matrix-run2.txt)
  - [cache-matrix-run3.txt](cache-matrix-run3.txt)
  - [hotpath-writes-after.txt](hotpath-writes-after.txt)
  - [sqlite-index-eval-prod.txt](sqlite-index-eval-prod.txt)
  - [sqlite-index-eval-t1.txt](sqlite-index-eval-t1.txt)
- Schemas and tokens (`json`):
  - [tool-activity-live.schema.json](tool-activity-live.schema.json): JSON Schema for the tool activity stream messages in [ephemeral-tool-activity.md](ephemeral-tool-activity.md).
  - [design-system/tokens.json](design-system/tokens.json): the machine-readable design token set.
- Multi-question UI evidence for [multi-question-messages.md](multi-question-messages.md):
  - [evidence/multi-question/README.md](evidence/multi-question/README.md): how the evidence was produced (rendered with mocked delivery, seven Firefox checks).
  - [results.json](evidence/multi-question/results.json): browser check results.
  - Screenshots (`png`): [answered](evidence/multi-question/answered.png), [desktop](evidence/multi-question/desktop.png), [locked](evidence/multi-question/locked.png), [mobile](evidence/multi-question/mobile.png), [retry](evidence/multi-question/retry.png), [stale](evidence/multi-question/stale.png).
- Mixed-work UI mockups for [plans/mixed-work-task-chains.md](plans/mixed-work-task-chains.md) (`html` with `png` renders):
  - [mockups/mixed-work.html](mockups/mixed-work.html), [mockups/mixed-work.png](mockups/mixed-work.png): the mixed-work concept.
  - [mockups/mixed-work-current-ui.html](mockups/mixed-work-current-ui.html), [mockups/mixed-work-current-ui.png](mockups/mixed-work-current-ui.png): the concept against the current UI.
