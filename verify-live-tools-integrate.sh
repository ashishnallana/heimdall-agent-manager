#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
if [[ "${1:-}" != --inside ]]; then
  exec nix develop -c bash "$0" --inside
fi
export LIVE_TOOLS_EVIDENCE
LIVE_TOOLS_EVIDENCE="$(mktemp -d "$HOME/.cache/heimdall-tests/live-tools-integrate-XXXXXX")"
export LIVE_TOOLS_BIN="$LIVE_TOOLS_EVIDENCE/bin"
mkdir -p "$LIVE_TOOLS_BIN"
exec > >(tee "$LIVE_TOOLS_EVIDENCE/verify.log") 2>&1
printf 'Source commit: %s\nEvidence: %s\n' "$(git rev-parse HEAD)" "$LIVE_TOOLS_EVIDENCE"
if [[ ! -d node_modules ]]; then npm ci --legacy-peer-deps --no-audit --no-fund; fi
for component in hub bridge ctl dev_proxy; do
  output="${component//_/-}"
  odin build "src/$component" -collection:odin_test=src "-out:$LIVE_TOOLS_BIN/ham-$output"
done
export LIVE_TOOLS_PTY="${LIVE_TOOLS_PTY:-$(command -v ham-pty-host)}"
test -x "$LIVE_TOOLS_PTY"
# Focused cross-boundary/bound/security regressions; B1/B2 full suites were
# already approved. Bridge dispatcher is the product fix made in this task.
scope() {
  local label="$1" package="$2" names="$3"
  printf '%s tests: %s\n' "$label" "$names"
  odin build "$package" -build-mode:test -collection:odin_test=src \
    "-out:$LIVE_TOOLS_BIN/$label-tests" -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_FANCY=false
  "$LIVE_TOOLS_BIN/$label-tests" "-tests:$names" 2>&1 | tee "$LIVE_TOOLS_EVIDENCE/$label.log"
}
scope bridge src/bridge bridge_dispatch_spec_accepts_status_ack_and_connection_replaced,test_live_bridge_push_snapshot_idle_and_reconnect
scope agent src/hub/service/agent test_live_relay_snapshot_is_on_demand_and_retains_no_content,test_live_relay_rejects_binding_launch_epoch_and_unsolicited_reply,test_live_relay_pending_caps_and_terminal_cancellation,test_live_relay_deadline_reclaims_slot_and_late_reply_is_discarded,test_live_chain_pages_are_bounded_and_roster_token_changes
scope http src/hub/transport/http test_live_relay_connection_epoch_sequence_and_rate_budget
scope tracker src/lib/tool_live test_live_global_memory_cap,test_live_all_active_capacity_recovers_and_retains_unseen_cutoff,test_live_owned_byte_and_wire_budgets
node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/live_tools_integration.mjs
node --import ./tests/helpers/vaultEndpointHarness.ts --test \
  tests/ui_live_tool_wire_integration_test.ts \
  tests/ui_live_tool_activity_test.ts \
  tests/ui_live_tool_activity_dom_test.ts 2>&1 | tee "$LIVE_TOOLS_EVIDENCE/ui.log"
npm run build 2>&1 | tee "$LIVE_TOOLS_EVIDENCE/ui-build.log"
git diff --check
python3 - <<'PY'
import os,pathlib,json,hashlib,subprocess,re
p=pathlib.Path(os.environ['LIVE_TOOLS_EVIDENCE'])
files=[f for f in p.glob('*.log') if f.name!='verify.log']+list((p/'bin').iterdir())+list(p.glob('*.jsonl'))+[p/'manifest.json',p/'setup.json']
receipt={'head':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
 'command':'bash /home/tanmay/hamwt/live-tools-integrate/verify-live-tools-integrate.sh',
 'odin_tests':sum(int(n) for f in [p/'bridge.log',p/'agent.log',p/'http.log',p/'tracker.log']
                  for n in re.findall(r'Finished (\d+) tests?',f.read_text())),
 'ui_tests':int(re.findall(r'\btests\s+(\d+)',(p/'ui.log').read_text())[-1]),
 'builds':['hub','bridge','ctl','dev-proxy','TypeScript','Vite','Electron'],
 'pty_host_binary':os.environ['LIVE_TOOLS_PTY'],
 'pty_host_sha256':hashlib.sha256(pathlib.Path(os.environ['LIVE_TOOLS_PTY']).read_bytes()).hexdigest(),
 'sha256':{str(f.relative_to(p)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files}}
(p/'verification.json').write_text(json.dumps(receipt,indent=2))
print('PASS scoped integration verification:',p/'verification.json')
PY
