#!/usr/bin/env bash
# Package a self-contained, de-Nixified Cloudtop bundle for Heimdall single-node operation.
# Produces dist/heimdall-cloudtop/ and dist/heimdall-cloudtop-bundle.tar.gz
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DIST_DIR="$ROOT/dist"
BUNDLE_DIR="$DIST_DIR/heimdall-cloudtop"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/bin" "$BUNDLE_DIR/lib" "$BUNDLE_DIR/share/migrations" "$BUNDLE_DIR/share/extensions" "$BUNDLE_DIR/extensions" "$BUNDLE_DIR/systemd" "$BUNDLE_DIR/scripts" "$BUNDLE_DIR/bridge"

echo "[bundle] 1. Building components via nix..."
nix build .#ham-hub -o result-hub
nix build .#ham-bridge -o result-bridge
nix build .#ham-dev-proxy -o result-devproxy
nix build .#ham-ctl -o result-ctl
nix build .#ham-pty-host -o result-ptyhost

echo "[bundle] 2. Copying binaries..."
if [ -f "result-hub/bin/.ham-hub-wrapped" ]; then
  cp "$(readlink -f result-hub/bin/.ham-hub-wrapped)" "$BUNDLE_DIR/bin/ham-hub"
else
  cp "$(readlink -f result-hub/bin/ham-hub)" "$BUNDLE_DIR/bin/ham-hub"
fi

if [ -f "result-bridge/bin/.ham-bridge-wrapped" ]; then
  cp "$(readlink -f result-bridge/bin/.ham-bridge-wrapped)" "$BUNDLE_DIR/bin/ham-bridge"
else
  cp "$(readlink -f result-bridge/bin/ham-bridge)" "$BUNDLE_DIR/bin/ham-bridge"
fi

cp "$(readlink -f result-devproxy/bin/ham-dev-proxy)" "$BUNDLE_DIR/bin/ham-dev-proxy"
cp "$(readlink -f result-ctl/bin/ham-ctl)" "$BUNDLE_DIR/bin/ham-ctl"
cp "$(readlink -f result-ptyhost/bin/ham-pty-host)" "$BUNDLE_DIR/bin/ham-pty-host"
chmod u+w "$BUNDLE_DIR/bin/"*
chmod +x "$BUNDLE_DIR/bin/"*

