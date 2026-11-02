#!/usr/bin/env bash
# Real local Hub/Bridge profile isolation smoke. No cloud model calls: a recording
# provider fixture launches via the real PTY/bootstrap and delegates plugin work
# to the installed Claude CLI against the checkout's LOCAL marketplace.
# Requires built runtime binaries, Node/UI dependencies, and a local Claude CLI.
# HEIMDALL_PROFILE_SMOKE_BIN_DIR, HEIMDALL_PROFILE_SMOKE_PORT_BASE (39300),
# HEIMDALL_PROFILE_SMOKE_REAL_CLAUDE, HEIMDALL_PROFILE_SMOKE_KEEP=1 (live preview).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTUAL_HOME="$HOME"
BIN="${HEIMDALL_PROFILE_SMOKE_BIN_DIR:?Set HEIMDALL_PROFILE_SMOKE_BIN_DIR to built runtime binaries}"
REAL_CLAUDE="${HEIMDALL_PROFILE_SMOKE_REAL_CLAUDE:-$(command -v claude || true)}"
[ -x "$REAL_CLAUDE" ] || { echo 'A local Claude CLI is required for real plugin installation.' >&2; exit 1; }
PB="${HEIMDALL_PROFILE_SMOKE_PORT_BASE:-39300}"
mkdir -p "${TMPDIR:-$ACTUAL_HOME/.cache/heimdall-tests}"
WORK="$(mktemp -d "${TMPDIR:-$ACTUAL_HOME/.cache/heimdall-tests}/profile-integration.XXXXXX")"
chmod 700 "$WORK"
export HEIMDALL_LOCAL_STATE_ROOT="$WORK/state"
export P4_REAL_CLAUDE="$REAL_CLAUDE"
HUB="$ROOT/scripts/local-hub.sh" BRIDGE="$ROOT/scripts/local-bridge.sh"
export HOME="$WORK/fake-home"
export CLAUDE_CONFIG_DIR="$WORK/decoys/claude" CODEX_HOME="$WORK/decoys/codex" GEMINI_CONFIG_DIR="$WORK/decoys/gemini"
export XDG_CONFIG_HOME="$WORK/decoys/config" XDG_DATA_HOME="$WORK/decoys/data" XDG_STATE_HOME="$WORK/decoys/state" XDG_CACHE_HOME="$WORK/decoys/cache"
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN OPENAI_API_KEY GOOGLE_API_KEY GEMINI_API_KEY
KEEP=0
cleanup() {
  [ "$KEEP" = 1 ] && return
  local cleanup_failed=0
  if [ -f "$WORK/state/bridges/profiles/config.toml" ]; then
    "$BRIDGE" stop --name profiles --purge-home >"$WORK/purge.log" 2>&1 || cleanup_failed=1
  fi
  "$HUB" stop --name profiles >"$WORK/stop.log" 2>&1 || true
  if [ "$cleanup_failed" = 1 ] || [ "${HEIMDALL_PROFILE_SMOKE_KEEP_FAILURE:-0}" = 1 ]; then
    printf 'Private diagnostic state: %s\n' "$WORK" >&2
  else rm -rf "$WORK"; fi
}
trap cleanup EXIT
node "$ROOT/scripts/local-runtime/profile-fixture.mjs" "$WORK" "$ACTUAL_HOME" "$ROOT/tests/fixtures/profile-provider.mjs"
start_hub() {
  timeout 180 "$HUB" start --name profiles --hub-port "$((PB+1))" --proxy-port "$((PB+2))" --ui-port "$((PB+3))" --oidc-port "$((PB+6))" --no-plan-limits --bin-dir "$BIN" >"$WORK/hub-start.log" 2>&1
}
start_bridge() {
  timeout 180 "$BRIDGE" start --name profiles --hub profiles --port "$((PB+4))" --local-endpoint-port "$((PB+5))" --auto-enroll --bin-dir "$BIN" >"$WORK/bridge-start.log" 2>&1
}
start_hub || { tail -n 30 "$WORK/hub-start.log"; exit 1; }
start_bridge || { tail -n 30 "$WORK/bridge-start.log"; exit 1; }
export HEIMDALL_LOCAL_UI_ORIGIN="http://127.0.0.1:$((PB+3))"
timeout 480 node --import "$ROOT/tests/helpers/vaultEndpointHarness.ts" "$ROOT/scripts/local-runtime/profile-integration.mjs" \
  "$HEIMDALL_LOCAL_UI_ORIGIN" "$WORK" "$ACTUAL_HOME" | tee "$WORK/integration.log"
"$BRIDGE" stop --name profiles --purge-home >"$WORK/purge.log" 2>&1
BD="$WORK/state/bridges/profiles"
for p in home credentials data/bridge/provider_profiles.json data/bridge/profile-secrets; do
  [ ! -e "$BD/$p" ] || { echo "FAIL purge left $p"; exit 1; }
done
[ -f "$WORK/profile-private-0/plugins/installed_plugins.json" ] && [ -f "$WORK/profile-private-1/plugins/installed_plugins.json" ]
echo 'ok   purge removed bridge home, identity, profiles, secrets and credentials; user runtime dirs retained'
"$HUB" stop --name profiles >"$WORK/stop.log" 2>&1
for delta in 1 2 3 4 5 6; do
  if (exec 3<>"/dev/tcp/127.0.0.1/$((PB+delta))") 2>/dev/null; then echo "FAIL port $((PB+delta)) remains bound"; exit 1; fi
done
echo 'ok   all private stack ports released'
if [ -n "${HEIMDALL_PROFILE_SMOKE_RESULT:-}" ]; then cp "$WORK/result.json" "$HEIMDALL_PROFILE_SMOKE_RESULT"; fi
if [ "${HEIMDALL_PROFILE_SMOKE_KEEP:-0}" = 1 ]; then
  start_hub
  start_bridge
  timeout 60 node --import "$ROOT/tests/helpers/vaultEndpointHarness.ts" "$ROOT/scripts/local-runtime/profile-integration.mjs" \
    "$HEIMDALL_LOCAL_UI_ORIGIN" "$WORK" "$ACTUAL_HOME" --seed-only
  KEEP=1
  [ -z "${HEIMDALL_PROFILE_SMOKE_STATE_FILE:-}" ] || printf '%s\n' "$WORK" >"$HEIMDALL_PROFILE_SMOKE_STATE_FILE"
  printf 'Live review state: %s\n' "$WORK"
fi
echo 'PASS (profile integration plus purge and port cleanup)'
