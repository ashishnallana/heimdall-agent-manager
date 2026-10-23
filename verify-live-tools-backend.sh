#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "${1:-}" != "--inside" ]]; then
  exec nix develop -c bash "$0" --inside
fi
test_dir="$HOME/.cache/heimdall-tests/live-tools-backend-$(date +%s)-$$"
mkdir -p "$test_dir"
printf 'Source commit: %s\n' "$(git rev-parse HEAD)"
printf 'Evidence directory: %s\n' "$test_dir"
names() {
  python3 - "$@" <<'PY'
import pathlib,re,sys
pattern=sys.argv[1]
found=[]
for name in sys.argv[2:]:
 for test in re.findall(r"@\(\s*test\s*\)\s*([A-Za-z_]\w*)\s*::",pathlib.Path(name).read_text()):
  if re.search(pattern,test): found.append(test)
assert found, "empty test scope"
print(",".join(found))
PY
}
run_scope() {
  local label="$1" package="$2" selected="$3"
  printf '%s: %s tests\n' "$label" "$(awk -F, '{print NF}' <<<"$selected")"
  odin build "$package" -build-mode:test -collection:odin_test=src \
    "-out:$test_dir/$label" -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1
  "$test_dir/$label" "-tests:$selected" 2>&1 | tee "$test_dir/$label.log"
}
run_scope tracker src/lib/tool_live "$(names . src/lib/tool_live/tracker_test.odin)"
run_scope agent src/hub/service/agent "$(names . src/hub/service/agent/tool_activity_live_test.odin src/hub/service/agent/extension_ingest_test.odin)"
run_scope http src/hub/transport/http "$(names . src/hub/transport/http/tool_activity_live_test.odin src/hub/transport/http/tool_activity_live_relay_test.odin)"
shell_tests="$(names '^(test_live_|test_req5_|test_req16_|test_req25_|test_t10_(absent_row_goes_terminal|untracked_session_is_adopted|unobserved_terminal_is_revived|observed_terminal_is_not_revived|apply_does_not_free_the_clock_string)$)' src/hub/service/shell_session/shell_session_lifecycle_test.odin src/hub/service/shell_session/shell_session_create_test.odin src/hub/service/shell_session/shell_session_reconcile_test.odin)"
run_scope shell src/hub/service/shell_session "$shell_tests"
run_scope bridge src/bridge "$(names . src/bridge/tool_activity_live_test.odin src/bridge/extension_event_test.odin src/bridge/extension_blockers_test.odin src/bridge/extension_permission_test.odin),$(names '^activity_normalize_' src/bridge/pty_host_activity_test.odin)"
python3 - <<'PY'
import json,pathlib,re
json.loads(pathlib.Path("docs/tool-activity-live.schema.json").read_text())
for example in re.findall(r"```json\n(.*?)```", pathlib.Path("docs/ephemeral-tool-activity.md").read_text(), re.S):
 json.loads(example)
print("Protocol schema and JSON examples parse successfully")
PY
odin build src/hub -collection:odin_test=src "-out:$test_dir/ham-hub"
odin build src/bridge -collection:odin_test=src "-out:$test_dir/ham-bridge"
if rg -n 'record_tool_activity_message|record_shell_run_marker|BRIDGE_EXT_TOOL_ACTIVITY_PATH|Tool_Agg|tool_agg_' src/hub src/bridge; then
  printf 'Retired conversation writer/aggregation reference remains\n' >&2
  exit 1
fi
printf 'ALL PASS: scoped live-tools regressions and Hub/Bridge builds\n'

