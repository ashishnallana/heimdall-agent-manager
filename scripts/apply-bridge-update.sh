#!/usr/bin/env bash
# scripts/apply-bridge-update.sh
# Detached out-of-process supervisor for atomic Heimdall Bridge binary replacement
# and health-monitored automated rollback (REQ-BUPD-4, REQ-BUPD-5).

set -euo pipefail

# --- Configuration & Defaults ------------------------------------------------
DATA_DIR="${DATA_DIR:-$HOME/.local/share/heimdall}"
STAGE_DIR="${STAGE_DIR:-}"
BRIDGE_PORT="${BRIDGE_PORT:-49323}"
HUB_URL="${HUB_URL:-http://127.0.0.1:8989}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-30}"
SERVICE_NAME="${SERVICE_NAME:-${HEIMDALL_BRIDGE_SERVICE_NAME:-}}"
BRIDGE_PID="${BRIDGE_PID:-}"
PTY_HOST_SOCKET="${PTY_HOST_SOCKET:-}"
STOP_PTY_HOSTS_ONLY=false
RESTART_HOOK="${RESTART_HOOK:-}"
STOP_HOOK="${STOP_HOOK:-}"
HEALTH_URL="${HEALTH_URL:-}"
HEALTH_METHOD="${HEALTH_METHOD:-}"

# Parse command line flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-dir)
      DATA_DIR="$2"
      shift 2
      ;;
    --stage-dir)
      STAGE_DIR="$2"
      shift 2
      ;;
    --bridge-port)
      BRIDGE_PORT="$2"
      shift 2
      ;;
    --hub-url)
      HUB_URL="$2"
      shift 2
      ;;
    --health-timeout)
      HEALTH_TIMEOUT="$2"
      shift 2
      ;;
    --service-name)
      SERVICE_NAME="$2"
      shift 2
      ;;
    --bridge-pid)
      BRIDGE_PID="$2"
      shift 2
      ;;
    --stop-pty-hosts-only)
      STOP_PTY_HOSTS_ONLY=true
      shift
      ;;
    --pty-host-socket)
      PTY_HOST_SOCKET="$2"
      shift 2
      ;;
    --restart-hook)
      RESTART_HOOK="$2"
      shift 2
      ;;
    --stop-hook)
      STOP_HOOK="$2"
      shift 2
      ;;
    --health-url)
      HEALTH_URL="$2"
      shift 2
      ;;
    --health-method)
      HEALTH_METHOD="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [options]"
      echo "  --data-dir DIR        Root data directory (default: ~/.local/share/heimdall)"
      echo "  --stage-dir DIR       Staging directory containing extracted binaries"
      echo "  --bridge-port PORT    Port bridge listens on for health check (default: 49323)"
      echo "  --hub-url URL         Central Hub URL"
      echo "  --health-timeout SEC  Healthcheck probe timeout in seconds (default: 30)"
      echo "  --service-name NAME   Systemd unit, launchd label or Termux runit service (auto-detected by default)"
      echo "  --bridge-pid PID      Exact bridge process to stop"
      echo "  --pty-host-socket PATH  Bridge-owned PTY daemon socket"
      echo "  --stop-pty-hosts-only   Only clean up this bridge’s PTY hosts"
      echo "  --restart-hook PATH   Executable restart hook for isolated tests"
      echo "  --stop-hook PATH      Executable stop hook for isolated tests"
      echo "  --health-url URL      Explicit health URL override (optional)"
      echo "  --health-method METHOD  Probe method override (default: OPTIONS, or GET with --health-url)"
      exit 0
      ;;
    *)
      echo "Unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

# Expand leading ~ in DATA_DIR if present
DATA_DIR="${DATA_DIR/#\~/$HOME}"
if [ -z "$STAGE_DIR" ]; then
  STAGE_DIR="$DATA_DIR/updates/stage"
fi
STAGE_DIR="${STAGE_DIR/#\~/$HOME}"

