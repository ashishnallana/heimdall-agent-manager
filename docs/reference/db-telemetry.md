# Hub DB latency and lock-contention telemetry (phase 1)

Design and rationale: [`docs/plans/db-latency-telemetry.md`](../plans/db-latency-telemetry.md) (approved rev 3).
Code: `src/hub/platform/dbtelemetry/`, `src/hub/repository/sqlite/db_telemetry.odin`, `tx.odin`, `conn.odin`, `transport/http/metrics_http.odin`.

The telemetry measures how long DB work waits for application locks and for the SQLite connection mutex, how long it executes, and which call sites cost the most. It does this without putting SQL text, parameters or identifiers in any label.

## 1. Configuration

All settings are read once at boot from the environment. Changing one needs a hub restart.

| Variable | Values | Default | Effect |
|---|---|---|---|
| `HEIMDALL_DB_TELEMETRY` | `off`, `basic` | `basic` (when unset or empty) | `basic`: everything in §2. `off`: explicit opt-out; wrappers behave as before, no new family is registered, and no extra mutex or clock call is made. `full` (phase-2 busy handler) is **not implemented**. It and any other value (case-sensitive) **fail boot** with an explicit message and exit status 1, so a typo never silently changes behaviour. |
| `HEIMDALL_DB_SLOW_MS` | integer ≥ 0 | `250` | HTTP requests at or over this many ms write a `db_slow_request` line with `reason=slow`. `0` disables threshold records. A non-integer or negative value is ignored (default kept), unlike the mode. |
| `HEIMDALL_DB_SAMPLE_N` | integer ≥ 0 | `1000` | One request in N writes a `reason=sample` baseline line. `0` disables sampling. A non-integer or negative value is ignored (default kept). |

The background-scope (`db_slow_scope`) threshold is fixed at 1 s. Both record kinds share one token bucket of ≤ 10 lines/s. Because `basic` is the default, slow and sampled records are emitted by default too (250 ms threshold, 1 in 1000 sample); set `HEIMDALL_DB_SLOW_MS=0` / `HEIMDALL_DB_SAMPLE_N=0` to silence them while keeping the metrics.

### Default (operator)

A hub built from this release runs `basic` with no configuration. The repository ships no hub unit/env file that sets the variable; the production unit lives outside this repo, so check it does not pin `HEIMDALL_DB_TELEMETRY=off` if you expect telemetry. Optional tuning:

```bash
# NixOS/systemd hub unit environment, then restart (a production change; schedule it)
Environment=HEIMDALL_DB_SLOW_MS=250
Environment=HEIMDALL_DB_SAMPLE_N=1000
```

After deploying (the plan §4.4 parity-first step was skipped by a user decision to ship `basic` on):
1. Watch CPU per request (`rate(process_cpu_seconds_total)` / `rate(heimdall_http_requests_total)`) against the previous 7 days, RSS, and `heimdall_metrics_series`.
2. Collect the observation windows.

Any hub boot failure (rejected mode, database open, listen failure) now exits with status 1 rather than 0, so a `Restart=on-failure` unit retries it.

### Rollback (opt out)

Set `HEIMDALL_DB_TELEMETRY=off` in the hub environment, then restart. Unsetting it no longer disables telemetry. No schema or data change is involved, and the legacy families (`heimdall_sqlite_query_duration_seconds`, `heimdall_sqlite_busy_total`, HTTP families) keep their meaning in both modes. You can also roll back the Nix generation.

## 2. Emitted metrics (`basic` only)

Disjoint per-thread intervals: `app_lock_wait`, `conn_wait` and `exec` never overlap on one thread, so their **sums** may be stacked and compared with request time. Hold and tx durations **contain** the holder's waits and execution, and are never added to them.

