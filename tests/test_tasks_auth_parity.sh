#!/usr/bin/env bash
# Integration & Parity Test for Task & Task-Chain Operations Parity
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

HUB_BIN="${REPO_DIR}/bin/ham-hub"
CTL_BIN="${REPO_DIR}/bin/ham-ctl"
DB_PATH="/tmp/parity_test_${RANDOM}.db"
MIGRATIONS_DIR="${REPO_DIR}/src/hub/repository/sqlite/migrations"
PORT=49329

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; echo "      got: $(echo "$2" | head -c 200)"; FAIL=$((FAIL+1)); }

has() { echo "$1" | grep -qF "$2"; }

echo "=== Provisioning Test Database and Credentials ==="
USER_OUT=$("$HUB_BIN" users create --name "Parity Tester" --email "parity@example.com" --db "$DB_PATH" --migrations-dir "$MIGRATIONS_DIR" 2>&1)
USER_TOKEN=$(echo "$USER_OUT" | grep -o 'token= hut_[^ ]*' | cut -d'=' -f2 | tr -d ' ' || true)
USER_ID=$(echo "$USER_OUT" | grep -o 'user_id= usr_[^ ]*' | cut -d'=' -f2 | tr -d ' ' || true)

if [ -z "$USER_TOKEN" ] || [ -z "$USER_ID" ]; then
  echo "[-] ERROR: Failed to provision user token"
  echo "$USER_OUT"
  exit 1
fi
echo "Provisioned USER_TOKEN=$USER_TOKEN USER_ID=$USER_ID"

echo "=== Starting ham-hub on port $PORT ==="
"$HUB_BIN" --port "$PORT" --db "$DB_PATH" --migrations-dir "$MIGRATIONS_DIR" > /tmp/parity_hub.log 2>&1 &
HUB_PID=$!

cleanup() {
  echo "=== Shutting down ham-hub (PID $HUB_PID) ==="
  kill "$HUB_PID" 2>/dev/null || true
  rm -f "$DB_PATH" /tmp/parity_hub.log || true
}
trap cleanup EXIT

for i in {1..10}; do
  if curl -sf "http://127.0.0.1:$PORT/api/v1/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

export HAM_HUB_URL="http://127.0.0.1:$PORT"
export HAM_USER_TOKEN="$USER_TOKEN"

echo "=== Starting Task Auth Parity Test Suite ==="

# 1. Health check
HEALTH=$("$CTL_BIN" health 2>&1)
if has "$HEALTH" '"ok":true'; then
  pass "Hub health check"
else
  fail "Hub health check" "$HEALTH"
fi

# 2. Test User Transport (--as user)
echo "--- Testing --as user transport ---"
CHAIN_USER_JSON=$("$CTL_BIN" task-chains create --as user --title "User Parity Chain" --description "Testing User REST surface" 2>&1)
if has "$CHAIN_USER_JSON" '"chain_id":'; then
  pass "User: create chain"
else
  fail "User: create chain" "$CHAIN_USER_JSON"
fi