if [ -z "$HEALTH_URL" ]; then
  HEALTH_URL="http://127.0.0.1:$BRIDGE_PORT/bridge/health"
  HEALTH_METHOD="${HEALTH_METHOD:-OPTIONS}"
else
  HEALTH_METHOD="${HEALTH_METHOD:-GET}"
fi

case "$HEALTH_METHOD" in
  GET|OPTIONS) ;;
  *)
    echo "Unsupported health method: $HEALTH_METHOD (expected GET or OPTIONS)" >&2
    exit 2
    ;;
esac

log() {
  printf '[apply-bridge-update] [%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

log_err() {
  printf '[apply-bridge-update] [%s] ERROR: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

# Termux (Android) exports TERMUX_VERSION and keeps $PREFIX in the app's data
# dir (same test as install.sh). There is no systemd there: install.sh
# registers the bridge as the termux-services (runit) service
# $PREFIX/var/service/ham-bridge, so the service is driven with `sv`.
is_termux() {
  [ -n "${TERMUX_VERSION:-}" ] && return 0
  case "${PREFIX:-}" in /data/data/com.termux|/data/data/com.termux/*) return 0 ;; esac
  return 1
}

# Stop only this bridge's hosts, including old unlinked binaries, and their
# descendants. Capture process identities before asking a daemon to shut down:
# its children may otherwise be reparented and become invisible to cleanup.
stop_pty_hosts() {
  python3 - "$DATA_DIR" "$PTY_HOST_SOCKET" <<'PY_PTY_CLEANUP'
import os, pathlib, re, shlex, signal, subprocess, sys, time

data = pathlib.Path(sys.argv[1]).resolve()
expected_socket = os.path.realpath(sys.argv[2]) if sys.argv[2] else ''
private_install = data.parent.name == 'bridges'
uid = os.geteuid()

def read_process(pid):
    try:
        proc = pathlib.Path('/proc')/str(pid)
        if pathlib.Path('/proc').exists():
            if proc.stat().st_uid != uid: return None
            fields = (proc/'stat').read_text().rsplit(')', 1)[1].split()
            if fields[0] == 'Z': return None
            argv = [os.fsdecode(arg) for arg in (proc/'cmdline').read_bytes().split(b'\0') if arg]
            try: exe = os.readlink(proc/'exe').removesuffix(' (deleted)')
            except OSError: exe = ''
            return (int(fields[1]), fields[19], argv, exe)
        line = subprocess.check_output(['ps','-p',str(pid),'-o','ppid=,uid=,lstart=,command='], text=True).strip()
        parts = line.split(None, 7)
        if len(parts) != 8 or int(parts[1]) != uid: return None
        command = parts[7]
        # ps on macOS does not quote argv paths containing spaces. The native
        # daemon's final --socket argument can be recovered without splitting it.
        host = re.match(r'^(.*?/ham-pty-host) (?=daemon |run |--socket )', command)
        if host:
            exe = host.group(1)
            tail = command[len(exe)+1:]
            if tail.startswith('daemon --socket '):
                argv = [exe, 'daemon', '--socket', tail[len('daemon --socket '):]]
            elif tail.startswith('--socket ') and tail.endswith(' daemon'):
                argv = [exe, '--socket', tail[len('--socket '):-len(' daemon')], 'daemon']
            else: argv = [exe] + shlex.split(tail)
        else: exe, argv = '', shlex.split(command)
        return (int(parts[0]), ' '.join(parts[2:7]), argv, exe)
    except (OSError, ValueError, IndexError, subprocess.CalledProcessError): return None

def processes():
    if pathlib.Path('/proc').exists():
        ids = [int(p.name) for p in pathlib.Path('/proc').iterdir() if p.name.isdigit()]
    else:
        ids = [int(p) for p in subprocess.check_output(['ps','-axo','pid='], text=True).split()]
    return {pid: info for pid in ids if (info := read_process(pid)) is not None}

snapshot = processes()
roots = {}
for pid, (parent, born, argv, exe) in snapshot.items():
    # An interpreter can run a test/script host; real release binaries use argv[0].
    candidates = [exe] + argv[:2]
    hosts = [p for p in candidates if pathlib.Path(p).name == 'ham-pty-host']
    if not hosts or not any(command in argv for command in ('daemon', 'run')): continue
    socket = ''
    for index, arg in enumerate(argv):
        if arg == '--socket' and index+1 < len(argv): socket = argv[index+1]
        elif arg.startswith('--socket='): socket = arg.split('=', 1)[1]
    owned_binary = private_install and any(pathlib.Path(os.path.realpath(p)).parent.parent == data and pathlib.Path(p).parent.name in ('bin','bin.old','bin.bak','bin.failed') for p in hosts)
    owned_socket = bool(expected_socket and socket and os.path.realpath(socket) == expected_socket)
    if owned_binary or owned_socket: roots[pid] = socket

owned = set(roots)
while True:
    children = {pid for pid, info in snapshot.items() if info[0] in owned}
    expanded = owned | children
    if expanded == owned: break
    owned = expanded

def alive(pid):
    info = read_process(pid)
    return info is not None and info[1] == snapshot[pid][1]

def send(pid, sig):
    if not alive(pid): return
    try:
        if hasattr(os, 'pidfd_open') and hasattr(signal, 'pidfd_send_signal'):
            fd = os.pidfd_open(pid)
            try:
                if alive(pid): signal.pidfd_send_signal(fd, sig)
            finally: os.close(fd)
        elif alive(pid): os.kill(pid, sig)
    except ProcessLookupError: pass

# Best effort protocol shutdown lets the PTY host terminate/reap its own agents.
client = data/'bin/ham-pty-host'
if client.is_file() and os.access(client, os.X_OK):
    for socket in set(roots.values())- {''}:
        try:
            subprocess.run([str(client),'--socket',socket,'stop'], timeout=3,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except (OSError, subprocess.TimeoutExpired): pass

if owned: print('[apply-bridge-update] stopping bridge-owned PTY processes:', ', '.join(map(str, sorted(owned))), flush=True)
for pid in owned: send(pid, signal.SIGTERM)
deadline = time.monotonic()+3
while any(alive(pid) for pid in owned) and time.monotonic() < deadline: time.sleep(0.05)
for pid in owned: send(pid, signal.SIGKILL)
deadline = time.monotonic()+2
while any(alive(pid) for pid in owned) and time.monotonic() < deadline: time.sleep(0.05)
if any(alive(pid) for pid in owned): sys.exit('Bridge-owned PTY processes did not stop; refusing binary swap.')
PY_PTY_CLEANUP
}

if "$STOP_PTY_HOSTS_ONLY"; then
  stop_pty_hosts
  exit 0
fi

log "Starting supervisor execution"
log "  DATA_DIR:       $DATA_DIR"
log "  STAGE_DIR:      $STAGE_DIR"
log "  BRIDGE_PORT:    $BRIDGE_PORT"
log "  HEALTH_URL:     $HEALTH_URL"
log "  HEALTH_METHOD:  $HEALTH_METHOD"
log "  HEALTH_TIMEOUT: ${HEALTH_TIMEOUT}s"
log "  BRIDGE_PID:     ${BRIDGE_PID:-unset}"

# Locate staged binaries
STAGE_BIN=""
if [ -d "$STAGE_DIR/bin" ]; then
  STAGE_BIN="$STAGE_DIR/bin"
elif [ -d "$STAGE_DIR/extract/bin" ]; then
  STAGE_BIN="$STAGE_DIR/extract/bin"
elif [ -d "$STAGE_DIR/heimdall-cloudtop/bin" ]; then
  STAGE_BIN="$STAGE_DIR/heimdall-cloudtop/bin"
elif [ -f "$STAGE_DIR/ham-bridge" ]; then
  STAGE_BIN="$STAGE_DIR"
else
  log_err "Staged binaries not found in $STAGE_DIR"
  exit 1
fi

log "Located staged binaries at: $STAGE_BIN"
for binary in ham-bridge ham-ctl heimdall ham-pty-host; do
  if [ -f "$DATA_DIR/bin/$binary" ] && [ ! -f "$STAGE_BIN/$binary" ]; then
    log_err "Update bundle is missing installed binary: $binary"; exit 1;
  fi
done

# REQ-T13-3: under Termux only a termux-* bundle may be installed. The glibc
# linux-* bundle dies on Android's seccomp filter (set_robust_list -> SIGSYS),
# so installing it would leave a bridge that can never restart. The bridge runs
# the staged bundle's copy of this script, so this also protects bridges that
# predate the termux release target and still ask the Hub for linux-arm64.
# A bundle without METADATA.json is refused too: its target cannot be proven.
if is_termux; then
  staged_target="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("target", ""))' \
    "$STAGE_BIN/../METADATA.json" 2>/dev/null || true)"
  case "$staged_target" in
    termux-*) log "  BUNDLE_TARGET:  $staged_target" ;;
    *)
      log_err "Refusing to install the ${staged_target:-unidentified} bundle under Termux; only termux-* bundles run on Android. Reinstall with install.sh."
      exit 1
      ;;
  esac
fi

# Resolve the owning service before stopping the bridge. Older installations do
# not export HEIMDALL_BRIDGE_SERVICE_NAME; match the installed executable instead
# of assuming the legacy unit name. A renamed bridge-id service works unchanged.
# On Termux the runit run file is matched the same way (install.sh writes it to
# exec the installed ham-bridge).
RUNIT_DIR=''
if [ -z "$SERVICE_NAME" ] && [ -z "$RESTART_HOOK" ] && is_termux && [ -n "${PREFIX:-}" ] \
  && grep -Fqs -- "$DATA_DIR/bin/ham-bridge" "$PREFIX/var/service/ham-bridge/run"; then
  SERVICE_NAME=ham-bridge
fi
if [ -z "$SERVICE_NAME" ] && [ -z "$RESTART_HOOK" ]; then
  SERVICE_NAME="$(python3 - "$DATA_DIR" <<'PY_SERVICE'
import pathlib, plistlib, shlex, sys
home = pathlib.Path.home()
exe = str(pathlib.Path(sys.argv[1])/'bin/ham-bridge')
matches = []
for unit in (home/'.config/systemd/user').glob('*.service'):
    text = unit.read_text()
    for line in text.splitlines():
        if not line.startswith('ExecStart='): continue
        try: args = shlex.split(line[len('ExecStart='):])
        except ValueError: continue
        if args and args[0].replace('%%', '%').replace('$$', '$') == exe:
            matches.append(unit.name)
            break
for file in (home/'Library/LaunchAgents').glob('*.plist'):
    try:
        plist = plistlib.loads(file.read_bytes())
        args = plist.get('ProgramArguments', [])
        if args and args[0] == exe: matches.append(plist['Label'])
    except (ValueError, OSError): pass
if len(matches) > 1: sys.exit('Multiple services reference this bridge; specify --service-name.')
print(matches[0] if matches else '')
PY_SERVICE
)"
fi
log "  SERVICE_NAME:   ${SERVICE_NAME:-standalone}"

# Fail before stopping or replacing anything if an explicitly managed service
# cannot be found. Never relaunch its binary without its config and credentials.
if [ -n "$SERVICE_NAME" ] && [ -z "$RESTART_HOOK" ] && is_termux; then
  RUNIT_DIR="${PREFIX:-}/var/service/$SERVICE_NAME"
  command -v sv >/dev/null || { log_err "termux-services (sv) not found; cannot manage $SERVICE_NAME"; exit 1; }
  [ -f "$RUNIT_DIR/run" ] || { log_err "Managed runit service not found: $RUNIT_DIR"; exit 1; }
  log "  RUNIT_DIR:      $RUNIT_DIR"
elif [ -n "$SERVICE_NAME" ] && [ -z "$RESTART_HOOK" ]; then
  if [[ "$(uname -s)" = Darwin ]]; then
    launchctl print "gui/$(id -u)/$SERVICE_NAME" >/dev/null
  else
    systemctl --user show "$SERVICE_NAME" -p LoadState --value | grep -Fxq loaded || {
      log_err "Managed service not found: $SERVICE_NAME"; exit 1;
    }
  fi
fi

# Helper to stop service
bridge_pid_running() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null || return 1
  # A dead child can remain briefly as a zombie while its parent reaps it.
  # Treat that as stopped; kill -0 alone cannot distinguish this state.
  local stat
  stat="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  [ -n "$stat" ] && [[ "$stat" != Z* ]]
}

stop_service() {
  log "Stopping active bridge service..."
  if [ -n "$STOP_HOOK" ]; then
    [ -x "$STOP_HOOK" ] || { log_err "Stop hook is not executable: $STOP_HOOK"; return 1; }
    "$STOP_HOOK" "$BRIDGE_PID"
  elif [[ "$BRIDGE_PID" =~ ^[1-9][0-9]*$ ]]; then
    # Under runit, `sv down` (which TERMs the supervised bridge) also keeps
    # runsv from respawning the old binary while it is being replaced.
    if [ -n "$RUNIT_DIR" ]; then
      sv down "$RUNIT_DIR" || kill -TERM "$BRIDGE_PID" 2>/dev/null || true
    else
      kill -TERM "$BRIDGE_PID" 2>/dev/null || true
    fi
    deadline=$((SECONDS + 10))
    while bridge_pid_running "$BRIDGE_PID" && [ "$SECONDS" -lt "$deadline" ]; do
      sleep 0.1
    done
    if bridge_pid_running "$BRIDGE_PID"; then
      log_err "Bridge PID $BRIDGE_PID did not exit after SIGTERM"
      return 1
    fi
  elif [ -n "$RUNIT_DIR" ]; then
    sv down "$RUNIT_DIR"
  elif [ -n "$SERVICE_NAME" ] && [[ "$(uname -s)" = Darwin ]]; then
    launchctl kill SIGTERM "gui/$(id -u)/$SERVICE_NAME"
  elif [ -n "$SERVICE_NAME" ]; then
    systemctl --user stop "$SERVICE_NAME"
  else
    log_err "No scoped bridge stop mechanism is available"
    return 1
  fi
}

# Helper to start service
start_service() {
  log "Starting bridge service..."
  if [ -n "$RESTART_HOOK" ]; then
    [ -x "$RESTART_HOOK" ] || { log_err "Restart hook is not executable: $RESTART_HOOK"; return 1; }
    "$RESTART_HOOK"
  elif [ -n "$RUNIT_DIR" ]; then
    sv up "$RUNIT_DIR"
  elif [ -n "$SERVICE_NAME" ] && [[ "$(uname -s)" = Darwin ]]; then
    launchctl kickstart -k "gui/$(id -u)/$SERVICE_NAME"
  elif [ -n "$SERVICE_NAME" ]; then
    systemctl --user daemon-reload || true
    systemctl --user restart "$SERVICE_NAME" || systemctl --user start "$SERVICE_NAME"
  elif [ -f "$DATA_DIR/start.sh" ]; then
    "$DATA_DIR/start.sh" --standalone &
  elif [ -f "$DATA_DIR/bin/start.sh" ]; then
    "$DATA_DIR/bin/start.sh" --standalone &
  elif [ -f "$DATA_DIR/bin/ham-bridge" ]; then
    "$DATA_DIR/bin/ham-bridge" &
  else
    log_err "No start mechanism found for bridge"
    return 1
  fi
}

# 1. Stop current service cleanly
if ! stop_service; then
  log_err "Failed to stop bridge through a scoped mechanism"
  exit 1
fi

stop_pty_hosts

# 2. Backup existing binaries
log "Backing up current bin to $DATA_DIR/bin.bak"
rm -rf "$DATA_DIR/bin.bak"
if [ -d "$DATA_DIR/bin" ]; then
  cp -R -p "$DATA_DIR/bin" "$DATA_DIR/bin.bak"
fi

# 3. Atomically replace binaries
log "Staging new binaries into $DATA_DIR/bin.new"
rm -rf "$DATA_DIR/bin.new"
mkdir -p "$DATA_DIR/bin.new"
cp -R -p "$STAGE_BIN/"* "$DATA_DIR/bin.new/"
# Installer-created CLI shims are installation-specific, not release binaries.
# Keep them across the directory swap (and in bin.bak for rollback).
for shim in "$DATA_DIR/bin"/ham-ctl-*; do
  [ -f "$shim" ] && [ ! -L "$shim" ] || continue
  cp -p "$shim" "$DATA_DIR/bin.new/"
done
chmod +x "$DATA_DIR/bin.new/"* 2>/dev/null || true

# Copy migrations or assets if staged
if [ -d "$STAGE_DIR/share/migrations" ]; then
  mkdir -p "$DATA_DIR/share/migrations"
  cp -R -p "$STAGE_DIR/share/migrations/"* "$DATA_DIR/share/migrations/"
fi

log "Performing atomic directory swap into $DATA_DIR/bin"
rm -rf "$DATA_DIR/bin.old"
if [ -d "$DATA_DIR/bin" ]; then
  mv "$DATA_DIR/bin" "$DATA_DIR/bin.old"
fi
mv "$DATA_DIR/bin.new" "$DATA_DIR/bin"
rm -rf "$DATA_DIR/bin.old"

# 4. Restart service
if ! start_service; then
  log_err "Failed to restart bridge service"
fi

# 5. Verification Gate: Poll health endpoint for up to HEALTH_TIMEOUT seconds
log "Beginning health check polling for up to ${HEALTH_TIMEOUT} seconds..."
deadline=$((SECONDS + HEALTH_TIMEOUT))
healthy=false

while [ $SECONDS -lt $deadline ]; do
  http_code=$(curl --silent --output /dev/null --write-out "%{http_code}" \
    --request "$HEALTH_METHOD" --connect-timeout 2 --max-time 3 "$HEALTH_URL" 2>/dev/null || true)
  if [ "$http_code" = "200" ]; then
    healthy=true
    log "Health check succeeded (HTTP code: $http_code)"
    break
  fi
  sleep 1
done

# 6. Finalize or Rollback
if [ "$healthy" = true ]; then
  log "Update verification succeeded! Removing backup and staging directory."
  rm -rf "$DATA_DIR/bin.bak" "$STAGE_DIR"
  log "Bridge update completed successfully."
  exit 0
else
  log_err "Health check timed out or failed after ${HEALTH_TIMEOUT}s! Initiating automatic rollback..."
  stop_service
  stop_pty_hosts

  if [ -d "$DATA_DIR/bin.bak" ]; then
    log "Restoring binaries from $DATA_DIR/bin.bak..."
    rm -rf "$DATA_DIR/bin.failed"
    if [ -d "$DATA_DIR/bin" ]; then
      mv "$DATA_DIR/bin" "$DATA_DIR/bin.failed"
    fi
    cp -R -p "$DATA_DIR/bin.bak" "$DATA_DIR/bin"
    rm -rf "$DATA_DIR/bin.failed"
  else
    log_err "No $DATA_DIR/bin.bak found to restore from!"
  fi

  log "Restarting rolled-back service..."
  start_service || true

  mkdir -p "$DATA_DIR/logs"
  rollback_log="$DATA_DIR/logs/update_rollback.log"
  echo "Update failed: Health check timed out or failed after ${HEALTH_TIMEOUT}s on $(date -u +'%Y-%m-%dT%H:%M:%SZ')" >> "$rollback_log"
  log_err "Rollback complete. Log written to $rollback_log"
  exit 1
fi