| Family | Type | Labels | Meaning |
|---|---|---|---|
| `heimdall_db_lock_wait_seconds` | histogram (1µs,10µs,100µs,500µs,1ms,5ms,25ms,100ms,1s,5s) | `lock` | Wait to acquire a DB-guarding lock, observed for every acquisition |
| `heimdall_db_lock_hold_seconds` | histogram (100µs,1ms,5ms,25ms,100ms,500ms,1s,5s,10s,30s) | `lock` (app locks) | Time the app lock was held |
| `heimdall_db_lock_waiters` | gauge | `lock` | Threads currently waiting (instantaneous, sampled at scrape) |
| `heimdall_db_lock_waiters_max` | gauge (collector) | `lock` | High-water mark of waiters since the previous scrape. Reset to the current depth on each scrape, so it is exact with one scraper and a lower bound with several. Use `contended_total` for manual checks. |
| `heimdall_db_lock_contended_total` | counter | `lock` | Acquisitions whose try-lock found the lock held |
| `heimdall_db_lock_held` | gauge | `lock` (app locks) | 1 while held |
| `heimdall_db_uow_oldest_hold_seconds` | gauge (collector) | — | Age of the open outer unit of work (0 if none) |
| `heimdall_db_uow_nested_total` | counter | — | Nested UoWs (savepoints). Never a second tx observation. |
| `heimdall_db_tx_duration_seconds` | histogram (hold buckets) | `conn, kind, rw, outcome` | Outer BEGIN → COMMIT/ROLLBACK return. Excludes after-commit hooks; for dedicated conns it starts when BEGIN returns. |
| `heimdall_sqlite_exec_seconds` | histogram (25µs,100µs,500µs,1ms,2.5ms,5ms,10ms,50ms,250ms,5s) | `conn, op` | Time inside SQLite with the conn mutex held, per wrapped call (step, exec, prepare, finalize) |
| `heimdall_sqlite_statements_total` | counter | `conn, op` | Statement executions: the first step of each execution (`sqlite3_stmt_busy == 0`) and one per `sqlite3_exec` call |
| `heimdall_sqlite_vm_steps_total`, `_fullscan_steps_total`, `_sort_total` | counter | `conn, op` | `sqlite3_stmt_status(…, reset=1)` deltas, read per step under the held mutex |
| `heimdall_sqlite_site_exec_seconds_total`, `_site_vm_steps_total`, `_site_fullscan_steps_total` | counter | `conn, site` | Same per call site. `site = <file>:<procedure>` of the caller; step calls only. |
| `heimdall_sqlite_errors_total` | counter | `conn, op, code` | Error rc on step, exec or prepare (finalize never double-counts) |
| `heimdall_sqlite_cache_events_total` | counter (collector) | `conn, kind=hit\|miss\|write\|spill` | `sqlite3_db_status` per open handle. Resets when a handle closes. |
| `heimdall_sqlite_library_info` | gauge = 1 | `version` | Linked SQLite library version (closes plan G9 / review F3) |
| `heimdall_db_scope_seconds_total` | counter | `scope, component` | DB time per scope by disjoint component |
| `heimdall_http_request_db_seconds_total` | counter | `route, component` | The same for plain HTTP dispatch, by route **pattern** |
| `heimdall_db_slow_log_dropped_total` | counter | `reason=slow\|sample` | Records dropped by the rate limiter |

Label enums:

- **`lock`:** `uow_tx, billing, vault, enroll, collector, projector, reconfig, launch_prefs, conn_main, conn_billing, conn_enroll, conn_vault, conn_metrics`.
- **`conn`:** `main, billing, enroll, vault, metrics, other`.
- **`op`:** `select insert update delete begin commit rollback pragma create other prepare finalize`.
- **`code`:** `busy busy_snapshot locked constraint corrupt ioerr other`.
- **`component`:** `app_lock_wait conn_wait exec_excl_busy busy_wait`. `busy_wait` is always 0 in phase 1, so `exec_excl_busy` equals exec.
- **`scope`:** `http ws timer merge bridge_log shell scrape other`.
- **`rw`:** `read write`. A UoW counts as `write` if it executed an insert, update or delete step.
- **`outcome`:** `commit rollback commit_failed begin_failed`.

The HTTP request histogram gains one bound (`le="0.0025"`) in `basic` mode, and all legacy bounds are kept. Never compute a `histogram_quantile` across that layout change.

### Cardinality

Series are created lazily: only exercised label sets exist.

| Family | Series |
|---|---|
| lock wait | 13 × 13 = 169 |
| lock hold | 8 × 13 = 104 |
| waiters / max / contended / held | ≈ 47 |
| exec | ~40 live `(conn,op)` pairs × 13 ≈ 520 |
| tx | ~8 live × 13 ≈ 104 |
| site counters | ≤ 3 × 261 |
| http db | routes × ≤ 3 non-zero components |

That totals well under the plan's 5 000-series budget (smaller than the plan's estimate because of the 10-bucket layouts). Post-deploy check (read-only):

```bash
curl -s localhost:9464/metrics | grep -c '^heimdall_db_\|^heimdall_sqlite_exec\|^heimdall_sqlite_site\|^heimdall_http_request_db'
```

## 3. Slow / sampled records (stderr log lines)

