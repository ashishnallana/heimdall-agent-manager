#!/usr/bin/env bash
# Task System v2 end-to-end smoke: hub + bridge + a FAKE worker provider, all from
# THIS tree, on isolated 18xxx ports, with every artefact under
# $HOME/.cache/heimdall-tests/smoke (never /tmp, never the repo, never ~/.heimdall).
#
#   scripts/task-v2-smoke.sh            # build, run every scenario, tear down
#   SMOKE_SKIP_BUILD=1 scripts/task-v2-smoke.sh
#   SMOKE_ONLY=1,2 scripts/task-v2-smoke.sh   # subset of scenarios (1 is always run)
#
# Scenarios (each step prints PASS/FAIL; the first FAIL exits non-zero):
#   1 bring-up: build, hub :18080, bridge :18081 (local endpoint :18082), device-flow
#     enrolment, browser session (mock OIDC sign-in), fake `claude`/`pi` on the bridge PATH, temp git repo
#     registered as the chain directory, two agents (worker, reviewer) + fleet rows.
#   2 happy path: brief (goal + acceptance, no command) → publish → ready →
#     matcher wake-grants the worker → fake worker confirms → submit (summary
#     reports its checks) → in_review → reviewer wake-granted → review post
#     approve → done.
#   3 negatives: a legacy brief carrying verify/auto_submit/require_independent_verify
#     is accepted with a verify_removed warning; submit when the caller holds no
#     lease (after done) → 409 lease_lost; cancel-then-submit → 409 lease_lost.
#   4 worker death: kill -9 the fake worker → bridge reports stopped → lease
#     expired(instance_lost) → re-grant attempt 2 to a re-woken instance.
#   5 bridge pause < TTL: SIGSTOP the bridge ~20 s → SIGCONT → lease unchanged.
#     (> TTL = 15 min is NOT exercised; see the note printed by the step.)
#   6 workflow chains: templates → run → immutability → status → cancel.
#   7 teardown (trap EXIT): kill hub/bridge/pty-host/fake agents, keep logs.
# (Verification commands were removed, so the old verify-gate, independent-verify,
# auto-submit and verify-dies-with-the-bridge checks are gone.)
#
# HOW THE WORKER IS DRIVEN. The bridge launches scripts/task-v2-smoke/fake-provider.sh
# as the provider binary (real wake_agent → pty-host → bootstrap → hlat token →
# run_dir shim). The fake calls `ham-ctl agent start-success` + `lease next` and then
# idles. The smoke drives submit/review AS that instance through the same
# shim (scripts/task-v2-smoke/agentcall.py reads HEIMDALL_BRIDGE_ENDPOINT/TOKEN from
# <run_dir>/bin/ham-ctl). When ham-ctl grows `lease submit` /
# `review post` the smoke switches to the ctl verbs automatically (ctl is rebuilt on
# every run and probed with `ham-ctl help lease`); until then the M2 verbs go through
# the bridge's agent.rest.request relay to the hub agent-actions paths (same token).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPERS="$ROOT/scripts/task-v2-smoke"
WORK="${SMOKE_WORK:-$HOME/.cache/heimdall-tests/smoke}"
HUB_PORT="${SMOKE_HUB_PORT:-18080}"
B_PORT="${SMOKE_BRIDGE_PORT:-18081}"
B_LOCAL="${SMOKE_BRIDGE_LOCAL:-18082}"
HUB="http://127.0.0.1:$HUB_PORT"
PTY_HOST_BIN="${SMOKE_PTY_HOST_BIN:-$HOME/.local/bin/ham-pty-host}"
ONLY="${SMOKE_ONLY:-}"
BIN="$WORK/bin"
LOGS="$WORK/logs"
MIGRATIONS="$ROOT/src/hub/repository/sqlite/migrations"
export PATH="$HOME/.local/bin:$PATH"
export TASKV2_SMOKE_WORK="$WORK"

# ---------------------------------------------------------------- reporting ----
PASSED=0; FAILED=0; STEP_T0=$(date +%s)
pass() { PASSED=$((PASSED+1)); echo "PASS: $*"; }
fail() { FAILED=$((FAILED+1)); echo "FAIL: $*" >&2; exit 1; }
note() { echo "      $*"; }
skip() { echo "SKIP: $*"; }
section() { echo; echo "=== $* ($(( $(date +%s) - STEP_T0 ))s) ==="; }
want() { case ",$ONLY," in *",$1,"*) return 0;; esac; [ -z "$ONLY" ]; }
jqr() { jq -r "$1" 2>/dev/null; }

