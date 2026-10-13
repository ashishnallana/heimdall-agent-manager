#!/usr/bin/env bash
# REQ-SHELL-1 end-to-end: create a session of EACH of the three kinds over the
# REST API, against a real hub + a real bridge, and prove the per-kind scope rules
# are enforced server-side rather than only in the UI.
#
# What this covers that the unit tests cannot: the whole path. A kind string
# travels handler -> service validation -> sqlite row -> shell_start frame ->
# bridge spawn -> status back on the row. A rename or a scope rule that is right
# in the domain and wrong on the wire fails here and nowhere else.
#
#   1. run    — agent scoped: created WITH an agent_instance_id, rejected without
#   2. shell  — bridge scoped: created bare, rejected when handed a chain_id
#   3. server — chain+bridge scoped: created with a chain_id, rejected without
#   4. the retired vocabulary (command / interactive / agent) is refused, not aliased
#   5. a by-chain listing returns the server and NOT the agent-scoped run
#
# Stands up a THROWAWAY stack on its own ports and tears it down again. It never
# touches a stack it did not start: every process it launches is recorded by PID
# and only those PIDs are killed. (Do not "clean up" by pattern-matching command
# lines on a shared host — that takes down other people's stacks.)
#
# Usage:
#   tests/e2e_shell1_three_kinds_test.sh
#
# Env (all optional):
#   S1_HUB_PORT     hub listen port                 (default 8493)
#   S1_PROXY_PORT   dev-proxy port (auth injection) (default 8492)
#   S1_BRIDGE_PORT  bridge service port             (default 49831)
#   S1_BRIDGE_LOCAL bridge local endpoint port      (default 49832)
#   S1_KEEP=1       leave the stack running afterwards
#   ODIN            odin binary (default: odin on PATH, else via nix develop)
#
# Requires a working odin toolchain (the repo's nix dev shell provides one),
# python3 and curl. Exits 0 only if every check below passes.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

HUB_PORT="${S1_HUB_PORT:-8493}"
PROXY_PORT="${S1_PROXY_PORT:-8492}"
B_PORT="${S1_BRIDGE_PORT:-49831}"
B_LOCAL="${S1_BRIDGE_LOCAL:-49832}"

