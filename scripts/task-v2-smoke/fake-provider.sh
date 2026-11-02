#!/bin/sh
# fake-provider.sh — the "worker agent" of the Task System v2 smoke.
#
# The smoke puts this script on the bridge's PATH under the catalog binary names
# (`claude`, `pi`), so the bridge's normal wake_agent → launch path (pty-host,
# bootstrap, fresh hlat token, ham-ctl shim in the run_dir) is exercised for real.
# The only thing fake is the model: instead of an LLM, this process
#   1. answers `--version` (the bridge's provider probe),
#   2. calls `ham-ctl agent start-success` through the run_dir shim,
#   3. confirms its wake-delivered lease with `ham-ctl agent lease next`
#      (GRANT_UNCONFIRMED is 180 s hub-side),
#   4. then stays alive printing a heartbeat line every few seconds (so the
#      bridge's activity detection sees it busy, never idle), while the smoke
#      drives the remaining verbs (verify / submit / review) through the SAME
#      shim + token this process holds (see agentcall.py).
#
# It records its pid under $WORK/agents/<instance>.pid so the smoke can kill it.
case "${1:-}" in
  --version|-v|version) echo "fake-provider 0.0.1 (heimdall task-v2 smoke)"; exit 0 ;;
esac

here="$(cd "$(dirname "$0")" && pwd)"
WORK="${TASKV2_SMOKE_WORK:-$(dirname "$here")}"
inst="${HEIMDALL_AGENT_INSTANCE_ID:-unknown}"
mkdir -p "$WORK/agents" "$WORK/logs"
log="$WORK/logs/agent-$inst.log"
echo $$ > "$WORK/agents/$inst.pid"
{
  echo "=== fake provider start $(date -u +%FT%TZ) pid=$$ inst=$inst cwd=$(pwd)"
  echo "argv: $*"
  echo "ctl: ${HEIMDALL_CTL_BIN:-<unset>} endpoint: ${HEIMDALL_BRIDGE_ENDPOINT:-<unset>}"
} >> "$log"

CTL="${HEIMDALL_CTL_BIN:-}"
[ -n "$CTL" ] || CTL="$(pwd)/bin/ham-ctl"
if [ ! -x "$CTL" ]; then
  echo "no ham-ctl shim at $CTL" >> "$log"
  CTL="ham-ctl"
fi

echo "--- start-success" >> "$log"
"$CTL" agent start-success >> "$log" 2>&1
echo "--- lease next (confirm wake grant)" >> "$log"
"$CTL" agent lease next >> "$log" 2>&1
echo "" >> "$log"

echo "fake worker $inst ready; waiting for the smoke to drive me"
n=0
while :; do
  n=$((n+1))
  echo "fake-agent $inst alive #$n $(date +%T)"
  sleep 4
done
