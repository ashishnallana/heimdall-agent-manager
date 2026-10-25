#!/usr/bin/env bash
# TEST-1 / LOG-1 local end-to-end: proves bridge bootstrap cache HIT vs hub FETCH
# against a LOCAL hub, for all three scenarios:
#   (1) COLD        : manifest 200 (MISS) + every object FETCH(hub)
#   (2) WARM        : manifest 304 (HIT)  + zero fetches (all disk HIT)
#   (3) AFTER_MEMORY: manifest 200 (MISS) + exactly ONE FETCH (memories) + rest HIT,
#                     and the new memory present in the assembled AGENTS.md.
#
# Requires: nix (to build), a free port. Builds ham-hub + the bridge bootstrap
# harness, stands up a throwaway local hub (own db/port/tokens), enrolls a bridge,
# creates an agent, and drives the REAL bridge bootstrap code path
# (bridge_bootstrap_conditional_manifest) so its HIT/FETCH log lines are the
# acceptance signal.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

PORT="${E2E_HUB_PORT:-$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')}"
H="127.0.0.1:$PORT"
DB="$(mktemp -t e2e-hub-XXXX.db)"
CACHE="$(mktemp -d -t e2e-bridge-cache-XXXX)"
TOKF="$(mktemp -t e2e-bridge-token-XXXX)"
ODIN_BIN="${ODIN:-odin}"
HARNESS="$(mktemp -t e2e-harness-XXXX)"
LOG="$(mktemp -t e2e-hub-log-XXXX)"

# shellcheck source=../scripts/lib/hub-oidc-dev.sh
. "$ROOT/scripts/lib/hub-oidc-dev.sh"
cleanup() { [ -n "${HUB_PID:-}" ] && kill "$HUB_PID" 2>/dev/null || true; hub_oidc_stop_mock; rm -rf "$DB" "$CACHE" "$TOKF" "$HARNESS" "$LOG"; }
trap cleanup EXIT

echo "[e2e] building ham-hub + ham-bridge via nix"
nix build "$ROOT#ham-hub" --out-link "$CACHE/result-hub" >/dev/null
nix build "$ROOT#ham-bridge" --out-link "$CACHE/result-bridge" >/dev/null
echo "[e2e] building bootstrap harness"
"$ODIN_BIN" build tests/e2e_bridge_bootstrap_cache_harness.odin -file -collection:odin_test=src -out:"$HARNESS"

echo "[e2e] starting mock OIDC + local hub on $H"
hub_oidc_start_mock "$CACHE"
hub_oidc_export_env
"$CACHE/result-hub/bin/ham-hub" --listen "$H" --db "$DB" \
  --migrations-dir src/hub/repository/sqlite/migrations \
  --ui-origin "http://$H" >"$LOG" 2>&1 &
HUB_PID=$!
sleep 2

# Browser session for alice (OIDC sign-in against the mock); Origin satisfies CSRF.
U=(-H "$(hub_oidc_cookie "$(hub_oidc_login "http://$H" alice)")" -H "Origin: http://$H")
curl -sf -m5 "${U[@]}" "http://$H/api/v1/me" >/dev/null
# ===== BROWSER-APPROVED DEVICE FLOW (REQ-ENROLL-9) =====
# The one-time-token endpoints are deleted (404). The three steps are driven here
# directly; the "$U" header array is what authenticates the approval, so it is a
# real authenticated approval by that user.
# bridge_public_key must be a 130-char lowercase-hex uncompressed P-256 point, no
# bridge_key_fingerprint may be sent (the Hub derives it), and PKCE is S256-only.
AUTHZ=$(curl -sf -m5 -X POST "http://$H/api/v1/device/authorize" -H 'Content-Type: application/json' \
  -d '{"client":"ham-bridge","device_label":"e2e","os":"linux","os_user":"tester","bridge_public_key":"040102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40","code_challenge":"J6jJRRlTiLmCVJAjMgzOjMLRQ-xSS_tovxAjutN8JWI","code_challenge_method":"S256"}')
