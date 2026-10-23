#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
if [[ ! -d node_modules ]]; then
  npm ci --legacy-peer-deps
fi
node --import ./tests/helpers/vaultEndpointHarness.ts --test \
  tests/ui_live_tool_activity_test.ts \
  tests/ui_live_tool_activity_dom_test.ts \
  tests/ui_tool_stream_url_test.ts \
  tests/ui_extension_tool_activity_test.ts \
  tests/ui_simplify_conversation_layout_test.ts \
  tests/ui_user_ws_connection_test.ts \
  tests/ui_user_ws_recovery_test.ts
# External captured-backend evidence is mandatory when explicitly requested by S3.
if [[ -n "${LIVE_TOOLS_EVIDENCE:-}" ]]; then
  node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_live_tool_wire_integration_test.ts
fi
# TypeScript, Vite UI and Electron build.
npm run build
git diff --check
git merge-base --is-ancestor fc983f52 HEAD
git merge-base --is-ancestor 263cdff81db41e067d00711a6aa99fd58a639bf0 HEAD
git rev-parse HEAD
git status --short
