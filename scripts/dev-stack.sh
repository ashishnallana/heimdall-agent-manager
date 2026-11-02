#!/usr/bin/env bash
# Local Heimdall dev stack: mock OIDC + hub + dev-proxy + bridge + (optional) UI.
# Users authenticate only with OIDC; locally that is tools/mock-oidc (DEV ONLY).
# Everything talks to the LOCAL hub (127.0.0.1:8081), never hub.mundus.in.
#
# Usage:
#   scripts/dev-stack.sh build      # build fresh nix binaries -> ./result-* symlinks
#   scripts/dev-stack.sh start      # repair bridge config, then start hub+proxy+bridge
#   scripts/dev-stack.sh enroll     # mint a fresh bridge token for this hub.db (fixes
#                                   # "bridge is offline" after a hub.db reset)
#   scripts/dev-stack.sh fix-config # rewrite bridge ham_ctl_bin/wrapper_bin to current
#                                   # build + strip [[peer]] blocks (start does this too)
#   scripts/dev-stack.sh stop       # stop local hub+proxy+bridge (NOT the mundus bridge)
#   scripts/dev-stack.sh status     # show what is running
#   scripts/dev-stack.sh ui         # run the Vite+Electron dev UI (foreground)
#
# Note: `start` always repairs the bridge config so it points at the CURRENT
# freshly-built ham-ctl/ham-wrapper. This avoids the classic trap where a pinned
# stale /nix/store ham-ctl lacks `agent start-success`, so launched agents run but
# get stuck at startup_failed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# RUN_DIR holds the pidfiles, logs and the generated bridge config. It is
# env-overridable for the same reason the ports are: `stop` kills whatever the
# pidfiles here name, so two stacks sharing this directory means one agent's `stop`
# can kill another agent's hub, bridge and proxy. Several agents run this script on
# the same checkout concurrently, so an isolated stack needs an isolated RUN_DIR as
# well as isolated ports. The default is unchanged.
RUN_DIR="${HAM_DEV_RUN_DIR:-$ROOT/.run-logs}"
mkdir -p "$RUN_DIR/bridge"

# Ports are env-overridable so a second stack can run beside an existing one, and
# so the stack can dodge a port already taken by an unrelated service on the host.
# Defaults are unchanged.
HUB_ADDR="${HAM_DEV_HUB_ADDR:-127.0.0.1:8081}"
PROXY_ADDR="${HAM_DEV_PROXY_ADDR:-127.0.0.1:8080}"
# The hub's --ui-origin: where its OIDC callback lands and the Origin its CSRF check
# expects on cookie-carrying requests. It is the browser UI (Vite, `dev-stack.sh ui`),
# not the proxy: the proxy brokers the sign-in (REQ-DEVAUTH) and sends this Origin to
# the hub itself, so a login on localhost lands on the UI and cookie WebSockets pass.
UI_ORIGIN="${HAM_DEV_UI_ORIGIN:-http://127.0.0.1:${HAM_DEV_UI_PORT:-5173}}"
# Extra browser origins the dev proxy may attach the brokered session for, comma
# separated (loopback origins always are). Only needed when a reverse proxy other
# than scripts/dev-preview.mjs or scripts/preview-server.mjs fronts the stack; those
# two rewrite the Heimdall preview origin themselves.
TRUSTED_ORIGINS="${HAM_DEV_TRUSTED_ORIGINS:-}"
# Mock OIDC provider (tools/mock-oidc): the only way to sign in to this local hub.
MOCK_OIDC_PORT="${HAM_DEV_OIDC_PORT:-8090}"
# shellcheck source=lib/hub-oidc-dev.sh
. "$ROOT/scripts/lib/hub-oidc-dev.sh"
BRIDGE_PORT="${HAM_DEV_BRIDGE_PORT:-49327}"
BRIDGE_LOCAL_ENDPOINT_PORT="${HAM_DEV_BRIDGE_LOCAL_ENDPOINT_PORT:-49328}"
HUB_DB="${HAM_DEV_HUB_DB:-$ROOT/hub.db}"
MIGRATIONS="$ROOT/src/hub/repository/sqlite/migrations"
BRIDGE_CONFIG="$RUN_DIR/bridge/bridge-config-full.toml"
BRIDGE_RUN_DIR="${HAM_DEV_BRIDGE_RUN_DIR:-/tmp/heimdall-bridge-dev}"

