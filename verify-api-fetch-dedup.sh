#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
mkdir -p "$HOME/.cache/heimdall-tests"
scratch=$(mktemp -d "$HOME/.cache/heimdall-tests/api-fetch-dedup.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
nix develop -c odin build tests/api_fetch_dedup.odin -file -collection:odin_test=src -out:"$scratch/backend"
nix develop -c "$scratch/backend"
nix develop -c odin build src/hub/transport/http -build-mode:test -collection:odin_test=src -out:"$scratch/http"
nix develop -c "$scratch/http" -tests:test_enrich_chain_list_items_archive_filter
bash verify-baseline.sh
if [ ! -d node_modules ]; then npm ci --legacy-peer-deps --no-audit --no-fund; fi
npm run typecheck
npx vite build --logLevel warn
node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_api_fetch_dedup_test.ts tests/ui_refresh_request_reduction_test.ts tests/ui_refresh_integration_test.ts tests/ui_refresh_performance_test.ts
echo "verify-api-fetch-dedup: ALL PASS"
