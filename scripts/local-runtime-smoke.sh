#!/usr/bin/env bash
# local-runtime-smoke.sh — bounded acceptance checks for local-hub.sh / local-bridge.sh.
#
# Always runs (seconds, no build): syntax, help, the shared Node helper tests, and
# lib.sh process-ownership / port-collision / launcher-refusal checks against a
# throwaway state root.
#
# Then the real fresh-stack smoke, when binaries can be had: a fresh hub (UI, seeds),
# a restart that must not duplicate seeds, a bridge that auto-enrolls through the
# real device flow, and stop that leaves nothing behind. Binaries come from
# HEIMDALL_LOCAL_SMOKE_BIN_DIR (ham-hub, ham-dev-proxy, ham-bridge, ham-ctl,
# ham-pty-host), else from `nix build` when nix exists. Without either the real
# smoke is reported as SKIPPED, never as passed; set HEIMDALL_LOCAL_SMOKE_REQUIRE_REAL=1
# to make that a failure. Ports: HEIMDALL_LOCAL_SMOKE_PORT_BASE (default 38000).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HUB="$ROOT/scripts/local-hub.sh" BRIDGE="$ROOT/scripts/local-bridge.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lr-smoke.XXXXXX")"
export HEIMDALL_LOCAL_STATE_ROOT="$TMP/state"
PASS=0
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
cleanup() {
  for d in "$TMP"/state/*/*/; do
    [ -d "$d" ] || continue
    kind="$(basename "$(dirname "$d")")"; name="$(basename "$d")"
    [ "$kind" = hubs ] && "$HUB" stop --name "$name" >/dev/null 2>&1 || true
    [ "$kind" = bridges ] && "$BRIDGE" stop --name "$name" >/dev/null 2>&1 || true
  done
  [ -n "${HOLDER:-}" ] && kill "$HOLDER" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# --- static ---------------------------------------------------------------
bash -n "$HUB" "$BRIDGE" "$ROOT/scripts/local-runtime/lib.sh" || fail "bash -n"
ok "bash -n"
"$HUB" help | grep -q 'start|stop|status|help' || fail "hub help"
"$BRIDGE" help | grep -q -- '--auto-enroll' || fail "bridge help"
ok "help output"
node --test "$ROOT/scripts/local-runtime/helpers.test.mjs" > "$TMP/node-test.log" 2>&1 || { cat "$TMP/node-test.log"; fail "node helper tests"; }
ok "node helper tests ($(grep -c '^✔' "$TMP/node-test.log") passed)"

# --- lib.sh: ownership and ports -----------------------------------------------
# shellcheck source=local-runtime/lib.sh
( source "$ROOT/scripts/local-runtime/lib.sh"
  D="$TMP/state/hubs/own"; mkdir -p "$D"
  lr_spawn "$D" svc "$D/svc.log" sleep 30
  pid="$(lr_owned_pid "$D" svc)" || fail "spawned process not owned"
  # A record whose start time does not match (a recycled pid) must never be signalled.
  read -r p _ < "$D/run/svc.pid"; echo "$p Mon_Jan_1_00:00:00_2001" > "$D/run/svc.pid"
  lr_owned_pid "$D" svc >/dev/null && fail "pid with wrong start time treated as owned"
  lr_stop_svc "$D" svc
  kill -0 "$pid" 2>/dev/null || fail "foreign (mismatched) process was killed"
  kill "$pid"
  lr_spawn "$D" svc "$D/svc.log" sleep 30
  pid="$(lr_owned_pid "$D" svc)"
  lr_stop_svc "$D" svc
  sleep 0.2; kill -0 "$pid" 2>/dev/null && fail "owned process survived stop"
  exit 0 ) || fail "ownership checks"
ok "stop signals only recorded processes with matching start time"

PB="${HEIMDALL_LOCAL_SMOKE_PORT_BASE:-38000}"
node -e 'require("net").createServer().listen(+process.argv[1],"127.0.0.1")' "$((PB + 9))" &
HOLDER=$!
for _ in $(seq 1 20); do (exec 3<>"/dev/tcp/127.0.0.1/$((PB + 9))") 2>/dev/null && break; sleep 0.1; done
out="$("$HUB" start --name busy --hub-port "$((PB + 9))" --proxy-port "$((PB + 8))" --no-ui --build none 2>&1)" && fail "start on a busy port succeeded"
grep -q "already in use" <<<"$out" || fail "busy-port refusal message: $out"
ok "hub refuses a busy port before building or starting anything"
out="$("$HUB" start --name dup --hub-port "$((PB + 7))" --proxy-port "$((PB + 7))" --no-ui --build none 2>&1)" && fail "duplicate ports accepted"
grep -q "two services" <<<"$out" || fail "duplicate-port message: $out"
ok "hub refuses one port for two services"
mkdir -p "$TMP/state/hubs/other"; printf 'KIND=hub\nHUB_PORT=%s\n' "$((PB + 6))" > "$TMP/state/hubs/other/instance.env"
out="$("$BRIDGE" start --name claim --hub-url http://127.0.0.1:1 --port "$((PB + 6))" --local-endpoint-port "$((PB + 5))" --build none 2>&1)" && fail "claimed port accepted"
grep -q "recorded by instance" <<<"$out" || fail "claimed-port message: $out"
ok "bridge refuses a port recorded by another instance"
out="$("$BRIDGE" start --name nohub 2>&1)" && fail "bridge without hub url started"
grep -q -- "--hub-url or --hub is required" <<<"$out" || fail "missing hub message: $out"
"$HUB" start --name 'Bad Name' >/dev/null 2>&1 && fail "invalid name accepted"
ok "bridge requires an explicit hub; invalid instance names refused"
"$HUB" status --name nothing >/dev/null 2>&1 && fail "status of missing instance succeeded"
ok "status reports a missing instance"
kill "$HOLDER" 2>/dev/null || true; HOLDER=""

# --- real fresh stack -------------------------------------------------------------
BIN="${HEIMDALL_LOCAL_SMOKE_BIN_DIR:-}"
if [ -z "$BIN" ] && ! command -v nix >/dev/null; then
  echo "SKIPPED real fresh-stack smoke: no HEIMDALL_LOCAL_SMOKE_BIN_DIR and no nix on this host"
  [ "${HEIMDALL_LOCAL_SMOKE_REQUIRE_REAL:-0}" = 1 ] && fail "real smoke required"
  echo "PASS ($PASS static checks; real smoke skipped)"; exit 0
fi
src=(); [ -n "$BIN" ] && src=(--bin-dir "$BIN")
H=(--name smoke --hub-port "$((PB + 1))" --proxy-port "$((PB + 2))" --ui-port "$((PB + 3))")
timeout 900 "$HUB" start "${H[@]}" "${src[@]}" > "$TMP/hub1.log" 2>&1 || { cat "$TMP/hub1.log"; fail "fresh hub start"; }
api="http://127.0.0.1:$((PB + 2))"
count() { curl -s -m 5 "$api$1" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const d=JSON.parse(s).data||[];console.log(d.filter(x=>(x.name||x.title||"").startsWith(process.argv[1])).length)})' "$2"; }
[ "$(count '/api/v1/agents?limit=200' 'Sample ')" = 2 ] || fail "seeded agents"
[ "$(count '/api/v1/task-chains?flat=1' 'Sample: ')" = 2 ] || fail "seeded chains"
[ "$(count '/api/v1/memories?limit=200' 'Sample: ')" = 2 ] || fail "seeded memories"
curl -s -m 5 "http://127.0.0.1:$((PB + 3))/" | grep -qi '<div id="root"\|<html' || fail "UI did not serve HTML"
ok "fresh hub serves UI and seeded 2 agents, 2 chains, 2 memories"
curl -s -m 5 "$api/api/v1/agents?limit=200" | grep -q '"active_instance_count":[1-9]' && fail "a seeded agent was launched"
ok "no seeded agent was launched"
"$HUB" stop --name smoke >/dev/null
timeout 300 "$HUB" start --name smoke "${src[@]}" > "$TMP/hub2.log" 2>&1 || { cat "$TMP/hub2.log"; fail "hub restart"; }
grep -q 'seed: 0 created' "$TMP/hub2.log" || fail "restart re-seeded"
[ "$(count '/api/v1/agents?limit=200' 'Sample ')" = 2 ] || fail "duplicate agents after restart"
ok "restart keeps state and seeds nothing twice"
timeout 600 "$BRIDGE" start --name smoke --hub smoke --port "$((PB + 4))" --local-endpoint-port "$((PB + 5))" \
  --auto-enroll "${src[@]}" > "$TMP/bridge.log" 2>&1 || { cat "$TMP/bridge.log"; fail "bridge auto-enroll start"; }
BD="$HEIMDALL_LOCAL_STATE_ROOT/bridges/smoke"
[ -s "$BD/credentials/bridge-token" ] && [ -s "$BD/credentials/bridge-token.refresh" ] || fail "credential pair"
grep -q 'bridge hub runtime ready' "$BD/logs/bridge.log" || fail "bridge not connected"
grep -q 'skipped installed-service call' "$BD/logs/enroll.log" || fail "installed service restart was not intercepted"
ok "bridge enrolled via device flow, connected, installed service untouched"
"$BRIDGE" stop --name smoke >/dev/null; "$HUB" stop --name smoke >/dev/null
for p in 1 2 3 4 5; do (exec 3<>"/dev/tcp/127.0.0.1/$((PB + p))") 2>/dev/null && fail "port $((PB + p)) still bound after stop"; done
ok "stop released every port"
echo "PASS ($PASS checks including real fresh-stack smoke)"
