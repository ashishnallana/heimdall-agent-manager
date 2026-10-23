#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$(realpath -- "$0")")"
if [[ ${TOOL_STREAM_IN_NIX:-0} != 1 ]]; then
  exec nix develop -c env TOOL_STREAM_IN_NIX=1 bash "$PWD/verify-tool-stream-backend.sh"
fi
test_dir="$HOME/.cache/heimdall-tests/tool-stream-backend-$$"
mkdir -p "$test_dir"
run_scoped() {
  local package="$1" output="$2" names
  shift 2
  names=$(awk '
    /@\(test\)/ { want=1; line=$0; sub(/.*@\(test\)/, "", line); if (line ~ /::/) { split(line,a,"::"); gsub(/[ \t]/,"",a[1]); print a[1]; want=0 }; next }
    want && /::/ { split($0,a,"::"); gsub(/[ \t]/,"",a[1]); print a[1]; want=0 }
  ' "$@" | sort -u | paste -sd, -)
  test -n "$names"
  echo "Scoped tests: $package ($names)"
  odin build "$package" -build-mode:test -collection:odin_test=src -out:"$test_dir/$output"
  "$test_dir/$output" -tests:"$names"
}
run_scoped src/lib/tool_live tracker src/lib/tool_live/tracker_test.odin
run_scoped src/hub/service/agent agent \
  src/hub/service/agent/tool_stream_test.odin \
  src/hub/service/agent/extension_ingest_test.odin
run_scoped src/bridge bridge \
  src/bridge/tool_activity_live_test.odin \
  src/bridge/hub_command_dispatch_test.odin
run_scoped src/hub/transport/http http \
  src/hub/transport/http/tool_stream_handler_test.odin \
  src/hub/transport/http/tool_activity_live_relay_test.odin \
  src/hub/transport/http/tool_activity_live_test.odin \
  src/hub/transport/http/bridge_ws_reader_test.odin
# Only two affected shell assertions changed when pending REST waiters vanished.
odin build src/hub/service/shell_session -build-mode:test -collection:odin_test=src -out:"$test_dir/shell"
"$test_dir/shell" -tests:test_live_inventory_does_not_reconstruct_hub_tool_state,test_live_shell_lifecycle_does_not_create_hub_tool_state
for binary in hub bridge ctl; do
  odin build "src/$binary" -collection:odin_test=src -out:"$test_dir/ham-$binary"
done
python3 -m json.tool docs/tool-activity-live.schema.json > /dev/null
git diff --check
echo 'PASS: summary-only tool stream scoped tests and Hub/Bridge/CLI builds'