build() {
  echo "[dev-stack] building fresh binaries via nix..."
  nix build "$ROOT#ham-hub" -o result-hub
  nix build "$ROOT#ham-dev-proxy" -o result-devproxy
  nix build "$ROOT#ham-bridge" -o result-bridge
  nix build "$ROOT#ham-ctl" -o result-ctl
  # BR-2: the dev bridge drives agents through ham-pty-host (same runtime as
  # production), so build it too and point the bridge at it in start().
  nix build "$ROOT#ham-pty-host" -o result-ptyhost
  echo "[dev-stack] built:"
  for r in result-hub result-devproxy result-bridge result-ctl result-ptyhost; do
    printf '  %-18s -> %s\n' "$r" "$(readlink "$r")"
  done
}

BRIDGE_TOKEN_FILE="$RUN_DIR/bridge/bridge-token"

# Rewrite the volatile fields in the bridge config so it always points at the
# CURRENT freshly-built binaries and this hub. This prevents the classic dev trap
# where the config pins stale /nix/store ham-ctl / ham-wrapper paths — an old
# ham-ctl lacks `agent start-success`, so every launched agent times out to
# startup_failed even though it is actually running.
_fix_bridge_config() {
  # Seed the config on first use instead of warning and carrying on.
  #
  # This function always required $BRIDGE_CONFIG to exist already, which worked only
  # because the default RUN_DIR had one left behind by an earlier run. Now that
  # RUN_DIR is overridable, a fresh stack starts with no config at all and the bridge
  # was being launched with --config pointing at a missing file. Seeding from the
  # repo's config.toml makes an isolated stack work from nothing, which is the whole
  # point of being able to isolate it.
  if [ ! -f "$BRIDGE_CONFIG" ]; then
    if [ -f "$ROOT/config.toml" ]; then
      mkdir -p "$(dirname "$BRIDGE_CONFIG")"
      cp "$ROOT/config.toml" "$BRIDGE_CONFIG"
      echo "[dev-stack] seeded $BRIDGE_CONFIG from config.toml"
    else
      echo "[dev-stack] WARN: $BRIDGE_CONFIG missing and no config.toml to seed from; skipping config fix"
      return
    fi
  fi
  local ctl_bin
  ctl_bin="$ROOT/result-ctl/bin/ham-ctl"
  BRIDGE_CONFIG="$BRIDGE_CONFIG" CTL_BIN="$ctl_bin" \
  HUB_URL="http://$HUB_ADDR" python3 - <<'PY'
import os, re
cfg = os.environ["BRIDGE_CONFIG"]
ctl, hub = os.environ["CTL_BIN"], os.environ["HUB_URL"]
t = open(cfg).read()

def set_key(text, key, value):
    # Replace `key = "..."` if present, else return unchanged (caller may append).
    pat = re.compile(rf'^({re.escape(key)} = ")[^"]*(")', re.M)
    if pat.search(text):
        return pat.sub(lambda m: f'{m.group(1)}{value}{m.group(2)}', text, count=1)
    return text

# Point tool binaries at the current build.
t = set_key(t, "ham_ctl_bin", ctl)
# Point the bridge/ctl at this local hub.
t = re.sub(r'(\[ctl\]\s*\n\s*\ndaemon_url = ")[^"]*(")', lambda m: f'{m.group(1)}{hub}{m.group(2)}', t, count=1)
# The bridge token is deliberately NOT written into config.toml any more.
#
# It used to be folded in from the token file. That was harmless when the credential
# never expired; it is actively wrong now that the access token has a 1h TTL and is
# rotated by the running bridge. A copy in config.toml goes stale within the hour and
# is never refreshed, so it becomes a second, lying source of truth. The bridge is
# started with --bridge-token-file and reads the live file, which the refresh worker
# keeps current. Audit F2 (a plaintext token sitting in config.toml) is also mooted
# by removing this line rather than merely by deleting the old enrollment flow.

# Strip any [[peer]] blocks (local single-hub dev needs no federation peers; a
# stale cloudtop peer just spams failed ws dials).
lines = t.split('\n'); out = []; skip = False
for l in lines:
    if l.strip() == '[[peer]]':
        skip = True; continue
    if skip and l.startswith('[') and l.strip() != '[[peer]]':
        skip = False
    if skip and l.strip() == '':
        skip = False; continue
    if not skip:
        out.append(l)
open(cfg, 'w').write('\n'.join(out))
print(f"[dev-stack] bridge config: ham_ctl_bin -> {ctl}")
print("[dev-stack] bridge config: stripped [[peer]] blocks")
PY
}

