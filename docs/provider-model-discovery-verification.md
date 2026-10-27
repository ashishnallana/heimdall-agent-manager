# On-demand provider model discovery: final verification

The integrated implementation supports explicit, bridge-scoped model refresh and consistent model selection from the UI through launch arguments. Final review found and fixed queued-request coalescing. Live metadata checks succeeded for Claude, Codex, Antigravity and Pi; Copilot authenticated discovery remains unverified. Completed suite failures were reproduced separately on the clean implementation baseline. The matrix has finished. This report does **not** claim an entirely green repository suite.

**Final evidence, 27 October 2026:** The user requested early code review while the suite continued. That review passed at `194d89d1`. This follow-up collects every remaining check outcome. The slow Bridge service completed all 55 tests successfully. Task approval then removed its old worktree, so the runner resumed only unfinished labels from the follow-up worktree; completed checks were preserved. Final chain closure still requires the configured review gate.

## Reviewed scope

Baseline: `286fc1ddad728172e075e3510b306878e91adbe8`.

| Commit | Reviewed change |
| --- | --- |
| `1dd6c7243d3f5fa6b53483602405e64598fd2e77` | Metadata adapters, bounded subprocesses, explicit discovery and local snapshots |
| `c7ef58e70669f7e13cefe1b0fc45c6c9b5c4abba` | Dedicated model scheduling lane and adapter review fixes |
| `d0a91fbc81145b967f46c439e0ed595a28ff4089` | Hub storage, effective catalogs, API stages and launch validation |
| `d4d09ff728a907b871a3eacabe7e945876e4b2f4` | Explicit UI refresh, bridge cache isolation and retained selections |
| `33d8d72c2189e93328374ebaaaff88ea1a46a64e` | Queue-aware refresh coalescing, regression test and full-check runner |
| `194d89d1f5ea970a456bd518b5c8f9bfbf8c8715` | Independently approved early verification snapshot |
| `e13c0381ec2747a701259dcbc30ae1ed0c3d25f5` | Resume verification after task worktree cleanup without repeating recorded checks |

Review covered the complete diff, including process/pipe ownership, deadlines, bounded queues and output, JSON correlation, persisted model ownership, migration registration, API compatibility, both Hub validators, task defaults, bridge membership, launch argv, UI refresh actions and cache behavior. The final report commit changes documentation only.

### Final audit fix

The isolated model lane has one worker. Previously, the second overlapping request recorded its start only after the first request completed, so it missed the existing single-flight reuse condition and repeated model probes. Dispatch now carries the original queue-entry time into model refresh. The regression verifies that an overlapping queued request reuses the completed result, while a later explicit request performs a new attempt. This adds neither a timer nor a retry. Existing stage-one workers, queue bounds and deadlines remain intact.

## Requirement alignment