WORK="$(mktemp -d -t shell1-kinds-XXXX)"
BIN="$WORK/bin"; mkdir -p "$BIN" "$WORK/run-b" "$WORK/logs"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "[shell1] PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "[shell1] FAIL  $1"; }
check(){ # $1=description $2=expected $3=actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

SESSION_IDS=()
PIDS=()
cleanup() {
  if [ "${S1_KEEP:-0}" = "1" ]; then
    echo "[shell1] S1_KEEP=1 — leaving stack up. Work dir: $WORK"
    return
  fi
  # Kill the sessions through the hub FIRST, while the stack is still alive: the
  # spawned processes are grandchildren of the bridge's pty-host and are not in PIDS.
  for sid in "${SESSION_IDS[@]:-}"; do
    [ -n "$sid" ] && curl -s -X DELETE "http://127.0.0.1:$PROXY_PORT/api/v1/shells/$sid" >/dev/null 2>&1 || true
  done
  sleep 1
  for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null || true; done
  sleep 1
  # The pty-host daemon is a grandchild too. Match it on THIS RUN'S work dir, which
  # no other stack can share — never on the binary name alone.
  for pid in $(pgrep -f "pty-host.*$WORK" 2>/dev/null || true); do kill "$pid" 2>/dev/null || true; done
  sleep 1
  rm -rf "$WORK"
}
trap cleanup EXIT

port_busy() { ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$1\$"; }
for p in "$HUB_PORT" "$PROXY_PORT" "$B_PORT" "$B_LOCAL"; do
  if port_busy "$p"; then
    echo "[shell1] FAIL: port $p is already in use. Override the S1_* env vars to pick a free block." >&2
    exit 1
  fi
done

echo "[shell1] building hub, bridge and dev-proxy"
ODIN_BIN="${ODIN:-odin}"
if command -v "$ODIN_BIN" >/dev/null 2>&1; then
  "$ODIN_BIN" build src/hub       -collection:odin_test=src -out:"$BIN/hub"
  "$ODIN_BIN" build src/bridge    -collection:odin_test=src -out:"$BIN/bridge"
  "$ODIN_BIN" build src/dev_proxy -collection:odin_test=src -out:"$BIN/devproxy"
else
  # The hub links against sqlite3, which is only on the search path inside the dev shell.
  nix develop "$ROOT" --command bash -c "cd '$ROOT' && odin build src/hub -collection:odin_test=src -out:'$BIN/hub' && odin build src/bridge -collection:odin_test=src -out:'$BIN/bridge' && odin build src/dev_proxy -collection:odin_test=src -out:'$BIN/devproxy'"
fi

echo "[shell1] starting hub on 127.0.0.1:$HUB_PORT"
"$BIN/hub" --listen "127.0.0.1:$HUB_PORT" --db "$WORK/hub.db" --trusted-proxy-cidr 127.0.0.1/32 \
  > "$WORK/logs/hub.log" 2>&1 & PIDS+=($!)

echo "[shell1] starting dev-proxy on 127.0.0.1:$PROXY_PORT (injects the authenticated user)"
"$BIN/devproxy" --listen "127.0.0.1:$PROXY_PORT" --hub-url "http://127.0.0.1:$HUB_PORT" --default-user tanmay \
  > "$WORK/logs/devproxy.log" 2>&1 & PIDS+=($!)

echo "[shell1] waiting for the hub to answer through the proxy"
for _ in $(seq 1 120); do
  curl -sf -o /dev/null "http://127.0.0.1:$PROXY_PORT/api/v1/projects" && break || sleep 0.25
done
curl -sf -o /dev/null "http://127.0.0.1:$PROXY_PORT/api/v1/projects" || {
  echo "[shell1] FAIL: hub/proxy never came up. Logs follow."
  echo "--- hub.log ---";      tail -30 "$WORK/logs/hub.log"      2>/dev/null
  echo "--- devproxy.log ---"; tail -30 "$WORK/logs/devproxy.log" 2>/dev/null
  exit 1
}

api() { curl -s -X "$1" "http://127.0.0.1:$PROXY_PORT$2" -H 'Content-Type: application/json' ${3:+-d "$3"}; }
# api_code returns the HTTP status alone, for the rejection checks.
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
AUTHZ_RESP="$(api POST /api/v1/device/authorize '{"client":"ham-bridge","device_label":"shell1-kinds","os":"linux","os_user":"tester","bridge_public_key":"040102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40","code_challenge":"J6jJRRlTiLmCVJAjMgzOjMLRQ-xSS_tovxAjutN8JWI","code_challenge_method":"S256"}')"
USER_CODE="$(printf '%s' "$AUTHZ_RESP" | python3 -c '
import json,sys
try: print(json.load(sys.stdin)["data"]["user_code"])
except Exception: print("")')"
DEVICE_CODE="$(printf '%s' "$AUTHZ_RESP" | python3 -c '
import json,sys
try: print(json.load(sys.stdin)["data"]["device_code"])
except Exception: print("")')"
[ -n "$USER_CODE" ] || { echo "[shell1] FAIL: device authorize returned no user_code. Response: $AUTHZ_RESP"; tail -30 "$WORK/logs/hub.log"; exit 1; }
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
[ -s "$WORK/b.token" ] || { echo "[shell1] FAIL: device flow issued no access token. Response: $TOKEN_RESP"; tail -30 "$WORK/logs/hub.log"; exit 1; }

"$BIN/bridge" --hub "http://127.0.0.1:$HUB_PORT" --bridge-token-file "$WORK/b.token" \
  --port "$B_PORT" --local-endpoint-port "$B_LOCAL" --local-run-dir "$WORK/run-b" \
  > "$WORK/logs/bridge.log" 2>&1 & PIDS+=($!)

echo "[shell1] waiting for the bridge to report 'runtime ready'"
for _ in $(seq 1 60); do
  grep -q "runtime ready" "$WORK/logs/bridge.log" 2>/dev/null && break || sleep 0.5
done
grep -q "runtime ready" "$WORK/logs/bridge.log" || { echo "[shell1] FAIL: bridge never connected"; exit 1; }

B_ID="$(api GET /api/v1/bridges | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][-1]["bridge_id"])')"
B_TOKEN="$(cat "$WORK/b.token")"
echo "[shell1] bridge = $B_ID"

CHAIN_ID="chain_shell1_e2e"

# REQ-SHELL-2 UPDATE: `run` became AGENT-ONLY, enforced at the API. This script
# creates a run to prove its SCOPE rules, so it now needs a real agent identity —
# a user-authenticated create of kind=run is refused with 403 before scope is ever
# reached, which would make every run assertion below fail for the wrong reason.
#
# The agent instance is created through the user API, then acted for with the
# bridge bearer plus the instance assertion header, which is exactly how the
# bridge relays an agent's own REST call.
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
AGENT_IID="inst_shell1_e2e"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "[shell1] FAIL: sqlite3 is required to seed the agent identity the run tests act as."
  exit 1
fi
sqlite3 "$WORK/hub.db" "INSERT INTO agent_instances
  (agent_instance_id, owner_user_id, agent_id, bridge_id, runtime_status, created_at, updated_at, last_seen_at)
  VALUES ('$AGENT_IID','tanmay','agt_shell1_e2e','$B_ID','running','$NOW','$NOW','$NOW');"
echo "[shell1] agent instance = $AGENT_IID (seeded)"

agent_api()      { curl -s -X "$1" "http://127.0.0.1:$HUB_PORT$2" -H 'Content-Type: application/json' \
                     -H "Authorization: Bearer $B_TOKEN" -H "X-Heimdall-Instance-Token: hit_$AGENT_IID" ${3:+-d "$3"}; }
agent_api_code() { curl -s -o /dev/null -w '%{http_code}' -X "$1" "http://127.0.0.1:$HUB_PORT$2" -H 'Content-Type: application/json' \
                     -H "Authorization: Bearer $B_TOKEN" -H "X-Heimdall-Instance-Token: hit_$AGENT_IID" ${3:+-d "$3"}; }

create() { # $1 = json body -> prints session_id ("" on failure)
  api POST "/api/v1/bridges/$B_ID/shells" "$1" \
    | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)["data"]["session"]["session_id"])
except Exception:
    print("")'
}
session_field() { # $1 = session_id, $2 = field
  api GET "/api/v1/shells/$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["session"][sys.argv[1]])' "$2"
}

