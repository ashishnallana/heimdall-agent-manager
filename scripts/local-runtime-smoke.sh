#!/usr/bin/env bash
# local-runtime-smoke.sh — bounded acceptance checks for local-hub.sh / local-bridge.sh.
#
# Always runs (seconds, no build): syntax, help, the shared Node helper tests, and
# lib.sh process-ownership / port-collision / launcher-refusal checks against a
# throwaway state root.
#
# Then the real fresh-stack smoke, when binaries can be had: a fresh hub (UI, seeds),
# a restart that must not duplicate seeds or the seed approver, a bridge that
# auto-enrolls through the real pairing flow (`ham-bridge enroll` -> approval and
# keyring unseal by the hub's seed approver), and stop that leaves nothing behind. Binaries come from
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
  # ham-bridge keeps each bridge's identity key under ~/.config/heimdall/bridges/<id>_*
  # (keyed by the id enrollment minted, so never shared). Remove only the ones of
  # the throwaway bridges enrolled here.
  local cfg id
  for cfg in "$TMP"/state/bridges/*/config.toml; do
    [ -f "$cfg" ] || continue
    id="$(sed -n 's/^daemon_id = "\(brg_[0-9a-f]*\)"$/\1/p' "$cfg" | head -1)"
    [ -n "$id" ] && rm -rf "$HOME/.config/heimdall/bridges/${id}_"*
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

# --- static ---------------------------------------------------------------
bash -n "$HUB" "$BRIDGE" "$ROOT/scripts/local-runtime/lib.sh" || fail "bash -n"
ok "bash -n"
"$HUB" help | grep -q 'start|stop|status|approve-device|help' || fail "hub help"
"$BRIDGE" help | grep -q -- '--auto-enroll' || fail "bridge help"
ok "help output"
node --test "$ROOT/scripts/local-runtime/helpers.test.mjs" "$ROOT/scripts/local-runtime/profile-state.test.mjs" > "$TMP/node-test.log" 2>&1 || { cat "$TMP/node-test.log"; fail "node helper tests"; }
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

# The enroll prompt as src/bridge/enroll_device_flow.odin prints it; the stale
# device-code wording must not match.
( source "$ROOT/scripts/local-runtime/lib.sh"
  L="$TMP/enroll-fixture.log"
  printf '\nEnroll this machine\n  On a device that already uses Heimdall, open:\n\n  http://127.0.0.1:15173/api/v1/device/add\n\n  and type this pairing code once:\n\n      6KSK-R5EV-7I6I-S4\n\n  The code is a secret.\n' > "$L"
  [ "$(lr_enroll_prompt "$L")" = "http://127.0.0.1:15173/api/v1/device/add 6KSK-R5EV-7I6I-S4" ] || fail "enroll prompt: $(lr_enroll_prompt "$L")"
  printf 'Go to http://h/device and enter the code ABCD-EFGH\n' > "$L"
  [ -z "$(lr_enroll_prompt "$L")" ] || fail "stale device-code prompt matched"
  exit 0 ) || fail "enroll prompt parsing"
ok "enroll prompt parser reads the approval link and pairing code"

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
out="$("$HUB" start --name badorigin --public-origin https://example.test/p/x/ 2>&1)" && fail "origin with a path accepted"
grep -q -- "--public-origin must be" <<<"$out" || fail "bad origin message: $out"
[ -e "$HEIMDALL_LOCAL_STATE_ROOT/hubs/badorigin" ] && fail "bad origin created state"
ok "hub refuses a public origin with a path before creating state"
"$HUB" status --name nothing >/dev/null 2>&1 && fail "status of missing instance succeeded"
ok "status reports a missing instance"
kill "$HOLDER" 2>/dev/null || true; HOLDER=""

# --- real fresh stack -------------------------------------------------------------
BIN="${HEIMDALL_LOCAL_SMOKE_BIN_DIR:-}"
# shellcheck source=local-runtime/lib.sh
if [ -z "$BIN" ] && { ! command -v nix >/dev/null || (source "$ROOT/scripts/local-runtime/lib.sh"; lr_nix_portable); }; then
  echo "SKIPPED real fresh-stack smoke: no HEIMDALL_LOCAL_SMOKE_BIN_DIR and no usable host nix (absent, or nix-portable)"
  [ "${HEIMDALL_LOCAL_SMOKE_REQUIRE_REAL:-0}" = 1 ] && fail "real smoke required"
  echo "PASS ($PASS static checks; real smoke skipped)"; exit 0
fi
src=(); [ -n "$BIN" ] && src=(--bin-dir "$BIN")
PUB=https://preview.smoke.test
H=(--name smoke --hub-port "$((PB + 1))" --proxy-port "$((PB + 2))" --ui-port "$((PB + 3))" --public-origin "$PUB/")
timeout 900 "$HUB" start "${H[@]}" "${src[@]}" > "$TMP/hub1.log" 2>&1 || { cat "$TMP/hub1.log"; fail "fresh hub start"; }
api="http://127.0.0.1:$((PB + 2))"
count() { curl -s -m 5 "$api$1" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const d=JSON.parse(s).data||[];console.log(d.filter(x=>(x.name||x.title||"").startsWith(process.argv[1])).length)})' "$2"; }
[ "$(count '/api/v1/agents?limit=200' 'Sample ')" = 2 ] || fail "seeded agents"
[ "$(count '/api/v1/task-chains?flat=1' 'Sample: ')" = 2 ] || fail "seeded chains"
[ "$(count '/api/v1/memories?limit=200' 'Sample: ')" = 2 ] || fail "seeded memories"
curl -s -m 5 "http://127.0.0.1:$((PB + 3))/" | grep -qi '<div id="root"\|<html' || fail "UI did not serve HTML"
ok "fresh hub serves UI and seeded 2 agents, 2 chains, 2 memories"
grep -q 'approver init: created' "$TMP/hub1.log" || { cat "$TMP/hub1.log"; fail "seed approver not created"; }
[ "$(stat -c %a "$HEIMDALL_LOCAL_STATE_ROOT/hubs/smoke/approver/device.json")" = 600 ] || fail "approver key is not 0600"
ok "seed approver rooted the hub vault (key 0600 in the instance dir)"
curl -s -m 5 "$api/api/v1/agents?limit=200" | grep -q '"active_instance_count":[1-9]' && fail "a seeded agent was launched"
ok "no seeded agent was launched"
# A state-changing request through the UI as a reverse proxy forwards it: the
# public Origin, no Sec-Fetch-Site, no cookie. The dev proxy trusts --public-origin,
# so it signs in and sends the hub its UI origin; a foreign origin gets neither.
csrf() { curl -s -m 5 -X POST -H "Origin: $1" -H 'Content-Type: application/json' -d '{}' "http://127.0.0.1:$((PB + 3))/api/v1/device/pair-salts"; }
out="$(csrf "$PUB")"; grep -q csrf_rejected <<<"$out" && fail "public origin rejected: $out"
grep -q candidates <<<"$out" || fail "public-origin request did not reach the hub: $out"
grep -q csrf_rejected <<<"$(csrf https://evil.test)" || fail "foreign origin accepted"
grep -q "public  : $PUB" <<<"$("$HUB" status --name smoke)" || fail "status does not show the public origin"
ok "dev proxy trusts --public-origin and the hub still refuses foreign origins"
"$HUB" stop --name smoke >/dev/null
timeout 300 "$HUB" start --name smoke "${src[@]}" > "$TMP/hub2.log" 2>&1 || { cat "$TMP/hub2.log"; fail "hub restart"; }
grep -q 'seed: 0 created' "$TMP/hub2.log" || fail "restart re-seeded"
grep -q 'approver init: kept' "$TMP/hub2.log" || { cat "$TMP/hub2.log"; fail "restart did not keep the seed approver"; }
grep -q csrf_rejected <<<"$(csrf "$PUB")" && fail "restart dropped the recorded public origin"
[ "$(count '/api/v1/agents?limit=200' 'Sample ')" = 2 ] || fail "duplicate agents after restart"
ok "restart keeps state and seeds nothing twice"
timeout 600 "$BRIDGE" start --name smoke --hub smoke --port "$((PB + 4))" --local-endpoint-port "$((PB + 5))" \
  --auto-enroll "${src[@]}" > "$TMP/bridge.log" 2>&1 || { cat "$TMP/bridge.log"; fail "bridge auto-enroll start"; }
BD="$HEIMDALL_LOCAL_STATE_ROOT/bridges/smoke"
[ -s "$BD/credentials/bridge-token" ] && [ -s "$BD/credentials/bridge-token.refresh" ] || fail "credential pair"
grep -q 'bridge hub runtime ready' "$BD/logs/bridge.log" || fail "bridge not connected"
grep -q 'approver bridge: approved and unsealed' "$TMP/bridge.log" || fail "seed approver did not approve the bridge"
grep -q 'bridge enroll SUCCESS' "$BD/logs/enroll.log" || fail "ham-bridge enroll did not report SUCCESS"
# An isolated provider home (the default) hides the installed service unit from
# enroll, so it restarts nothing; a shared-home bridge tries, and the shim catches it.
if [ "$(grep '^ISOLATED_HOME=' "$BD/instance.env" | cut -d= -f2)" = 1 ]; then
  grep -q 'no registered bridge service was found' "$BD/logs/enroll.log" || fail "isolated enroll looked for the installed service"
  [ ! -s "$BD/logs/enroll-shims.log" ] || fail "isolated enroll called the service manager: $(cat "$BD/logs/enroll-shims.log")"
  [ -f "$BD/home/.heimdall-home-manifest.json" ] || fail "isolated provider home was not seeded"
  [ -f "$BD/data/extensions/claude-code/.claude-plugin/plugin.json" ] || fail "checkout extensions not synced"
  ok "bridge runs with an isolated, seeded provider home and checkout extension snapshot"
else
  grep -q 'skipped installed-service call: systemctl --user restart heimdall-bridge' "$BD/logs/enroll-shims.log" || fail "installed service restart was not intercepted"
fi
ok "bridge enrolled via pairing code + seed approver, connected, installed service untouched"
"$BRIDGE" stop --name smoke >/dev/null
if [ "$(grep '^ISOLATED_HOME=' "$BD/instance.env" | cut -d= -f2)" = 1 ]; then
  mkdir -p "$BD/data/bridge/profile-secrets"
  printf '{"version":2,"profiles":[]}\n' > "$BD/data/bridge/provider_profiles.json"
  printf 'smoke-profile-secret\n' > "$BD/data/bridge/profile-secrets/smoke.bin"
  "$BRIDGE" stop --name smoke --purge-home >/dev/null || fail "isolated purge"
  [ ! -e "$BD/home" ] && [ ! -e "$BD/data/bridge/provider_profiles.json" ] && [ ! -e "$BD/data/bridge/profile-secrets" ] || fail "purge left profile state"
  [ ! -e "$BD/credentials/bridge-token" ] || fail "purge left unusable enrollment credentials"
  ok "purge removed isolated vault scope, profiles, secrets, home and enrollment credentials"
fi
"$HUB" stop --name smoke >/dev/null
for p in 1 2 3 4 5; do (exec 3<>"/dev/tcp/127.0.0.1/$((PB + p))") 2>/dev/null && fail "port $((PB + p)) still bound after stop"; done
ok "stop released every port"
echo "PASS ($PASS checks including real fresh-stack smoke)"
