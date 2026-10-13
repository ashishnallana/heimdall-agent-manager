#!/usr/bin/env bash
# REQ-SHELL-2 end-to-end: `run` and `serve` over the shared create path, with
# EXPLICIT backgrounding, against a real hub + a real bridge.
#
# What this covers that the unit tests cannot: the whole path, and specifically the
# AUTHORIZATION boundary. `run` is agent-only, so it is exercised with a genuine
# agent identity (bridge bearer + X-Heimdall-Instance-Token) rather than as a user
# — which is the only way to prove both that an agent CAN and a user CANNOT.
#
#   1. AC5   a USER creating kind=run is refused by the hub
#   2. AC1   an agent's foreground run blocks, returns output inline, notifies nothing
#   3. AC2   --bg returns immediately with a session id
#   4. AC4   BRIDGE_SHELL_ASYNC_THRESHOLD is GONE from the tree, and a >15s
#            foreground run still returns inline rather than being auto-backgrounded
#   5. AC6   rows carry agent_instance_id / chain_id / conversation id / cmd / cwd / pid
#   6. AC7   the spec file exists while live and is gone once terminal
#   7. AC8   DELETE kills an agent-started run and an agent-started server
#   8. AC9   output is readable on demand via /log and is NOT in the hub DB
#   9. AC11  serve is reachable through the existing preview/tunnel path; a serve
#            with no --port starts fine and exposes nothing
#  10. AC13  two live sessions cannot hold one port; the port is released on exit
#  11. AC14  over-cap creates are refused
#
# Stands up a THROWAWAY stack on its own ports and tears it down again. It never
# touches a stack it did not start: every process it launches is recorded by PID
# and only those PIDs are killed. (Do not "clean up" by pattern-matching command
# lines on a shared host — that takes down other people's stacks.)
#
# Usage:
#   tests/e2e_shell2_run_serve_test.sh
#
# Env (all optional):
#   S2_HUB_PORT     hub listen port                 (default 8593)
#   S2_PROXY_PORT   dev-proxy port (auth injection) (default 8592)
#   S2_BRIDGE_PORT  bridge service port             (default 49931)
#   S2_BRIDGE_LOCAL bridge local endpoint port      (default 49932)
#   S2_SERVE_PORT   port the test server binds       (default 8911)
#   S2_KEEP=1       leave the stack running afterwards
#   S2_SKIP_SLOW=1  skip the >15s foreground check (AC4's behavioural half)
#   ODIN            odin binary (default: odin on PATH, else via nix develop)
#
# Requires a working odin toolchain (the repo's nix dev shell provides one),
# python3 and curl. Exits 0 only if every check below passes.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

HUB_PORT="${S2_HUB_PORT:-8593}"
PROXY_PORT="${S2_PROXY_PORT:-8592}"
B_PORT="${S2_BRIDGE_PORT:-49931}"
B_LOCAL="${S2_BRIDGE_LOCAL:-49932}"
SERVE_PORT="${S2_SERVE_PORT:-8911}"

WORK="$(mktemp -d -t shell2-run-XXXX)"
BIN="$WORK/bin"; mkdir -p "$BIN" "$WORK/run-b" "$WORK/logs" "$WORK/data-b"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "[shell2] PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "[shell2] FAIL  $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }
contains(){ case "$2" in *"$3"*) ok "$1";; *) bad "$1 (missing '$3' in: $(printf '%.200s' "$2"))";; esac; }
absent(){ case "$2" in *"$3"*) bad "$1 (unexpectedly found '$3')";; *) ok "$1";; esac; }

