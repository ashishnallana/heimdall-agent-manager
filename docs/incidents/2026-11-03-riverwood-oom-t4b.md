# Riverwood OOM: ham-bridge leak A/B (T4b)

Task `task_18e49235efe4bd20`, chain `chain_18e484df28ff5da1`. Run on dawnstar, 2026-11-03 15:26–16:10Z.
Supersedes `oom_t4`, which exhausted its attempt budget.

## Verdict

**Confirmed (dominant leak): `src/bridge/hub_command_dispatch.odin:690-716`** (`bridge_command_dispatch_worker`).
The 14 dispatch worker threads (`BRIDGE_DISPATCH_WORKER_CLASSES`, `:142`) run every hub command for the life of the process. Handlers allocate from the per-thread `context.temp_allocator`, and nothing in the worker loop ever reset it, so each worker retains every temp allocation it has made. The A/B below shows that this is the dominant ham-bridge leak under command load (1,420 MiB/h vs 23 MiB/h). A small residual remains (13–15 MiB/h post-warm-up over a short window) and is not yet explained.

**Consistent with the riverwood observations, but not proven against them.** No riverwood command or payload attribution was captured.
- **Growth follows activity:** ~5 MB/h while quiet versus 78–92 MiB/h over busy Prometheus segments and ~150 MiB/h in the 48-min live sample (oom_t2 fits). A per-command arena leak predicts exactly this.
- **Step jumps (+108 MiB at 07:07Z, +604 MiB within one minute at 07:31Z):** a single large command can permanently grow a worker's arena by roughly its payload size. *Hypothesis:* this soak only used 4 MB payloads, and the commands behind those two jumps were not identified.
- **RSS above oom_t4's tracked heap:** that tracking wrapper covered `context.allocator`, not the temp arena, so this leak was invisible to it.

Fix (`f904c37b`): `free_all(context.temp_allocator)` after `bridge_command_dispatch_finish` in each iteration.
`runtime.arena_free_all` frees every block except the first and resets it, so a large-payload block is returned to the OS.

Two minor leaks were fixed alongside it:
- `bfc1efe8`: the `schedules_epoch` string leaked once per heartbeat ack (`hub_runtime_client.odin`, `bridge_heartbeat_ack` branch).
- `2db14c72`: fs containment resolution (`fs_management.odin` `bridge_fs_resolve_within`, `bridge_fs_realpath_existing_prefix`, `bridge_fs_canonicalize_existing`) leaked the cleaned path, the expanded/joined request, the real prefix and the tail on every fs command (~288 B/op per oom_t4). The new test `test_fs_resolve_within_frees_intermediates` reports 20 leaked allocations before the fix and 0 after.

## Method

- **Base:** `origin/main` `5dd44e78` (v0.5.44). The bug is unchanged there from riverwood's v0.5.35.
- **Builds** (inside `nix develop`):
  `odin build src/bridge -collection:odin_test=src -out:<dir>/ham-bridge` (hub, dev-proxy and ctl built the same way from `src/hub`, `src/dev_proxy`, `src/ctl`).
  - **A** = main.
  - **B** = main + `f904c37b` only.
  - **C** = branch HEAD, with all three fixes.
- **Isolated stack** (never the live hub or bridge):
  `scripts/local-hub.sh start --name oomt4b --hub-port 18481 --proxy-port 18480 --ui-port 15473 --oidc-port 18490 --no-ui --no-plan-limits --build none --bin-dir <A>`,
  then `scripts/local-bridge.sh start --name oomt4b-{a,b,c} --hub oomt4b --port 496{2,3,4}7 --local-endpoint-port 496{2,3,4}8 --auto-enroll --build none --bin-dir <A|B|C>`.
- **Load:** `scripts/oom/dispatch-soak.py`. It interleaves the identical op mix across the bridges under test:
  - `GET /api/v1/bridges/<id>/fs?path=src/bridge` (`fs_list_dir`)
  - `GET .../fs/file?path=src/bridge/hub_runtime_client.odin` (`fs_read_file`)
  - a 4 MB file read every 60th cycle

  It runs at 4 cycles/s. Every op is a hub→bridge command executed on a dispatch worker. Any failed op aborts the run with exit 1. Every 30 s it samples `/proc/<pid>/status` VmRSS and Threads.

## Results

### 20-minute A/B (both bridges fresh, run side by side)

CSV: `docs/incidents/t4b/soak-20m.csv`. 9,596 ops per bridge, 0 failures.

| build | RSS t0 | RSS t10 | RSS t20 | slope (OLS, MiB/h) | 2nd-half slope | threads |
|---|---|---|---|---|---|---|
| A (main) | 53.6 MiB | 298.7 MiB | 533.8 MiB | **1420.3** | 1425.6 | 25 (flat) |
| B (dispatch temp reset) | 46.9 MiB | 59.0 MiB | 61.4 MiB | **22.9** | 15.4 | 25 (flat) |

### 10-minute B vs C (both fresh)

CSV: `docs/incidents/t4b/soak-10m-bc.csv`.

4,790 ops per bridge, 0 failures.

| build | RSS t0 | RSS t5 | RSS t10 | slope (whole run) | 2nd-half slope | threads |
|---|---|---|---|---|---|---|
| B (dispatch temp reset only) | 20.0 MiB | 49.0 MiB | 51.2 MiB | 76.8 MiB/h | **24.7 MiB/h** | 25 (flat) |
| C (all three fixes) | 28.3 MiB | 57.2 MiB | 58.2 MiB | 70.3 MiB/h | **13.4 MiB/h** | 25 (flat) |

The first ~5 minutes are warm-up (allocator and arena high-water mark) in both builds. After warm-up, C's residual is about half of B's, which is consistent with the fs and heartbeat leaks being removed. That residual is ~100× below A's 1,420 MiB/h under the same load. A 10-minute window cannot tell whether the remaining ~13 MiB/h is a plateau that hasn't settled yet or a further small leak. Watch it on riverwood after deploy.

## Checks

- `nix develop --command odin test src/bridge -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/oomt4b-bridge-all`: **944/944 pass**.
- `test_fs_resolve_within_frees_intermediates`: fails on main (`expected len(track.allocation_map) to be 0, got 20`) and passes with `2db14c72`.

## Not covered / follow-ups

- **Agent launch/stop and pane streaming were not driven.** They need a vault `enc_spec` or a provider. The fix sits in the shared dispatch loop, so it covers every command those flows send through the dispatch workers. Long-lived threads outside the dispatch pool that use the temp allocator without resetting it are worth a separate audit (for example `action_scheduler.odin`, `wrapper_endpoint.odin`).
- **Riverwood's oomd kills** were caused by 65–71 GiB agent process-tree spikes (oom_t1), not by this leak. This fix removes the slow bridge growth; it does not prevent those spikes. See oom_t5 for the guardrails.
- **Deploy:** apply the patch and release. Afterwards, watch `heimdall_bridge_process_resident_bytes{bridge_id="brg_18e3eca32f338693",process="bridge"}` flatten.
