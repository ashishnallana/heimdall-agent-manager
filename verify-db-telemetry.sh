#!/usr/bin/env bash
# Scoped verification for phase-1 DB latency telemetry (task_18e09d831b5102b8;
# basic-by-default in task_18e0b0eb96f02802).
# Runs the telemetry tests (single-threaded: they flip the process-global mode),
# the HTTP accounting tests, the default-mode tests, the lock-inventory check,
# the hub build, a startup smoke of the built hub (unset -> basic, explicit off,
# full/unknown rejected) and the off/basic wrapper microbenchmark. Fails on any
# regression.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
OUT="$HOME/.cache/heimdall-tests"
mkdir -p "$OUT"

run_tests() { # <pkg dir> <out name> <comma test names>
	echo "== $1: $3"
	nix develop -c odin build "$1" -build-mode:test -collection:odin_test=src \
		-define:ODIN_TEST_NAMES="$3" -define:ODIN_TEST_THREADS=1 -define:DBT_TESTS=true -out:"$OUT/$2"
	nix develop -c "$OUT/$2"
}

SQLITE_TESTS=sqlite.test_db_conn_wait_split,sqlite.test_step_changes_single_wait,sqlite.test_uow_wait_hold_outcomes,sqlite.test_uow_nested_no_double_count,sqlite.test_dedicated_mutex_timed,sqlite.test_telemetry_off_is_passthrough,sqlite.test_labels_bounded,sqlite.test_site_attribution,sqlite.test_stmt_status_counters,sqlite.test_conn_kind_tagging,sqlite.test_statement_count_reuse,sqlite.test_waiters_max_scrape_reset
# Legacy metric behaviour (telemetry off) must be unchanged.
SQLITE_LEGACY=sqlite.test_sqlite_op_from_sql_enum,sqlite.test_sqlite_metrics_observe_step_and_exec
run_tests src/hub/repository/sqlite sqlite_dbt "$SQLITE_TESTS,$SQLITE_LEGACY"
run_tests src/hub/repository/sqlite sqlite_dbt_mode sqlite.test_parse_mode_default_basic
run_tests src/hub/transport/http http_dbt http.test_request_db_scope_flush,http.test_slow_request_log_sanitized
run_tests src/hub/app app_dbt app.test_db_telemetry_default_basic,app.test_metrics_respond_routes

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