# Ensure the bridge config has a bridge_token that this hub.db actually knows.
# If the current token fails the hub-runtime handshake, re-enroll to mint a fresh
# matching token and write it into the config. Idempotent.
# enroll drives the BROWSER-APPROVED DEVICE FLOW, which is the only enrollment there
# is (REQ-ENROLL-9). The one-time `hbe_` token and `POST /api/v1/bridges/enroll` are
# deleted, so the old two-step "mint a token, then exchange it" is gone.
#
# HOW THIS STAYS NON-INTERACTIVE WITHOUT WEAKENING ANYTHING. The device flow requires
# a human approval, and that is the point of it — but on this stack the local user
# can sign in non-interactively through the mock OIDC provider (the real browser
# flow, auto-approved). So the script signs in, then POSTs the approval with that
# browser session: a real, authenticated approval by the local developer, made
# through the same endpoint and Auth_Context a browser would use. No test-only
# bypass exists in the Hub, and none is needed here.
#
# WHAT IS WRITTEN. The credential is now an EXPIRING PAIR: the access token goes to
# $BRIDGE_TOKEN_FILE and the refresh token to "$BRIDGE_TOKEN_FILE.refresh". The
# running bridge renews the access token on its own. The token is deliberately NOT
# folded into config.toml any more — see _fix_bridge_config.
enroll() {
  [ -e result-bridge ] || { echo "[dev-stack] run 'build' first"; exit 1; }
  _running "$(_pidfile hub)" || { echo "[dev-stack] start the hub first (dev-stack start)"; exit 1; }
  _running "$(_pidfile devproxy)" || { echo "[dev-stack] start the dev-proxy first (dev-stack start) — the approval goes through it"; exit 1; }
  mkdir -p "$RUN_DIR/bridge"

  local log="$RUN_DIR/bridge/enroll.log"
  rm -f "$log" "$BRIDGE_TOKEN_FILE" "$BRIDGE_TOKEN_FILE.refresh"

  # The production command restarts a registered service after handoff. This
  # source-tree harness owns lifecycle itself, so a scoped fake acknowledges
  # that restart while the harness starts the bridge in its normal start step.
  mkdir -p "$RUN_DIR/enroll-bin"
  printf '#!/bin/sh\nexit 0\n' > "$RUN_DIR/enroll-bin/systemctl"
  chmod 0755 "$RUN_DIR/enroll-bin/systemctl"
  echo "[dev-stack] starting device-flow enrollment (headless) against http://$HUB_ADDR"
  PATH="$RUN_DIR/enroll-bin:$PATH" ./result-bridge/bin/ham-bridge enroll \
    --hub "http://$HUB_ADDR" --headless \
    --config "$BRIDGE_CONFIG" \
    --bridge-token-file "$BRIDGE_TOKEN_FILE" > "$log" 2>&1 &
  local enroll_pid=$!

  # Wait for the user code the bridge printed. Taking the last field of the
  # "enter the code" (older bridges) / "Enter device code" (current) line keeps this independent of the code's alphabet and width.
  local code=""
  local i
  for i in $(seq 1 30); do
    # `|| true` is load-bearing: this script runs under `set -e`, and grep exits 1
    # when the line is not there yet — which is the NORMAL case on early iterations.
    # Without it the assignment fails and the whole script exits silently, with the
    # enrollment half-started and no diagnostic. That is exactly what happened the
    # first time this ran.
    code="$(grep -aiE 'enter (the|device) code' "$log" 2>/dev/null | tail -1 | awk '{print $NF}' || true)"
    [ -n "$code" ] && break
    kill -0 "$enroll_pid" 2>/dev/null || break
    sleep 1
  done
  if [ -z "$code" ]; then
    kill "$enroll_pid" 2>/dev/null || true
    echo "[dev-stack] enrollment did not produce a user code; enroll log follows:"
    sed 's/^/  /' "$log"
    exit 1
  fi
  echo "[dev-stack] approving code $code as the local user via dev-proxy"

  local approve session
  session="$(hub_oidc_login "http://$PROXY_ADDR" tanmay)" || { kill "$enroll_pid" 2>/dev/null || true; echo "[dev-stack] OIDC sign-in failed (is the mock running? dev-stack start)"; exit 1; }
  approve="$(curl -s -m10 -X POST "http://$PROXY_ADDR/api/v1/device/approve" \
    -H "$(hub_oidc_cookie "$session")" -H "Origin: $UI_ORIGIN" \
    -H 'Content-Type: application/json' \
    -d "{\"user_code\":\"$code\",\"approve\":true}")"
  case "$approve" in
    *'"error"'*)
      kill "$enroll_pid" 2>/dev/null || true
      echo "[dev-stack] approval failed: $approve"
      exit 1
      ;;
  esac

  # The bridge is polling; it exits once it has stored its credential.
  if ! wait "$enroll_pid"; then
    echo "[dev-stack] enrollment failed; enroll log follows:"
    sed 's/^/  /' "$log"
    exit 1
  fi
  [ -s "$BRIDGE_TOKEN_FILE" ] || { echo "[dev-stack] enroll did not write an access token to $BRIDGE_TOKEN_FILE"; sed 's/^/  /' "$log"; exit 1; }
  [ -s "$BRIDGE_TOKEN_FILE.refresh" ] || { echo "[dev-stack] enroll did not write a refresh token to $BRIDGE_TOKEN_FILE.refresh"; sed 's/^/  /' "$log"; exit 1; }

  _fix_bridge_config
  echo "[dev-stack] enrolled."
  echo "  access token : $BRIDGE_TOKEN_FILE  (expires; the bridge renews it)"
  echo "  refresh token: $BRIDGE_TOKEN_FILE.refresh"
}