Approved requirements: [revised plan](artifact://art_18e248184b1fddc1), [approved HTML plan](artifact://art_18e2483b34e3d179). REQ-MODEL-9 was added to the implementation task acceptance criteria.

| Requirement | Implementation and direct evidence |
| --- | --- |
| **REQ-MODEL-1: bridge scope** | Migration `148_bridge_provider_models.sql` keys observations by bridge/provider and stores successful executable path/version as provenance. `effective_model_observation` replaces only an owned bridge view. SQLite regression proves bridge A's seed-absent ID is rejected on bridge B and never added to the global catalog. Failed attempts retain successful provenance; binary changes do not trigger refresh. |
| **REQ-MODEL-2: metadata only** | Production adapters send Claude control initialization, Codex initialization and `model/list`, Pi `get_available_models`, Copilot `models.list`, or `agy models`. No inference prompt, turn or agent conversation is created. Live production-adapter smoke returned four catalogs without persisting them. Claude suppresses hooks/tools/MCP; Pi disables extensions/MCP/skills and runs offline. |
| **REQ-MODEL-3: shared selection** | Status views, `provider.validate_launchable`, `agent.validate_provider_model_intersection` and task defaults use the bridge-effective policy. Bridge membership reads its saved discoveries. SQLite, task placement and bridge tests cover new IDs absent from seeds. The bridge test builds actual launch argv and verifies the ID is unchanged. The mounted UI test selects the new ID and verifies the actual reconfiguration HTTP body preserves it. These are connected component tests, not a paid provider inference launch. |
| **REQ-MODEL-4: explicit only** | Only `provider_models_discover` reaches the production model refresh/probe path. Only the explicit API model response applies model reports to Hub storage. Stage two is not retry-safe; no timer/TTL/startup/reconnect/config-change path calls it. Status GETs and picker polling read persisted lists. UI tests cover no model probe on mount, binary-only enrollment, enable-before-model ordering, one explicit two-stage refresh and no retry on failure. Identical successful results advance checked time. Queue coalescing is covered by the final regression. Stage one retains its 8-second Bridge / 10-second Hub bounds; model commands have a separate 30-second budget and lane, with per-provider probes capped at 18 seconds. |
| **REQ-MODEL-5: fallback and empty** | API/UI expose source, successful checked time, last attempted time, outcome and snapshot presence. A failed request preserves the last successful snapshot; an initial failure uses labeled static fallback. Valid empty snapshots replace seeds and deny previous models. Snapshot age never expires a catalog or starts a probe. Parser, repository, API and UI tests cover these cases. Ordinary/extension detection reports cannot erase the independent model table. |
| **REQ-MODEL-6: IDs and saved selections** | Parser fixtures cover Claude alias/resolved-ID separation, Codex launch IDs/pagination, Antigravity effort suffixes and Pi provider-qualified IDs, including custom provider names. UI keeps unavailable explicit choices visible without emitting replacement selections. Task placement returns explicit provider/model unchanged so validation rejects an unavailable selection instead of silently substituting a model. |
| **REQ-MODEL-7: compatibility and limits** | Missing model observations and optional repository callbacks preserve static fallback for older bridges/implementations. New fields are additive; `resolved_model` is optional. Old Hubs still validate before dispatch, so a new Bridge snapshot cannot bypass their catalog validation. No version-mixed binary deployment was executed; compatibility evidence is code review plus fallback/unsupported fixtures. Output is capped at 1 MiB, snapshots at 128 KiB/provider, catalogs at 512 models; IDs, pagination and report correlation are validated. |
| **REQ-MODEL-8: verification scope** | Adapter task reported 19 impacted checks; Hub task 15 impacted checks; UI task 61 impacted checks plus a selected-bridge query regression, typecheck and Vite build. Their handoffs explicitly deferred full suites. `model_final` depends on all three, ran the full matrix, reviewed the entire branch, reproduced baseline failures and rechecked its scoped fix. UI/full suites were not repeated after the Bridge-only fix; the affected full Bridge suite, focused adapter checks and Bridge production build were repeated. |
| **REQ-MODEL-9: two stages and enablement** | Existing `POST /api/v1/bridges/:id/providers/discover` defaults to `stage=providers`; `stage=models` derives the filter from durable active + present + enabled state. Client `providers`/`enabled` fields cannot widen it. Empty filters do no probes. A real WebSocket HTTP test proves disabled Claude and absent Pi are excluded while enabled/present Codex receives stage two and its new model returns through the existing response. Plain enable toggles and extension completion never enumerate models. |

## Verification results

The Odin matrix covered **43 packages**, reporting **2,709 passed and 12 baseline test failures** from 2,721 tests. Separately, **18 of 29 standalone programs passed** and 11 reproduced failures on the clean baseline. Failed names, exact commands and baseline comparisons are in the companion JSON evidence.

| Package/program | Tests reported | Exit | Outcome |
| --- | ---: | ---: | --- |
| `src/hub/transport/http` | 502 | 1 | Baseline failure |
| `src/bridge` | 828 | 1 | Baseline failure |
| `src/contracts` | 9 | 0 | Passed |
| `src/ctl` | 176 | 0 | Passed |
| `src/ctl/extension` | 76 | 0 | Passed |
| `src/dev_proxy` | 2 | 0 | Passed |
| `src/hub` | 57 | 1 | Baseline failure |
| `src/hub/app` | 30 | 1 | Baseline failure |
| `src/hub/domain` | 17 | 0 | Passed |
| `src/hub/repository/sqlite` | 152 | 0 | Passed |
| `src/hub/service/agent` | 63 | 1 | Baseline failure |
| `src/hub/service/auth` | 26 | 0 | Passed |
| `src/hub/service/billing` | 17 | 0 | Passed |
| `src/hub/service/bridge` | 55 | 0 | Passed |
| `src/hub/service/bridge_log` | 9 | 0 | Passed |
| `src/hub/service/bridge_runtime` | 38 | 0 | Passed |
| `src/hub/service/card` | 32 | 0 | Passed |
| `src/hub/service/content` | 16 | 0 | Passed |
| `src/hub/service/events` | 17 | 0 | Passed |
| `src/hub/service/issue` | 1 | 0 | Passed |
| `src/hub/service/provider` | 1 | 0 | Passed |
| `src/hub/service/push` | 40 | 0 | Passed |
| `src/hub/service/shell_session` | 188 | 0 | Passed |
| `src/hub/service/taskchain` | 14 | 1 | Baseline failure |
| `src/hub/service/taskv2` | 150 | 1 | Baseline failure |
| `src/hub/service/user` | 3 | 0 | Passed |
| `src/hub/service/vault_directory` | 14 | 0 | Passed |
| `src/lib/agent_runtime` | 8 | 0 | Passed |
| `src/lib/httpc` | 34 | 0 | Passed |
| `src/lib/jsonx` | 18 | 0 | Passed |
| `src/lib/local_socket` | 6 | 0 | Passed |
| `src/lib/metrics` | 9 | 0 | Passed |
| `src/lib/tls_stream` | 2 | 0 | Passed |
| `src/lib/tool_live` | 18 | 0 | Passed |
| `src/lib/vault` | 25 | 0 | Passed |
| `src/lib/ws` | 24 | 0 | Passed |
| `src/manager` | 38 | 0 | Passed |
| `tests/hub_bootstrap_golden_test` | 1 | 0 | Passed |
| `tests/migration_bootstrap_test` | 1 | 0 | Passed |
| `tests/push_crypto_test` | 1 | 0 | Passed |
| `tests/push_repo_test` | 1 | 0 | Passed |
| `tests/taskchain_grouping_test` | 1 | 0 | Passed |
| `tests/vcs_backend_test` | 1 | 0 | Passed |
| `tests/bridge_bootstrap_conditional_test.odin` | 0 | 0 | Passed |
| `tests/bridge_local_endpoint_test.odin` | 0 | 0 | Passed |
| `tests/bridge_start_success_relay_test.odin` | 0 | 1 | Baseline failure |
| `tests/device_auth_grant_store_test.odin` | 0 | 0 | Passed |
| `tests/device_auth_security_matrix_test.odin` | 0 | 0 | Passed |
| `tests/device_auth_token_poll_test.odin` | 0 | 0 | Passed |
| `tests/device_auth_verify_approve_test.odin` | 0 | 0 | Passed |
| `tests/hub_actions_repo_test.odin` | 0 | 0 | Passed |
| `tests/hub_agent_instance_token_authz_test.odin` | 0 | 0 | Passed |
| `tests/hub_agent_search_isolation_test.odin` | 0 | 1 | Baseline failure |
| `tests/hub_bridge_offline_mark_test.odin` | 0 | -11 | Baseline failure |
| `tests/hub_cards_repo_test.odin` | 0 | 0 | Passed |
| `tests/hub_chain_closed_broadcast_test.odin` | 0 | 1 | Baseline failure |
| `tests/hub_chain_member_instance_only_test.odin` | 0 | 0 | Passed |
| `tests/hub_ct_title_lifecycle_test.odin` | 0 | 0 | Passed |
| `tests/hub_fts_repair_test.odin` | 0 | 1 | Baseline failure |
| `tests/hub_h9_coordinator_single_source_test.odin` | 0 | 0 | Passed |
| `tests/hub_memory_actions_test.odin` | 0 | 1 | Baseline failure |
| `tests/hub_project_archive_repo_test.odin` | 0 | 0 | Passed |
| `tests/hub_readonly_cross_chain_test.odin` | 0 | 1 | Baseline failure |
| `tests/hub_search_comments_skills_test.odin` | 0 | 1 | Baseline failure |
| `tests/hub_search_fts_all_test.odin` | 0 | 1 | Baseline failure |
| `tests/hub_search_fts_comments_test.odin` | 0 | 1 | Baseline failure |
| `tests/hub_search_message_handler_test.odin` | 0 | 0 | Passed |
| `tests/hub_search_messages_test.odin` | 0 | 0 | Passed |
| `tests/hub_search_owner_isolation_test.odin` | 0 | 1 | Baseline failure |
| `tests/hub_search_scope_validation_test.odin` | 0 | 0 | Passed |
| `tests/hub_skills_handler_test.odin` | 0 | 0 | Passed |
| `tests/hub_startup_blocked_projection_test.odin` | 0 | 0 | Passed |

Other completed checks: UI 1,145 passed / one baseline failure / one opt-in skip, plus 16 pretests passed; Hub/Bridge/CLI and full UI/Electron builds passed; focused model checks 20/20 passed; Rust 180 passed / two ignored; runtime helpers 10/10 passed; HTTP boundary passed; QR checks passed with required tools. Python distribution: two passed / 18 baseline setup errors from 20 tests. Live metadata: four providers successful; Copilot bounded timeout.

### Reproducible command conventions

Full matrix commands, executed through managed shell sessions from the task worktree:

```bash
nix develop -c python3 scripts/provider-model-full-check.py --group odin --out-dir /home/tanmay/.cache/heimdall-tests/model-final-20261027
python3 scripts/provider-model-full-check.py --group ui --out-dir /home/tanmay/.cache/heimdall-tests/model-final-20261027
python3 scripts/provider-model-full-check.py --group misc --out-dir /home/tanmay/.cache/heimdall-tests/model-final-20261027
nix develop -c python3 scripts/provider-model-full-check.py --group odin --resume --out-dir /home/tanmay/.cache/heimdall-tests/model-final-20261027
```

The Odin matrix discovers every source package containing `*test.odin`, test-entrypoint packages under `tests/`, and standalone `tests/*_test.odin` programs. Package commands use:

```bash
odin test <package> -collection:odin_test=src -define:ODIN_TEST_THREADS=1 -out:<unique-home-cache-binary>
odin run <standalone-test-file> -file -collection:odin_test=src -out:<unique-home-cache-binary>
```

Production builds used the pinned development environment:

```bash
nix develop -c odin build src/hub -collection:odin_test=src -out:<home-cache>/hub-build
nix develop -c odin build src/bridge -collection:odin_test=src -out:<home-cache>/bridge-build-final
nix develop -c odin build src/ctl -collection:odin_test=src -out:<home-cache>/ctl-build
npm run build
bash scripts/provider-model-discovery-check.sh
nix develop -c cargo test --manifest-path tools/pty_host/Cargo.toml --locked --target-dir <home-cache>/rust-target
nix shell --inputs-from . nixpkgs#qrencode nixpkgs#zbar --command node --test auth/flow-ui/qr.test.mjs
git diff 286fc1ddad728172e075e3510b306878e91adbe8 HEAD --check
```

The companion final evidence manifest records every matrix outcome, executed command, log location and hash. It preserves the initial Bridge compile failure and explicitly supersedes that row with the completed 828-test rerun. The runner interruption and resume are recorded separately from test outcomes. All executables are under the home cache, following the repository's endpoint-security guidance. The full matrix ran once; only affected checks or concrete failures were investigated further. The initial full Bridge compilation caught a typo in the newly added regression's cleanup call; it was corrected before the final full Bridge run and exact-commit focused check. Its failed intermediate log is retained rather than counted as a passing run. An exploratory baseline concurrency check exceeded its 90-second limit; the complete Bridge service suite subsequently passed all 55 tests in 14 minutes 32 seconds, so that exploratory timeout is not treated as a failed full suite.

### Live metadata coverage

The temporary final-verification harness called the production adapter directly using installed executables and isolated probe working directories. It saved no catalog and requested no inference. Its source and log are retained with the evidence.

| Provider | Result |
| --- | --- |
| Claude | Success: 13 models |
| Codex | Success: 8 models |
| Antigravity | Success: 13 models |
| Pi | Success: 33 configured models |
| Copilot | Bounded timeout: zero models; authenticated success remains unverified |

Counts are host/account observations, not guarantees of inference authorization. Copilot fixtures cover framed replies, ignored unrelated IDs, authentication errors, policy exclusion, output limits and retained fallback. Neither a timeout nor fixture success is presented as authenticated production discovery. Windows subprocess-tree cleanup is implemented but not runtime-tested on Windows. Pi extension-provided/online model sources are excluded by the approved safe metadata mode and were not verified.

Memory tracking remained enabled. Focused model checks reported no memory diagnostics. Full legacy suites emit existing retained-memory warnings. The live harness additionally reported five 256-byte allocations from the existing executable path lookup's `os.stat`/readlink path; this is separate from parser/snapshot ownership coverage. The UI build has existing environment-placeholder, circular-export and large-chunk warnings.

## Pre-existing failures and practical limits

| Failure | Clean-baseline evidence and tracking |
| --- | --- |
| Distribution test setup parses `native_001_…sql` as an integer | Same `ValueError` on `286fc1dd`; `iss_18e24c895db335f5` |
| Task event UI has no sentence for `held` | Same 18-pass / one-failure focused baseline run; `iss_18e24c8969bf68c6` |
| Three HTTP extension-overlap tests expect no additional install | Same three assertions and counts on baseline; `iss_18e24cae2f70a827` |
| Bridge Termux target test expects refusal before staging | Same focused baseline assertion; `iss_18e24cae37aec8a6` |
| Hub action fixture gets experimental-feature-disabled 403 | Same focused baseline failure; `iss_18e24cae3ff34780` |
| App plan sweep fixture expects one reconcile, gets zero | Same focused baseline failure; `iss_18e24cbfb7fe4007` |
| Agent wake payload expects verbatim lease pack | Same focused baseline failure; `iss_18e24cd438e7e27d` |
| Task-chain publish brief/gate fixture | Same focused baseline failure; `iss_18e24e81362ab54e` |
| Four task-engine lifecycle/expiry/review fixtures | Same four failures on focused baseline; `iss_18e24e81442e6035` |
| Ten standalone programs with outdated fixtures/contracts | Same failing exit codes on baseline; `iss_18e24ee81e674979` |
| Bridge-offline standalone harness SIGSEGV | Same exit-11 on baseline; `iss_18e24ee826d8025a` |

The suite is not wholly green. Each listed unrelated failure was reproduced on clean baseline `286fc1dd` using the same pinned compiler/dependencies; these failures were filed as project issues rather than expanding this chain's implementation scope. Network/service-dependent shell end-to-end scripts, paid model inference, production deployment, and Windows/macOS execution were not performed. The opt-in production Hub terminal-rendering UI test remains skipped without its external harness. Rust retains its two ignored tests.

## Changed paths

- `AGENTS.md`
- `docs/provider-model-discovery-verification.md`
- `package.json`
- `scripts/provider-model-discovery-check.sh`
- `scripts/provider-model-full-check.py`
- `scripts/provider-model-hub-check.sh`
- `src/bridge/hub_command_dispatch.odin`
- `src/bridge/hub_command_dispatch_test.odin`
- `src/bridge/hub_runtime_client.odin`
- `src/bridge/provider_catalog_cache.odin`
- `src/bridge/provider_model_discovery.odin`
- `src/bridge/provider_model_discovery_test.odin`
- `src/bridge/provider_model_process_unix.odin`
- `src/bridge/provider_model_process_windows.odin`
- `src/bridge/provider_models_effective_test.odin`
- `src/hub/domain/provider.odin`
- `src/hub/repository/iface/provider_repo.odin`
- `src/hub/repository/sqlite/migrations.odin`
- `src/hub/repository/sqlite/migrations/148_bridge_provider_models.sql`
- `src/hub/repository/sqlite/provider_models_test.odin`
- `src/hub/repository/sqlite/provider_repo_sqlite.odin`
- `src/hub/service/agent/agent_service.odin`
- `src/hub/service/provider/provider_models.odin`
- `src/hub/service/provider/provider_service.odin`
- `src/hub/service/taskv2/dispatch_test.odin`
- `src/hub/service/taskv2/placement.odin`
- `src/hub/transport/http/bridge_handlers.odin`
- `src/hub/transport/http/provider_extension_handlers_test.odin`
- `src/hub/transport/http/provider_handlers.odin`
- `src/hub/transport/http/provider_model_handlers.odin`
- `src/ui/api/endpoints/bridgeSupport.ts`
- `src/ui/components/chat/RuntimeConfigurationOptions.tsx`
- `src/ui/components/providers/ModelCatalogRefresh.tsx`
- `src/ui/components/providers/ProviderSetupSurface.tsx`
- `src/ui/components/providers/modelCatalogStatus.ts`
- `src/ui/components/providers/providerSetupApi.ts`
- `src/ui/components/tasks/FleetManagementDrawer.tsx`
- `tests/ui_provider_model_discovery_test.ts`

## Handoff

Confidence is high for the scoped discovery behavior: live metadata succeeded for four providers, model-specific regression checks passed, production builds passed, and completed suite failures have clean-baseline evidence. Every planned matrix check now has an outcome; all failed standalone programs were also reproduced on clean baseline with matching exit codes, including the bridge-offline SIGSEGV. Pre-existing failures remain explicitly reported. Copilot authenticated support and other-platform runtime behavior remain explicit limitations. Proposed quality rating: **good for the scoped implementation and verification**, with repository-wide baseline failures carried separately. The configured independent task reviewer still owns the review verdict; this report does not approve its own task or close the chain before every required item finishes.
