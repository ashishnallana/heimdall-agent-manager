#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
if [[ ! -d node_modules ]]; then
  npm ci --legacy-peer-deps
fi
node --import ./tests/helpers/vaultEndpointHarness.ts --test \
  tests/ui_live_tool_activity_test.ts \
  tests/ui_live_tool_activity_dom_test.ts \
  tests/ui_extension_tool_activity_test.ts \
  tests/ui_simplify_conversation_layout_test.ts \
  tests/ui_user_ws_connection_test.ts \
  tests/ui_user_ws_recovery_test.ts
# Includes TypeScript project checks, Vite production build, and Electron build.
npm run build
git rev-parse HEAD
git status --short
