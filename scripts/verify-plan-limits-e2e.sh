#!/usr/bin/env bash
# T7 HTTP/WS smoke tests, actual plan labels, preview approval links, and UI gates.
# Run from the repository root inside nix develop.
set -euo pipefail

mkdir -p "$HOME/.cache/heimdall-tests"
test_dir=$(mktemp -d "$HOME/.cache/heimdall-tests/plan-limits-e2e.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

test_names() {
  sed -n 's/^\([[:alnum:]_]*\) :: proc(t: \^testing.T) {.*$/\1/p' "$@" | paste -sd, -
}

odin test src/hub/domain -collection:odin_test=src -out:"$test_dir/domain"
odin test src/hub/service/billing -collection:odin_test=src -out:"$test_dir/billing"

odin build src/hub/service/bridge -build-mode:test -collection:odin_test=src -out:"$test_dir/bridge-service"
"$test_dir/bridge-service" -tests:test_plan_bridge_approval_cap_pending_and_attach,test_plan_bridge_reconcile_ranking_upgrade_revoke_and_stale_save,test_plan_bridge_semver_and_exact_ties,test_plan_bridge_runtime_rejects_before_activity_update,test_plan_bridge_reconcile_rolls_back_partial_suspensions,test_plan_bridge_suspension_stays_sticky_after_heartbeat,test_plan_bridge_revoke_succeeds_when_reconciliation_fails

odin build src/hub/service/shell_session -build-mode:test -collection:odin_test=src -out:"$test_dir/shell-session"
"$test_dir/shell-session" -tests:"$(test_names \
  src/hub/service/shell_session/shell_session_create_test.odin \
  src/hub/service/shell_session/pane_plan_limits_test.odin)"

odin build src/hub/transport/http -build-mode:test -collection:odin_test=src -out:"$test_dir/http"
"$test_dir/http" -tests:"$(test_names \
  src/hub/transport/http/terminal_entitlements_test.odin \
  src/hub/transport/http/agent_instance_stream_test.odin \
  src/hub/transport/http/agent_instance_input_test.odin \
  src/hub/transport/http/shell_session_stream_test.odin \
  src/hub/transport/http/shell_stream_screen_snapshot_test.odin)"

odin build src/hub/service/agent -build-mode:test -collection:odin_test=src -out:"$test_dir/agent"
"$test_dir/agent" -tests:test_plan_launch_gate_refresh_and_reconfiguration_details
odin build src/bridge -build-mode:test -collection:odin_test=src -out:"$test_dir/bridge-tests"
"$test_dir/bridge-tests" -tests:"$(test_names src/bridge/enroll_device_flow_test.odin)"
odin build src/bridge -collection:odin_test=src -out:"$test_dir/ham-bridge"
odin build src/hub -collection:odin_test=src -out:"$test_dir/ham-hub"

HEIMDALL_BILLING_TEST_BINARY="$test_dir/ham-hub" python3 tests/test_account_billing_http.py -v
node --test scripts/local-runtime/helpers.test.mjs
node --import ./tests/helpers/vaultEndpointHarness.ts --test \
  tests/ui_plan_limits_test.ts \
  tests/ui_interactive_shell_launch_test.ts \
  tests/ui_device_approval_lookup_test.ts
