#!/usr/bin/env bash
# Run from the repository root inside nix develop.
set -euo pipefail
mkdir -p "$HOME/.cache/heimdall-tests"
test_dir=$(mktemp -d "$HOME/.cache/heimdall-tests/pty-stream-limits.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
odin build src/hub/service/shell_session -build-mode:test -collection:odin_test=src -out:"$test_dir/shell"
service_tests=$(sed -n 's/^\(test_[a-zA-Z0-9_]*\) :: proc.*/\1/p' \
  src/hub/service/shell_session/pane_plan_limits_test.odin \
  src/hub/service/shell_session/pane_viewer_writer_test.odin \
  src/hub/service/shell_session/shell_snapshot_cache_test.odin | paste -sd, -)
"$test_dir/shell" "-tests:$service_tests"
odin build src/hub/transport/http -build-mode:test -collection:odin_test=src -out:"$test_dir/http"
http_tests=$(sed -n 's/^\(test_[a-zA-Z0-9_]*\) :: proc.*/\1/p' \
  src/hub/transport/http/pty_stream_admission_test.odin \
  src/hub/transport/http/terminal_entitlements_test.odin \
  src/hub/transport/http/agent_instance_stream_test.odin \
  src/hub/transport/http/shell_session_stream_test.odin \
  src/hub/transport/http/shell_stream_screen_snapshot_test.odin \
  src/hub/transport/http/shell_snapshot_single_repaint_test.odin | paste -sd, -)
"$test_dir/http" "-tests:$http_tests"
odin build src/hub -collection:odin_test=src -out:"$test_dir/ham-hub"
npm run typecheck
node --import ./tests/helpers/vaultEndpointHarness.ts --test \
  tests/ui_agent_pane_feed_test.ts tests/ui_shell_pane_feed_test.ts
