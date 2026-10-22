#!/usr/bin/env bash
# Focused T1 regression checks; run from the repository root inside nix develop.
set -euo pipefail

mkdir -p "$HOME/.cache/heimdall-tests"
test_dir=$(mktemp -d "$HOME/.cache/heimdall-tests/plan-entitlements.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

odin test src/contracts -collection:odin_test=src -out:"$test_dir/contracts"
odin test src/hub/domain -collection:odin_test=src -out:"$test_dir/domain"
odin test src/hub/service/billing -collection:odin_test=src -out:"$test_dir/billing"
odin build src/hub/repository/sqlite -build-mode:test -collection:odin_test=src -out:"$test_dir/sqlite"
"$test_dir/sqlite" -tests:test_billing_persists_effective_parameters_and_custom_overrides,test_billing_webhook_ordering_deduplication_and_parameter_persistence,test_billing_grace_expiry_does_not_extend_on_updates,test_billing_checkout_reservations_and_environment_guard,test_free_one_bridge_migration_updates_existing_accounts_preserves_paid_and_custom,test_plan_enforcement_migration_upgrades_snapshots_defaults_and_preserves_overrides
odin build src/hub/app -build-mode:test -collection:odin_test=src -out:"$test_dir/app"
"$test_dir/app" -tests:test_db_collectors_query_snapshot,test_db_collectors_attach_exposes_and_caches
odin build src/hub -collection:odin_test=src -out:"$test_dir/ham-hub"
HEIMDALL_BILLING_TEST_BINARY="$test_dir/ham-hub" python3 tests/test_account_billing_http.py
