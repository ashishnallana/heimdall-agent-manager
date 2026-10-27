#!/usr/bin/env bash
# Impacted persistence/API/launch checks. Full suite belongs to model_final.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${IN_NIX_SHELL:-}" ]]; then
  exec nix develop "$ROOT" -c bash "$ROOT/scripts/provider-model-hub-check.sh"
fi
cd "$ROOT"
OUT="${HEIMDALL_TEST_OUT:-$HOME/.cache/heimdall-tests}"
mkdir -p "$OUT"
odin test src/hub/repository/sqlite -collection:odin_test=src -define:ODIN_TEST_THREADS=1 \
  -define:ODIN_TEST_NAMES=sqlite.test_bridge_models_persistence_effective_launch_and_isolation,sqlite.test_bridge_models_report_rejects_unsolicited_or_malformed_data,sqlite.test_provider_catalog_meta_etag_matches_canonical_body,sqlite.test_provider_discovery_report_persists_extension_state,sqlite.test_provider_discovery_report_rejects_unknown_extension_state \
  -out:"$OUT/model-hub-sqlite-$$"
odin test src/hub/transport/http -collection:odin_test=src -define:ODIN_TEST_THREADS=1 \
  -define:ODIN_TEST_NAMES=http.test_provider_models_api_filter_empty_and_additive_metadata,http.test_provider_models_reply_correlation_presence_and_failure,http.test_provider_models_existing_api_runtime_round_trip,http.test_extension_install_endpoint_dispatch_tracking_and_verified_completion,http.test_extension_auto_install_excludes_disabled_absent_error_and_unmeasured \
  -out:"$OUT/model-hub-http-$$"
odin test src/hub/service/taskv2 -collection:odin_test=src -define:ODIN_TEST_THREADS=1 \
  -define:ODIN_TEST_NAMES=taskv2.test_dispatch_discovered_default_and_explicit_selection,taskv2.test_dispatch_provider_override_empty_model_matches_catalog \
  -out:"$OUT/model-hub-task-$$"
odin test src/bridge -collection:odin_test=src -define:ODIN_TEST_THREADS=1 \
  -define:ODIN_TEST_NAMES=main.test_bridge_effective_models_and_launch_argv,main.test_provider_catalog_ask_args_reach_ask_launch,main.test_provider_catalog_without_ask_args_omits_yolo_only \
  -out:"$OUT/model-hub-bridge-$$"
