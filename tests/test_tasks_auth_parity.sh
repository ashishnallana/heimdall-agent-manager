#!/usr/bin/env bash
# Integration & Parity Test for Task & Task-Chain Operations Parity
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

HUB_BIN="${HUB_BIN:-${REPO_DIR}/bin/ham-hub}"
CTL_BIN="${CTL_BIN:-${REPO_DIR}/bin/ham-ctl}"
DB_PATH="/tmp/parity_test_${RANDOM}.db"
MIGRATIONS_DIR="${REPO_DIR}/src/hub/repository/sqlite/migrations"
PORT=49329

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; echo "      got: $(echo "$2" | head -c 200)"; FAIL=$((FAIL+1)); }

has() { echo "$1" | grep -qF "$2"; }

echo "=== Starting mock OIDC + ham-hub on port $PORT ==="
# Users authenticate only with OIDC: sign in through the real browser flow against
# tools/mock-oidc. (Hub user tokens and `ham-ctl --as user` were removed.)
# shellcheck source=../scripts/lib/hub-oidc-dev.sh
. "$REPO_DIR/scripts/lib/hub-oidc-dev.sh"
hub_oidc_start_mock /tmp parity
hub_oidc_export_env
"$HUB_BIN" --port "$PORT" --db "$DB_PATH" --migrations-dir "$MIGRATIONS_DIR" --ui-origin "http://127.0.0.1:$PORT" > /tmp/parity_hub.log 2>&1 &
HUB_PID=$!

cleanup() {
  echo "=== Shutting down ham-hub (PID $HUB_PID) ==="
  kill "$HUB_PID" 2>/dev/null || true
  hub_oidc_stop_mock
  rm -f "$DB_PATH" /tmp/parity_hub.log || true
}
trap cleanup EXIT

for i in {1..40}; do
  if curl -sf "http://127.0.0.1:$PORT/api/v1/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

SESSION=$(hub_oidc_login "http://127.0.0.1:$PORT" parity)
USER_ID=parity
UAUTH=(-H "$(hub_oidc_cookie "$SESSION")" -H "Origin: http://127.0.0.1:$PORT")
export HAM_HUB_URL="http://127.0.0.1:$PORT"

echo "=== Starting Task Auth Parity Test Suite ==="

# 1. Health check
HEALTH=$("$CTL_BIN" health 2>&1)
if has "$HEALTH" '"ok":true'; then
  pass "Hub health check"
else
  fail "Hub health check" "$HEALTH"
fi

# 2. User transport: Hub user tokens were removed, so ham-ctl user mode must
# refuse a hut_ token with a clear explanation (not a confusing hub error).
USER_MODE=$(HAM_USER_TOKEN=hut_removed "$CTL_BIN" task-chains list --as user 2>&1 || true)
if has "$USER_MODE" "were removed"; then
  pass "User: ham-ctl explains that hut_ user tokens were removed"
else
  fail "User: ham-ctl user-token removal message" "$USER_MODE"
fi

# 3. Provision Bridge & Agent Instances for Agent-Asserted Parity Verification
echo "--- Testing Bridge-Relayed Instance Transport Parity ---"
# ===== BROWSER-APPROVED DEVICE FLOW (REQ-ENROLL-9) =====
# Replaces the deleted "mint an enrollment token, then exchange it" pair. The user
# browser session authenticates the approval step, which binds the bridge's owner.
# Note the credential is now an EXPIRING access token, so BRIDGE_TOKEN below is an
# `hba_`, not the old non-expiring `hbr_`.
AUTHZ_RESP=$(curl -s -X POST "http://127.0.0.1:$PORT/api/v1/device/authorize" -H "Content-Type: application/json" \
  -d '{"client":"ham-bridge","device_label":"test-bridge","os":"linux","os_user":"tester","bridge_public_key":"040102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40","code_challenge":"J6jJRRlTiLmCVJAjMgzOjMLRQ-xSS_tovxAjutN8JWI","code_challenge_method":"S256"}' 2>&1)
