#!/usr/bin/env bash
# Scoped verification for the hidden-pane catch-up fix (refresh/catchup-fix), all in
# THIS worktree: typecheck, production vite build, the request-count regressions, the
# performance suite, the mounted hidden-pane suite (incl. the pending-GET catch-up,
# error, unmount/remount and API-reset regressions) and the other suites that drive the
# user-WS consumer's flush path.
#
# Backend: this branch changes no file outside src/ui, tests and this script relative to
# refresh/performance (asserted below). The backend checks were run on that tree by
# verify-refresh-performance.sh (ham-ctl verify session sh_0becc54b5302a53c5b04ba544d2f6924,
# exit 0, at dfb7f37a) and are not repeated here.
set -euo pipefail
cd "$(dirname "$0")"

echo "== scope: no backend change relative to refresh/performance =="
OTHER=$(git diff --name-only refresh/performance HEAD -- . ':!src/ui' ':!tests' ':!verify-refresh-catchup.sh')
if [ -n "$OTHER" ]; then
  echo "unexpected non-UI changes; run verify-refresh-performance.sh instead:"
  echo "$OTHER"
  exit 1
fi
echo "ok (only src/ui, tests, verify script)"

if [ ! -d node_modules ]; then npm ci --legacy-peer-deps --no-audit --no-fund; fi

echo "== ui: typecheck =="
timeout 600 npm run typecheck

echo "== ui: production build =="
timeout 900 npx vite build --logLevel warn

run() { timeout 300 node --import ./tests/helpers/vaultEndpointHarness.ts --test "$@"; }

echo "== ui: request-count regressions (integration, trim) =="
run tests/ui_refresh_integration_test.ts
run tests/ui_refresh_request_reduction_test.ts

echo "== ui: performance and mounted hidden pane / catch-up =="
run tests/ui_refresh_performance_test.ts
run tests/ui_pane_deferral_mounted_test.ts

echo "== ui: other user-WS flush consumers =="
run tests/ui_attention_deck_test.ts tests/ui_notification_funnel_integration_test.ts tests/ui_pane_visibility_gate_test.ts
timeout 300 npx tsx --test tests/search_title_cache_test.ts

echo "verify-refresh-catchup: ALL PASS"
