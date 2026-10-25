#!/usr/bin/env bash
# REQ-XM-9 end-to-end: declare a server port on an ALREADY-RUNNING session.
#
# This is the workflow the feature exists for, and the test performs it literally
# rather than approximating it:
#
#   1. open an INTERACTIVE session with no port — as a person does, not knowing yet
#      that they are about to start a server
#   2. TYPE a server into it through the input endpoint (not baked into cmd: a cmd
#      would be a server session wearing an interactive label)
#   3. declare the port after the fact with POST /api/v1/shells/<id>/port
#   4. reach it on BOTH access paths without restarting anything
#
# It also proves the part that is easy to fake: CHANGING an already-set port routes
# to the NEW port. That only works if the BRIDGE's own copy of the session is
# updated, because the bridge re-validates server_port against that copy when a
# tunnel is opened — a hub-only change would pass step 4 and fail this one.
#
#   client -> bridge A local endpoint -> hub -> bridge B -> the typed-in server
#   browser-equivalent -> hub /api/v1/preview/<id>/ -> bridge B -> same server
#
# Stands up a THROWAWAY stack on its own ports and tears it down again. It never
# touches a stack it did not start: every process it launches is recorded by PID and
# only those PIDs are killed. (Do not "clean up" by pattern-matching command lines on
# a shared host — that takes down other people's stacks.)
#
# Usage:
#   tests/e2e_xm9_set_port_test.sh
#
# Point it somewhere else with env vars (all optional):
#   XM9_HUB_PORT       hub listen port                  (default 8491)
#   XM9_PROXY_PORT     dev-proxy port (auth injection)  (default 8490)
#   XM9_BRIDGE_A_PORT  bridge A service port            (default 49825)
#   XM9_BRIDGE_A_LOCAL bridge A LOCAL ENDPOINT port     (default 49826) <- client target
#   XM9_BRIDGE_B_PORT  bridge B service port            (default 49827)
#   XM9_BRIDGE_B_LOCAL bridge B local endpoint port     (default 49828)
#   XM9_PORT_ONE       first server port on bridge B    (default 45301)
#   XM9_PORT_TWO       second server port on bridge B   (default 45302)
#   XM9_KEEP=1         leave the stack running afterwards
#   ODIN               odin binary (default: odin on PATH, via nix develop)
#
# Requires: a working odin toolchain (the repo's nix dev shell provides one) and
# python3. Exits 0 only if every check below passes.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

HUB_PORT="${XM9_HUB_PORT:-8491}"
PROXY_PORT="${XM9_PROXY_PORT:-8490}"
A_PORT="${XM9_BRIDGE_A_PORT:-49825}"
A_LOCAL="${XM9_BRIDGE_A_LOCAL:-49826}"
B_PORT="${XM9_BRIDGE_B_PORT:-49827}"
B_LOCAL="${XM9_BRIDGE_B_LOCAL:-49828}"
PORT_ONE="${XM9_PORT_ONE:-45301}"
PORT_TWO="${XM9_PORT_TWO:-45302}"

