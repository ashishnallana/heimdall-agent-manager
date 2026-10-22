#!/usr/bin/env bash
# Run from the repository root inside nix develop.
set -euo pipefail
mkdir -p "$HOME/.cache/heimdall-tests"
test_dir=$(mktemp -d "$HOME/.cache/heimdall-tests/terminal-plan-limits.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
odin build src/hub/transport/http -build-mode:test -collection:odin_test=src -out:"$test_dir/http"
tests=$(sed -n 's/^\(test_[a-zA-Z0-9_]*\) :: proc.*/\1/p' \
  src/hub/transport/http/terminal_entitlements_test.odin \
  src/hub/transport/http/agent_instance_stream_test.odin \
  src/hub/transport/http/agent_instance_input_test.odin \
  src/hub/transport/http/shell_session_stream_test.odin \
  src/hub/transport/http/shell_stream_screen_snapshot_test.odin | paste -sd, -)
"$test_dir/http" "-tests:$tests"
odin build src/hub -collection:odin_test=src -out:"$test_dir/ham-hub"