USER_CODE=$(echo "$AUTHZ_RESP" | grep -o '"user_code":"[^"]*"' | cut -d'"' -f4 || true)
DEVICE_CODE=$(echo "$AUTHZ_RESP" | grep -o '"device_code":"[^"]*"' | cut -d'"' -f4 || true)

curl -s -X POST "http://127.0.0.1:$PORT/api/v1/device/approve" "${UAUTH[@]}" -H "Content-Type: application/json" \
  -d "{\"user_code\":\"$USER_CODE\",\"approve\":true}" >/dev/null 2>&1

BRIDGE_RESP=$(curl -s -X POST "http://127.0.0.1:$PORT/api/v1/device/token" -H "Content-Type: application/json" \
  -d "{\"device_code\":\"$DEVICE_CODE\",\"code_verifier\":\"heimdall-req-impl-6-test-code-verifier-aaaa\"}" 2>&1)
BRIDGE_TOKEN=$(echo "$BRIDGE_RESP" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4 || true)
BRIDGE_ID=$(echo "$BRIDGE_RESP" | grep -o '"bridge_id":"[^"]*"' | cut -d'"' -f4 || true)

AGENT_RESP=$(curl -s -X POST "http://127.0.0.1:$PORT/api/v1/agents" "${UAUTH[@]}" -H "Content-Type: application/json" -d '{"name":"Test Agent","slug":"test-agent"}' 2>&1)
AGENT_ID=$(echo "$AGENT_RESP" | grep -o '"agent_id":"[^"]*"' | cut -d'"' -f4 || true)

INST_ID="inst_parity_member"
INST2_ID="inst_parity_nonmember"

# Seed test instances into database
sqlite3 "$DB_PATH" "INSERT INTO agent_instances (agent_instance_id, owner_user_id, agent_id, bridge_id, runtime_status, created_at, updated_at) VALUES ('$INST_ID', '$USER_ID', '$AGENT_ID', '$BRIDGE_ID', 'active', '2026-07-29T00:00:00Z', '2026-07-29T00:00:00Z');"
sqlite3 "$DB_PATH" "INSERT INTO agent_instances (agent_instance_id, owner_user_id, agent_id, bridge_id, runtime_status, created_at, updated_at) VALUES ('$INST2_ID', '$USER_ID', '$AGENT_ID', '$BRIDGE_ID', 'active', '2026-07-29T00:00:00Z', '2026-07-29T00:00:00Z');"

if [ -n "$BRIDGE_TOKEN" ] && [ -n "$BRIDGE_ID" ]; then
  pass "Provisioned Bridge $BRIDGE_ID and Agent Instances $INST_ID, $INST2_ID"
else
  fail "Provision Bridge and Agent Instance" "$BRIDGE_RESP"
fi

# Create Chain via Bridge-Relayed Instance Auth
CHAIN_AGENT_RESP=$(curl -s -X POST "http://127.0.0.1:$PORT/api/v1/task-chains" \
  -H "Authorization: Bearer $BRIDGE_TOKEN" \
  -H "X-Heimdall-Instance-Token: hit_$INST_ID" \
  -H "Content-Type: application/json" \
  -d "{\"title\":\"Agent Parity Chain\",\"description\":\"Testing Agent REST surface\"}" 2>&1)

if has "$CHAIN_AGENT_RESP" '"chain_id":'; then
  pass "Agent REST: create chain via bridge-relayed assertion"
else
  fail "Agent REST: create chain" "$CHAIN_AGENT_RESP"
fi