SESSION_ID=""
WORK="$(mktemp -d -t xm9-setport-XXXX)"
BIN="$WORK/bin"; mkdir -p "$BIN" "$WORK/run-a" "$WORK/run-b" "$WORK/logs" "$WORK/site-one" "$WORK/site-two"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "[xm9] PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "[xm9] FAIL  $1"; }
check(){ # $1=description $2=expected $3=actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

# Only these PIDs are ever killed. NEVER clean up by pattern-matching command lines
# on a shared host: a substring like a username or a flag value is shared by every
# stack on the box, and matching it takes down other people's work.
PIDS=()
# shellcheck source=../scripts/lib/hub-oidc-dev.sh
. "$ROOT/scripts/lib/hub-oidc-dev.sh"
# Browser-session auth for requests through the dev-proxy (filled after sign-in).
AUTH=()
pcurl() { curl "${AUTH[@]}" "$@"; }

cleanup() {
  if [ "${XM9_KEEP:-0}" = "1" ]; then
    echo "[xm9] XM9_KEEP=1 — leaving stack up. Work dir: $WORK  session: ${SESSION_ID:-<none>}"
    return
  fi
  # Kill the session FIRST, through the hub, while the stack is still alive: the
  # servers typed into it are GRANDCHILDREN (bridge B's pty-host spawned the shell,
  # the shell spawned python), so they are not in PIDS and killing the bridge alone
  # orphans them — leaving the ports bound and failing the next run's precheck.
  if [ -n "${SESSION_ID:-}" ]; then
    pcurl -s -X DELETE "http://127.0.0.1:$PROXY_PORT/api/v1/shells/$SESSION_ID" >/dev/null 2>&1 || true
    sleep 1
  fi
  for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null || true; done
  sleep 1
  # The per-bridge pty-host daemons are also grandchildren. Match them on THIS RUN'S
  # work dir, which no other stack can share — never on the binary name alone.
  for pid in $(pgrep -f "pty-host.*$WORK" 2>/dev/null || true); do kill "$pid" 2>/dev/null || true; done
  # Last resort for the typed-in servers. They are BACKGROUNDED inside the shell, so
  # killing the session's foreground does not take them with it, and their command line
  # does NOT contain $WORK — the cd is a separate word, so a $WORK match finds nothing.
  # Match "http.server <this run's port>", which is specific to this run's port block;
  # never "http.server" alone, which would kill other people's servers on this host.
  for p in "$PORT_ONE" "$PORT_TWO"; do
    for pid in $(pgrep -f "http.server $p " 2>/dev/null || true); do kill "$pid" 2>/dev/null || true; done
  done
  sleep 1
  rm -rf "$WORK"
  hub_oidc_stop_mock
}
trap cleanup EXIT

port_busy() { ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$1\$"; }
for p in "$HUB_PORT" "$PROXY_PORT" "$A_PORT" "$A_LOCAL" "$B_PORT" "$B_LOCAL" "$PORT_ONE" "$PORT_TWO"; do
  if port_busy "$p"; then
    echo "[xm9] FAIL: port $p is already in use. Override the XM9_* env vars to pick a free block." >&2
    exit 1
  fi
done

# Two different bodies, so "which port am I talking to" is answered by the CONTENT
# and not by whether anything answered at all.
echo "SERVER-ONE" > "$WORK/site-one/index.html"
echo "SERVER-TWO" > "$WORK/site-two/index.html"

echo "[xm9] building hub, bridge and dev-proxy"
ODIN_BIN="${ODIN:-odin}"
if command -v "$ODIN_BIN" >/dev/null 2>&1; then
  "$ODIN_BIN" build src/hub    -collection:odin_test=src -out:"$BIN/hub"
  "$ODIN_BIN" build src/bridge -collection:odin_test=src -out:"$BIN/bridge"
  "$ODIN_BIN" build src/dev_proxy -collection:odin_test=src -out:"$BIN/devproxy"
else
  # The hub links against sqlite3, which is only on the search path inside the dev shell.
  nix develop "$ROOT" --command bash -c "cd '$ROOT' && odin build src/hub -collection:odin_test=src -out:'$BIN/hub' && odin build src/bridge -collection:odin_test=src -out:'$BIN/bridge' && odin build src/dev_proxy -collection:odin_test=src -out:'$BIN/devproxy'"
fi

echo "[xm9] starting hub on 127.0.0.1:$HUB_PORT"
hub_oidc_start_mock "$WORK" tanmay
hub_oidc_export_env
"$BIN/hub" --listen "127.0.0.1:$HUB_PORT" --db "$WORK/hub.db" --ui-origin "http://127.0.0.1:$PROXY_PORT" \
  > "$WORK/logs/hub.log" 2>&1 & PIDS+=($!)

echo "[xm9] starting dev-proxy on 127.0.0.1:$PROXY_PORT (forwards the browser session; sign-in via mock OIDC)"
"$BIN/devproxy" --listen "127.0.0.1:$PROXY_PORT" --hub-url "http://127.0.0.1:$HUB_PORT" --default-user tanmay \
  > "$WORK/logs/devproxy.log" 2>&1 & PIDS+=($!)

for _ in $(seq 1 40); do
  curl -sf -o /dev/null "http://127.0.0.1:$PROXY_PORT/api/v1/health" && break || sleep 0.25
done

# Sign in as tanmay through the dev-proxy: real OIDC flow against the mock provider.
SESSION="$(hub_oidc_login "http://127.0.0.1:$PROXY_PORT" tanmay)" || { echo "[xm9] FAIL: OIDC sign-in failed"; exit 1; }
AUTH=(-H "$(hub_oidc_cookie "$SESSION")" -H "Origin: http://127.0.0.1:$PROXY_PORT")

api() { pcurl -s -X "$1" "http://127.0.0.1:$PROXY_PORT$2" -H 'Content-Type: application/json' ${3:+-d "$3"}; }

enroll() { # $1=label $2=token file -> writes the ACCESS token to $2
  # ===== BROWSER-APPROVED DEVICE FLOW (REQ-ENROLL-9) =====
  #
  # This replaced "mint a one-time enrollment token, then exchange it at
  # POST /api/v1/bridges/enroll". Both endpoints are deleted and 404 now, and
  # `bridge enroll --hub --enrollment-token` is gone with them.
  #
  # It drives the three HTTP steps directly rather than shelling out to
  # `bridge enroll --hub`, because that command waits for an approval and would
  # need backgrounding plus output scraping. Here the script IS the approver:
  # these suites talk through the dev-proxy, which authenticates every request
  # as the local user, so the approval is a real authenticated one.
  #
  # Three things that are hard refusals, not warnings:
  #   - bridge_public_key must be a 130-char lowercase-hex uncompressed P-256 point
  #   - do NOT send bridge_key_fingerprint; the Hub derives it and rejects a
  #     body-supplied one that disagrees
  #   - PKCE is mandatory and S256-only; the pair below is precomputed
  local authz user_code device_code tok
  authz="$(api POST /api/v1/device/authorize "{\"client\":\"ham-bridge\",\"device_label\":\"$1\",\"os\":\"linux\",\"os_user\":\"tester\",\"bridge_public_key\":\"040102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40\",\"code_challenge\":\"J6jJRRlTiLmCVJAjMgzOjMLRQ-xSS_tovxAjutN8JWI\",\"code_challenge_method\":\"S256\"}")"
  user_code="$(printf '%s' "$authz" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["user_code"])')"
  device_code="$(printf '%s' "$authz" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["device_code"])')"
  api POST /api/v1/device/approve "{\"user_code\":\"$user_code\",\"approve\":true}" >/dev/null
  # The access token is the credential; the refresh half goes beside it under
  # the ".refresh" suffix the bridge itself uses, so a bridge started with
  # --bridge-token-file "$2" can renew rather than dying after an hour.
  tok="$(api POST /api/v1/device/token "{\"device_code\":\"$device_code\",\"code_verifier\":\"heimdall-req-impl-6-test-code-verifier-aaaa\"}")"
  printf '%s' "$tok" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["access_token"])' > "$2"
  printf '%s' "$tok" | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(d.get("refresh_token",""))' > "$2.refresh"
  chmod 600 "$2" "$2.refresh"
}

echo "[xm9] enrolling bridge A (originating) and bridge B (target)"
enroll xm9-setport-A "$WORK/a.token"
enroll xm9-setport-B "$WORK/b.token"

"$BIN/bridge" --hub "http://127.0.0.1:$HUB_PORT" --bridge-token-file "$WORK/a.token" \
  --port "$A_PORT" --local-endpoint-port "$A_LOCAL" --local-run-dir "$WORK/run-a" \
  > "$WORK/logs/bridge-a.log" 2>&1 & PIDS+=($!)
"$BIN/bridge" --hub "http://127.0.0.1:$HUB_PORT" --bridge-token-file "$WORK/b.token" \
  --port "$B_PORT" --local-endpoint-port "$B_LOCAL" --local-run-dir "$WORK/run-b" \
  > "$WORK/logs/bridge-b.log" 2>&1 & PIDS+=($!)

echo "[xm9] waiting for both bridges to report 'bridge hub runtime ready'"
for _ in $(seq 1 60); do
  if grep -q "runtime ready" "$WORK/logs/bridge-a.log" 2>/dev/null \
  && grep -q "runtime ready" "$WORK/logs/bridge-b.log" 2>/dev/null; then break; fi
  sleep 0.5
done
grep -q "runtime ready" "$WORK/logs/bridge-a.log" || { echo "[xm9] FAIL: bridge A never connected"; exit 1; }
grep -q "runtime ready" "$WORK/logs/bridge-b.log" || { echo "[xm9] FAIL: bridge B never connected"; exit 1; }

B_ID="$(api GET /api/v1/bridges | python3 -c '
import json,sys
for b in json.load(sys.stdin)["data"]:
    if (b.get("name") or "").endswith("setport-B"): print(b["bridge_id"]); break
')"
[ -n "$B_ID" ] || B_ID="$(api GET /api/v1/bridges | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][-1]["bridge_id"])')"
echo "[xm9] bridge B = $B_ID"

# ---- 1. an INTERACTIVE session with NO port -------------------------------------
echo "[xm9] opening an interactive session on bridge B with NO port declared"
SESSION_ID="$(api POST "/api/v1/bridges/$B_ID/shells" \
  "{\"kind\":\"shell\",\"cwd\":\"$WORK\",\"label\":\"xm9-terminal\"}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["session"]["session_id"])')"
echo "[xm9] session = $SESSION_ID"
[ -n "$SESSION_ID" ] || { echo "[xm9] FAIL: no session id"; exit 1; }

declared_port() {
  api GET "/api/v1/shells/$SESSION_ID" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["session"]["server_port"])'
}
check "a session started without a port has server_port=0" "0" "$(declared_port)"

# ---- 2. TYPE a server into it ---------------------------------------------------
type_into_session() { # $1 = line to type
  api POST "/api/v1/shells/$SESSION_ID/input" \
    "$(python3 -c 'import json,sys; print(json.dumps({"data": sys.argv[1] + "\n"}))' "$1")" >/dev/null
}
wait_for_local_port() { # $1 = port
  for _ in $(seq 1 60); do curl -sf -o /dev/null "http://127.0.0.1:$1/index.html" && return 0 || sleep 0.25; done
  return 1
}

echo "[xm9] typing a server into the running terminal (port $PORT_ONE)"
# Backgrounded with & so the prompt returns and a SECOND server can be typed in later.
# Both then run at once, which is what makes the repoint check below strict: the only
# thing deciding which one answers is the declared port, not which one is alive.
type_into_session "cd $WORK/site-one && python3 -m http.server $PORT_ONE --bind 127.0.0.1 &"
wait_for_local_port "$PORT_ONE" || { echo "[xm9] FAIL: the typed-in server never came up"; exit 1; }
ok "a server typed into a running interactive session is listening on $PORT_ONE"

# ---- the two access paths -------------------------------------------------------
# Hub preview URL: what a browser tab loads.
preview_body() { pcurl -s "http://127.0.0.1:$PROXY_PORT/api/v1/preview/$SESSION_ID/index.html"; }
preview_status() { pcurl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PROXY_PORT/api/v1/preview/$SESSION_ID/index.html"; }
# Bridge proxy URL: what a process on bridge A's host reaches, with no user token.
proxy_body() { curl -s --max-time 20 "http://127.0.0.1:$A_LOCAL/proxy/$SESSION_ID/index.html"; }
proxy_status() { curl -s --max-time 20 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$A_LOCAL/proxy/$SESSION_ID/index.html"; }

echo "[xm9] before set-port: both paths must still refuse"
check "hub preview refuses a portless session (409)" "409" "$(preview_status)"
check "bridge proxy refuses a portless session (409)" "409" "$(proxy_status)"
check "bridge proxy names the reason" "no_server_port" \
  "$(proxy_body | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("error",""))
except Exception: print("<unparseable>")')"

# ---- 3. declare the port AFTER the fact -----------------------------------------
set_port() { # $1 = port; echoes the HTTP status, logs status+body for diagnosis
  local code
  code="$(pcurl -s -o "$WORK/setport.out" -w '%{http_code}' -X POST \
    "http://127.0.0.1:$PROXY_PORT/api/v1/shells/$SESSION_ID/port" \
    -H 'Content-Type: application/json' -d "{\"server_port\":$1}")"
  # The body on stderr, always: a bare status code turns every refusal into the same
  # failure, and the reason is the whole point of a refusal.
  echo "[xm9]   set-port($1) -> $code $(tr -d '\n' < "$WORK/setport.out")" >&2
  echo "$code"
}

echo "[xm9] declaring port $PORT_ONE on the already-running session"
check "set-port on a running session succeeds" "200" "$(set_port "$PORT_ONE")"
check "the session now reports the declared port" "$PORT_ONE" "$(declared_port)"

# ---- 4. THE ACCEPTANCE CASE -----------------------------------------------------
echo "[xm9] ===== acceptance: reachable on BOTH paths, with no restart ====="
check "hub preview URL reaches the server" "SERVER-ONE" "$(preview_body | tr -d '\r\n')"
check "bridge proxy URL reaches the server" "SERVER-ONE" "$(proxy_body | tr -d '\r\n')"

# ---- 5. CHANGING the port takes effect (no stale bridge-side copy) --------------
echo "[xm9] starting a SECOND server in the same session on $PORT_TWO, then repointing"
type_into_session "cd $WORK/site-two && python3 -m http.server $PORT_TWO --bind 127.0.0.1 &"
wait_for_local_port "$PORT_TWO" || { echo "[xm9] FAIL: the second server never came up"; exit 1; }

check "set-port to a different port succeeds" "200" "$(set_port "$PORT_TWO")"
check "the session reports the NEW port" "$PORT_TWO" "$(declared_port)"
check "the first server is still listening (so the routing choice is the port)" "SERVER-ONE" \
  "$(curl -s "http://127.0.0.1:$PORT_ONE/index.html" | tr -d '\r\n')"
check "hub preview URL now reaches the NEW server" "SERVER-TWO" "$(preview_body | tr -d '\r\n')"
check "bridge proxy URL now reaches the NEW server" "SERVER-TWO" "$(proxy_body | tr -d '\r\n')"

# ---- 6. clearing makes it unreachable again -------------------------------------
echo "[xm9] clearing the port"
check "clearing the port succeeds" "200" "$(set_port 0)"
check "the session reports no port" "0" "$(declared_port)"
check "hub preview refuses again (409)" "409" "$(preview_status)"
check "bridge proxy refuses again (409)" "409" "$(proxy_status)"
check "and names the same reason as before" "no_server_port" \
  "$(proxy_body | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("error",""))
except Exception: print("<unparseable>")')"

# ---- 7. validation --------------------------------------------------------------
check "a port above 65535 is refused (400)" "400" "$(set_port 70000)"
check "a negative port is refused (400)" "400" "$(set_port -1)"
check "a body with no server_port is refused (400)" "400" \
  "$(pcurl -s -o /dev/null -w '%{http_code}' -X POST \
     "http://127.0.0.1:$PROXY_PORT/api/v1/shells/$SESSION_ID/port" \
     -H 'Content-Type: application/json' -d '{}')"

# ---- 8. ownership ---------------------------------------------------------------
# Straight at the hub with a DIFFERENT user's real browser session (mallory signs
# in through the same OIDC flow), so this is a genuine second user.
echo "[xm9] cross-owner attempt"
MALLORY="$(hub_oidc_login "http://127.0.0.1:$PROXY_PORT" mallory)"
check "another user cannot set a port on this session (404)" "404" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     "http://127.0.0.1:$HUB_PORT/api/v1/shells/$SESSION_ID/port" \
     -H "$(hub_oidc_cookie "$MALLORY")" -H "Origin: http://127.0.0.1:$PROXY_PORT" -H 'Content-Type: application/json' \
     -d "{\"server_port\":$PORT_TWO}")"
check "and the session's port is untouched" "0" "$(declared_port)"

# ---- 9. exited session ----------------------------------------------------------
echo "[xm9] killing the session, then trying to set a port on it"
pcurl -s -X DELETE "http://127.0.0.1:$PROXY_PORT/api/v1/shells/$SESSION_ID" >/dev/null
for _ in $(seq 1 40); do
  st="$(api GET "/api/v1/shells/$SESSION_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["session"]["status"])')"
  [ "$st" = "running" ] || break
  sleep 0.5
done
check "the session is no longer running" "1" "$([ "$st" = "running" ] && echo 0 || echo 1)"
check "set-port on an exited session is refused (409)" "409" "$(set_port "$PORT_ONE")"

echo
echo "[xm9] ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || { echo "[xm9] FAIL"; exit 1; }
echo "[xm9] PASS — a port declared on an already-running session is honoured end to end"