echo "== startup smoke: built hub, HEIMDALL_DB_TELEMETRY unset/basic/off/full/bogus"
SMOKE="$(mktemp -d)"
smoke_pid=""
trap '[ -n "$smoke_pid" ] && kill "$smoke_pid" 2>/dev/null; rm -rf "$SMOKE"' EXIT
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }
# smoke_boot <label> <expect: basic|off|reject> [env assignment]
smoke_boot() {
	local label="$1" expect="$2" hub_port metrics_port i
	shift 2
	hub_port="$(free_port)"; metrics_port="$(free_port)"
	while [ "$metrics_port" = "$hub_port" ]; do metrics_port="$(free_port)"; done
	rm -f "$SMOKE/hub.db"*
	env -u HEIMDALL_DB_TELEMETRY "$@" HEIMDALL_METRICS_ADDR="127.0.0.1:$metrics_port" \
		nix develop -c "$OUT/hub_dbt" --listen "127.0.0.1:$hub_port" --db "$SMOKE/hub.db" \
		--migrations-dir "$ROOT/src/hub/repository/sqlite/migrations" --trusted-proxy-cidr 127.0.0.1/32 \
		>"$SMOKE/$label.log" 2>&1 &
	smoke_pid=$!
	if [ "$expect" = reject ]; then
		for i in $(seq 1 120); do kill -0 "$smoke_pid" 2>/dev/null || break; sleep 0.5; done
		if kill -0 "$smoke_pid" 2>/dev/null; then echo "[$label] hub kept running; expected boot failure"; cat "$SMOKE/$label.log"; exit 1; fi
		if wait "$smoke_pid"; then echo "[$label] hub exited 0; expected failure"; exit 1; fi
		smoke_pid=""
		grep -q HEIMDALL_DB_TELEMETRY "$SMOKE/$label.log" || { echo "[$label] rejection message missing"; cat "$SMOKE/$label.log"; exit 1; }
		echo "[$label] rejected at boot: $(grep -m1 HEIMDALL_DB_TELEMETRY "$SMOKE/$label.log")"
		return
	fi
	for i in $(seq 1 120); do
		curl -sf "http://127.0.0.1:$metrics_port/metrics" -o "$SMOKE/$label.prom" && break
		kill -0 "$smoke_pid" 2>/dev/null || { echo "[$label] hub died"; cat "$SMOKE/$label.log"; exit 1; }
		sleep 0.5
	done
	[ -s "$SMOKE/$label.prom" ] || { echo "[$label] no /metrics"; cat "$SMOKE/$label.log"; exit 1; }
	# Drive some DB work through the public listener, then scrape again.
	for i in 1 2 3 4 5; do curl -s -o /dev/null "http://127.0.0.1:$hub_port/healthz" || true; curl -s -o /dev/null "http://127.0.0.1:$hub_port/api/v1/me" || true; done
	curl -sf "http://127.0.0.1:$metrics_port/metrics" -o "$SMOKE/$label.prom"
	kill "$smoke_pid"; wait "$smoke_pid" 2>/dev/null || true; smoke_pid=""
	# Families with eager series, plus SQLite-side ones the boot's own
	# migrations populate. Lazy per-route families (http_request_db) only
	# appear after an authenticated routed request; they are reported, not gated.
	local fams="heimdall_db_lock_wait_seconds heimdall_db_scope_seconds_total heimdall_db_slow_log_dropped_total heimdall_sqlite_exec_seconds heimdall_sqlite_statements_total heimdall_sqlite_site_exec_seconds_total"
	local f
	for f in heimdall_sqlite_query_duration_seconds heimdall_http_requests_total; do
		grep -q "^# TYPE $f " "$SMOKE/$label.prom" || { echo "[$label] legacy family $f missing"; exit 1; }
	done
	for f in $fams; do
		if grep -q "^# TYPE $f " "$SMOKE/$label.prom"; then
			[ "$expect" = basic ] || { echo "[$label] off must not register $f"; exit 1; }
		else
			[ "$expect" = off ] || { echo "[$label] basic must register $f"; grep '^# TYPE heimdall_db' "$SMOKE/$label.prom"; exit 1; }
		fi
	done
	if [ "$expect" = off ]; then
		# Parity: no telemetry family at all (incl. collector-only ones), no
		# telemetry-only SQLite families and no fine HTTP bucket layout.
		if grep -E '^# TYPE (heimdall_db_|heimdall_sqlite_(exec_seconds|statements_total|errors_total|vm_steps_total|fullscan_steps_total|sort_total|site_|cache_events_total|library_info)|heimdall_http_request_db_)' "$SMOKE/$label.prom"; then
			echo "[$label] off registered telemetry families"; exit 1
		fi
		# The layout check is only meaningful once the smoke requests reached the router.
		grep -q '^heimdall_http_request_duration_seconds_bucket{' "$SMOKE/$label.prom" || { echo "[$label] no routed request recorded"; exit 1; }
		if grep -q '^heimdall_http_request_duration_seconds_bucket{.*le="0.0025"' "$SMOKE/$label.prom"; then echo "[$label] off uses the basic HTTP bucket layout"; exit 1; fi
	fi
	echo "[$label] $expect OK: $(grep -c '^heimdall_db_' "$SMOKE/$label.prom") heimdall_db_* samples, $(grep -c '^# TYPE heimdall_db_' "$SMOKE/$label.prom") heimdall_db_* families, $(grep -vc '^#' "$SMOKE/$label.prom") total samples; http_request_db series: $(grep -c '^heimdall_http_request_db_seconds_total' "$SMOKE/$label.prom" || true)"
}
smoke_boot unset basic
smoke_boot basic basic HEIMDALL_DB_TELEMETRY=basic
smoke_boot off off HEIMDALL_DB_TELEMETRY=off
smoke_boot full reject HEIMDALL_DB_TELEMETRY=full
smoke_boot bogus reject HEIMDALL_DB_TELEMETRY=on
echo "startup smoke OK"

echo "== microbenchmark (off vs basic; budget basic-off <= 300 ns per wrapped call)"
# Optimised build (production builds are optimised; test builds are not), no
# memory tracking. Five runs; numbers are reported, the gate is read by a human
# against docs/reference/db-telemetry.md (shared hosts are too noisy to assert).
bench_log="$OUT/sqlite_dbt_bench.log"
nix develop -c odin build src/hub/repository/sqlite -build-mode:test -o:speed -collection:odin_test=src \
	-define:ODIN_TEST_NAMES=sqlite.test_db_telemetry_bench -define:ODIN_TEST_THREADS=1 -define:DBT_TESTS=true \
	-define:ODIN_TEST_TRACK_MEMORY=false -out:"$OUT/sqlite_dbt_bench"
: >"$bench_log"
for _ in 1 2 3 4 5; do nix develop -c "$OUT/sqlite_dbt_bench" >>"$bench_log" 2>&1 || { cat "$bench_log"; exit 1; }; done
grep DBT_BENCH "$bench_log"
echo "verify-db-telemetry: OK"
