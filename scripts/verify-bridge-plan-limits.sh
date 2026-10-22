#!/usr/bin/env bash
# Focused T2 checks. Run from the repository root inside nix develop.
set -euo pipefail

mkdir -p "$HOME/.cache/heimdall-tests"
test_dir=$(mktemp -d "$HOME/.cache/heimdall-tests/bridge-plan-limits.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

odin build src/hub/service/bridge -build-mode:test -collection:odin_test=src -out:"$test_dir/bridge"
"$test_dir/bridge" -tests:test_plan_bridge_suspension_stays_sticky_after_heartbeat,test_plan_bridge_revoke_succeeds_when_reconciliation_fails,test_plan_bridge_approval_cap_pending_and_attach,test_plan_bridge_reconcile_ranking_upgrade_revoke_and_stale_save,test_plan_bridge_semver_and_exact_ties,test_plan_bridge_runtime_rejects_before_activity_update,test_plan_bridge_reconcile_rolls_back_partial_suspensions,test_rotate_for_device_grant_reuses_bridge_id_and_revokes_old_credential,test_rotate_for_device_grant_rejects_unowned_target,test_rotate_for_device_grant_rejects_revoked_target,test_enroll_without_target_bridge_id_mints_distinct_bridges,test_new_device_enrollment_uses_operator_bridge_label
odin build src/hub/repository/sqlite -build-mode:test -collection:odin_test=src -out:"$test_dir/sqlite"
"$test_dir/sqlite" -tests:test_plan_bridge_approval_serializes_across_connections,test_bridge_vault_status_repo_roundtrip,test_enroll_commit_simultaneous_commits_serialize
odin build src/hub/app -build-mode:test -collection:odin_test=src -out:"$test_dir/app"
"$test_dir/app" -tests:test_plan_sweep_continues_after_owner_lookup_failure,test_plan_sweep_continues_after_owner_reconcile_failure
odin build src/hub/service/agent -build-mode:test -collection:odin_test=src -out:"$test_dir/agent"
"$test_dir/agent" -tests:test_plan_launch_gate_refresh_and_reconfiguration_details
odin test src/hub/service/billing -collection:odin_test=src -out:"$test_dir/billing"
odin build src/bridge -build-mode:test -collection:odin_test=src -out:"$test_dir/bridge-cli-tests"
"$test_dir/bridge-cli-tests" -tests:test_bridge_hub_plan_refusal_logs_upgrade_url,hub_runtime_bridge_error_preserves_hub_diagnostic,hub_runtime_bridge_error_without_message_has_safe_fallback
odin build src/bridge -collection:odin_test=src -out:"$test_dir/ham-bridge"
odin build src/hub -collection:odin_test=src -out:"$test_dir/ham-hub"
HEIMDALL_BILLING_TEST_BINARY="$test_dir/ham-hub" python3 tests/test_account_billing_http.py
npm run typecheck
node --experimental-strip-types --test tests/ui_composer_bridge_options_test.ts tests/ui_bridge_launch_options_test.ts