# ---- 1. each of the three kinds is creatable, scoped per its own rule -----------
echo "[shell1] creating one session of each kind"

RUN_ID="$(agent_api POST "/api/v1/bridges/$B_ID/shells" "{\"kind\":\"run\",\"cmd\":\"echo hello-run\",\"cwd\":\"$WORK\"}" \
  | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)["data"]["session"]["session_id"])
except Exception:
    print("")')"
SESSION_IDS+=("$RUN_ID")
[ -n "$RUN_ID" ] && ok "run created over REST" || bad "run created over REST"

SHELL_ID="$(create "{\"kind\":\"shell\",\"cwd\":\"$WORK\",\"label\":\"shell1-term\"}")"
SESSION_IDS+=("$SHELL_ID")
[ -n "$SHELL_ID" ] && ok "shell created over REST (no cmd — defaults to \$SHELL)" || bad "shell created over REST"

SERVER_ID="$(create "{\"kind\":\"server\",\"cmd\":\"sleep 300\",\"cwd\":\"$WORK\",\"chain_id\":\"$CHAIN_ID\"}")"
SESSION_IDS+=("$SERVER_ID")
[ -n "$SERVER_ID" ] && ok "server created over REST" || bad "server created over REST"

# The kind round-trips through the DB as the NEW spelling, not a legacy one.
[ -n "$RUN_ID" ]    && check "run row stores kind=run"       "run"    "$(session_field "$RUN_ID" kind)"
[ -n "$SHELL_ID" ]  && check "shell row stores kind=shell"   "shell"  "$(session_field "$SHELL_ID" kind)"
[ -n "$SERVER_ID" ] && check "server row stores kind=server" "server" "$(session_field "$SERVER_ID" kind)"