```text
db_slow_request reason=slow|sample route="<pattern>" method=GET status=2xx request_ns=… app_lock_wait_ns=… conn_wait_ns=… exec_ns=… busy_wait_ns=0 steps=… statements=… tx_count=… tx_hold_ns=… busy_errors=… dropped_since_last=… request_id=<≤64 chars [A-Za-z0-9_.:-]> top1=<conn>/<op>/<file>.odin:<line>/exec_ns=…/wait_ns=… …
db_slow_scope reason=… scope=timer|merge|bridge_log|shell|scrape elapsed_ns=… (same component fields)
```

- Records never include SQL text, parameters, query strings, bodies, path parameters or user/agent ids.
- `request_id` is client-supplied: it is a correlation hint only, and is filtered and truncated.
- `tx_hold_ns` overlaps the other fields and must not be added to them.
- Criteria about slow requests use `reason=slow` only. Report the drop rate from `dropped_since_last` and `heimdall_db_slow_log_dropped_total`.

## 4. PromQL (Prometheus 3; `le` prints as `"0.001"`, `"1.0"`)

Every query below names only families and labels emitted by this code. The tests check the names and labels; the queries have **not** been run against a live Prometheus.

```promql
# Main-connection utilisation (fraction of wall time the conn mutex is held by wrapped calls)
sum by (conn) (rate(heimdall_sqlite_exec_seconds_sum[5m]))

# Conn queueing relative to execution
sum(rate(heimdall_db_lock_wait_seconds_sum{lock="conn_main"}[5m]))
  / sum(rate(heimdall_sqlite_exec_seconds_sum{conn="main"}[5m]))

# Share of HTTP time per disjoint DB component (ratio of sums)
sum by (component) (rate(heimdall_http_request_db_seconds_total[5m]))
  / scalar(sum(rate(heimdall_http_request_duration_seconds_sum[5m])))

# Lock wait p99 per lock
histogram_quantile(0.99, sum by (le, lock) (rate(heimdall_db_lock_wait_seconds_bucket[5m])))

# Fraction of conn_main acquisitions that waited > 1 ms
1 - sum(rate(heimdall_db_lock_wait_seconds_bucket{lock="conn_main",le="0.001"}[5m]))
      / sum(rate(heimdall_db_lock_wait_seconds_count{lock="conn_main"}[5m]))

# Peak queue depth between scrapes / contended share
max_over_time(heimdall_db_lock_waiters_max{lock="conn_main"}[5m])
sum by (lock) (rate(heimdall_db_lock_contended_total[5m])) / sum by (lock) (rate(heimdall_db_lock_wait_seconds_count[5m]))

# Read share of main-conn execution
sum(rate(heimdall_sqlite_exec_seconds_sum{conn="main",op="select"}[5m])) / sum(rate(heimdall_sqlite_exec_seconds_sum{conn="main"}[5m]))

# Unit of work: hold p99, rate by outcome, stuck UoW
histogram_quantile(0.99, sum by (le) (rate(heimdall_db_lock_hold_seconds_bucket{lock="uow_tx"}[5m])))
sum by (outcome, rw) (rate(heimdall_db_tx_duration_seconds_count{kind="uow"}[5m]))
max_over_time(heimdall_db_uow_oldest_hold_seconds[5m])

# Mean statement cost
sum by (op) (rate(heimdall_sqlite_vm_steps_total{conn="main"}[5m])) / sum by (op) (rate(heimdall_sqlite_statements_total{conn="main"}[5m]))

# R5: share of main step time in the top 3 call sites; and which sites scan
sum(topk(3, sum by (site) (increase(heimdall_sqlite_site_exec_seconds_total{conn="main"}[1h]))))
  / sum(increase(heimdall_sqlite_site_exec_seconds_total{conn="main"}[1h]))
topk(10, sum by (site) (increase(heimdall_sqlite_site_fullscan_steps_total{conn="main"}[1h])))

# Busy/locked errors and IO proxy
sum by (conn, code) (rate(heimdall_sqlite_errors_total{code=~"busy.*|locked"}[5m]))
sum by (conn, kind) (rate(heimdall_sqlite_cache_events_total{kind=~"miss|write|spill"}[5m]))

# Overhead watch
rate(process_cpu_seconds_total[1h]) / rate(heimdall_http_requests_total[1h])
```

Grafana: these panels, and more, are in the generated **Heimdall / Hub DB** dashboard
(`tools/telemetry/hub/grafana/dashboards/hub-db.json`, uid `heimdall-hub-db`). The README in
`tools/telemetry/hub/` explains how to activate it; pushing the repository does not update a live Grafana.

## 5. Overhead (measured)

