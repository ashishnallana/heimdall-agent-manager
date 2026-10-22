#!/usr/bin/env bash
# Scoped verification for refresh_integrate: the dependency backend checks (producer
# events, user-WS transport) re-run in THIS worktree, then the UI: typecheck,
# production vite build, and the request-count regressions. No full suites.
set -euo pipefail
cd "$(dirname "$0")"

echo "== backend: resource refresh events (refresh_producers) =="
bash ./verify-refresh-events.sh

echo "== backend + ui: user WS transport (refresh_transport) =="
bash ./verify-refresh-transport.sh

if [ ! -d node_modules ]; then npm ci --legacy-peer-deps --no-audit --no-fund; fi

echo "== ui: typecheck =="
timeout 600 npm run typecheck

echo "== ui: production build =="
timeout 900 npx vite build --logLevel warn

echo "== ui: request-count regressions =="
timeout 300 node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_refresh_integration_test.ts
timeout 300 node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_refresh_request_reduction_test.ts

echo "verify-refresh-integrated: ALL PASS"