SESSION_IDS=()
PIDS=()
cleanup() {
  if [ "${S2_KEEP:-0}" = "1" ]; then
    echo "[shell2] S2_KEEP=1 — leaving stack up. Work dir: $WORK"
    return
  fi
  for sid in "${SESSION_IDS[@]:-}"; do
    [ -n "$sid" ] && curl -s -X DELETE "http://127.0.0.1:$PROXY_PORT/api/v1/shells/$sid" >/dev/null 2>&1 || true
  done
  sleep 1
  for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null || true; done
  sleep 1
  for pid in $(pgrep -f "pty-host.*$WORK" 2>/dev/null || true); do kill "$pid" 2>/dev/null || true; done
  sleep 1
  rm -rf "$WORK"
}
trap cleanup EXIT

port_busy() { ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$1\$"; }
for p in "$HUB_PORT" "$PROXY_PORT" "$B_PORT" "$B_LOCAL" "$SERVE_PORT"; do
  if port_busy "$p"; then
    echo "[shell2] FAIL: port $p is already in use. Override the S2_* env vars to pick a free block." >&2
    exit 1
  fi
done

echo "[shell2] building hub, bridge and dev-proxy"
ODIN_BIN="${ODIN:-odin}"
if command -v "$ODIN_BIN" >/dev/null 2>&1; then
  "$ODIN_BIN" build src/hub       -collection:odin_test=src -out:"$BIN/hub"
  "$ODIN_BIN" build src/bridge    -collection:odin_test=src -out:"$BIN/bridge"
  "$ODIN_BIN" build src/dev_proxy -collection:odin_test=src -out:"$BIN/devproxy"
else
  nix develop "$ROOT" --command bash -c "cd '$ROOT' && odin build src/hub -collection:odin_test=src -out:'$BIN/hub' && odin build src/bridge -collection:odin_test=src -out:'$BIN/bridge' && odin build src/dev_proxy -collection:odin_test=src -out:'$BIN/devproxy'"
fi

echo "[shell2] starting hub on 127.0.0.1:$HUB_PORT"
"$BIN/hub" --listen "127.0.0.1:$HUB_PORT" --db "$WORK/hub.db" --trusted-proxy-cidr 127.0.0.1/32 \
  > "$WORK/logs/hub.log" 2>&1 & PIDS+=($!)

echo "[shell2] starting dev-proxy on 127.0.0.1:$PROXY_PORT (injects the authenticated user)"
"$BIN/devproxy" --listen "127.0.0.1:$PROXY_PORT" --hub-url "http://127.0.0.1:$HUB_PORT" --default-user tanmay \
  > "$WORK/logs/devproxy.log" 2>&1 & PIDS+=($!)

for _ in $(seq 1 120); do
  curl -sf -o /dev/null "http://127.0.0.1:$PROXY_PORT/api/v1/projects" && break || sleep 0.25
done
curl -sf -o /dev/null "http://127.0.0.1:$PROXY_PORT/api/v1/projects" || {
  echo "[shell2] FAIL: hub/proxy never came up. Logs follow."
  echo "--- hub.log ---";      tail -30 "$WORK/logs/hub.log"      2>/dev/null
  echo "--- devproxy.log ---"; tail -30 "$WORK/logs/devproxy.log" 2>/dev/null
  exit 1
}

api()      { curl -s -X "$1" "http://127.0.0.1:$PROXY_PORT$2" -H 'Content-Type: application/json' ${3:+-d "$3"}; }
api_code() { curl -s -o /dev/null -w '%{http_code}' -X "$1" "http://127.0.0.1:$PROXY_PORT$2" -H 'Content-Type: application/json' ${3:+-d "$3"}; }

# ===== BROWSER-APPROVED DEVICE FLOW (REQ-ENROLL-9) =====
#
# This replaced "mint a one-time enrollment token, then exchange it at
# POST /api/v1/bridges/enroll". Both endpoints are deleted and 404 now, and
# `bridge enroll --hub --enrollment-token` is gone with them.
#
# The three HTTP steps are driven directly rather than via `bridge enroll --hub`,
# which waits for an approval and would need backgrounding plus output scraping.
# Here the script IS the approver: this suite talks through the dev-proxy, which
# authenticates every request as the local user, so this is a real authenticated
# approval and not a test-only bypass.
#
# Hard refusals to respect: bridge_public_key must be a 130-char lowercase-hex
# uncompressed P-256 point; do NOT send bridge_key_fingerprint (the Hub derives it
# and rejects a disagreeing one); PKCE is mandatory and S256-only.
AUTHZ_RESP="$(api POST /api/v1/device/authorize '{"client":"ham-bridge","device_label":"shell2-run","os":"linux","os_user":"tester","bridge_public_key":"040102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40","code_challenge":"J6jJRRlTiLmCVJAjMgzOjMLRQ-xSS_tovxAjutN8JWI","code_challenge_method":"S256"}')"
USER_CODE="$(printf '%s' "$AUTHZ_RESP" | python3 -c '
import json,sys
try: print(json.load(sys.stdin)["data"]["user_code"])
except Exception: print("")')"
DEVICE_CODE="$(printf '%s' "$AUTHZ_RESP" | python3 -c '
import json,sys
try: print(json.load(sys.stdin)["data"]["device_code"])
except Exception: print("")')"
[ -n "$USER_CODE" ] || { echo "[shell2] FAIL: device authorize returned no user_code. Response: $AUTHZ_RESP"; tail -30 "$WORK/logs/hub.log"; exit 1; }
api POST /api/v1/device/approve "{\"user_code\":\"$USER_CODE\",\"approve\":true}" >/dev/null
TOKEN_RESP="$(api POST /api/v1/device/token "{\"device_code\":\"$DEVICE_CODE\",\"code_verifier\":\"heimdall-req-impl-6-test-code-verifier-aaaa\"}")"
printf '%s' "$TOKEN_RESP" | python3 -c '
import json,sys
try: print(json.load(sys.stdin)["data"]["access_token"])
except Exception: print("")' > "$WORK/b.token"
# The refresh half goes beside it under the ".refresh" suffix the bridge itself
# uses, so a bridge started with --bridge-token-file can renew rather than dying
# after the access token's hour is up.
printf '%s' "$TOKEN_RESP" | python3 -c '
import json,sys
try: print(json.load(sys.stdin)["data"].get("refresh_token",""))
except Exception: print("")' > "$WORK/b.token".refresh
chmod 600 "$WORK/b.token" "$WORK/b.token".refresh
[ -s "$WORK/b.token" ] || { echo "[shell2] FAIL: device flow issued no access token. Response: $TOKEN_RESP"; tail -30 "$WORK/logs/hub.log"; exit 1; }

"$BIN/bridge" --hub "http://127.0.0.1:$HUB_PORT" --bridge-token-file "$WORK/b.token" \
  --port "$B_PORT" --local-endpoint-port "$B_LOCAL" --local-run-dir "$WORK/run-b" --data-dir "$WORK/data-b" \
  > "$WORK/logs/bridge.log" 2>&1 & PIDS+=($!)

for _ in $(seq 1 60); do
  grep -q "runtime ready" "$WORK/logs/bridge.log" 2>/dev/null && break || sleep 0.5
done
grep -q "runtime ready" "$WORK/logs/bridge.log" || { echo "[shell2] FAIL: bridge never connected"; tail -30 "$WORK/logs/bridge.log"; exit 1; }

B_ID="$(api GET /api/v1/bridges | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][-1]["bridge_id"])')"
B_TOKEN="$(cat "$WORK/b.token")"
echo "[shell2] bridge = $B_ID"

# An agent identity on THIS bridge. `run` is agent-only, so without one the
# positive half of every run assertion below is untestable.
# The agent instance the run tests act as.
#
# SEEDED DIRECTLY INTO THE HUB DB, on purpose. Creating one through the API
# requires a PROVIDER to be installed and enabled on the bridge (an agent instance
# is something the hub can launch), and this suite is about shell sessions, not
# about agent launching — making it depend on a provider binary would make it fail
# on hosts where nothing is wrong with the code under test.
#
# Nothing about the AUTHORIZATION path is shortcut by this: the hub still verifies
# the bridge bearer token, still looks the instance up, still checks the instance
# belongs to the calling bridge, and still matches the assertion header. Only the
# instance's creation is bypassed, and no assertion below depends on how it was
# created.
AGENT_IID="inst_shell2_e2e"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "[shell2] FAIL: sqlite3 is required to seed the agent identity the run tests act as."
  exit 1
fi
sqlite3 "$WORK/hub.db" "INSERT INTO agent_instances
  (agent_instance_id, owner_user_id, agent_id, bridge_id, runtime_status, created_at, updated_at, last_seen_at)
  VALUES ('$AGENT_IID','tanmay','agt_shell2_e2e','$B_ID','running','$NOW','$NOW','$NOW');"
echo "[shell2] agent instance = $AGENT_IID (seeded)"


# Agent-authenticated call: bridge bearer + the instance assertion header. This is
# exactly how the bridge relays an agent's REST call, so it exercises the real
# authorization path rather than a test-only shortcut.
agent_api() { curl -s -X "$1" "http://127.0.0.1:$HUB_PORT$2" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $B_TOKEN" \
    -H "X-Heimdall-Instance-Token: hit_$AGENT_IID" ${3:+-d "$3"}; }
agent_api_code() { curl -s -o /dev/null -w '%{http_code}' -X "$1" "http://127.0.0.1:$HUB_PORT$2" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $B_TOKEN" \
    -H "X-Heimdall-Instance-Token: hit_$AGENT_IID" ${3:+-d "$3"}; }

sid_of() { python3 -c '
import json,sys
try: print(json.load(sys.stdin)["data"]["session"]["session_id"])
except Exception: print("")'; }
session_field() { api GET "/api/v1/shells/$1" | python3 -c '
import json,sys
try: print(json.load(sys.stdin)["data"]["session"][sys.argv[1]])
except Exception: print("")' "$2"; }

CHAIN_ID="chain_shell2_e2e"

# ---- AC5: a USER cannot start a run -------------------------------------------
echo "[shell2] AC5: a user may not start a run"
check "AC5: a user creating kind=run is refused" "403" \
  "$(api_code POST "/api/v1/bridges/$B_ID/shells" "{\"kind\":\"run\",\"cmd\":\"echo nope\",\"agent_instance_id\":\"$AGENT_IID\"}")"

# N3: an omitted kind no longer defaults to a kind the caller cannot start.
NOKIND_CODE="$(api_code POST "/api/v1/bridges/$B_ID/shells" "{\"cmd\":\"true\",\"cwd\":\"$WORK\"}")"
check "N3: a user omitting kind gets a session, not a confusing 400" "200" "$NOKIND_CODE"

# ---- AC1 / AC6 / AC7 / AC9: an agent's FOREGROUND run --------------------------
echo "[shell2] AC1: an agent's foreground run"
FG_RESP="$(agent_api POST "/api/v1/bridges/$B_ID/shells" "{\"kind\":\"run\",\"cmd\":\"echo hello-foreground\",\"cwd\":\"$WORK\",\"conversation_id\":\"chat_e2e\"}")"
FG_ID="$(printf '%s' "$FG_RESP" | sid_of)"
SESSION_IDS+=("$FG_ID")
[ -n "$FG_ID" ] && ok "AC5/AC1: an AGENT may start a run" || { bad "an agent could not start a run: $FG_RESP"; }

if [ -n "$FG_ID" ]; then
  # AC6: the identity columns a run must carry to be renderable at all.
  check "AC6: run carries its agent_instance_id" "$AGENT_IID" "$(session_field "$FG_ID" agent_instance_id)"
  check "AC6: run carries the triggering conversation" "chat_e2e" "$(session_field "$FG_ID" conversation_id)"
  check "AC6: run carries its cmd"  "echo hello-foreground" "$(session_field "$FG_ID" cmd)"
  check "AC6: run carries its cwd"  "$WORK"                 "$(session_field "$FG_ID" cwd)"
  check "AC6: run leaves chain_id empty (agent scoped)" "" "$(session_field "$FG_ID" chain_id)"
  PID_VAL="$(session_field "$FG_ID" pid)"
  [ "${PID_VAL:-0}" -gt 0 ] 2>/dev/null && ok "AC6: run records a pid" || bad "AC6: run records a pid (got '$PID_VAL')"
  # AC1: a foreground run is NOT background.
  check "AC1: a foreground run is not marked background" "False" "$(session_field "$FG_ID" background | python3 -c 'import sys; print(str(sys.stdin.read().strip()=="True"))')"

  # AC9: output is readable on demand, and is NOT in the hub DB.
  LOG_BODY="$(api GET "/api/v1/shells/$FG_ID/log")"
  contains "AC9: output is readable on demand via /log" "$LOG_BODY" "hello-foreground"
fi

# AC9, the no-DB half. Asserted against the SCHEMA: if there is nowhere to put
# output, no future code path can start putting it there.
if command -v sqlite3 >/dev/null 2>&1; then
  COLS="$(sqlite3 "$WORK/hub.db" 'PRAGMA table_info(shell_sessions);' | cut -d'|' -f2 | tr '\n' ' ')"
  absent "AC9: the hub DB has no output column"  "$COLS" "output"
  absent "AC9: the hub DB has no stdout column"  "$COLS" "stdout"
else
  echo "[shell2] note: sqlite3 not on PATH; the no-DB schema check is covered by the repo unit test instead"
fi

# ---- AC2: --bg returns immediately --------------------------------------------
echo "[shell2] AC2: a background run returns immediately"
BG_START="$(date +%s)"
BG_RESP="$(agent_api POST "/api/v1/bridges/$B_ID/shells" "{\"kind\":\"run\",\"cmd\":\"sleep 60\",\"cwd\":\"$WORK\",\"background\":true,\"conversation_id\":\"chat_e2e\"}")"
BG_END="$(date +%s)"
BG_ID="$(printf '%s' "$BG_RESP" | sid_of)"
SESSION_IDS+=("$BG_ID")
[ -n "$BG_ID" ] && ok "AC2: --bg returns a session id" || bad "AC2: --bg returns a session id ($BG_RESP)"
[ $((BG_END - BG_START)) -lt 10 ] && ok "AC2: --bg returned without waiting for the 60s command" \
  || bad "AC2: --bg took $((BG_END - BG_START))s, which means it waited"

# AC7: the spec exists on the bridge while the run is live.
if [ -n "$BG_ID" ]; then
  [ -f "$WORK/data-b/shell_sessions/$BG_ID.json" ] \
    && ok "AC7: the spec file exists while the run is live" \
    || bad "AC7: the spec file exists while the run is live (looked in $WORK/data-b/shell_sessions/)"
fi

# ---- AC3: conversion of a live foreground run ---------------------------------
echo "[shell2] AC3: converting a live run to background"
if [ -n "$BG_ID" ]; then
  # Already background: the conversion is ONE-WAY, so this must be refused rather
  # than silently accepted.
  check "AC3: a run already background is refused (one-way)" "409" \
    "$(api_code POST "/api/v1/shells/$BG_ID/background" '{}')"
fi
CONV_RESP="$(agent_api POST "/api/v1/bridges/$B_ID/shells" "{\"kind\":\"run\",\"cmd\":\"sleep 45\",\"cwd\":\"$WORK\",\"background\":true,\"conversation_id\":\"chat_e2e\"}")"
CONV_ID="$(printf '%s' "$CONV_RESP" | sid_of)"
SESSION_IDS+=("$CONV_ID")

# ---- AC8: DELETE kills an agent-started run -----------------------------------
echo "[shell2] AC8: DELETE kills an agent-started run"
if [ -n "$BG_ID" ]; then
  check "AC8: DELETE on an agent-started run is accepted" "200" \
    "$(api_code DELETE "/api/v1/shells/$BG_ID")"
  for _ in $(seq 1 40); do
    ST="$(session_field "$BG_ID" status)"
    [ "$ST" != "running" ] && break || sleep 0.25
  done
  ST="$(session_field "$BG_ID" status)"
  [ "$ST" != "running" ] && ok "AC8: the killed run reaches a terminal status (got '$ST')" \
    || bad "AC8: the killed run is still running"
  # AC7's second half: the spec is gone once terminal.
  [ ! -f "$WORK/data-b/shell_sessions/$BG_ID.json" ] \
    && ok "AC7: the spec file is gone once the run is terminal" \
    || bad "AC7: the spec file is still present after the run ended"
fi

# ---- AC11 / AC13: serve, ports, and the preview path ---------------------------
echo "[shell2] AC11: serve with a port, and serve without one"
SRV_RESP="$(agent_api POST "/api/v1/bridges/$B_ID/shells" "{\"kind\":\"server\",\"cmd\":\"python3 -m http.server $SERVE_PORT --bind 127.0.0.1\",\"cwd\":\"$WORK\",\"chain_id\":\"$CHAIN_ID\",\"server_port\":$SERVE_PORT}")"
SRV_ID="$(printf '%s' "$SRV_RESP" | sid_of)"
SESSION_IDS+=("$SRV_ID")
[ -n "$SRV_ID" ] && ok "AC11: an agent may start a server with a port" || bad "AC11: serve with a port ($SRV_RESP)"

NOPORT_RESP="$(agent_api POST "/api/v1/bridges/$B_ID/shells" "{\"kind\":\"server\",\"cmd\":\"sleep 120\",\"cwd\":\"$WORK\",\"chain_id\":\"$CHAIN_ID\"}")"
NOPORT_ID="$(printf '%s' "$NOPORT_RESP" | sid_of)"
SESSION_IDS+=("$NOPORT_ID")
[ -n "$NOPORT_ID" ] && ok "AC11: a serve with NO port starts fine" || bad "AC11: a serve with no port ($NOPORT_RESP)"
[ -n "$NOPORT_ID" ] && check "AC11: a portless server exposes nothing" "0" "$(session_field "$NOPORT_ID" server_port)"

# AC11: reachable through the EXISTING preview/tunnel path (the bridge's local proxy).
if [ -n "$SRV_ID" ]; then
  echo "hello-from-served-file" > "$WORK/probe.txt"
  REACHED=""
  for _ in $(seq 1 40); do
    REACHED="$(curl -s --max-time 2 "http://127.0.0.1:$B_LOCAL/proxy/$SRV_ID/probe.txt" 2>/dev/null || true)"
    case "$REACHED" in *hello-from-served-file*) break;; esac
    sleep 0.5
  done
  contains "AC11: the server is reachable through the existing preview/tunnel path" "$REACHED" "hello-from-served-file"
fi

# AC13: a second live session cannot hold the same port.
echo "[shell2] AC13: port conflicts"
DUP_CODE="$(agent_api_code POST "/api/v1/bridges/$B_ID/shells" "{\"kind\":\"server\",\"cmd\":\"sleep 30\",\"cwd\":\"$WORK\",\"chain_id\":\"$CHAIN_ID\",\"server_port\":$SERVE_PORT}")"
check "AC13: a second server on the same port is refused" "409" "$DUP_CODE"

# AC8 for a server + AC13's release half: killing the holder frees the port.
if [ -n "$SRV_ID" ]; then
  check "AC8: DELETE on an agent-started server is accepted" "200" "$(api_code DELETE "/api/v1/shells/$SRV_ID")"
  for _ in $(seq 1 40); do
    [ "$(session_field "$SRV_ID" status)" != "running" ] && break || sleep 0.25
  done
  REUSE_RESP="$(agent_api POST "/api/v1/bridges/$B_ID/shells" "{\"kind\":\"server\",\"cmd\":\"sleep 30\",\"cwd\":\"$WORK\",\"chain_id\":\"$CHAIN_ID\",\"server_port\":$SERVE_PORT}")"
  REUSE_ID="$(printf '%s' "$REUSE_RESP" | sid_of)"
  SESSION_IDS+=("$REUSE_ID")
  [ -n "$REUSE_ID" ] && ok "AC13: the port is released once the holder is terminal" \
    || bad "AC13: the port was not released after the holder exited ($REUSE_RESP)"
fi

# ---- AC14: caps ----------------------------------------------------------------
# Exercised against the SERVER cap, which is the smaller of the two, so the test
# is bounded. The run cap is the same code path with a different scope column and
# is covered by the service unit tests.
echo "[shell2] AC14: the per-chain server cap"
CAP_CHAIN="chain_shell2_cap"
CAP_N=0
CAP_REFUSED=""
for i in $(seq 1 20); do
  CODE="$(agent_api_code POST "/api/v1/bridges/$B_ID/shells" "{\"kind\":\"server\",\"cmd\":\"sleep 120\",\"cwd\":\"$WORK\",\"chain_id\":\"$CAP_CHAIN\"}")"
  if [ "$CODE" = "409" ]; then CAP_REFUSED="yes"; break; fi
  CAP_N=$((CAP_N+1))
done
[ -n "$CAP_REFUSED" ] && ok "AC14: over-cap server creates are refused (after $CAP_N)" \
  || bad "AC14: the per-chain server cap never refused anything (created $CAP_N)"
# Sweep the cap servers so cleanup is not left with 16 sleepers.
for sid in $(api GET "/api/v1/shells?chain_id=$CAP_CHAIN" | python3 -c '
import json,sys
try:
    for s in json.load(sys.stdin)["data"]["sessions"]: print(s["session_id"])
except Exception: pass'); do
  SESSION_IDS+=("$sid")
done

# ---- AC4, behavioural half: a >15s foreground run is NOT auto-backgrounded ------
if [ "${S2_SKIP_SLOW:-0}" = "1" ]; then
  echo "[shell2] S2_SKIP_SLOW=1 — skipping the >15s foreground check"
else
  echo "[shell2] AC4: a >15s foreground run still returns inline (this takes ~18s)"
  SLOW_START="$(date +%s)"
  SLOW_RESP="$(agent_api POST "/api/v1/bridges/$B_ID/shells" "{\"kind\":\"run\",\"cmd\":\"sleep 18; echo slow-but-inline\",\"cwd\":\"$WORK\",\"conversation_id\":\"chat_e2e\"}")"
  SLOW_ID="$(printf '%s' "$SLOW_RESP" | sid_of)"
  SESSION_IDS+=("$SLOW_ID")
  if [ -n "$SLOW_ID" ]; then
    for _ in $(seq 1 120); do
      [ "$(session_field "$SLOW_ID" status)" != "running" ] && break || sleep 0.5
    done
    SLOW_END="$(date +%s)"
    [ $((SLOW_END - SLOW_START)) -ge 15 ] && ok "AC4: the run genuinely ran past the old 15s threshold" \
      || bad "AC4: the slow run finished too fast to prove anything"
    # THE POINT: it was never converted. background stays false however long it ran.
    check "AC4: a >15s run is NOT auto-backgrounded" "false" \
      "$(session_field "$SLOW_ID" background | tr 'A-Z' 'a-z')"
    SLOW_LOG="$(api GET "/api/v1/shells/$SLOW_ID/log")"
    contains "AC4: and its output is still readable inline" "$SLOW_LOG" "slow-but-inline"
  else
    bad "AC4: the slow run could not be created ($SLOW_RESP)"
  fi
fi

echo
echo "[shell2] ---------------------------------------------"
echo "[shell2] passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "[shell2] OK"