`verify-db-telemetry.sh` runs `sqlite.test_db_telemetry_bench`: an optimised build (`-o:speed`), 5 runs, 200 k iterations on an in-process `SELECT 1`. On the dev host (basic-default integration, 5 runs) it gave:

| Loop | off (ns/iter) | basic (ns/iter) | delta |
|---|---|---|---|
| step + reset (1 wrapped call + raw reset) | ≈ 685–698 | ≈ 333–343 | **−347 to −365** |
| prepare + finalize (2 wrapped calls) | ≈ 1 039–1 053 | ≈ 1 246–1 314 | **+207 to +270** (≈ +104–135 per call) |

- `basic` is *cheaper* than `off` for steps. The legacy wrapper (kept unchanged for `off` parity) calls `metrics.with` per step and reads `time.tick_now`, which on Linux is a raw `clock_gettime(MONOTONIC_RAW)` **syscall**. `basic` uses pre-resolved series and the libc vDSO `clock_gettime(MONOTONIC)` (`platform/dbtelemetry/clock_posix.odin`).
- These numbers are from a micro loop on the development host, not Dawnstar and not production CPU. They meet the plan's ≤ 300 ns/call gate. The 0.5 % CPU and 2 MB RSS budgets are **unverified**: production CPU/RSS overhead has not been measured and needs the post-deploy watch.
- Exposition size from the startup smoke (fresh DB, no traffic): `basic` 967 samples (382 `heimdall_db_*`), `off` 223. The `heimdall_db_*` count is mostly eager per-lock histogram buckets; per-route/site series grow lazily with traffic.
- Site table and slot table memory is fixed: 512 site slots plus 16 conn slots, a few tens of KB.

## 6. Limitations (phase 1)

- **bind/column/reset not wrapped.** Their conn-mutex waits are unmeasured, but bounded by the preceding step (residual G3).
- **No busy-handler instrumentation.** Successful busy_timeout sleeps are inside `exec` on write/tx ops. `busy_wait` is always 0. `full` mode is rejected.
- **WebSocket and raw-upgrade frames** have no `ws` scope in phase 1. Their DB time is flushed per call into `scope="other"`, so nothing is dropped, but it is not separated from other unscoped work.
- **Exec start includes a little statement metadata work.** For steps, the exec interval starts at mutex acquisition, so it includes `sqlite3_sql` / `sqlite3_stmt_busy`: tens of ns, under the held mutex.
- **Dedicated-connection tx durations** (billing/enroll/vault) are tracked by the exec wrapper from a successful `BEGIN` to `COMMIT`/`ROLLBACK`. They exclude BEGIN's own exec time.
- **Background slow-scope records use wall time.** `db_slow_scope` (≥ 1 s) is decided on the scope's elapsed time, not its DB components, so a background job that sleeps or waits on a bridge inside its scope (e.g. paced shell kill-intent replay, possibly merge jobs) can log `reason=slow` without slow DB work. Read the line's component fields before blaming the DB.
- **A scrape can wait behind a long statement.** The SQLite collector holds the connection-slot table lock while reading `sqlite3_db_status`, which takes each connection's mutex; a statement stuck in `busy_timeout` (≤ 5 s) delays `/metrics` and any concurrent handle open/close for that long. No deadlock path exists (nothing holds a connection mutex and then takes the slot lock).
- **Unregistered handles** (more than 16 open, tests only) get exec-only timing with `conn="other"` and no wait split.
- **Lock inventory is textual.** It covers the eight app locks in the plan §1.5a audit at `2a467a5a`. `verify-db-telemetry.sh` fails if any of them is acquired untimed, but it cannot discover a *new* DB-guarding lock. Re-audit when adding one.
- **Histogram layouts follow the 10-bucket cap.** `lib/metrics` caps histograms at 10 buckets, so the layouts are thinned from the plan's 16–18. The HTTP layout gains only 2.5 ms, not 1/2.5/5 ms.
- **The favorite-cap race is not fixed.** It is out of scope (plan §1.5a): `transport/http/agent_handlers.odin` releases `launch_prefs` before the save. The lock is timed as-is.

## 7. Verify

```bash
bash verify-db-dashboard.sh   # Grafana: generator reproducibility, JSON/UID/panel-id checks,
                              # metrics and label values against src/, promtool PromQL syntax
bash verify-db-telemetry.sh   # scoped tests (DBT_TESTS, single thread), default-mode tests, lock inventory,
                              # hub build, startup smoke (unset/basic -> basic, off -> no families,
                              # full/unknown -> boot fails), benchmark
```