# The bridge actually spawned each one: status leaves 'starting'.
[ -n "$SHELL_ID" ]  && check "shell reached running"  "running" "$(session_field "$SHELL_ID" status)"
[ -n "$SERVER_ID" ] && check "server reached running" "running" "$(session_field "$SERVER_ID" status)"

# Scope columns are populated per the kind's rule and left EMPTY where unused,
# rather than filled with noise.
[ -n "$RUN_ID" ] && {
  check "run carries its agent_instance_id" "$AGENT_IID" "$(session_field "$RUN_ID" agent_instance_id)"
  check "run leaves chain_id empty"         ""           "$(session_field "$RUN_ID" chain_id)"
}
[ -n "$SHELL_ID" ] && {
  check "shell leaves chain_id empty"          "" "$(session_field "$SHELL_ID" chain_id)"
  check "shell leaves agent_instance_id empty" "" "$(session_field "$SHELL_ID" agent_instance_id)"
}
[ -n "$SERVER_ID" ] && {
  check "server carries its chain_id"            "$CHAIN_ID" "$(session_field "$SERVER_ID" chain_id)"
  check "server leaves agent_instance_id empty"  ""          "$(session_field "$SERVER_ID" agent_instance_id)"
}

# ---- 2. scope is enforced SERVER-SIDE, not just in the UI -----------------------
echo "[shell1] checking the negative cases are rejected by the hub"
# A run with no agent scope. Asserted through an agent identity WITHOUT an
# instance assertion is not possible here (the header is what makes it an agent),
# so this now checks the user path, where REQ-SHELL-2's starter rule refuses first
# with 403. The scope-missing case itself is covered by the service unit test
# test_shell_session_create_rejects_a_kind_missing_its_scope.
check "a run started by a USER is rejected (run is agent-only)" "403" \
  "$(api_code POST "/api/v1/bridges/$B_ID/shells" "{\"kind\":\"run\",\"cmd\":\"echo nope\",\"agent_instance_id\":\"$AGENT_IID\"}")"
check "a server with no chain_id is rejected" "400" \
  "$(api_code POST "/api/v1/bridges/$B_ID/shells" "{\"kind\":\"server\",\"cmd\":\"sleep 1\"}")"
check "a shell carrying an agent_instance_id is rejected" "400" \
  "$(api_code POST "/api/v1/bridges/$B_ID/shells" "{\"kind\":\"shell\",\"agent_instance_id\":\"$AGENT_IID\"}")"
check "a server carrying an agent_instance_id is rejected" "400" \
  "$(api_code POST "/api/v1/bridges/$B_ID/shells" "{\"kind\":\"server\",\"cmd\":\"sleep 1\",\"chain_id\":\"$CHAIN_ID\",\"agent_instance_id\":\"$AGENT_IID\"}")"

# ---- 3. the retired vocabulary is refused, not aliased --------------------------
for retired in command interactive agent; do
  check "kind=$retired is refused, not aliased" "400" \
    "$(api_code POST "/api/v1/bridges/$B_ID/shells" "{\"kind\":\"$retired\",\"cmd\":\"echo x\"}")"
done

# ---- 4. a by-chain listing respects per-kind scope ------------------------------
# chain is a scope key for `server` only, so the agent-scoped run must not appear
# under a chain-narrowed query even though both belong to this owner.
CHAIN_KINDS="$(api GET "/api/v1/shells?chain_id=$CHAIN_ID" | python3 -c '
import json,sys
print(",".join(sorted(s["kind"] for s in json.load(sys.stdin)["data"]["sessions"])))')"
check "a by-chain listing returns servers only" "server" "$CHAIN_KINDS"

AGENT_KINDS="$(api GET "/api/v1/shells?agent_instance_id=$AGENT_IID" | python3 -c '
import json,sys
print(",".join(sorted(s["kind"] for s in json.load(sys.stdin)["data"]["sessions"])))')"
check "a by-agent listing returns runs only" "run" "$AGENT_KINDS"

echo
echo "[shell1] ---------------------------------------------"
echo "[shell1] passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "[shell1] OK"