_pidfile() { echo "$RUN_DIR/$1.pid"; }

_running() { # $1=pidfile
  local f="$1"
  [ -f "$f" ] && kill -0 "$(cat "$f")" 2>/dev/null
}

_stop_pidfile() { # $1=name
  local f; f="$(_pidfile "$1")"
  if _running "$f"; then
    local pid; pid="$(cat "$f")"
    echo "[dev-stack] stopping $1 (pid $pid)"
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$f"
}

_stop_by_match() { # $1=grep-pattern label
  # Stop LOCAL processes matching pattern, but never the mundus bridge.
  local pat="$1"
  local pids
  pids=$(ps ax -o pid= -o command= | grep -E "$pat" | grep -v grep | grep -v "hub.mundus.in" | awk '{print $1}' || true)
  for pid in $pids; do
    echo "[dev-stack] stopping stray '$pat' pid $pid"
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
  done
}

stop() {
  _stop_pidfile oidc
  _stop_pidfile hub
  _stop_pidfile devproxy
  _stop_pidfile bridge
  # Clean up any stale copies bound to the local hub only.
  _stop_by_match "ham-hub .*--listen ${HUB_ADDR}"
  _stop_by_match "ham-dev-proxy .*${PROXY_ADDR}"
  # Match on $HUB_ADDR, not a hardcoded 8081: with HAM_DEV_HUB_ADDR overridden
  # the literal both MISSED the dev bridge this script started and could match
  # an UNRELATED bridge that happens to talk to :8081 on a shared host.
  _stop_by_match "ham-bridge .*hub http://${HUB_ADDR}"
  echo "[dev-stack] local stack stopped (mundus bridge left running)."
}