CHAIN_USER_ID=$(echo "$CHAIN_USER_JSON" | grep -o '"chain_id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
if [ -z "$CHAIN_USER_ID" ]; then
  echo "[-] ERROR: Failed to extract user chain_id"
  exit 1
fi
pass "User: extracted chain_id $CHAIN_USER_ID"

CHAIN_SHOW_USER=$("$CTL_BIN" task-chains show --as user --chain "$CHAIN_USER_ID" 2>&1)
if has "$CHAIN_SHOW_USER" "User Parity Chain"; then
  pass "User: show chain"
else
  fail "User: show chain" "$CHAIN_SHOW_USER"
fi

PUBLISH_CHAIN=$("$CTL_BIN" task-chains publish --as user --chain "$CHAIN_USER_ID" 2>&1)
if has "$PUBLISH_CHAIN" '"publish_state":"published"'; then
  pass "User: publish task chain"
else
  fail "User: publish task chain" "$PUBLISH_CHAIN"
fi

TASK_USER_JSON=$("$CTL_BIN" tasks create --as user --chain "$CHAIN_USER_ID" --title "User Parity Task" --description "Testing user task creation" 2>&1)
if has "$TASK_USER_JSON" '"task_id":'; then
  pass "User: create task"
else
  fail "User: create task" "$TASK_USER_JSON"
fi

TASK_USER_ID=$(echo "$TASK_USER_JSON" | grep -o '"task_id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
if [ -z "$TASK_USER_ID" ]; then
  echo "[-] ERROR: Failed to extract user task_id"
  exit 1
fi
pass "User: extracted task_id $TASK_USER_ID"

TASK_LIST_USER=$("$CTL_BIN" tasks list --as user --chain "$CHAIN_USER_ID" 2>&1)
if has "$TASK_LIST_USER" "$TASK_USER_ID"; then
  pass "User: list tasks"
else
  fail "User: list tasks" "$TASK_LIST_USER"
fi

COMMENT_USER=$("$CTL_BIN" tasks comment --as user --chain "$CHAIN_USER_ID" --task "$TASK_USER_ID" --body "User comment test" 2>&1)
if has "$COMMENT_USER" '"comment_id":'; then
  pass "User: comment on task"
else
  fail "User: comment on task" "$COMMENT_USER"
fi

COMMENTS_LIST_USER=$("$CTL_BIN" tasks comments --as user --chain "$CHAIN_USER_ID" --task "$TASK_USER_ID" 2>&1)
if has "$COMMENTS_LIST_USER" "User comment test"; then
  pass "User: list task comments"
else
  fail "User: list task comments" "$COMMENTS_LIST_USER"
fi

COMPLETE_CHAIN=$("$CTL_BIN" task-chains complete --as user --chain "$CHAIN_USER_ID" 2>&1)
if has "$COMPLETE_CHAIN" '"status":"completed"'; then
  pass "User: complete task chain"
else
  fail "User: complete task chain" "$COMPLETE_CHAIN"
fi

# 3. Provision Bridge & Agent Instances for Agent-Asserted Parity Verification
echo "--- Testing Bridge-Relayed Instance Transport Parity ---"
# ===== BROWSER-APPROVED DEVICE FLOW (REQ-ENROLL-9) =====
# Replaces the deleted "mint an enrollment token, then exchange it" pair. The user
# token authenticates the approval step, which is what binds the bridge's owner.
# Note the credential is now an EXPIRING access token, so BRIDGE_TOKEN below is an
# `hba_`, not the old non-expiring `hbr_`.
AUTHZ_RESP=$(curl -s -X POST "http://127.0.0.1:$PORT/api/v1/device/authorize" -H "Content-Type: application/json" \
  -d '{"client":"ham-bridge","device_label":"test-bridge","os":"linux","os_user":"tester","bridge_public_key":"040102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40","code_challenge":"J6jJRRlTiLmCVJAjMgzOjMLRQ-xSS_tovxAjutN8JWI","code_challenge_method":"S256"}' 2>&1)
USER_CODE=$(echo "$AUTHZ_RESP" | grep -o '"user_code":"[^"]*"' | cut -d'"' -f4 || true)
DEVICE_CODE=$(echo "$AUTHZ_RESP" | grep -o '"device_code":"[^"]*"' | cut -d'"' -f4 || true)

curl -s -X POST "http://127.0.0.1:$PORT/api/v1/device/approve" -H "Authorization: Bearer $USER_TOKEN" -H "Content-Type: application/json" \
  -d "{\"user_code\":\"$USER_CODE\",\"approve\":true}" >/dev/null 2>&1

BRIDGE_RESP=$(curl -s -X POST "http://127.0.0.1:$PORT/api/v1/device/token" -H "Content-Type: application/json" \
  -d "{\"device_code\":\"$DEVICE_CODE\",\"code_verifier\":\"heimdall-req-impl-6-test-code-verifier-aaaa\"}" 2>&1)
BRIDGE_TOKEN=$(echo "$BRIDGE_RESP" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4 || true)
BRIDGE_ID=$(echo "$BRIDGE_RESP" | grep -o '"bridge_id":"[^"]*"' | cut -d'"' -f4 || true)

AGENT_RESP=$(curl -s -X POST "http://127.0.0.1:$PORT/api/v1/agents" -H "Authorization: Bearer $USER_TOKEN" -H "Content-Type: application/json" -d '{"name":"Test Agent","slug":"test-agent"}' 2>&1)
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

# 4. Test Deprecation Aliases
echo "--- Testing CLI Deprecation Aliases ---"
ALIAS_HUB_CHAINS=$("$CTL_BIN" hub task-chains list 2>&1)
if has "$ALIAS_HUB_CHAINS" "Notice: 'ham-ctl hub task-chains' is deprecated"; then
  pass "Alias: 'ham-ctl hub task-chains' prints deprecation notice to stderr"
else
  fail "Alias: 'ham-ctl hub task-chains' deprecation notice" "$ALIAS_HUB_CHAINS"
fi

ALIAS_HUB_TASKS=$("$CTL_BIN" hub tasks list --chain "$CHAIN_USER_ID" 2>&1)
if has "$ALIAS_HUB_TASKS" "Notice: 'ham-ctl hub tasks' is deprecated"; then
  pass "Alias: 'ham-ctl hub tasks' prints deprecation notice to stderr"
else
  fail "Alias: 'ham-ctl hub tasks' deprecation notice" "$ALIAS_HUB_TASKS"
fi

# 5. Security Invariant Check
echo "--- Testing Security Invariants ---"
DIRECT_REST_BAD=$(curl -s -X GET "http://127.0.0.1:$PORT/api/v1/task-chains" -H "Authorization: Bearer hit_fake_instance_token" 2>&1 || true)
if has "$DIRECT_REST_BAD" '"code":"unauthenticated"' && has "$DIRECT_REST_BAD" "unsupported bearer token"; then
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
