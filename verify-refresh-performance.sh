#!/usr/bin/env bash
# Scoped verification for the refresh performance pass, all in THIS worktree: the
# integrated backend checks (producer events, user-WS transport), the agents list
# summary-view hub test, typecheck, production vite build, the integration and trim
# request-count regressions, and the new performance + hidden-pane suites.
set -euo pipefail
cd "$(dirname "$0")"

echo "== backend: resource refresh events (refresh_producers) =="
bash ./verify-refresh-events.sh

echo "== backend + ui: user WS transport (refresh_transport) =="
bash ./verify-refresh-transport.sh

echo "== backend: GET /agents?view=summary =="
OUT="$HOME/.cache/heimdall-tests"
mkdir -p "$OUT"
BIN="$OUT/refresh-performance-hub"
timeout 1200 nix develop -c odin build src/hub -build-mode:test -collection:odin_test=src -out:"$BIN"
LOG="$OUT/refresh-performance-hub.log"
set +e
timeout 300 nix develop -c "$BIN" -tests:test_agents_list_summary_view_is_opt_in >"$LOG" 2>&1
rc=$?
set -e
grep -v '+++ leak' "$LOG" | grep -E 'agents list bytes|Finished|failed|FATAL|ERROR' || true
if [ "$rc" -ne 0 ] || ! grep -q 'The test was successful' "$LOG"; then echo "agents summary view: FAILED (exit $rc)"; exit 1; fi

if [ ! -d node_modules ]; then npm ci --legacy-peer-deps --no-audit --no-fund; fi

echo "== ui: typecheck =="
timeout 600 npm run typecheck

echo "== ui: production build =="
timeout 900 npx vite build --logLevel warn

echo "== ui: request-count regressions (integration, trim) =="
timeout 300 node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_refresh_integration_test.ts
timeout 300 node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_refresh_request_reduction_test.ts

echo "== ui: performance (fake timers, request + byte counts) and mounted hidden pane =="
timeout 300 node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_refresh_performance_test.ts
timeout 300 node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_pane_deferral_mounted_test.ts

echo "verify-refresh-performance: ALL PASS"
