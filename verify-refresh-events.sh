#!/usr/bin/env bash
# Scoped verification for refresh_producers (REQ-2): builds the hub test package
# and runs only the resource-refresh event tests plus the pre-existing live
# event test they extend. Fails on any build error, test failure or timeout.
set -euo pipefail
cd "$(dirname "$0")"
OUT="$HOME/.cache/heimdall-tests"
mkdir -p "$OUT"
BIN="$OUT/refresh-events-hub"
TESTS="test_refresh_user_send_reaches_every_owner_tab_only,test_refresh_conversation_created_and_updated_summary,test_refresh_reconfiguration_get_is_pure_and_reaper_times_out,test_refresh_instance_writers_publish,test_refresh_identity_bridge_provider_events,test_refresh_shell_background_publishes_after_write,test_refresh_workflow_events_name_run_and_stage,test_refresh_task_effects_dedupe_and_facet_kind,test_title_mutation_live_events_and_flat_listing"
timeout 1200 nix develop -c odin build src/hub -build-mode:test -collection:odin_test=src -out:"$BIN"
LOG="$OUT/refresh-events-hub.log"
set +e
timeout 300 nix develop -c "$BIN" -tests:"$TESTS" >"$LOG" 2>&1
rc=$?
set -e
grep -v '+++ leak' "$LOG" | grep -E 'Finished|failed|FATAL|ERROR' || true
if [ "$rc" -ne 0 ]; then echo "verify-refresh-events: FAILED (exit $rc)"; exit "$rc"; fi
grep -q 'All tests were successful' "$LOG" || { echo "verify-refresh-events: no success line"; exit 1; }
count=$(grep -oE 'Finished [0-9]+ test' "$LOG" | grep -oE '[0-9]+' || echo 0)
expected=$(echo "$TESTS" | tr ',' '\n' | wc -l)
[ "$count" -eq "$expected" ] || { echo "verify-refresh-events: ran $count tests, expected $expected"; exit 1; }
echo "verify-refresh-events: OK ($count tests)"
