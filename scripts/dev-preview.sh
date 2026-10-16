#!/usr/bin/env bash
# dev-preview.sh — run a live Vite dev server with HMR in a ham-ctl shell session
# for instant, live UI previews in Heimdall.
#
# What this gets you:
# - Live Vite dev server running under /api/v1/preview/<session_id>/
# - Instant Hot Module Replacement (HMR) on file save
# - Injected slash guard ensuring hash routing starts cleanly at #/
# - Real-time diagnostics in `ham-ctl shell log <session_id>`
#
# Usage:
#   scripts/dev-preview.sh            # start dev preview session
#   scripts/dev-preview.sh --stop     # terminate session
#
# Env:
#   HEIMDALL_PREVIEW_PORT       port for reverse proxy (default: 5173)
#   HEIMDALL_VITE_PORT          port for internal Vite (default: 5174)
#   HEIMDALL_PREVIEW_CHAIN      file session under this chain (optional)
#   HAM_CTL                     ham-ctl binary path (optional)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Assume the directory the script was run from is the target repository to watch
REPO="${PWD}"
if [[ ! -f "$REPO/package.json" && -f "$REPO/../package.json" ]]; then
  REPO="$(cd "$REPO/.." && pwd)"
fi
cd "$REPO"

PORT="${HEIMDALL_PREVIEW_PORT:-5173}"
VITE_PORT="${HEIMDALL_VITE_PORT:-5174}"
if [[ -z "${HAM_CTL:-}" ]]; then
  for candidate in \
    "$REPO/.heimdall/bin/ham-ctl" \
    /tmp/heimdall-bridge-local/instances/*/.heimdall/bin/ham-ctl \
    "$HOME/.nix-profile/bin/ham-ctl" \
    "/usr/local/google/home/tanmayvijay/.nix-profile/bin/ham-ctl"; do
    if [[ -x "$candidate" ]]; then
      HAM_CTL="$candidate"
      break
    fi
  done
  HAM_CTL="${HAM_CTL:-$(which ham-ctl 2>/dev/null || true)}"
fi
LABEL="heimdall-ui-live-preview"
STATE="$REPO/.dev-preview-session"

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

json() { python3 -c 'import json,sys,re; raw=sys.stdin.read(); m=re.search(r"(\{.*\})", raw, re.DOTALL); d=json.loads(m.group(1)) if m else {}; exec(sys.argv[1])' "$1"; }

command -v python3 >/dev/null || die "python3 is required (used to read ham-ctl JSON)"
command -v "$HAM_CTL" >/dev/null || die "ham-ctl not found at $HAM_CTL"

# --- stop ------------------------------------------------------------------
if [[ "${1:-}" == "--stop" ]]; then
  [[ -f "$STATE" ]] || die "no session recorded in $STATE"
  sid="$(cat "$STATE")"
  "$HAM_CTL" shell kill "$sid" >/dev/null 2>&1 || true
  rm -f "$STATE"
  log "killed session $sid"
  exit 0
fi

# --- 1. kill previous dev preview sessions ---------------------------------
log "checking for previous dev preview sessions"
prev=""
if [[ -f "$STATE" ]]; then
  prev="$(cat "$STATE")"
fi

running_sids="$("$HAM_CTL" shell list --status running 2>/dev/null \
  | json 'print(" ".join(s["session_id"] for s in d.get("data",{}).get("data",{}).get("sessions",[])
                         if s.get("status")=="running" and s.get("label")=="'"$LABEL"'"))' 2>/dev/null || true)"

for old in $prev $running_sids; do
  if [[ -n "$old" ]]; then
    log "killing old session $old"
    "$HAM_CTL" shell kill "$old" >/dev/null 2>&1 || true
  fi
done
rm -f "$STATE"

# Wait for port to clear
for _ in $(seq 1 20); do
  (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null || break
  exec 3>&- 3<&-
  sleep 0.5
done

# --- 2. start shell session ------------------------------------------------
log "starting dev preview shell session on port $PORT (internal Vite on $VITE_PORT)"
BRIDGE="${HEIMDALL_BRIDGE_ID:-}"
if [[ -z "$BRIDGE" ]]; then
  BRIDGE="$("$HAM_CTL" bridge list | json '
bridges = d.get("data",{}).get("bridges",[])
match = [b["bridge"]["bridge_id"] for b in bridges if b.get("origin") == "hub" and b.get("bridge",{}).get("status") == "online" and "jetski" in str(b.get("bridge",{}).get("capabilities",[]))]
if not match:
  match = [b["bridge"]["bridge_id"] for b in bridges if b.get("origin") == "hub" and b.get("bridge",{}).get("status") == "online"]
print(match[0] if match else "brg_18d03379a7d6d47b")
')"
fi
ENDPOINT_PORT="$("$HAM_CTL" bridge list --scope configured | json 'print(d["data"]["bridges"][0]["local_endpoint_port"])')"

EXTRA=()
CHAIN="${HEIMDALL_PREVIEW_CHAIN:-}"
if [[ -z "$CHAIN" ]]; then
  CHAIN="$("$HAM_CTL" context 2>/dev/null | json 'print(d.get("data",{}).get("data",{}).get("chain_id",""))' 2>/dev/null || true)"
fi
if [[ -n "$CHAIN" ]]; then
  EXTRA+=(--chain "$CHAIN")
fi


UPSTREAM_FLAG=""
if [[ -n "${HEIMDALL_PREVIEW_UPSTREAM:-}" ]]; then
  UPSTREAM_FLAG="--upstream $HEIMDALL_PREVIEW_UPSTREAM"
elif (exec 3<>"/dev/tcp/127.0.0.1/8080") 2>/dev/null; then
  exec 3>&- 3<&-
  UPSTREAM_FLAG="--upstream http://127.0.0.1:8080"
elif (exec 3<>"/dev/tcp/127.0.0.1/8090") 2>/dev/null; then
  exec 3>&- 3<&-
  UPSTREAM_FLAG="--upstream http://127.0.0.1:8090"
fi

SID=""
for attempt in 0 1 2 3; do
  CUR_PORT=$((PORT + attempt * 2))
  CUR_VITE_PORT=$((VITE_PORT + attempt * 2))
  START_RESPONSE="$("$HAM_CTL" shell start \
    --bridge "$BRIDGE" \
    ${EXTRA[@]+"${EXTRA[@]}"} \
    --kind server \
    --port "$CUR_PORT" \
    --label "$LABEL" \
    --cwd "$REPO" \
    --cmd "node \"$SCRIPT_DIR/dev-preview.mjs\" --port $CUR_PORT --vite-port $CUR_VITE_PORT --root \"$REPO\" --ham-ctl \"$HAM_CTL\" ${UPSTREAM_FLAG}")"

  SID="$(printf '%s' "$START_RESPONSE" | json 'print(d.get("data",{}).get("data",{}).get("session",{}).get("session_id",""))' 2>/dev/null || true)"
  if [[ -n "$SID" ]]; then
    PORT="$CUR_PORT"
    VITE_PORT="$CUR_VITE_PORT"
    break
  fi
  if ! echo "$START_RESPONSE" | grep -q "already held"; then
    die "shell start returned no session_id. Response was: $START_RESPONSE"
  fi
  log "port $CUR_PORT already held on bridge; trying port $((CUR_PORT + 2))"
done

[[ -n "$SID" ]] || die "shell start returned no session_id. Response was: $START_RESPONSE"
echo "$SID" > "$STATE"

log "started session $SID on port $PORT (PID $(printf '%s' "$START_RESPONSE" | json 'print(d.get("data",{}).get("data",{}).get("session",{}).get("pid","?"))'))"

# --- 3. wait for server to become ready -------------------------------------
BASE="http://127.0.0.1:$ENDPOINT_PORT/proxy/$SID"
log "waiting for preview tunnel at $BASE/ to become ready"

ready=0
for _ in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/" 2>/dev/null || echo 000)"
  if [[ "$code" == "200" ]]; then
    ready=1
    break
  fi
  sleep 0.5
done

if (( ! ready )); then
  die "dev preview server did not answer 200 within 30s. Check logs:
    $HAM_CTL shell log $SID"
fi

# --- 4. verify preview response --------------------------------------------
log "verifying preview HTML and guard"
html="$(curl -s "$BASE/")"

if echo "$html" | grep -q 'data-heimdall-preview-guard'; then
  printf '  ok   %-28s guard injected\n' "slash guard"
else
  printf '  FAIL %-28s missing guard script\n' "slash guard"
fi

if echo "$html" | grep -q "/api/v1/preview/$SID/"; then
  printf '  ok   %-28s Vite base configured\n' "base prefix"
else
  printf '  WARN %-28s base prefix not seen in initial HTML\n' "base prefix"
fi

log "dev preview is ready!"
echo "  Session ID:      $SID"
echo "  Bridge Local:    http://127.0.0.1:$ENDPOINT_PORT/proxy/$SID/#/"
echo "  Remote Preview:  https://heimdall.mundus.in/api/v1/preview/$SID/#/"
echo ""
echo "Stream logs with:"
echo "  $HAM_CTL shell log $SID"
