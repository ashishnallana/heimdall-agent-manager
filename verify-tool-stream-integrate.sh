#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$(realpath -- "$0")")"
if [[ ${TOOL_STREAM_IN_NIX:-0} != 1 ]]; then
  exec nix develop -c env TOOL_STREAM_IN_NIX=1 bash "$PWD/verify-tool-stream-integrate.sh"
fi
source_head=$(git rev-parse HEAD)
test -z "$(git status --porcelain)"
for ancestor in fc983f52 263cdff81db41e067d00711a6aa99fd58a639bf0 e8a2fea692c6f3838b3b4eda40e8cb78c276d373 19200023ff44e4c9b42648cbac46e0ef08658c38 6f2bad615d9be07f5f81ea4e3db6b87720b1c34d; do
  git merge-base --is-ancestor "$ancestor" "$source_head"
done
mkdir -p "$HOME/.cache/heimdall-tests"
export LIVE_TOOLS_EVIDENCE
LIVE_TOOLS_EVIDENCE=$(mktemp -d "$HOME/.cache/heimdall-tests/tool-stream-integrate-XXXXXX")
export LIVE_TOOLS_BIN="$LIVE_TOOLS_EVIDENCE/bin"
mkdir -p "$LIVE_TOOLS_BIN"
exec > >(tee "$LIVE_TOOLS_EVIDENCE/verify.log") 2>&1
printf 'Source commit: %s\nEvidence: %s\n' "$source_head" "$LIVE_TOOLS_EVIDENCE"
if [[ ! -d node_modules ]]; then npm ci --legacy-peer-deps --no-audit --no-fund; fi
for component in hub bridge ctl dev_proxy; do
  odin build "src/$component" -collection:odin_test=src "-out:$LIVE_TOOLS_BIN/ham-${component//_/-}"
done
export LIVE_TOOLS_PTY="${LIVE_TOOLS_PTY:-$(command -v ham-pty-host)}"
test -x "$LIVE_TOOLS_PTY"
scope() {
  local label="$1" package="$2" names
  shift 2
  names=$(awk '
    /@\(test\)/ { want=1; line=$0; sub(/.*@\(test\)/, "", line); if (line ~ /::/) { split(line,a,"::"); gsub(/[ \t]/,"",a[1]); print a[1]; want=0 }; next }
    want && /::/ { split($0,a,"::"); gsub(/[ \t]/,"",a[1]); print a[1]; want=0 }
  ' "$@" | sort -u | paste -sd, -)
  test -n "$names"
  odin build "$package" -build-mode:test -collection:odin_test=src "-out:$LIVE_TOOLS_BIN/$label-tests" -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_FANCY=false
  "$LIVE_TOOLS_BIN/$label-tests" "-tests:$names" 2>&1 | tee "$LIVE_TOOLS_EVIDENCE/$label.log"
}
# Focus on stream transport, bounds and freshness; approved unrelated extension
# and blocker suites are not rerun.
scope tracker src/lib/tool_live src/lib/tool_live/tracker_test.odin
scope agent src/hub/service/agent src/hub/service/agent/tool_stream_test.odin
scope bridge src/bridge src/bridge/tool_activity_live_test.odin src/bridge/hub_command_dispatch_test.odin
scope http src/hub/transport/http src/hub/transport/http/tool_stream_handler_test.odin src/hub/transport/http/tool_activity_live_relay_test.odin src/hub/transport/http/tool_activity_live_test.odin src/hub/transport/http/bridge_ws_reader_test.odin
node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/tool_stream_integration.mjs
node --import ./tests/helpers/vaultEndpointHarness.ts --test \
  tests/ui_live_tool_wire_integration_test.ts \
  tests/ui_live_tool_activity_test.ts \
  tests/ui_live_tool_activity_dom_test.ts \
  tests/ui_tool_stream_url_test.ts \
  tests/ui_aux_panes_store_test.ts \
  tests/ui_aux_dock_test.ts \
  tests/ui_refresh_integration_test.ts \
  tests/ui_extension_tool_activity_test.ts \
  tests/ui_simplify_conversation_layout_test.ts \
  tests/ui_user_ws_connection_test.ts \
  tests/ui_user_ws_recovery_test.ts 2>&1 | tee "$LIVE_TOOLS_EVIDENCE/ui.log"
npm run build 2>&1 | tee "$LIVE_TOOLS_EVIDENCE/ui-build.log"
python3 -m json.tool docs/tool-activity-live.schema.json >/dev/null
git diff --check
test -z "$(git status --porcelain)"
test "$(git rev-parse HEAD)" = "$source_head"
python3 - <<'PY'
import os,pathlib,json,hashlib,subprocess,re
p=pathlib.Path(os.environ['LIVE_TOOLS_EVIDENCE'])
files=[f for f in p.glob('*.log') if f.name!='verify.log']+list((p/'bin').iterdir())+list(p.glob('*.jsonl'))+[p/'manifest.json',p/'setup.json']+list(p.glob('prior-*.json'))
receipt={'head':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
 'command':'bash /home/tanmay/hamwt/tool-stream-integrate/verify-tool-stream-integrate.sh',
 'odin_tests':sum(int(n) for f in [p/'bridge.log',p/'agent.log',p/'http.log',p/'tracker.log'] for n in re.findall(r'Finished (\d+) tests?',f.read_text())),
 'ui_tests':int(re.findall(r'\btests\s+(\d+)',(p/'ui.log').read_text())[-1]),
 'builds':['hub','bridge','ctl','dev-proxy','TypeScript','Vite','Electron'],
 'pty_host_binary':os.environ['LIVE_TOOLS_PTY'],
 'pty_host_sha256':hashlib.sha256(pathlib.Path(os.environ['LIVE_TOOLS_PTY']).read_bytes()).hexdigest(),
 'sha256':{str(f.relative_to(p)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files}}
(p/'verification.json').write_text(json.dumps(receipt,indent=2))
print('PASS scoped integration verification:',p/'verification.json')
PY