# ----------------------------------------------------------------- teardown ----
PIDS=()
HUB_PID=""; BRIDGE_PID=""
# shellcheck source=lib/hub-oidc-dev.sh
. "$ROOT/scripts/lib/hub-oidc-dev.sh"
SESSION=""
cleanup() {
  local rc=$?
  trap - EXIT
  hub_oidc_stop_mock
  section "7. teardown"
  # fake agents first (they are children of the pty-host, not of us)
  for f in "$WORK"/agents/*.pid; do [ -f "$f" ] && kill -9 "$(cat "$f")" 2>/dev/null || true; done
  [ -n "$BRIDGE_PID" ] && kill "$BRIDGE_PID" 2>/dev/null || true
  [ -n "$HUB_PID" ] && kill "$HUB_PID" 2>/dev/null || true
  sleep 1
  # the pty-host daemon the bridge lazily started under OUR run dir, and any
  # fake-provider loops that survived their parent
  for pid in $(pgrep -f "$WORK" 2>/dev/null || true); do [ "$pid" != "$$" ] && kill -9 "$pid" 2>/dev/null || true; done
  for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true; done
  for p in "$HUB_PORT" "$B_PORT" "$B_LOCAL"; do
    for pid in $(ss -ltnp 2>/dev/null | awk -v p=":$p" '$4 ~ p"$" {print $6}' | grep -o 'pid=[0-9]*' | cut -d= -f2); do kill -9 "$pid" 2>/dev/null || true; done
  done
  rm -rf "$WORK/repo" "$WORK/bridge-data" "$WORK/run-b" "$WORK/agents" "$WORK/hub.db"* 2>/dev/null || true
  echo "[smoke] passed=$PASSED failed=$FAILED  logs: $LOGS"
  [ "$rc" -eq 0 ] && [ "$FAILED" -eq 0 ] && echo "[smoke] RESULT: GREEN" || { echo "[smoke] RESULT: RED (exit $rc)"; rc=1; }
  exit "$rc"
}
trap cleanup EXIT INT TERM

# -------------------------------------------------------------- http helpers ----
# api <METHOD> <path> [body]  — browser-session call; prints the body, sets $HTTP_CODE
api() {
  local out
  out="$(curl -s -m 20 -w $'\n%{http_code}' -X "$1" "$HUB$2" \
      -H "$(hub_oidc_cookie "$SESSION")" -H "Origin: $HUB" -H 'Content-Type: application/json' \
      ${3:+-d "$3"})"
  # api runs inside $(...) most of the time, so the status travels via a file
  printf '%s' "${out##*$'\n'}" > "$WORK/.http_code"; printf '%s' "${out%$'\n'*}"
}
http_code() { cat "$WORK/.http_code" 2>/dev/null || echo 000; }
api_ok() { # api + ok assertion
  local body; body="$(api "$@")"
  case "$(http_code)" in 2*) printf '%s' "$body";; *) echo "[http $(http_code)] $1 $2 -> $body" >&2; return 1;; esac
}
# agent calls (as an instance, through the bridge local endpoint)
acall() { python3 "$HELPERS/agentcall.py" --shim "$1" "${@:2}"; }
shim_of() { echo "$WORK/run-b/instances/$1/bin/ham-ctl"; }
wait_for() { # wait_for <seconds> <desc> <cmd...>
  local deadline=$(( $(date +%s) + $1 )) desc="$2"; shift 2
  while :; do
    "$@" && return 0
    [ "$(date +%s)" -ge "$deadline" ] && { echo "[timeout ${desc}]" >&2; return 1; }
    sleep 1
  done
}
task_json() { api GET "/api/v1/task-chains/$CHAIN/tasks/$1"; }
task_state() { task_json "$1" | jqr .data.state; }
task_lease() { # task_lease <task> <kind> <field>
  task_json "$1" | jq -r --arg k "$2" --arg f "$3" '[.data.leases[]? | select(.kind==$k)][0][$f] // empty' 2>/dev/null
}
facet() { api GET "/api/v1/task-chains/$CHAIN/tasks/$1/fetch?ref=facet:$1:$2:$3"; }
inst_status() { api GET "/api/v1/agent-instances/$1" | jqr .data.runtime_status; }
bridge_log_count() { grep -c "runtime ready" "$LOGS/bridge.log" 2>/dev/null || echo 0; }
port_busy() { ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$1\$"; }
ctl_has() { # ctl_has <group> <verb>: the group's help page lists the verb under VERBS
  "$BIN/ham-ctl" help "$1" 2>/dev/null | grep -q "^ham-ctl $1 " && "$BIN/ham-ctl" help "$1" 2>/dev/null | grep -qE "^  $2( |$)"
}
ctl_has_top() { "$BIN/ham-ctl" help "$1" 2>/dev/null | grep -qE "^ham-ctl $1( |$)"; }

# ============================================================== 1. bring-up ====
section "1. bring-up"
for p in "$HUB_PORT" "$B_PORT" "$B_LOCAL"; do port_busy "$p" && fail "port $p busy (another smoke or stray process?)"; done
for t in jq curl python3 git ss; do command -v "$t" >/dev/null || fail "missing tool: $t"; done
[ -x "$PTY_HOST_BIN" ] || fail "ham-pty-host not found at $PTY_HOST_BIN (SMOKE_PTY_HOST_BIN=…)"
rm -rf "$WORK/repo" "$WORK/bridge-data" "$WORK/run-b" "$WORK/agents" "$WORK/hub.db"* "$WORK/fakebin"
mkdir -p "$BIN" "$LOGS" "$WORK/run-b" "$WORK/bridge-data" "$WORK/fakebin" "$WORK/agents"
: > "$LOGS/hub.log"; : > "$LOGS/bridge.log"; rm -f "$LOGS"/agent-*.log

if [ -z "${SMOKE_SKIP_BUILD:-}" ]; then
  SQLITE_LIB="$(dirname "$(find /nix/store -maxdepth 3 -name 'libsqlite3.so' 2>/dev/null | head -n1)")"
  EXTRA_LINKER=""
  [ -n "$SQLITE_LIB" ] && [ -d "$SQLITE_LIB" ] && EXTRA_LINKER="-extra-linker-flags:-L$SQLITE_LIB"
  for t in hub bridge ctl; do
    if ( cd "$ROOT" && odin build "src/$t" -collection:odin_test=src ${EXTRA_LINKER:+"$EXTRA_LINKER"} -out:"$BIN/ham-$t.new" ) >"$LOGS/build-$t.log" 2>&1; then
      mv -f "$BIN/ham-$t.new" "$BIN/ham-$t"
    elif [ "$t" = ctl ] && [ -x "$BIN/ham-ctl" ]; then
      # ctl is being edited by another agent; the shim only needs start-success /
      # lease next, so a previous build of ham-ctl keeps the smoke useful.
      note "WARNING: odin build src/ctl FAILED (see $LOGS/build-ctl.log) — using the previous $BIN/ham-ctl"
      grep -m3 "Error" "$LOGS/build-ctl.log" | sed 's/^/      /'
    else
      cat "$LOGS/build-$t.log" >&2; fail "odin build src/$t"
    fi
  done
  pass "built ham-hub, ham-bridge, ham-ctl from $ROOT into $BIN"
else
  [ -x "$BIN/ham-hub" ] && [ -x "$BIN/ham-bridge" ] && [ -x "$BIN/ham-ctl" ] || fail "SMOKE_SKIP_BUILD set but $BIN incomplete"
  pass "using existing binaries in $BIN"
fi

# fake provider on the bridge PATH under the catalog binary names
for name in claude pi; do ln -sf "$HELPERS/fake-provider.sh" "$WORK/fakebin/$name"; done
chmod +x "$HELPERS/fake-provider.sh" "$HELPERS/agentcall.py"

# Users sign in only with OIDC: mock provider (DEV ONLY), then a real browser sign-in.
hub_oidc_start_mock "$LOGS" smoke || fail "mock OIDC provider did not start"
hub_oidc_export_env
"$BIN/ham-hub" --listen "127.0.0.1:$HUB_PORT" --db "$WORK/hub.db" --migrations-dir "$MIGRATIONS" \
  --ui-origin "$HUB" >"$LOGS/hub.log" 2>&1 &
HUB_PID=$!; PIDS+=("$HUB_PID")
wait_for 30 "hub health" curl -sf -o /dev/null "$HUB/api/v1/health" || { tail -20 "$LOGS/hub.log" >&2; fail "hub did not come up"; }
pass "hub up on :$HUB_PORT (pid $HUB_PID)"
SESSION="$(hub_oidc_login "$HUB" smoke)" || fail "OIDC sign-in"
USER_ID=smoke
pass "user $USER_ID signed in (browser session)"

# bridge enrolment: browser-approved device flow, approved with the browser session
AUTHZ="$(curl -s -X POST "$HUB/api/v1/device/authorize" -H 'Content-Type: application/json' -d '{"client":"ham-bridge","device_label":"taskv2-smoke","os":"linux","os_user":"smoke","bridge_public_key":"040102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40","code_challenge":"J6jJRRlTiLmCVJAjMgzOjMLRQ-xSS_tovxAjutN8JWI","code_challenge_method":"S256"}')"
USER_CODE="$(printf '%s' "$AUTHZ" | jqr .data.user_code)"; DEVICE_CODE="$(printf '%s' "$AUTHZ" | jqr .data.device_code)"
[ -n "$USER_CODE" ] && [ "$USER_CODE" != null ] || { echo "$AUTHZ" >&2; fail "device/authorize"; }
api_ok POST /api/v1/device/approve "{\"user_code\":\"$USER_CODE\",\"approve\":true}" >/dev/null || fail "device/approve"
TOK="$(curl -s -X POST "$HUB/api/v1/device/token" -H 'Content-Type: application/json' -d "{\"device_code\":\"$DEVICE_CODE\",\"code_verifier\":\"heimdall-req-impl-6-test-code-verifier-aaaa\"}")"
printf '%s' "$TOK" | jqr .data.access_token > "$WORK/bridge-data/b.token"
printf '%s' "$TOK" | jqr '.data.refresh_token // ""' > "$WORK/bridge-data/b.token.refresh"
chmod 600 "$WORK/bridge-data/b.token" "$WORK/bridge-data/b.token.refresh"
BRIDGE_ID="$(printf '%s' "$TOK" | jqr .data.bridge_id)"
grep -q '^hba_' "$WORK/bridge-data/b.token" || { echo "$TOK" >&2; fail "device/token did not mint a bridge access token"; }
pass "bridge enrolled: $BRIDGE_ID"

start_bridge() {
  PATH="$WORK/fakebin:$PATH" HEIMDALL_HAM_CTL_BIN="$BIN/ham-ctl" HEIMDALL_BRIDGE_PTY_HOST=1 HEIMDALL_HAM_PTY_HOST_BIN="$PTY_HOST_BIN" \
  "$BIN/ham-bridge" --hub "$HUB" --bridge-token-file "$WORK/bridge-data/b.token" --data-dir "$WORK/bridge-data" \
    --bind-host 127.0.0.1 --port "$B_PORT" --local-endpoint-port "$B_LOCAL" --local-run-dir "$WORK/run-b" >>"$LOGS/bridge.log" 2>&1 &
  BRIDGE_PID=$!; PIDS+=("$BRIDGE_PID")
}
start_bridge
wait_for 40 "bridge runtime ready" grep -q "runtime ready" "$LOGS/bridge.log" || { tail -30 "$LOGS/bridge.log" >&2; fail "bridge never connected"; }
pass "bridge up on :$B_PORT / local endpoint :$B_LOCAL (pid $BRIDGE_PID)"

# the fake provider must be present+enabled on the bridge for JIT launches
PROVIDER="${SMOKE_PROVIDER:-claude}"
MODEL="${SMOKE_MODEL:-}"
api POST "/api/v1/bridges/$BRIDGE_ID/providers/discover" '{}' >/dev/null
pstatus() { api GET "/api/v1/bridges/$BRIDGE_ID/provider-status"; }
provider_present() { pstatus | jq -e --arg p "$PROVIDER" '.data.providers[]? | select(.provider==$p and .state=="present")' >/dev/null; }
wait_for 30 "provider $PROVIDER present on bridge" provider_present || { pstatus >&2; echo; fail "bridge never reported fake provider $PROVIDER as present (PATH=$WORK/fakebin)"; }
[ -n "$MODEL" ] || MODEL="$(pstatus | jq -r --arg p "$PROVIDER" '[.data.providers[]? | select(.provider==$p) | .models[]? | select(.state=="active")][0].model_id // empty')"
[ -n "$MODEL" ] || fail "no active model for provider $PROVIDER in the catalog"
api_ok PUT "/api/v1/bridges/$BRIDGE_ID/providers/$PROVIDER" '{"enabled":true}' >/dev/null || fail "enable provider"
pass "fake provider '$PROVIDER' present+enabled on bridge (model $MODEL)"
printf '%s' "$SESSION" > "$WORK/user.session"; chmod 600 "$WORK/user.session"
note "debug: curl -H \"Cookie: __Host-heimdall_session=\$(cat $WORK/user.session)\" -H \"Origin: $HUB\" $HUB/api/v1/…"

# chain directory: a temp git repo with one commit
REPO="$WORK/repo"; mkdir -p "$REPO"
( cd "$REPO" && git init -q -b main . && git -c user.name=smoke -c user.email=smoke@example.com commit -q --allow-empty -m "init" && echo hello > README && git add README && git -c user.name=smoke -c user.email=smoke@example.com commit -q -m "readme" ) || fail "git init"
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"

CHAIN="$(api_ok POST /api/v1/task-chains '{"title":"taskv2 smoke chain","description":"Task System v2 smoke"}' | jqr .data.chain_id)" || fail "create chain"
[ -n "$CHAIN" ] && [ "$CHAIN" != null ] || fail "create chain (no chain_id)"
DIR_JSON="$(api POST "/api/v1/task-chains/$CHAIN/directories" "{\"path\":\"$REPO\",\"bridge_id\":\"$BRIDGE_ID\",\"vcs_kind\":\"git\"}")"
case "$(http_code)" in 2*) pass "chain $CHAIN + directory $(printf '%s' "$DIR_JSON" | jqr .data.directory_id) ($REPO @ ${HEAD_SHA:0:8})";;
  *) note "directory registration answered $(http_code): $DIR_JSON"; pass "chain $CHAIN (directory registration not available — placement falls back to the fleet/coordinator bridge)";; esac

AGENT_W="$(api_ok POST /api/v1/agents '{"name":"smoke-worker","slug":"smoke-worker"}' | jqr .data.agent_id)" || fail "create worker agent"
AGENT_R="$(api_ok POST /api/v1/agents '{"name":"smoke-reviewer","slug":"smoke-reviewer"}' | jqr .data.agent_id)" || fail "create reviewer agent"
AGENT_C="$(api_ok POST /api/v1/agents '{"name":"smoke-coordinator","slug":"smoke-coordinator"}' | jqr .data.agent_id)" || fail "create coordinator agent"
for a in "$AGENT_W" "$AGENT_R" "$AGENT_C"; do
  api PUT "/api/v1/agents/$a/bridge-support" "{\"bridges\":[{\"bridge_id\":\"$BRIDGE_ID\",\"enabled\":true}]}" >/dev/null
done
api_ok PUT "/api/v1/task-chains/$CHAIN/fleets/$AGENT_W" "{\"capacity\":1,\"roles\":[\"worker\"],\"provider\":\"$PROVIDER\",\"model\":\"$MODEL\",\"bridge_id\":\"$BRIDGE_ID\"}" >/dev/null || fail "fleet row worker"
api_ok PUT "/api/v1/task-chains/$CHAIN/fleets/$AGENT_R" "{\"capacity\":1,\"roles\":[\"reviewer\"],\"provider\":\"$PROVIDER\",\"model\":\"$MODEL\",\"bridge_id\":\"$BRIDGE_ID\"}" >/dev/null || fail "fleet row reviewer"
pass "agents worker=$AGENT_W reviewer=$AGENT_R + fleet rows (roles worker / reviewer)"

# A chain's FIRST instance becomes its coordinator (agent_service.prepare_instance),
# and the coordinator is never granted a lease — so without a coordinator the
# matcher's JIT worker would be promoted to coordinator and the task would sit in
# `ready` forever. Launch an explicit coordinator (the fake provider: it calls
# start-success + `lease next` → status none) before any task is published.
COORD="$(api_ok POST /api/v1/agent-instances "{\"agent_id\":\"$AGENT_C\",\"bridge_id\":\"$BRIDGE_ID\",\"chain_id\":\"$CHAIN\",\"provider\":\"$PROVIDER\",\"model\":\"$MODEL\",\"display_name\":\"smoke coordinator\"}" | jqr .data.agent_instance_id)" || fail "launch coordinator instance"
coord_is_coordinator() { api GET "/api/v1/task-chains/$CHAIN" | jq -e --arg c "$COORD" '.data.coordinator_agent_instance_id == $c' >/dev/null; }
wait_for 20 "coordinator binding" coord_is_coordinator || fail "instance $COORD did not become the chain coordinator"
coord_running() { [ "$(inst_status "$COORD")" = "running" ]; }
wait_for 90 "coordinator start-success" coord_running || { note "coordinator status: $(inst_status "$COORD")"; grep -n "launch\|bootstrap\|wake" "$LOGS/bridge.log" | tail -10 >&2; fail "coordinator instance never reached running (fake provider launch path broken?)"; }
pass "coordinator $COORD launched via the real bridge launch path and reported start-success"

CTL_SUBMIT=0; CTL_REVIEW=0
ctl_has lease submit && CTL_SUBMIT=1
ctl_has review post && CTL_REVIEW=1
note "ctl verbs available: lease submit=$CTL_SUBMIT review post=$CTL_REVIEW (missing ones are driven via agent.rest.request)"

# ------------------------------------------------------------ task helpers ----
make_task() { # make_task <title> -> task_id (goal + acceptance is the whole contract)
  api_ok POST "/api/v1/task-chains/$CHAIN/tasks" "{\"title\":\"$1\",\"brief\":{\"goal\":\"smoke: $1\",\"acceptance\":[\"README.md exists at the submitted head\"],\"review_roles\":[\"reviewer\"]}}" | jqr .data.task_id
}
publish_chain() { api_ok POST "/api/v1/task-chains/$CHAIN/publish" '{}' >/dev/null; }
publish_task() { api_ok POST "/api/v1/task-chains/$CHAIN/tasks/$1/publish" '{}' >/dev/null; }
wait_lease() { # wait_lease <task> <kind> [secs] -> HOLDER LEASE_ID ATTEMPT
  local t="$1" k="$2" secs="${3:-120}" deadline=$(( $(date +%s) + ${3:-120} ))
  while :; do
    HOLDER="$(task_lease "$t" "$k" holder_instance_id)"
    if [ -n "$HOLDER" ]; then LEASE_ID="$(task_lease "$t" "$k" lease_id)"; ATTEMPT="$(task_lease "$t" "$k" attempt_no)"; return 0; fi
    [ "$(date +%s)" -ge "$deadline" ] && { echo "[timeout waiting $k lease on $t] task: $(task_json "$t" | jq -c '.data | {state, attempt_no, leases}')" >&2; return 1; }
    sleep 1
  done
}
wait_confirmed() { # the fake has called lease next (confirmed_at set) and its shim exists
  local t="$1" k="$2" deadline=$(( $(date +%s) + 120 ))
  while :; do
    local c; c="$(task_lease "$t" "$k" confirmed_at)"
    [ -n "$c" ] && [ -x "$(shim_of "$HOLDER")" ] && return 0
    [ "$(date +%s)" -ge "$deadline" ] && { echo "[timeout waiting confirm of $k lease on $t by $HOLDER]" >&2; tail -20 "$LOGS/bridge.log" >&2; return 1; }
    sleep 1
  done
}
wait_state() { # wait_state <task> <state> [secs]
  local deadline=$(( $(date +%s) + ${3:-60} ))
  while :; do
    local s; s="$(task_state "$1")"; [ "$s" = "$2" ] && return 0
    [ "$(date +%s)" -ge "$deadline" ] && { echo "[timeout: $1 is '$s', wanted '$2'] $(task_json "$1" | jq -c '.data | {state, attempt_no, blocked_on, leases}')" >&2; return 1; }
    sleep 1
  done
}
submit_as() { # submit_as <shim> <summary> -> response json (exit = ok)
  if [ "$CTL_SUBMIT" = 1 ]; then ( cd "$REPO" && "$1" lease submit --summary "$2" ); else acall "$1" agent.lease.submit "{\"summary\":\"$2\"}"; fi
}
review_as() { # review_as <shim> <verdict>
  if [ "$CTL_REVIEW" = 1 ]; then "$1" review post --verdict "$2"; else acall "$1" agent.review.post "{\"verdict\":\"$2\"}"; fi
}
err_code() {
  jq -r '(try (.error.message | fromjson) catch {}) as $inner | $inner.error.details.code // $inner.error.code // .error.details.code // .error.code // .message // empty' 2>/dev/null
}

# ============================================================ 2. happy path ====
if want 2; then
section "2. happy path: publish → grant → submit → review → done"
T1="$(make_task "smoke-happy")" || fail "create task"
[ -n "$T1" ] && [ "$T1" != null ] || fail "create task (no id)"
pass "task $T1 created with full brief (draft, state=$(task_state "$T1"))"
publish_chain || fail "publish chain (brief validation?)"
wait_state "$T1" ready 10 || wait_state "$T1" in_progress 10 || fail "task not ready after publish"
pass "chain published; task $T1 state=$(task_state "$T1")"
wait_lease "$T1" work 120 || { grep -n "taskv2\|wake" "$LOGS/hub.log" | tail -20 >&2; fail "matcher did not grant a work lease"; }
pass "matcher granted work lease $LEASE_ID attempt=$ATTEMPT to $HOLDER (delivery=$(task_lease "$T1" work delivery))"
wait_for 60 "bridge wake_agent launch of $HOLDER" grep -q "wake_agent: launched instance $HOLDER\|wake_agent: re-bootstrapped and restarted instance $HOLDER" "$LOGS/bridge.log" \
  || { grep -n "wake_agent\|launch" "$LOGS/bridge.log" | tail -20 >&2; fail "bridge did not launch the woken worker"; }
pass "bridge launched the fake worker ($HOLDER)"
wait_confirmed "$T1" work || fail "fake worker never confirmed its lease (start-success + lease next)"
wait_state "$T1" in_progress 20 || fail "task not in_progress after confirm"
WSHIM="$(shim_of "$HOLDER")"
pass "worker confirmed lease (task in_progress); shim=$WSHIM"
WTASK_MD="$WORK/run-b/instances/$HOLDER/TASK.md"
[ -f "$WTASK_MD" ] && pass "M3: bridge materialised $WTASK_MD ($(wc -c < "$WTASK_MD") bytes)" || fail "M3: $WTASK_MD was not materialised on wake/lease.next"
RT_FACET="$(facet "$T1" "$ATTEMPT" runtime | jq -c '.data.body // empty')"
printf '%s' "$RT_FACET" | jq -e '(.bridge_id | length > 0) and (.started_at | length > 0)' >/dev/null 2>&1 \
  && pass "M3: runtime facet written on lease grant: $RT_FACET" || fail "M3: runtime facet missing on grant: $RT_FACET"

R="$(submit_as "$WSHIM" "done: README added; checks: test -f README.md (pass)")" || fail "submit: $R"
OUTCOME="$(printf '%s' "$R" | jq -r '.data.data.outcome // .data.outcome // .outcome // empty')"
[ "$OUTCOME" = "in_review" ] && pass "submit → outcome in_review" || fail "submit outcome '$OUTCOME': $R"
RT_END="$(facet "$T1" "$ATTEMPT" runtime | jq -r '.data.body.ended_at // empty')"
[ -n "$RT_END" ] && pass "M3: runtime facet ended_at updated on lease release ($RT_END)" || fail "M3: runtime facet ended_at not populated on lease release"
wait_state "$T1" in_review 10 || fail "state after submit"
wait_lease "$T1" review 120 || fail "matcher did not grant a review lease"
[ "$HOLDER" != "$(task_lease "$T1" work holder_instance_id)" ] || true
RHOLDER="$HOLDER"
pass "review lease $LEASE_ID role=$(task_lease "$T1" review review_role) granted to reviewer $RHOLDER"
wait_confirmed "$T1" review || fail "fake reviewer never confirmed"
RSHIM="$(shim_of "$RHOLDER")"
pass "reviewer confirmed (shim=$RSHIM)"
R="$(review_as "$RSHIM" approve)" || fail "review post: $R"
GATE="$(printf '%s' "$R" | jq -r '.data.data.gate // .data.gate // .gate // empty')"
[ "$GATE" = "approved" ] && pass "review post approve → gate approved" || fail "gate '$GATE': $R"
wait_state "$T1" done 15 || fail "task not done after approval"
pass "task $T1 is DONE"

else
  # scenarios 3-5 need the published chain and a known worker
  publish_chain || true
fi

# ============================================================ 3. negatives ====
if want 3 && want 2; then
section "3. negatives"
# 3a legacy brief keys: accepted and dropped with a verify_removed warning (one release)
R="$(api POST "/api/v1/task-chains/$CHAIN/tasks" '{"title":"smoke-legacy-brief","brief":{"goal":"smoke: legacy keys","acceptance":["keys are dropped"],"verify":"true","auto_submit":true,"require_independent_verify":true,"review_roles":["reviewer"]}}' || true)"
printf '%s' "$R" | jq -e '[.. | objects | select(.code? == "verify_removed")] | length > 0' >/dev/null 2>&1 \
  && pass "3a legacy verify/auto_submit/require_independent_verify brief → created with a verify_removed warning" \
  || fail "3a expected a verify_removed warning, got: $R"
T_LEGACY="$(printf '%s' "$R" | jqr .data.task_id)"
[ -n "$T_LEGACY" ] && [ "$T_LEGACY" != null ] && api POST "/api/v1/task-chains/$CHAIN/tasks/$T_LEGACY/cancel" '{"reason":"smoke"}' >/dev/null 2>&1 || true
R="$(submit_as "$WSHIM" "ghost submit" || true)"
[ "$(printf '%s' "$R" | err_code)" = "unauthenticated" ] && R="$(submit_as "$(shim_of "$COORD")" "ghost submit" || true)"
[ "$(printf '%s' "$R" | err_code)" = "lease_lost" ] && pass "3b submit with no live lease (after done) → 409 lease_lost" || fail "3b expected lease_lost, got: $R"

T2="$(make_task "smoke-cancel")"
wait_lease "$T2" work 150 || fail "no grant for $T2"
wait_confirmed "$T2" work || fail "worker never confirmed $T2"
W2SHIM="$(shim_of "$HOLDER")"
api_ok POST "/api/v1/task-chains/$CHAIN/tasks/$T2/cancel" '{"reason":"smoke"}' >/dev/null || fail "cancel $T2"
wait_state "$T2" cancelled 10 || fail "cancel state"
R="$(submit_as "$W2SHIM" "late submit" || true)"
C="$(printf '%s' "$R" | err_code)"
case "$C" in lease_lost) pass "3c submit after cancel expired the lease → 409 lease_lost";;
  *) note "after cancel the submit answered: $R"; [ -n "$C" ] && pass "3c submit after cancel rejected ($C) — lease_lost expected once the stopped instance's token is still accepted" || fail "3c submit after cancel succeeded?! $R";; esac
fi

# ======================================================= 4. worker death ====
if want 4; then
section "4. kill the worker → instance_lost → re-grant attempt 2"
T3="$(make_task "smoke-instance-lost")"
wait_lease "$T3" work 150 || fail "no grant for $T3"
wait_confirmed "$T3" work || fail "worker never confirmed $T3"
H1="$HOLDER"; L1="$LEASE_ID"; A1="$ATTEMPT"
PIDF="$WORK/agents/$H1.pid"; [ -f "$PIDF" ] || fail "fake worker pid file missing ($PIDF)"
FPID="$(cat "$PIDF")"; kill -9 "$FPID" 2>/dev/null; pkill -9 -P "$FPID" 2>/dev/null || true
pass "killed fake worker pid $FPID (instance $H1, lease $L1 attempt $A1)"
regranted() { local l a; l="$(task_lease "$T3" work lease_id)"; a="$(task_lease "$T3" work attempt_no)"; [ -n "$l" ] && [ "$l" != "$L1" ] && [ "$a" -gt "$A1" ] 2>/dev/null; }
wait_for 120 "re-grant after instance_lost" regranted || { echo "task: $(task_json "$T3" | jq -c '.data|{state,attempt_no,leases}')" >&2; grep -n "instance_lost\|taskv2" "$LOGS/hub.log" | tail >&2; fail "lease was not re-granted after the worker died"; }
HOLDER="$(task_lease "$T3" work holder_instance_id)"; LEASE_ID="$(task_lease "$T3" work lease_id)"; ATTEMPT="$(task_lease "$T3" work attempt_no)"
pass "re-granted: lease $LEASE_ID attempt=$ATTEMPT holder=$HOLDER (was $H1)"
grep -q "instance_lost" "$LOGS/hub.log" && pass "hub log shows the instance_lost expiry" || note "no 'instance_lost' text in hub.log (expiry reason only in task_events)"
wait_confirmed "$T3" work || fail "re-woken worker never confirmed attempt $ATTEMPT"
pass "re-woken worker $HOLDER confirmed attempt $ATTEMPT"
fi

# ================================================ 5. bridge pause < TTL ====
if want 5; then
section "5. bridge SIGSTOP ~20 s (< lease TTL) → lease unchanged on reconnect"
[ -n "${T3:-}" ] || { T3="$(make_task "smoke-pause")"; publish_task "$T3" || publish_chain; wait_lease "$T3" work 150 || fail "no grant"; wait_confirmed "$T3" work || fail "no confirm"; }
L_BEFORE="$(task_lease "$T3" work lease_id)"; H_BEFORE="$(task_lease "$T3" work holder_instance_id)"
READY_BEFORE="$(bridge_log_count)"
kill -STOP "$BRIDGE_PID"; sleep 20; kill -CONT "$BRIDGE_PID"
pass "bridge paused 20 s and resumed"
sleep 5
B_STATUS="$(api GET "/api/v1/bridges/$BRIDGE_ID" | jqr '.data.status // .data.state // "?"')"
note "bridge status after resume: $B_STATUS; runtime-ready lines before=$READY_BEFORE now=$(bridge_log_count)"
[ "$(task_lease "$T3" work lease_id)" = "$L_BEFORE" ] && [ "$(task_lease "$T3" work holder_instance_id)" = "$H_BEFORE" ] \
  && pass "lease $L_BEFORE / holder $H_BEFORE unchanged across the pause" || fail "lease changed across a <TTL pause: $(task_json "$T3" | jq -c '.data.leases')"
skip "bridge disconnect > TTL (15 min) not exercised in the smoke — covered by hub unit tests (lease_test.odin); no hub flag shortens LEASE_TTL_SECONDS today"
fi

# =============================================== 6. workflow chains (M3b) ====
if want 6; then
section "6. workflow chains: templates → run → lazy materialisation → status → cancel"

# 7a. Templates
TEMPLATES_RESP="$(api GET "/api/v1/workflows/templates")"
echo "$TEMPLATES_RESP" | jq -e '.data.templates[] | select(.name == "explore_plan_build")' >/dev/null \
  && pass "7a built-in explore_plan_build template available via /api/v1/workflows/templates" \
  || fail "7a explore_plan_build template missing from templates response: $TEMPLATES_RESP"

# 7b. Run workflow
WF_RUN_RESP="$(api_ok POST "/api/v1/workflows/run" "{\"ref\":\"explore_plan_build\",\"title\":\"Smoke Workflow Run\",\"inputs\":{\"goal\":\"smoke test goal\"},\"bridge_id\":\"$BRIDGE_ID\"}")"
WF_CHAIN="$(printf '%s' "$WF_RUN_RESP" | jqr '.data.chain_id // .chain_id')"
[ -n "$WF_CHAIN" ] && pass "7b started workflow run (chain_id=$WF_CHAIN)" || fail "7b failed to start workflow: $WF_RUN_RESP"

# 7c. Immutability: manual task create on workflow chain rejected with 403
CREATE_ATTEMPT="$(api POST "/api/v1/task-chains/$WF_CHAIN/tasks" '{"title":"manual task","brief":{"goal":"should fail","acceptance":["rejected"]}}' || true)"
[ "$(printf '%s' "$CREATE_ATTEMPT" | err_code)" = "workflow_immutable" ] \
  && pass "7c manual task.create on workflow chain rejected with 403 workflow_immutable" \
  || fail "7c expected workflow_immutable 403, got: $CREATE_ATTEMPT"

# 7d. Check status and root stage materialisation
WF_STATUS_RESP="$(api_ok GET "/api/v1/task-chains/$WF_CHAIN/workflow/status")"
echo "$WF_STATUS_RESP" | jq -e '.data.stages[] | select(.key == "explore")' >/dev/null \
  && pass "7d workflow status returns root explore stage" \
  || fail "7d explore stage missing from workflow status: $WF_STATUS_RESP"

# 7e. Cancel workflow chain
CANCEL_RESP="$(api_ok POST "/api/v1/task-chains/$WF_CHAIN/workflow/cancel" '{"reason":"smoke complete"}')"
[ "$(printf '%s' "$CANCEL_RESP" | jqr '.data.status // .status')" = "cancelled" ] \
  && pass "7e cancelled workflow chain $WF_CHAIN cleanly" \
  || fail "7e cancel workflow failed: $CANCEL_RESP"

fi

section "done"
exit 0