CHAIN_AGENT_ID=$(echo "$CHAIN_AGENT_RESP" | grep -o '"chain_id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)

# Show Chain via Bridge-Relayed Instance Auth
CHAIN_SHOW_AGENT=$(curl -s -X GET "http://127.0.0.1:$PORT/api/v1/task-chains/$CHAIN_AGENT_ID" \
  -H "Authorization: Bearer $BRIDGE_TOKEN" \
  -H "X-Heimdall-Instance-Token: hit_$INST_ID" 2>&1)

if has "$CHAIN_SHOW_AGENT" "Agent Parity Chain"; then
  pass "Agent REST: show chain"
else
  fail "Agent REST: show chain" "$CHAIN_SHOW_AGENT"
fi

# Publish Chain via Bridge-Relayed Instance Auth
PUBLISH_CHAIN_AGENT=$(curl -s -X POST "http://127.0.0.1:$PORT/api/v1/task-chains/$CHAIN_AGENT_ID/publish" \
  -H "Authorization: Bearer $BRIDGE_TOKEN" \
  -H "X-Heimdall-Instance-Token: hit_$INST_ID" \
  -H "Content-Type: application/json" -d '{}' 2>&1)

if has "$PUBLISH_CHAIN_AGENT" '"publish_state":"published"'; then
  pass "Agent REST: publish chain"
else
  fail "Agent REST: publish chain" "$PUBLISH_CHAIN_AGENT"
fi

# Create Task via Bridge-Relayed Instance Auth
TASK_AGENT_RESP=$(curl -s -X POST "http://127.0.0.1:$PORT/api/v1/task-chains/$CHAIN_AGENT_ID/tasks" \
  -H "Authorization: Bearer $BRIDGE_TOKEN" \
  -H "X-Heimdall-Instance-Token: hit_$INST_ID" \
  -H "Content-Type: application/json" \
  -d "{\"title\":\"Agent Parity Task\",\"description\":\"Testing agent task creation\"}" 2>&1)

if has "$TASK_AGENT_RESP" '"task_id":'; then
  pass "Agent REST: create task"
else
  fail "Agent REST: create task" "$TASK_AGENT_RESP"
fi

TASK_AGENT_ID=$(echo "$TASK_AGENT_RESP" | grep -o '"task_id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)

# Comment on Task via Bridge-Relayed Instance Auth
COMMENT_AGENT_RESP=$(curl -s -X POST "http://127.0.0.1:$PORT/api/v1/task-chains/$CHAIN_AGENT_ID/tasks/$TASK_AGENT_ID/comments" \
  -H "Authorization: Bearer $BRIDGE_TOKEN" \
  -H "X-Heimdall-Instance-Token: hit_$INST_ID" \
  -H "Content-Type: application/json" \
  -d '{"body":"Agent comment parity test"}' 2>&1)

if has "$COMMENT_AGENT_RESP" '"comment_id":'; then
  pass "Agent REST: comment on task"
else
  fail "Agent REST: comment on task" "$COMMENT_AGENT_RESP"
fi

# 5. Security Invariant Check
echo "--- Testing Security Invariants ---"
DIRECT_REST_BAD=$(curl -s -X GET "http://127.0.0.1:$PORT/api/v1/task-chains" -H "Authorization: Bearer hit_fake_instance_token" 2>&1 || true)
if has "$DIRECT_REST_BAD" '"code":"unauthenticated"'; then
  pass "Security: Standalone hit_... bearer token rejected on Hub REST surface"
else
  fail "Security: Standalone hit_... bearer token rejection" "$DIRECT_REST_BAD"
fi

# Non-member instance token authorization check (Forbidden)
FORBIDDEN_RESP=$(curl -s -X GET "http://127.0.0.1:$PORT/api/v1/task-chains/$CHAIN_AGENT_ID" \
  -H "Authorization: Bearer $BRIDGE_TOKEN" \
  -H "X-Heimdall-Instance-Token: hit_$INST2_ID" 2>&1)

if has "$FORBIDDEN_RESP" '"code":"forbidden"'; then
  pass "Security: Non-member instance token caller rejected with 403 Forbidden"
else
  fail "Security: Non-member instance token caller rejection" "$FORBIDDEN_RESP"
fi

echo "=== Summary ==="
echo "Passed: $PASS, Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
echo "Task Auth Parity tests completed successfully!"
