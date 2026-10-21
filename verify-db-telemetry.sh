#!/usr/bin/env bash
# Scoped verification for phase-1 DB latency telemetry (task_18e09d831b5102b8).
# Runs the telemetry tests (single-threaded: they flip the process-global mode),
# the HTTP accounting tests, the lock-inventory check, the hub build and the
# off/basic wrapper microbenchmark. Fails on any regression.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
OUT="$HOME/.cache/heimdall-tests"
mkdir -p "$OUT"

run_tests() { # <pkg dir> <out name> <comma test names>
	echo "== $1: $3"
	nix develop -c odin build "$1" -build-mode:test -collection:odin_test=src \
		-define:ODIN_TEST_NAMES="$3" -define:ODIN_TEST_THREADS=1 -out:"$OUT/$2"
	nix develop -c "$OUT/$2"
}

SQLITE_TESTS=sqlite.test_db_conn_wait_split,sqlite.test_step_changes_single_wait,sqlite.test_uow_wait_hold_outcomes,sqlite.test_uow_nested_no_double_count,sqlite.test_dedicated_mutex_timed,sqlite.test_telemetry_off_is_passthrough,sqlite.test_labels_bounded,sqlite.test_site_attribution,sqlite.test_stmt_status_counters,sqlite.test_conn_kind_tagging,sqlite.test_statement_count_reuse,sqlite.test_waiters_max_scrape_reset
# Legacy metric behaviour (telemetry off) must be unchanged.
SQLITE_LEGACY=sqlite.test_sqlite_op_from_sql_enum,sqlite.test_sqlite_metrics_observe_step_and_exec
run_tests src/hub/repository/sqlite sqlite_dbt "$SQLITE_TESTS,$SQLITE_LEGACY"
run_tests src/hub/transport/http http_dbt http.test_request_db_scope_flush,http.test_slow_request_log_sanitized

echo "== lock inventory: service/app/transport mutexes around repository calls must use dbt.timed_lock"
# Every lock named in the dbtelemetry Lock enum (app locks) is timed at all of its sites.
fail=0
for mu in projector_mutex reconfiguration_mutex launch_preferences_mutex; do
	if git grep -nE "sync\.(mutex_)?lock\(&[a-z_.]*${mu}\)" -- 'src/hub/*.odin' ':!*_test.odin' | grep .; then
		echo "untimed acquisition of ${mu}"; fail=1
	fi
done
for f in billing_repo_sqlite vault_directory_repo_sqlite bridge_token_repo_sqlite; do
	if git grep -nE "sync\.(mutex_)?lock\(&impl\.(commit\.)?mutex\)" -- "src/hub/repository/sqlite/${f}.odin" | grep .; then
		echo "untimed dedicated repo mutex in ${f}"; fail=1
	fi
done
# The scrape (which holds db_collectors.mu across its query) must be timed;
# attach/detach/invalidate are boot/test paths and stay plain.
if ! grep -A6 '^db_collectors_collect ::' src/hub/app/metrics_db_collectors.odin | grep -q 'dbt.timed_lock(&db_collectors.mu, .Collector)'; then
	echo "untimed collector scrape lock"; fail=1
fi
[ "$fail" = 0 ] || exit 1
echo "lock inventory OK"

echo "== hub build"
nix develop -c odin build src/hub -collection:odin_test=src -out:"$OUT/hub_dbt"

echo "== microbenchmark (off vs basic; budget basic-off <= 300 ns per wrapped call)"
# Optimised build (production builds are optimised; test builds are not), no
# memory tracking. Three runs; numbers are reported, the gate is read by a human
# against docs/operations/db-telemetry.md (shared hosts are too noisy to assert).
bench_log="$OUT/sqlite_dbt_bench.log"
nix develop -c odin build src/hub/repository/sqlite -build-mode:test -o:speed -collection:odin_test=src \
	-define:ODIN_TEST_NAMES=sqlite.test_db_telemetry_bench -define:ODIN_TEST_THREADS=1 \
	-define:ODIN_TEST_TRACK_MEMORY=false -out:"$OUT/sqlite_dbt_bench"
: >"$bench_log"
for _ in 1 2 3; do nix develop -c "$OUT/sqlite_dbt_bench" >>"$bench_log" 2>&1 || { cat "$bench_log"; exit 1; }; done
grep DBT_BENCH "$bench_log"
echo "verify-db-telemetry: OK"