start() {
  [ -e result-hub ] || { echo "[dev-stack] run 'build' first"; exit 1; }
  stop
  sleep 1

  echo "[dev-stack] starting mock OIDC provider on 127.0.0.1:$MOCK_OIDC_PORT (dev only)"
  nohup python3 "$ROOT/tools/mock-oidc/mock_oidc.py" --port "$MOCK_OIDC_PORT" --username tanmay \
    >"$RUN_DIR/mock-oidc.log" 2>&1 &
  echo $! > "$(_pidfile oidc)"
  disown $!
  hub_oidc_export_env

  echo "[dev-stack] starting hub on $HUB_ADDR"
  nohup ./result-hub/bin/ham-hub \
    --listen "$HUB_ADDR" --db "$HUB_DB" \
    --migrations-dir "$MIGRATIONS" \
    --ui-origin "$UI_ORIGIN" \
    >"$RUN_DIR/hub.log" 2>&1 &
  echo $! > "$(_pidfile hub)"
  disown $!
  sleep 2

  # Fail loudly if the hub did not actually come up. Without this the stack
  # carries on and the health probe below can report OK from an UNRELATED process
  # that already owns the port (e.g. hub.log "listen failed ... Address_In_Use"),
  # so the bridge is pointed at a foreign service and every observation taken
  # from the stack is worthless. Better to stop here than to emit false evidence.
  if ! _running "$(_pidfile hub)"; then
    echo "[dev-stack] ERROR: hub failed to start. Last lines of $RUN_DIR/hub.log:" >&2
    tail -5 "$RUN_DIR/hub.log" >&2
    echo "[dev-stack]        if this says Address_In_Use, the port is taken by another" >&2
    echo "[dev-stack]        process; re-run with HAM_DEV_HUB_ADDR=127.0.0.1:<free-port>" >&2
    exit 1
  fi

  echo "[dev-stack] starting dev-proxy on $PROXY_ADDR -> hub (brokers OIDC sign-in)"
  local trusted_args=() origins=() origin
  IFS=, read -ra origins <<<"$TRUSTED_ORIGINS"
  for origin in ${origins[@]+"${origins[@]}"}; do [ -n "$origin" ] && trusted_args+=(--trusted-origin "$origin"); done
  nohup ./result-devproxy/bin/ham-dev-proxy \
    --listen "$PROXY_ADDR" --hub-url "http://$HUB_ADDR" \
    --hub-ui-origin "$UI_ORIGIN" ${trusted_args[@]+"${trusted_args[@]}"} \
    --default-user tanmay \
    >"$RUN_DIR/dev-proxy.log" 2>&1 &
  echo $! > "$(_pidfile devproxy)"
  disown $!
  sleep 1

  # Always repair the bridge config against the CURRENT build + this hub before
  # launching. The credential is NOT folded in — it lives only in the token file,
  # because it expires and is rotated (see _fix_bridge_config).
  _fix_bridge_config

  echo "[dev-stack] starting bridge on port $BRIDGE_PORT -> hub"
  local bridge_token_args=()
  [ -s "$BRIDGE_TOKEN_FILE" ] && bridge_token_args=(--bridge-token-file "$BRIDGE_TOKEN_FILE")
  HEIMDALL_HAM_CTL_BIN="$ROOT/result-ctl/bin/ham-ctl" \
  HEIMDALL_BRIDGE_PTY_HOST=1 \
  HEIMDALL_HAM_PTY_HOST_BIN="$ROOT/result-ptyhost/bin/ham-pty-host" \
  nohup ./result-bridge/bin/ham-bridge \
    --config "$BRIDGE_CONFIG" \
    --bind-host 127.0.0.1 --port "$BRIDGE_PORT" \
    --hub "http://$HUB_ADDR" \
    "${bridge_token_args[@]}" \
    --local-endpoint-port "$BRIDGE_LOCAL_ENDPOINT_PORT" \
    --local-run-dir "$BRIDGE_RUN_DIR" \
    >"$RUN_DIR/bridge.log" 2>&1 &
  echo $! > "$(_pidfile bridge)"
  disown $!
  sleep 3

  # Detect the stale-token trap: if the bridge never reaches "hub runtime ready",
  # the config token doesn't match this hub.db — tell the operator to enroll.
  if ! grep -q "bridge hub runtime ready" "$RUN_DIR/bridge.log"; then
    echo "[dev-stack] WARN: bridge has not reported 'hub runtime ready'."
    echo "[dev-stack]       If launches fail with 'bridge is offline', run:"
    echo "[dev-stack]         scripts/dev-stack.sh enroll && scripts/dev-stack.sh start"
  fi

  status
}

status() {
  echo "=== dev-stack status ==="
  for s in oidc hub devproxy bridge; do
    f="$(_pidfile "$s")"
    if _running "$f"; then echo "  $s: RUNNING (pid $(cat "$f"))"; else echo "  $s: stopped"; fi
  done
  echo "--- listeners ---"
  lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -E "${PROXY_ADDR##*:}|${HUB_ADDR##*:}|$BRIDGE_PORT|$BRIDGE_LOCAL_ENDPOINT_PORT" | awk '{print "  "$1, $9}' || true
  echo "--- health ---"
  curl -s -m 3 "http://$HUB_ADDR/api/v1/health" >/dev/null 2>&1 && echo "  hub /api/v1/health: OK" || echo "  hub health: (check log)"
  echo "NOTE: mundus bridge (hub.mundus.in) is intentionally left untouched."
}

ui() {
  echo "[dev-stack] launching Vite + Electron dev UI on $UI_ORIGIN (hub API -> $HUB_ADDR, /api/v1 -> dev-proxy $PROXY_ADDR)"
  HEIMDALL_HUB_API_URL="http://$HUB_ADDR" \
  HEIMDALL_DEV_PROXY_URL="http://$PROXY_ADDR" \
    npm run dev
}

case "${1:-}" in
  build) build ;;
  start) start ;;
  stop) stop ;;
  status) status ;;
  enroll) enroll ;;
  fix-config) _fix_bridge_config ;;
  ui) ui ;;
  *) echo "usage: $0 {build|start|stop|status|enroll|fix-config|ui}"; exit 2 ;;
esac
