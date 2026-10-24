#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

# This baseline's encrypted search vectors live in ui_vault_v2_envelope_test.ts.
# Home's rendered RPC regression additionally exercises the real encrypted transport.
node --import ./tests/helpers/vaultEndpointHarness.ts --test \
  tests/ui_home_chain_search_test.ts \
  tests/ui_task_chain_selector_test.ts \
  tests/ui_vault_v2_envelope_test.ts
npm run typecheck
npx --no-install vite build