echo "[bundle] 3. Copying migrations & configs..."
cp -r src/hub/repository/sqlite/migrations/* "$BUNDLE_DIR/share/migrations/"
if [ -d "extensions" ]; then
  echo "[bundle] 3.05 Copying bundled extensions..."
  mkdir -p "$BUNDLE_DIR/share/extensions" "$BUNDLE_DIR/extensions"
  cp -r extensions/* "$BUNDLE_DIR/share/extensions/"
  cp -r extensions/* "$BUNDLE_DIR/extensions/"
fi
cp systemd/heimdall.service "$BUNDLE_DIR/systemd/heimdall.service"
cp scripts/install-systemd-service.sh "$BUNDLE_DIR/scripts/install-systemd-service.sh"
cp scripts/snapshot-hub.sh "$BUNDLE_DIR/scripts/snapshot-hub.sh"
cp scripts/install.sh "$BUNDLE_DIR/install.sh"
chmod +x "$BUNDLE_DIR/install.sh"
if [ -f "scripts/publish-mpm.sh" ]; then
  cp scripts/publish-mpm.sh "$BUNDLE_DIR/scripts/publish-mpm.sh"
  chmod +x "$BUNDLE_DIR/scripts/publish-mpm.sh"
fi
if [ -d "packaging" ]; then
  cp -r packaging "$BUNDLE_DIR/"
fi

echo "[bundle] 3.1 Pre-seeding Jetski provider configuration..."
mkdir -p "$BUNDLE_DIR/bridge"
cat << 'PROVIDERSEOF' > "$BUNDLE_DIR/bridge/providers.json"
{
  "default_provider": "jetski",
  "default_tier": "normal",
  "providers": [
    {
      "name": "jetski",
      "enabled": true,
      "command": [
        "/google/bin/releases/jetski-devs/tools/cli"
      ],
      "models": {
        "flag": "--model",
        "cheap": "Gemini",
        "normal": "Gemini",
        "smart": "Gemini"
      },
      "prompt_flags": [
        "--prompt-interactive"
      ],
      "yolo_flags": [
        "--dangerously-skip-permissions"
      ],
      "starter_prompt": "First, run: {ctl_bin} --token {token} start-success.",
      "prompt_delivery": "",
      "skill_dir": ".agents/skills",
      "bootstrap_file_name": "AGENTS.md",
      "startup_detection": {
        "enabled": false,
        "startup_probe_seconds": 20,
        "capture_interval_ms": 500,
        "blocked_patterns": [],
        "auto_enter_patterns": [],
        "auto_enter_pre_keys": [],
        "startup_unknown_is_blocked": false,
        "sanitized_reason_mapping": []
      },
      "activity_detection": {
        "enabled": false,
        "sample_line_count": 20,
        "ignore_bottom_lines": 0,
        "check_interval_seconds": 2,
        "min_gap_ms": 250,
        "max_gap_ms": 5000
      }
    }
  ]
}
PROVIDERSEOF
chmod 0644 "$BUNDLE_DIR/bridge/providers.json"

echo "[bundle] 3.5. Building production UI assets via vite..."
mkdir -p "$BUNDLE_DIR/ui"
npm run typecheck
npx vite build --outDir "$BUNDLE_DIR/ui"

echo "[bundle] 4. Writing start.sh and stop.sh..."
cat << 'STARTEOF' > "$BUNDLE_DIR/start.sh"
#!/usr/bin/env bash
# One-click startup script for Heimdall Cloudtop (Single-Node or Standalone Remote Bridge)
set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${HEIMDALL_DATA_DIR:-$HOME/.local/share/heimdall}"
RUN_DIR="$DATA_DIR/run"
LOG_DIR="$DATA_DIR/logs"

if [ -d "$BUNDLE_DIR/bin" ]; then
  BIN_DIR="$BUNDLE_DIR/bin"
elif [ -f "$BUNDLE_DIR/ham-hub" ]; then
  BIN_DIR="$BUNDLE_DIR"
else
  BIN_DIR="$DATA_DIR/bin"
fi

if [ -d "$BUNDLE_DIR/share/migrations" ]; then
  MIGRATIONS_DIR="$BUNDLE_DIR/share/migrations"
elif [ -d "$DATA_DIR/share/migrations" ]; then
  MIGRATIONS_DIR="$DATA_DIR/share/migrations"
elif [ -d "$BUNDLE_DIR/../share/migrations" ]; then
  MIGRATIONS_DIR="$BUNDLE_DIR/../share/migrations"
else
  MIGRATIONS_DIR="$DATA_DIR/share/migrations"
fi

mkdir -p "$DATA_DIR" "$RUN_DIR" "$LOG_DIR" "$DATA_DIR/extensions"
chmod 0700 "$DATA_DIR"
if [ -d "$BUNDLE_DIR/share/extensions" ]; then
  cp -rn "$BUNDLE_DIR/share/extensions/"* "$DATA_DIR/extensions/" 2>/dev/null || true
elif [ -d "$BUNDLE_DIR/extensions" ]; then
  cp -rn "$BUNDLE_DIR/extensions/"* "$DATA_DIR/extensions/" 2>/dev/null || true
fi

is_ancestor_or_self() {
  local target_pid="$1"
  local cur=$$
  while [ -n "$cur" ] && [ "$cur" -gt 1 ] 2>/dev/null; do
    if [ "$cur" -eq "$target_pid" ] 2>/dev/null; then
      return 0
    fi
    cur="$(ps -o ppid= -p "$cur" 2>/dev/null | tr -d ' ' || true)"
  done
  return 1
}

find_port_pids() {
  local port="$1"
  local found=""
  if command -v lsof >/dev/null 2>&1; then
    local pids_lsof
    pids_lsof="$(lsof -n -P -ti :"$port" 2>/dev/null || true)"
    found="$found $pids_lsof"
  fi
  if command -v fuser >/dev/null 2>&1; then
    local pids_fuser
    pids_fuser="$(fuser "$port/tcp" 2>/dev/null || true)"
    found="$found $pids_fuser"
  fi
  if command -v ss >/dev/null 2>&1; then
    local pids_ss
    pids_ss="$(ss -tlpn "sport = :$port" 2>/dev/null | grep -oP 'pid=\K[0-9]+' || true)"
    found="$found $pids_ss"
  fi
  echo "$found" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u || true
}

check_and_resolve_conflicts() {
  local force="${1:-false}"
  local conflict_ports=(49322 49323 49325 8989)
  if [ "${IS_STANDALONE:-false}" = true ]; then
    conflict_ports=("$BRIDGE_PORT")
  fi
  local occupied_pids=""
  local has_conflict=false
  local service_active_or_looping=false

  # 1. Check systemd service status for heimdall.service
  local is_own_unit=false
  if [ -f "/proc/self/cgroup" ] && grep -q "heimdall\.service" /proc/self/cgroup 2>/dev/null; then
    is_own_unit=true
  fi

  local should_check_systemd=true
  if [ "${IS_STANDALONE:-false}" = true ] && [ "$DATA_DIR" != "$HOME/.local/share/heimdall" ]; then
    should_check_systemd=false
  fi

  if [ "$is_own_unit" = false ] && [ "$should_check_systemd" = true ] && command -v systemctl >/dev/null 2>&1; then
    local active_state sub_state n_restarts main_pid
    active_state="$(systemctl --user show heimdall.service -p ActiveState --value 2>/dev/null || true)"
    sub_state="$(systemctl --user show heimdall.service -p SubState --value 2>/dev/null || true)"
    n_restarts="$(systemctl --user show heimdall.service -p NRestarts --value 2>/dev/null || true)"
    main_pid="$(systemctl --user show heimdall.service -p MainPID --value 2>/dev/null || true)"

    if [ "$active_state" = "active" ] || [ "$active_state" = "activating" ] || [ "$sub_state" = "auto-restart" ] || { [ -n "$n_restarts" ] && [ "$n_restarts" -gt 0 ] 2>/dev/null && [ "$active_state" != "inactive" ]; }; then
      service_active_or_looping=true
      has_conflict=true
      if [ -n "$main_pid" ] && [ "$main_pid" -gt 0 ] 2>/dev/null; then
        occupied_pids="$occupied_pids $main_pid"
      fi
    fi
  fi

  # 2. Check ports via ss / lsof / fuser
  for p in "${conflict_ports[@]}"; do
    local pids
    pids="$(find_port_pids "$p")"
    if [ -n "$pids" ]; then
      has_conflict=true
      occupied_pids="$occupied_pids $pids"
    fi
  done

  # 3. Check existing pid files in RUN_DIR
  if [ -d "$RUN_DIR" ]; then
    local pid_files=("$RUN_DIR"/*.pid)
    if [ "${IS_STANDALONE:-false}" = true ]; then
      pid_files=("$RUN_DIR/bridge.pid")
    fi
    for pf in "${pid_files[@]}"; do
      if [ -f "$pf" ]; then
        local pid
        pid="$(tr -d '[:space:]' < "$pf" 2>/dev/null || true)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
          has_conflict=true
          occupied_pids="$occupied_pids $pid"
        fi
      fi
    done
  fi

  # Filter out self and ancestor processes
  local filtered_pids=""
  for pid in $(echo "$occupied_pids" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u); do
    if ! is_ancestor_or_self "$pid"; then
      filtered_pids="$filtered_pids $pid"
    fi
  done
  filtered_pids="$(echo "$filtered_pids" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

  # If no conflict or only protected ancestors, proceed
  if [ "$has_conflict" = false ] || { [ -z "$filtered_pids" ] && [ "$service_active_or_looping" = false ]; }; then
    return 0
  fi

  local pid_display="$filtered_pids"
  if [ -z "$pid_display" ]; then
    pid_display="service: heimdall.service"
  fi

  local prompt_msg="Existing Heimdall processes/service occupy ports (PIDs $pid_display). Stop/kill them to restart cleanly? [Y/n]"

  if [ "$force" = true ] || [ "$is_own_unit" = true ]; then
    echo "[conflict] --force specified: Automatically stopping existing Heimdall processes/service (PIDs: $pid_display)..."
  elif [ -t 0 ]; then
    echo "Existing Heimdall service/processes occupy ports (PIDs $pid_display)."
    read -rp "$prompt_msg " CONFIRM_CLEAN
    if [[ "$CONFIRM_CLEAN" =~ ^[Nn]$ ]]; then
      echo "Startup aborted by user."
      exit 1
    fi
  else
    echo "[-] Error: $prompt_msg" >&2
    echo "[-] Existing Heimdall service/processes occupy ports (PIDs $pid_display)." >&2
    echo "[-] Hint: Pass --force to terminate existing processes/service automatically." >&2
    exit 1
  fi

  # Stop systemd unit if running or looping
  if [ "$is_own_unit" = false ] && [ "$should_check_systemd" = true ] && command -v systemctl >/dev/null 2>&1; then
    echo "[conflict] Stopping systemd user service heimdall.service..."
    systemctl --user stop heimdall.service 2>/dev/null || true
  fi

  # Kill stale PIDs
  if [ -n "$filtered_pids" ]; then
    echo "[conflict] Terminating stale processes (PIDs: $filtered_pids)..."
    for pid in $filtered_pids; do
      kill -TERM "$pid" 2>/dev/null || true
    done
    local kill_deadline=$((SECONDS + 3))
    for pid in $filtered_pids; do
      while kill -0 "$pid" 2>/dev/null; do
        if [ $SECONDS -ge $kill_deadline ]; then
          kill -KILL "$pid" 2>/dev/null || true
          break
        fi
        sleep 0.1
      done
    done
  fi

  # Clean stale pid files in RUN_DIR
  if [ -d "$RUN_DIR" ]; then
    if [ "${IS_STANDALONE:-false}" = true ]; then
      echo "[conflict] Cleaning stale pid files in $RUN_DIR..."
      rm -f "$RUN_DIR/bridge.pid"
    else
      echo "[conflict] Cleaning stale pid files in $RUN_DIR..."
      rm -f "$RUN_DIR"/*.pid
    fi
  fi

  # Ensure ports are freed
  for p in "${conflict_ports[@]}"; do
    local remaining
    remaining="$(find_port_pids "$p")"
    for pid in $remaining; do
      if ! is_ancestor_or_self "$pid"; then
        kill -KILL "$pid" 2>/dev/null || true
      fi
    done
  done
  sleep 0.2
}

# 0.5 Ensure Jetski provider is preconfigured
if [ ! -f "$DATA_DIR/bridge/providers.json" ] || ! grep -q '"jetski"' "$DATA_DIR/bridge/providers.json" 2>/dev/null; then
  mkdir -p "$DATA_DIR/bridge"
  chmod 0700 "$DATA_DIR/bridge"
  if [ -f "$BUNDLE_DIR/bridge/providers.json" ]; then
    cp "$BUNDLE_DIR/bridge/providers.json" "$DATA_DIR/bridge/providers.json"
  elif [ -f "$BUNDLE_DIR/../bridge/providers.json" ]; then
    cp "$BUNDLE_DIR/../bridge/providers.json" "$DATA_DIR/bridge/providers.json"
  fi
  chmod 0600 "$DATA_DIR/bridge/providers.json" 2>/dev/null || true
fi

# 1. Detect Standalone Remote Bridge Mode and options
IS_STANDALONE=false
STANDALONE_HUB_URL=""
FORCE=false
FOREGROUND=false

for arg in "$@"; do
  case "$arg" in
    --standalone)
      IS_STANDALONE=true
      ;;
    --force)
      FORCE=true
      ;;
    --foreground)
      FOREGROUND=true
      ;;
    -f)
      FORCE=true
      FOREGROUND=true
      ;;
  esac
done

if [ -f "$DATA_DIR/standalone.env" ]; then
  # shellcheck source=/dev/null
  source "$DATA_DIR/standalone.env"
  if [ "${HEIMDALL_STANDALONE:-false}" = "true" ]; then
    IS_STANDALONE=true
    STANDALONE_HUB_URL="${HEIMDALL_HUB_URL:-}"
  fi
fi

BRIDGE_PORT="${HEIMDALL_BRIDGE_PORT:-49323}"
BRIDGE_ENDPOINT_PORT="${HEIMDALL_BRIDGE_ENDPOINT_PORT:-49324}"
BRIDGE_RUN_DIR="${HEIMDALL_BRIDGE_RUN_DIR:-/tmp/heimdall-bridge-local}"

if [ "$IS_STANDALONE" = true ]; then
  # Detect if default port 49323 is already in use before conflict check
  if python3 -c "import socket; s=socket.socket(); s.settimeout(0.1); exit(0 if s.connect_ex(('127.0.0.1', int('$BRIDGE_PORT'))) == 0 else 1)" 2>/dev/null || [ -n "$(find_port_pids "$BRIDGE_PORT")" ]; then
    if [ "$BRIDGE_PORT" = "49323" ]; then
      echo "[bridge] Port 49323 is occupied; using fallback port 49325 for standalone bridge"
      BRIDGE_PORT=49325
      BRIDGE_ENDPOINT_PORT=49326
      BRIDGE_RUN_DIR="/tmp/heimdall-bridge-standalone"
    fi
  fi
fi

# 1.5 Inspect and resolve port / service conflicts
check_and_resolve_conflicts "$FORCE"

# 2. Check LOAS / gcert
if command -v gcertstatus >/dev/null 2>&1; then
  echo "[gcert] Checking LOAS certificate status..."
  gcertstatus 2>&1 | head -n 2 || true
fi

# =========================================================================
# STANDALONE REMOTE BRIDGE MODE
# =========================================================================
if [ "$IS_STANDALONE" = true ]; then
  echo "========================================================================"
  echo "    Heimdall Remote Bridge (Cloudtop Standalone Mode)"
  echo "========================================================================"
  if [ -z "$STANDALONE_HUB_URL" ]; then
    echo "[-] Error: Standalone mode enabled but HEIMDALL_HUB_URL is not set."
    echo "    Re-run install.sh --standalone or set HEIMDALL_HUB_URL in $DATA_DIR/standalone.env"
    exit 1
  fi

  BRIDGE_LOG="$LOG_DIR/bridge.log"
  BRIDGE_PID_FILE="$RUN_DIR/bridge.pid"
  BRIDGE_TOKEN_FILE="$DATA_DIR/bridge_token_cloudtop"

  if [ -f "$BRIDGE_PID_FILE" ] && kill -0 "$(cat "$BRIDGE_PID_FILE")" 2>/dev/null; then
    echo "[bridge] Already running (PID $(cat "$BRIDGE_PID_FILE"))"
  else
    echo "[bridge] Starting ham-bridge connected to Central Hub at $STANDALONE_HUB_URL..."
    export HEIMDALL_HAM_PTY_HOST_BIN="$BIN_DIR/ham-pty-host"
    export HEIMDALL_HAM_CTL_BIN="$BIN_DIR/ham-ctl"
    nohup "$BIN_DIR/ham-bridge"       --bind-host 127.0.0.1       --port "$BRIDGE_PORT"       --local-endpoint-port "$BRIDGE_ENDPOINT_PORT"       --hub "$STANDALONE_HUB_URL"       --local-run-dir "$BRIDGE_RUN_DIR"       --bridge-token-file "$BRIDGE_TOKEN_FILE" >> "$BRIDGE_LOG" 2>&1 &
    PID=$!
    echo $PID > "$BRIDGE_PID_FILE"
    disown $PID 2>/dev/null || true
  fi

  # Wait for Bridge port
  deadline=$((SECONDS + 10))
  while ! curl -s "http://127.0.0.1:$BRIDGE_PORT/api/v1/health" >/dev/null 2>&1; do
    if [ $SECONDS -ge $deadline ]; then
      echo "[-] Bridge failed to start or respond on port $BRIDGE_PORT. Check $BRIDGE_LOG"
      exit 1
    fi
    sleep 0.2
  done

  HUB_UI_URL="$(echo "$STANDALONE_HUB_URL" | sed -e 's/:49322/:8989/')"
  echo ""
  echo "========================================================================"
  echo "    Heimdall Standalone Remote Bridge is UP!"
  echo "========================================================================"
  echo "  Connected to Central Hub:"
  echo "    $STANDALONE_HUB_URL"
  echo ""
  echo "  👉 Open Central Web UI to manage agents & tasks:"
  echo "    $HUB_UI_URL"
  echo ""
  echo "  Bridge Status:   http://127.0.0.1:$BRIDGE_PORT"
  echo "  Logs:            $BRIDGE_LOG"
  echo "========================================================================"

  if [ "$FOREGROUND" = true ]; then
    trap 'echo "[supervisor] Shutting down Heimdall bridge..."; "$BIN_DIR/stop.sh" || true; exit 0' SIGTERM SIGINT SIGHUP
    echo "[supervisor] Running in foreground under systemd. Monitoring bridge daemon..."
    while true; do
      sleep 2
      if [ -f "$BRIDGE_PID_FILE" ] && ! kill -0 "$(cat "$BRIDGE_PID_FILE")" 2>/dev/null; then
        echo "[-] Process ham-bridge died unexpectedly!"
        exit 1
      fi
    done
  fi

  exit 0
fi

# =========================================================================
# FULL SINGLE-NODE STACK (Hub, Bridge, Dev-Proxy, UI)
# =========================================================================
echo "========================================================================"
echo "    Heimdall Agent Manager (Cloudtop Single-Node)"
echo "========================================================================"

# 2. Start Hub
HUB_LOG="$LOG_DIR/hub.log"
HUB_PID_FILE="$RUN_DIR/hub.pid"
HUB_SECRET_FLAG=""
if [ -f "$DATA_DIR/proxy_secret" ]; then
  HUB_SECRET_FLAG="--proxy-secret-file $DATA_DIR/proxy_secret"
fi

if [ -f "$HUB_PID_FILE" ] && kill -0 "$(cat "$HUB_PID_FILE")" 2>/dev/null; then
  echo "[hub] Already running (PID $(cat "$HUB_PID_FILE"))"
else
  echo "[hub] Starting ham-hub on 127.0.0.1:49322..."
  nohup "$BIN_DIR/ham-hub" --listen 127.0.0.1:49322 --db "$DATA_DIR/hub.db" --migrations-dir "$MIGRATIONS_DIR" $HUB_SECRET_FLAG >> "$HUB_LOG" 2>&1 &
  PID=$!
  echo $PID > "$HUB_PID_FILE"
  disown $PID 2>/dev/null || true
fi

# Wait for Hub port
deadline=$((SECONDS + 10))
while ! curl -s "http://127.0.0.1:49322/api/v1/health" >/dev/null 2>&1; do
  if [ $SECONDS -ge $deadline ]; then
    echo "[-] Hub failed to start. Check $HUB_LOG"
    exit 1
  fi
  sleep 0.2
done
echo "[hub] Ready at http://127.0.0.1:49322"

# 3. Start Bridge
BRIDGE_LOG="$LOG_DIR/bridge.log"
BRIDGE_PID_FILE="$RUN_DIR/bridge.pid"
BRIDGE_PORT="${HEIMDALL_BRIDGE_PORT:-49323}"
BRIDGE_ENDPOINT_PORT="${HEIMDALL_BRIDGE_ENDPOINT_PORT:-49324}"
BRIDGE_RUN_DIR="${HEIMDALL_BRIDGE_RUN_DIR:-/tmp/heimdall-bridge-local}"
BRIDGE_TOKEN_FILE="$DATA_DIR/bridge_token"

# Sync bridge tokens if one exists and the other doesn't (REQ-CT-12a)
if [ -s "$DATA_DIR/bridge_token" ] && [ ! -s "$DATA_DIR/bridge_token_cloudtop" ]; then
  cp "$DATA_DIR/bridge_token" "$DATA_DIR/bridge_token_cloudtop"
  chmod 0600 "$DATA_DIR/bridge_token_cloudtop"
elif [ ! -s "$DATA_DIR/bridge_token" ] && [ -s "$DATA_DIR/bridge_token_cloudtop" ]; then
  cp "$DATA_DIR/bridge_token_cloudtop" "$DATA_DIR/bridge_token"
  chmod 0600 "$DATA_DIR/bridge_token"
fi

# Detect if default port 49323 is already in use
if python3 -c "import socket; s=socket.socket(); s.settimeout(0.1); exit(0 if s.connect_ex(('127.0.0.1', int('$BRIDGE_PORT'))) == 0 else 1)" 2>/dev/null; then
  if [ "$BRIDGE_PORT" = "49323" ]; then
    echo "[bridge] Port 49323 is occupied; using port 49325 for standalone bridge"
    BRIDGE_PORT=49325
    BRIDGE_ENDPOINT_PORT=49326
    BRIDGE_RUN_DIR="/tmp/heimdall-bridge-standalone"
  fi
fi

if [ -f "$BRIDGE_PID_FILE" ] && kill -0 "$(cat "$BRIDGE_PID_FILE")" 2>/dev/null; then
  echo "[bridge] Already running (PID $(cat "$BRIDGE_PID_FILE"))"
else
  # Auto-pair if token not yet present
  if [ ! -s "$BRIDGE_TOKEN_FILE" ]; then
    echo "[bridge] Auto-pairing bridge with local Hub..."
    "$BIN_DIR/ham-bridge" enroll --hub http://127.0.0.1:49322 --name "$(hostname -s)" --user "${USER:-$(whoami)}" --bridge-token-file "$BRIDGE_TOKEN_FILE" || true
    if [ -s "$DATA_DIR/bridge_token" ]; then
      cp "$DATA_DIR/bridge_token" "$DATA_DIR/bridge_token_cloudtop"
      chmod 0600 "$DATA_DIR/bridge_token_cloudtop"
    fi
  fi

  echo "[bridge] Starting ham-bridge on 127.0.0.1:$BRIDGE_PORT..."
  export HEIMDALL_HAM_PTY_HOST_BIN="$BIN_DIR/ham-pty-host"
  export HEIMDALL_HAM_CTL_BIN="$BIN_DIR/ham-ctl"
  export HEIMDALL_BRIDGE_DATA_DIR="$DATA_DIR"
  nohup "$BIN_DIR/ham-bridge" --daemon-id brg_local --bind-host 127.0.0.1 --port "$BRIDGE_PORT" --local-endpoint-port "$BRIDGE_ENDPOINT_PORT" --hub http://127.0.0.1:49322 --local-run-dir "$BRIDGE_RUN_DIR" --data-dir "$DATA_DIR" --bridge-token-file "$BRIDGE_TOKEN_FILE" >> "$BRIDGE_LOG" 2>&1 &
  PID=$!
  echo $PID > "$BRIDGE_PID_FILE"
  disown $PID 2>/dev/null || true
fi

# Wait for Bridge port
deadline=$((SECONDS + 10))
while ! curl -s "http://127.0.0.1:$BRIDGE_PORT/api/v1/health" >/dev/null 2>&1; do
  if [ $SECONDS -ge $deadline ]; then
    echo "[bridge] Warning: ham-bridge did not respond on port $BRIDGE_PORT within 10s. Check $BRIDGE_LOG"
    break
  fi
  sleep 0.2
done
if curl -s "http://127.0.0.1:$BRIDGE_PORT/api/v1/health" >/dev/null 2>&1; then
  echo "[bridge] Ready at http://127.0.0.1:$BRIDGE_PORT"
fi

# 4. Start Dev-Proxy (Port 8989 Cloudtop Gateway)
PROXY_LOG="$LOG_DIR/dev-proxy.log"
PROXY_PID_FILE="$RUN_DIR/dev-proxy.pid"
PROXY_SECRET_FLAG=""
if [ -f "$DATA_DIR/proxy_secret" ]; then
  PROXY_SECRET_FLAG="--proxy-secret-file $DATA_DIR/proxy_secret"
fi

STATIC_UI_DIR=""
if [ -d "$BUNDLE_DIR/ui" ] && [ -f "$BUNDLE_DIR/ui/index.html" ]; then
  STATIC_UI_DIR="$BUNDLE_DIR/ui"
elif [ -d "$DATA_DIR/ui" ] && [ -f "$DATA_DIR/ui/index.html" ]; then
  STATIC_UI_DIR="$DATA_DIR/ui"
elif [ -d "$BIN_DIR/../ui" ] && [ -f "$BIN_DIR/../ui/index.html" ]; then
  STATIC_UI_DIR="$BIN_DIR/../ui"
fi

STATIC_UI_FLAG=""
if [ -n "$STATIC_UI_DIR" ]; then
  STATIC_UI_FLAG="--static-dir $STATIC_UI_DIR"
  echo "[ui] Found pre-built static UI at $STATIC_UI_DIR (no Node.js/Vite needed)"
fi

if [ -f "$PROXY_PID_FILE" ] && kill -0 "$(cat "$PROXY_PID_FILE")" 2>/dev/null; then
  echo "[proxy] Already running (PID $(cat "$PROXY_PID_FILE"))"
else
  echo "[proxy] Starting ham-dev-proxy on 0.0.0.0:8989..."
  nohup "$BIN_DIR/ham-dev-proxy" --listen 0.0.0.0:8989 --hub-url http://127.0.0.1:49322 --vite-url http://127.0.0.1:5173 $PROXY_SECRET_FLAG $STATIC_UI_FLAG >> "$PROXY_LOG" 2>&1 &
  PID=$!
  echo $PID > "$PROXY_PID_FILE"
  disown $PID 2>/dev/null || true
fi

# 5. Start Vite Dev Server (Frontend UI) - only if no static UI is available
if [ -n "$STATIC_UI_DIR" ]; then
  echo "[ui] Static UI served directly by dev-proxy; skipping Vite dev server."
else
  VITE_LOG="$LOG_DIR/vite.log"
  VITE_PID_FILE="$RUN_DIR/vite.pid"
  if [ -f "$VITE_PID_FILE" ] && kill -0 "$(cat "$VITE_PID_FILE")" 2>/dev/null; then
    echo "[ui] Vite server already running (PID $(cat "$VITE_PID_FILE"))"
  elif ss -tlpn 2>/dev/null | grep -q ":5173\b"; then
    echo "[ui] Vite server already running on port 5173"
  else
    UI_DIR="$BUNDLE_DIR/ui"
    if [ ! -d "$UI_DIR" ]; then
      if [ -f "$BUNDLE_DIR/../../package.json" ]; then
        UI_DIR="$(cd "$BUNDLE_DIR/../.." && pwd)"
      elif [ -f "$HOME/heimdall-cloudtop/package.json" ]; then
        UI_DIR="$HOME/heimdall-cloudtop"
      elif [ -f "$HOME/heimdall-agent-manager/package.json" ]; then
        UI_DIR="$HOME/heimdall-agent-manager"
      fi
    fi
    if [ -d "$UI_DIR" ] && [ -f "$UI_DIR/package.json" ]; then
      echo "[ui] Starting Vite dev server in $UI_DIR on 127.0.0.1:5173..."
      nohup bash -c "cd '$UI_DIR' && HEIMDALL_DEV_PROXY_URL='http://127.0.0.1:8989' exec npx vite --host 127.0.0.1 --port 5173" >> "$VITE_LOG" 2>&1 &
      PID=$!
      echo $PID > "$VITE_PID_FILE"
      disown $PID 2>/dev/null || true
    fi
  fi
fi

# Wait for Dev-Proxy port
deadline=$((SECONDS + 10))
while ! curl -s "http://127.0.0.1:8989/api/v1/health" >/dev/null 2>&1; do
  if [ $SECONDS -ge $deadline ]; then
    echo "[proxy] Warning: Dev proxy gateway not yet responding on port 8989. Check $PROXY_LOG"
    break
  fi
  sleep 0.2
done

HOST_FQDN="$(hostname | sed 's/\.c\.googlers\.com$//').c.googlers.com"
echo ""
echo "========================================================================"
echo "    Heimdall Single-Node Stack is UP!"
echo "========================================================================"
echo ""
echo "  👉 Open Web UI:      http://${HOST_FQDN}:8989"
echo "                       (or http://127.0.0.1:8989)"
echo ""
echo "  Hub API:             http://127.0.0.1:49322"
echo "  Bridge Status:       http://127.0.0.1:$BRIDGE_PORT"
echo "  Cloudtop Gateway:    http://${HOST_FQDN}:8989"
echo "========================================================================"

if [ "$FOREGROUND" = true ]; then
  trap 'echo "[supervisor] Shutting down Heimdall services..."; "$BIN_DIR/stop.sh" || true; exit 0' SIGTERM SIGINT SIGHUP
  echo "[supervisor] Running in foreground under systemd. Monitoring daemons..."
  while true; do
    sleep 2
    for pidf in "$HUB_PID_FILE" "$BRIDGE_PID_FILE" "$PROXY_PID_FILE"; do
      if [ -f "$pidf" ] && ! kill -0 "$(cat "$pidf")" 2>/dev/null; then
        echo "[-] Process $(basename "$pidf" .pid) died unexpectedly!"
        exit 1
      fi
    done
  done
fi
STARTEOF
chmod +x "$BUNDLE_DIR/start.sh"

cat << 'STOPEOF' > "$BUNDLE_DIR/stop.sh"
#!/usr/bin/env bash
# One-click stop script for Heimdall Cloudtop Single-Node
set -euo pipefail

DATA_DIR="${HEIMDALL_DATA_DIR:-$HOME/.local/share/heimdall}"
RUN_DIR="$DATA_DIR/run"

stop_proc() {
  local name="$1"
  local pid_file="$RUN_DIR/$name.pid"
  if [ -f "$pid_file" ]; then
    local pid
    pid="$(cat "$pid_file")"
    if kill -0 "$pid" 2>/dev/null; then
      echo "[$name] Stopping PID $pid..."
      kill -TERM "$pid" 2>/dev/null || true
      deadline=$((SECONDS + 5))
      while kill -0 "$pid" 2>/dev/null; do
        if [ $SECONDS -ge $deadline ]; then
          echo "[$name] Force killing PID $pid..."
          kill -KILL "$pid" 2>/dev/null || true
          break
        fi
        sleep 0.1
      done
    fi
    rm -f "$pid_file"
    echo "[$name] Stopped."
  fi
}

echo "=== Stopping Heimdall Single-Node Stack ==="
stop_proc "vite"
stop_proc "dev-proxy"
stop_proc "bridge"
stop_proc "hub"
pkill -f "ham-pty-host.*heimdall-bridge-standalone" 2>/dev/null || true
echo "=== Heimdall Single-Node Stack Stopped ==="
STOPEOF
chmod +x "$BUNDLE_DIR/stop.sh"
chmod +x "$BUNDLE_DIR/stop.sh"

cat << 'READMEEOF' > "$BUNDLE_DIR/README.md"
# Heimdall Cloudtop - Installation & Operations Guide

Heimdall is an enterprise-grade multi-agent orchestrator optimized for Google Cloudtop workstations. This distribution is 100% self-contained: it includes pre-compiled ELF binaries and pre-built static UI assets with **zero external dependencies** (no Nix, Node.js, npm, or Git required on the target Cloudtop).

---

## 1. Quick Start: Interactive Setup (Recommended)

Simply extract the bundle and run `./install.sh`:

```bash
# 1. Extract the bundle
mkdir -p ~/.local/share/heimdall
tar -xzf heimdall-cloudtop-bundle.tar.gz -C ~/.local/share/heimdall

# 2. Run the installer
cd ~/.local/share/heimdall
./install.sh
```

When run interactively in your terminal, `./install.sh` presents a menu:
- **Option 1: Full Single-Node Stack** (Default) — Runs Central Hub, Web UI (port 8989), Dev-Proxy, and Local Bridge on this workstation.
- **Option 2: Standalone Remote Bridge** — Prompts for Central Hub URL and Enrollment Token to run this Cloudtop as an execution worker bridge.
- **Option 3: Uninstall Heimdall** — Safely stops running services, disables systemd units, and removes binaries (with optional data purge).

---

## 2. Quick Start: Mode 1 — Full Single-Node Stack (Scripted)

Use this mode if this Cloudtop is your **primary workstation** where you want to run the Heimdall Hub, the Web UI, and a local execution bridge.

### Installation

```bash
./install.sh --full
# Or simply: ./install.sh (non-interactively defaults to full stack)
```

### What Happens:
- Installs binaries to `~/.local/share/heimdall/bin/`.
- Symlinks `ham-ctl` to `~/.local/bin/ham-ctl`.
- Configures and enables a `systemd --user` service with linger enabled (runs in background across reboots).
- Starts:
  * **ham-hub** (Central Hub API) on `127.0.0.1:49322`.
  * **ham-bridge** (Agent execution bridge) on `127.0.0.1:49323`.
  * **ham-dev-proxy** (Cloudtop Edge Gateway) on `0.0.0.0:8989`.
  * **Pre-built Static Web UI** served directly on port 8989.

### Access Points:
- **Web UI:** `http://<your-hostname>.c.googlers.com:8989` (or `http://127.0.0.1:8989`)
- **Hub API:** `http://127.0.0.1:49322`
- **Bridge Status:** `http://127.0.0.1:49323`

---

## 3. Quick Start: Mode 2 — Standalone Remote Bridge (Bridge-Only)

Use this mode if you already have a Central Heimdall Hub running (e.g. on your primary workstation or shared server), and you want this Cloudtop to act **only as an execution worker bridge** that connects back to the Central Hub.

### Installation (Interactive)

```bash
cd ~/.local/share/heimdall
./install.sh --standalone
```
The script will prompt you for:
1. **Central Hub URL:** (e.g. `http://my-primary-workstation.c.googlers.com:8989`)
2. **Hub Enrollment Token:** (Generate in the Central Hub UI: `Settings` -> `Bridges` -> `Add bridge` -> Copy Token)

### Installation (Non-Interactive / Scripted)

```bash
./install.sh --standalone \
  --hub "http://my-primary-workstation.c.googlers.com:8989" \
  --token "<ENROLLMENT_TOKEN>"
```

### What Happens:
- Installs only bridge binaries (`ham-bridge`, `ham-pty-host`, `ham-ctl`).
- Authenticates and enrolls this workstation with the Central Hub via LOAS / Token.
- Saves the bridge token to `~/.local/share/heimdall/bridge_token_cloudtop`.
- Starts **only** `ham-bridge` connected back to the remote Central Hub.
- **Does NOT** start a local Hub, Dev-Proxy, or Web UI.
- All agents and tasks assigned to this Cloudtop are controlled directly from your Central Hub UI!

---

## 4. Operations & Service Management

### Using systemd (Recommended)

Heimdall installs a user systemd service (`heimdall.service`):

```bash
# Check service status
systemctl --user status heimdall.service

# View live service logs
journalctl --user -u heimdall.service -f

# Restart the service
systemctl --user restart heimdall.service

# Stop the service
systemctl --user stop heimdall.service

# Start the service
systemctl --user start heimdall.service
```

### Using Management Scripts

You can also control services directly:

```bash
# Start daemons (detects single-node vs standalone bridge automatically)
~/.local/share/heimdall/bin/start.sh

# Stop all daemons
~/.local/share/heimdall/bin/stop.sh
```

### Agent Run Directories & CLI (`ham-ctl`)

Each agent instance operates in an isolated run directory (e.g. `instances/<instance_id>/`). On startup, Heimdall installs a bootstrap shim at `.heimdall/bin/ham-ctl` that automatically:
- Defaults `HAM_HUB_URL` to `http://127.0.0.1:8989` (the Cloudtop Edge Gateway) via `export HAM_HUB_URL=${HAM_HUB_URL:-'http://127.0.0.1:8989'}`, so agents and tools can interact directly with the Hub API without manual environment configuration.
- Injects `HEIMDALL_BRIDGE_ENDPOINT`, `HEIMDALL_AGENT_TOKEN`, and `HEIMDALL_AGENT_INSTANCE_ID` for secure local bridge IPC.

---

## 5. Switching Between Modes

You can switch between Full Stack and Standalone Remote Bridge at any time:

- **Switch to Standalone Bridge:**
  ```bash
  ./install.sh --standalone --hub <url> --token <token>
  ```
- **Switch back to Full Stack:**
  ```bash
  ./install.sh --full
  ```

---

## 6. Uninstallation

To completely stop running services and remove Heimdall from your system:

```bash
cd ~/.local/share/heimdall
./install.sh --uninstall
```

### What the Uninstaller Does:
1. Stops and disables the `heimdall.service` systemd unit.
2. Terminates any running Heimdall daemons (`ham-hub`, `ham-bridge`, `ham-dev-proxy`, `ham-pty-host`, `vite`).
3. Removes the systemd unit file (`~/.config/systemd/user/heimdall.service`).
4. Removes the CLI symlink (`~/.local/bin/ham-ctl`).
5. Removes installed binaries, runtime libraries, migrations, and scripts.
6. **Retains** user database, tokens, and logs in `~/.local/share/heimdall`.

### Complete Purge (Delete All Data)
To also delete the database, encryption keys, and log files:
```bash
./install.sh --uninstall --purge
```

READMEEOF

echo "[bundle] 5. De-Nixifying ELF binaries via patchelf..."
chmod u+w "$BUNDLE_DIR/bin/"*
nix-shell -p patchelf --run "
for bin in '$BUNDLE_DIR'/bin/*; do
  [ -f \"\$bin\" ] || continue
  # Extract any non-standard store dependencies
  for lib in \$(ldd \"\$bin\" 2>/dev/null | grep '/nix/store' | awk '{print \$3}'); do
    if [ -f \"\$lib\" ]; then
      case \"\$lib\" in
        *libc.so*|*libm.so*|*libpthread.so*|*libdl.so*|*ld-linux*)
          ;;
        *)
          cp -n \"\$lib\" '$BUNDLE_DIR/lib/' || true
          ;;
      esac
    fi
  done
  patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 \"\$bin\"
  patchelf --set-rpath '\$ORIGIN/../lib:\$ORIGIN' \"\$bin\"
done
chmod -R u+w '$BUNDLE_DIR/lib/' 2>/dev/null || true
for f in '$BUNDLE_DIR'/lib/libsqlite3.so.*; do
  if [ -f \"\$f\" ] && [ ! -f '$BUNDLE_DIR'/lib/libsqlite3.so ]; then
    ln -s \"\$(basename \"\$f\")\" '$BUNDLE_DIR'/lib/libsqlite3.so
  fi
done
for libfile in '$BUNDLE_DIR'/lib/*.so*; do
  if [ -f \"\$libfile\" ] && [ ! -L \"\$libfile\" ]; then
    patchelf --set-rpath '\$ORIGIN' \"\$libfile\" 2>/dev/null || true
  fi
done
"

echo "[bundle] 5.5. Verifying zero /nix/store references in binaries..."
NIX_REFS=$(ldd "$BUNDLE_DIR/bin/"* 2>/dev/null | grep '/nix/store' || true)
if [ -n "$NIX_REFS" ]; then
  echo "[-] ERROR: Detected lingering /nix/store references in bundled binaries:"
  echo "$NIX_REFS"
  exit 1
fi
echo "[bundle] Zero /nix/store references verified!"

echo "[bundle] 6. Creating archive dist/heimdall-cloudtop-bundle.tar.gz..."
tar -czf "$DIST_DIR/heimdall-cloudtop-bundle.tar.gz" -C "$DIST_DIR" heimdall-cloudtop

echo "[bundle] SUCCESS: Created $DIST_DIR/heimdall-cloudtop-bundle.tar.gz"
ls -lh "$DIST_DIR/heimdall-cloudtop-bundle.tar.gz"