UCODE=$(printf '%s' "$AUTHZ" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["user_code"])')
DCODE=$(printf '%s' "$AUTHZ" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["device_code"])')
curl -sf -m5 "${U[@]}" -X POST "http://$H/api/v1/device/approve" -H 'Content-Type: application/json' \
  -d "{\"user_code\":\"$UCODE\",\"approve\":true}" >/dev/null
TRESP=$(curl -sf -m5 -X POST "http://$H/api/v1/device/token" -H 'Content-Type: application/json' \
  -d "{\"device_code\":\"$DCODE\",\"code_verifier\":\"heimdall-req-impl-6-test-code-verifier-aaaa\"}")
printf '%s' "$TRESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["access_token"])' > "$TOKF"
# Refresh half beside it, under the suffix the bridge itself uses, so the bridge can
# renew instead of dying when the access token's hour is up.
printf '%s' "$TRESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"].get("refresh_token",""))' > "$TOKF.refresh"
chmod 600 "$TOKF" "$TOKF.refresh"
BT=$(cat "$TOKF")
AG=$(curl -sf -m5 "${U[@]}" -X POST "http://$H/api/v1/agents" -H 'Content-Type: application/json' \
  -d '{"name":"E2E Agent","slug":"e2e","default_provider":"claude","default_tier":"normal","instructions":"You are the e2e test agent."}')
AID=$(printf '%s' "$AG" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["agent_id"])')
echo "[e2e] agent=$AID bridge_token=${BT:0:12}..."

fail() { echo "FAIL: $1"; exit 1; }

echo "######## (1) COLD ########"
OUT1=$("$HARNESS" "http://$H" "$BT" "$AID" "$CACHE" cold 2>&1); echo "$OUT1"
echo "$OUT1" | grep -q "manifest MISS (200)" || fail "cold: expected manifest MISS(200)"
[ "$(echo "$OUT1" | grep -c "blob FETCH (hub)")" -ge 4 ] || fail "cold: expected blob FETCHes"
echo "$OUT1" | grep -q "blob HIT (disk)" && fail "cold: must have zero disk HITs" || true

echo "######## (2) WARM ########"
OUT2=$("$HARNESS" "http://$H" "$BT" "$AID" "$CACHE" warm 2>&1); echo "$OUT2"
echo "$OUT2" | grep -q "manifest HIT (304)" || fail "warm: expected manifest HIT(304)"
[ "$(echo "$OUT2" | grep -c "blob FETCH (hub)")" -eq 0 ] || fail "warm: expected ZERO blob fetches"
[ "$(echo "$OUT2" | grep -c "blob HIT (disk)")" -ge 4 ] || fail "warm: expected disk HITs"

echo "[e2e] adding an agent-scoped memory"
curl -sf -m5 "${U[@]}" -X POST "http://$H/api/v1/memories" -H 'Content-Type: application/json' \
  -d "{\"type\":\"fact\",\"title\":\"E2E Rule\",\"body\":\"Always cite the run id.\",\"agent_id\":\"$AID\",\"status\":\"active\"}" >/dev/null

echo "######## (3) AFTER_MEMORY ########"
OUT3=$("$HARNESS" "http://$H" "$BT" "$AID" "$CACHE" after_memory 2>&1); echo "$OUT3"
echo "$OUT3" | grep -q "manifest MISS (200)" || fail "after_memory: expected manifest MISS(200)"
[ "$(echo "$OUT3" | grep -c "blob FETCH (hub)")" -eq 1 ] || fail "after_memory: expected EXACTLY ONE blob FETCH"
echo "$OUT3" | grep -q "contains_new_memory= true" || fail "after_memory: new memory must be in AGENTS.md"

echo
echo "PASS: TEST-1 all three scenarios (COLD 200+FETCH / WARM 304+0 fetch / AFTER_MEMORY 200+1 FETCH + memory present)"
