#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
if [[ ! -d node_modules ]]; then
  npm ci --legacy-peer-deps
fi
node --import ./tests/helpers/vaultEndpointHarness.ts --test \
  tests/ui_aux_panes_store_test.ts \
  tests/ui_aux_dock_test.ts \
  tests/ui_extension_badge_test.ts \
  tests/ui_extension_blockers_test.ts \
  tests/ui_extension_permission_test.ts \
  tests/ui_composer_permission_toggle_test.ts \
  tests/ui_extension_tool_activity_test.ts \
  tests/ui_live_tool_activity_test.ts \
  tests/ui_live_tool_activity_dom_test.ts \
  tests/ui_simplify_conversation_layout_test.ts \
  tests/ui_refresh_integration_test.ts
npm run build
git diff --check
git merge-base --is-ancestor e8a2fea692c6f3838b3b4eda40e8cb78c276d373 HEAD
git merge-base --is-ancestor 19200023ff44e4c9b42648cbac46e0ef08658c38 HEAD
git rev-parse HEAD
git status --short
