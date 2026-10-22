#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
npm run typecheck
node --import ./tests/helpers/vaultEndpointHarness.ts --test \
  tests/ui_plan_limits_test.ts tests/ui_account_billing_test.ts \
  tests/ui_agent_pane_composer_panel_test.ts tests/ui_agent_pane_feed_test.ts \
  tests/ui_shell_pane_feed_test.ts tests/ui_interactive_shell_launch_test.ts \
  tests/ui_device_approval_lookup_test.ts tests/ui_bridge_enrollment_reuse_test.ts \
  tests/ui_composer_bridge_options_test.ts tests/ui_shell_streaming_test.ts \
  tests/ui_pane_visibility_gate_test.ts tests/ui_settings_modal_test.ts \
  tests/ui_shell_panes_test.ts tests/ui_pane_switchers_test.ts \
  tests/ui_shell_open_preview_test.ts tests/ui_aux_dock_test.ts \
  tests/ui_bridges_panel_update_test.ts
npm exec -- vite build --logLevel warn
