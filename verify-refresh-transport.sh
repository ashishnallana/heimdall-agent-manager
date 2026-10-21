#!/usr/bin/env bash
# Scoped verification for refresh_transport (REQ-3): user WebSocket delivery stream,
# slot exhaustion, concurrent fan-out, and UI recovery/auth/retry. No full suites.
set -euo pipefail
cd "$(dirname "$0")"
OUT="$HOME/.cache/heimdall-tests/refresh-transport"
mkdir -p "$OUT"

echo "== hub: events package (bus stream, concurrency, slots, oversize) =="
nix develop -c bash -c "
  set -euo pipefail
  odin build src/hub/service/events -build-mode:test -collection:odin_test=src -out:'$OUT/events'
  timeout 300 '$OUT/events'

  echo '== hub: http package, event-bus consumers (compile + scoped run) =='
  odin build src/hub/transport/http -build-mode:test -collection:odin_test=src -out:'$OUT/http' \
    -define:ODIN_TEST_NAMES=http.test_apply_vault_status_report_publishes_on_change_only,http.test_apply_vault_status_report_ignores_frames_without_the_field,http.test_agent_action_event_json_shape
  timeout 300 '$OUT/http'

  echo '== hub: main package, live WS events through the router =='
  odin build src/hub -build-mode:test -collection:odin_test=src -out:'$OUT/hub' \
    -define:ODIN_TEST_NAMES=main.test_title_mutation_live_events_and_flat_listing
  timeout 300 '$OUT/hub'
"

echo "== ui: recovery rules + connection loop =="
if [ ! -d node_modules ]; then npm ci --legacy-peer-deps --no-audit --no-fund; fi
timeout 300 node --test tests/ui_user_ws_recovery_test.ts
timeout 300 node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_user_ws_connection_test.ts

echo "verify-refresh-transport: ALL PASS"
