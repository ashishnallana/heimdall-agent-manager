#!/usr/bin/env bash
# Impacted bridge checks only. Full-suite verification belongs to model_final.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${IN_NIX_SHELL:-}" ]]; then
  exec nix develop "$ROOT" -c bash "$ROOT/scripts/provider-model-discovery-check.sh"
fi
cd "$ROOT"
OUT="${HEIMDALL_TEST_OUT:-$HOME/.cache/heimdall-tests}"
mkdir -p "$OUT"
names=(
  test_model_discovery_claude_correlation_and_aliases
  test_model_discovery_codex_pages_and_invalid_entries
  test_model_discovery_pi_qualification_and_empty_success
  test_model_discovery_copilot_policy_and_auth
  test_model_discovery_agy_ids_and_output_limits
  test_model_discovery_failure_retains_snapshot_and_empty_replaces
  test_model_discovery_process_pagination_and_cleanup
  test_model_discovery_process_agy_exit_and_timeout
  test_model_discovery_explicit_command_and_empty_filter
  test_model_discovery_coalesces_queued_overlap_only
  test_model_discovery_process_framing_and_output_limit
  test_model_discovery_worker_snapshot_ownership
  test_model_discovery_pi_probe_disables_extensions
  bridge_dispatch_classifies_blocking_incident_paths
  bridge_dispatch_admission_is_bounded_and_reserves_control_path
  bridge_dispatch_models_cannot_starve_provider_detection
  bridge_dispatch_spec_covers_every_hub_to_bridge_frame
  bridge_command_registry_covers_every_reader_command
  test_provider_version_probe_kills_and_reaps_at_deadline
  test_provider_discovery_coalesces_identical_concurrent_scans
)
printf -v qualified 'main.%s,' "${names[@]}"
odin test src/bridge -collection:odin_test=src \
  -define:ODIN_TEST_NAMES="${qualified%,}" -define:ODIN_TEST_THREADS=1 \
  -out:"$OUT/model-adapters-$$"
