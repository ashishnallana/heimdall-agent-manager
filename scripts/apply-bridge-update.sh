#!/usr/bin/env bash
# scripts/apply-bridge-update.sh
# Detached out-of-process supervisor for atomic Heimdall Bridge binary replacement
# and health-monitored automated rollback (REQ-BUPD-4, REQ-BUPD-5).

set -euo pipefail

# --- Leave the bridge's process group ----------------------------------------
# The bridge starts this script as a plain child, so it shares the bridge's
# process group, and this script makes the bridge exit. launchd kills every
# process left in a job's process group when the job's main process exits
# (unless the plist sets AbandonProcessGroup, which older installs lack), so on
# macOS the supervisor died between stopping the bridge and restarting it,
# leaving the bridge down on the old version or with no bin/ at all. systemd
# units use KillMode=process; a new session is harmless there and under runit.
# Re-exec into a new session before doing anything. exec keeps the PID, so a
# caller that waits on this script still waits for the whole update.
# The PTY-only cleanup mode runs synchronously under the live bridge: skip it.
# A caller that already started this script in a new session (macOS has no
# setsid(1)) says so with --already-detached or HEIMDALL_UPDATE_SUPERVISOR_DETACHED=1.
detach_from_bridge_session() {
  [ -z "${HEIMDALL_UPDATE_SUPERVISOR_DETACHED:-}" ] || return 0
  local arg
  for arg in "$@"; do
    case "$arg" in
      --stop-pty-hosts-only|-h|--help) return 0 ;;
      --already-detached) export HEIMDALL_UPDATE_SUPERVISOR_DETACHED=1; return 0 ;;
    esac
  done
  # Already a session leader: there is no bridge session left to leave.
  if [ "$(ps -o sid= -p $$ 2>/dev/null | tr -d '[:space:]')" = "$$" ]; then
    export HEIMDALL_UPDATE_SUPERVISOR_DETACHED=1
    return 0
  fi
  if command -v setsid >/dev/null 2>&1; then
    export HEIMDALL_UPDATE_SUPERVISOR_DETACHED=1
    # setsid(1) calls setsid(2) in place, so exec keeps this PID. Only for a
    # process-group leader (where setsid(2) fails) does it fork once and let
    # the parent exit.
    exec setsid "$BASH" "$0" "$@"
  fi
  echo "[apply-bridge-update] WARNING: setsid unavailable; cannot leave the bridge's process group" >&2
}
detach_from_bridge_session "$@"

# --- Configuration & Defaults ------------------------------------------------
DATA_DIR="${DATA_DIR:-$HOME/.local/share/heimdall}"
STAGE_DIR="${STAGE_DIR:-}"
BRIDGE_PORT="${BRIDGE_PORT:-49323}"
HUB_URL="${HUB_URL:-http://127.0.0.1:8989}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-30}"
SERVICE_NAME="${SERVICE_NAME:-${HEIMDALL_BRIDGE_SERVICE_NAME:-}}"
BRIDGE_PID="${BRIDGE_PID:-}"
PTY_HOST_SOCKET="${PTY_HOST_SOCKET:-}"
LAUNCHD_PLIST=""
LAUNCHD_LOADED=false
STOP_PTY_HOSTS_ONLY=false
RESTART_HOOK="${RESTART_HOOK:-}"
STOP_HOOK="${STOP_HOOK:-}"
HEALTH_URL="${HEALTH_URL:-}"
HEALTH_METHOD="${HEALTH_METHOD:-}"
# Caller contract (see "Caller interface" in docs/SELF_HOSTING.md). Interface 1
# is the original argv; deployed Bridges send it without --interface or any
# version. Interface 2 callers also name the running and the target version.
SUPPORTED_INTERFACE=2
INTERFACE=""
FROM_VERSION=""
TO_VERSION=""

# Fail on a flag given without its value instead of on an unbound $2.
require_value() {
  if [ "$2" -lt 2 ]; then
    echo "Missing value for $1" >&2
    exit 2
  fi
}

# Parse command line flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --interface)
      require_value "$1" "$#"
      INTERFACE="$2"
      shift 2
      ;;
    --from-version)
      require_value "$1" "$#"
      FROM_VERSION="$2"
      shift 2
      ;;
    --to-version)
      require_value "$1" "$#"
      TO_VERSION="$2"
      shift 2
      ;;
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
    --already-detached)
      # Consumed by detach_from_bridge_session above.
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
      echo "  --interface N         Caller interface version (default 1; current callers send $SUPPORTED_INTERFACE)."
      echo "                        A newer interface than $SUPPORTED_INTERFACE is refused before any change."
      echo "  --from-version VER    Version of the running bridge (required by interface 2;"
      echo "                        absent = legacy caller, the version-independent flow)"
      echo "  --to-version VER      Version being installed (required by interface 2)"
      echo "                        Version hooks run on these before anything is stopped or"
      echo "                        swapped. All three flags also apply to --stop-pty-hosts-only."
      echo "  --data-dir DIR       Root data directory (default: ~/.local/share/heimdall)"
      echo "  --stage-dir DIR       Staging directory containing extracted binaries"
      echo "  --bridge-port PORT    Port bridge listens on for health check (default: 49323)"
      echo "  --hub-url URL         Central Hub URL"
      echo "  --health-timeout SEC  Healthcheck probe timeout in seconds (default: 30)"
      echo "  --service-name NAME   Systemd unit, launchd label or Termux runit service (auto-detected by default)"
      echo "  --bridge-pid PID      Exact bridge process to stop"
      echo "  --pty-host-socket PATH  Bridge-owned PTY daemon socket"
      echo "  --stop-pty-hosts-only   Only clean up this bridge’s PTY hosts"
      echo "  --already-detached    The caller started this script in a new session"
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

# Validate the caller contract before anything is stopped, cleaned up or swapped.
if [ -z "$INTERFACE" ]; then
  INTERFACE=1
elif ! [[ "$INTERFACE" =~ ^[1-9][0-9]{0,8}$ ]]; then
  echo "Invalid --interface value: $INTERFACE (expected a positive integer)" >&2
  exit 2
elif [ "$INTERFACE" -gt "$SUPPORTED_INTERFACE" ]; then
  echo "Unsupported supervisor interface $INTERFACE: this apply-bridge-update.sh supports interfaces 1-$SUPPORTED_INTERFACE; refusing before any change" >&2
  exit 2
fi
if [ "$INTERFACE" -ge 2 ] && { [ -z "$FROM_VERSION" ] || [ -z "$TO_VERSION" ]; }; then
  echo "Supervisor interface $INTERFACE requires --from-version and --to-version" >&2
  exit 2
fi

log() {
  printf '[apply-bridge-update] [%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

log_err() {
  printf '[apply-bridge-update] [%s] ERROR: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

# --- Version comparison ------------------------------------------------------
# SemVer 2.0 precedence in plain bash (3.2-safe). A leading "v" is accepted and
# +build metadata is ignored, as SemVer requires.
SEMVER_RE='^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
semver_valid() {
  [[ "$1" =~ $SEMVER_RE ]]
}

# Compare one dot-separated identifier; sets IDENT_CMP to -1, 0 or 1. Numbers
# compare by value (any length, no integer overflow) and rank below
# alphanumeric identifiers, which compare in ASCII order.
IDENT_CMP=0
semver_ident_cmp() {
  local a="$1" b="$2" LC_ALL=C
  if [[ "$a" =~ ^[0-9]+$ ]] && [[ "$b" =~ ^[0-9]+$ ]]; then
    a="${a#"${a%%[!0]*}"}"; b="${b#"${b%%[!0]*}"}"
    if [ "${#a}" -ne "${#b}" ]; then
      [ "${#a}" -lt "${#b}" ] && IDENT_CMP=-1 || IDENT_CMP=1
      return 0
    fi
  elif [[ "$a" =~ ^[0-9]+$ ]]; then
    IDENT_CMP=-1; return 0
  elif [[ "$b" =~ ^[0-9]+$ ]]; then
    IDENT_CMP=1; return 0
  fi
  if [[ "$a" < "$b" ]]; then IDENT_CMP=-1
  elif [[ "$a" > "$b" ]]; then IDENT_CMP=1
  else IDENT_CMP=0
  fi
}

# semver_compare A B: sets SEMVER_CMP to -1, 0 or 1 (A <, = or > B). Returns 1
# with SEMVER_CMP empty when either side is not a SemVer version.
SEMVER_CMP=""
semver_compare() {
  SEMVER_CMP=""
  semver_valid "$1" && semver_valid "$2" || return 1
  local a="${1#v}" b="${2#v}" a_pre="" b_pre="" i
  local -a a_ids b_ids
  a="${a%%+*}"; b="${b%%+*}"
  case "$a" in *-*) a_pre="${a#*-}"; a="${a%%-*}" ;; esac
  case "$b" in *-*) b_pre="${b#*-}"; b="${b%%-*}" ;; esac
  IFS=. read -r -a a_ids <<< "$a"
  IFS=. read -r -a b_ids <<< "$b"
  for i in 0 1 2; do
    semver_ident_cmp "${a_ids[$i]}" "${b_ids[$i]}"
    [ "$IDENT_CMP" -eq 0 ] || { SEMVER_CMP="$IDENT_CMP"; return 0; }
  done
  # A release ranks above any of its pre-releases.
  if [ -z "$a_pre" ] || [ -z "$b_pre" ]; then
    if [ -n "$a_pre" ]; then SEMVER_CMP=-1
    elif [ -n "$b_pre" ]; then SEMVER_CMP=1
    else SEMVER_CMP=0
    fi
    return 0
  fi
  IFS=. read -r -a a_ids <<< "$a_pre"
  IFS=. read -r -a b_ids <<< "$b_pre"
  i=0
  while [ "$i" -lt "${#a_ids[@]}" ] && [ "$i" -lt "${#b_ids[@]}" ]; do
    semver_ident_cmp "${a_ids[$i]}" "${b_ids[$i]}"
    [ "$IDENT_CMP" -eq 0 ] || { SEMVER_CMP="$IDENT_CMP"; return 0; }
    i=$((i + 1))
  done
  # Equal so far: the longer identifier list ranks higher.
  semver_ident_cmp "${#a_ids[@]}" "${#b_ids[@]}"
  SEMVER_CMP="$IDENT_CMP"
}

# Range tests for version hooks; both are false for a non-SemVer version.
version_before() { semver_compare "$1" "$2" && [ "$SEMVER_CMP" -lt 0 ]; }
version_at_least() { semver_compare "$1" "$2" && [ "$SEMVER_CMP" -ge 0 ]; }

# Termux (Android) exports TERMUX_VERSION and keeps $PREFIX in the app's data
# dir (same test as install.sh). There is no systemd there: install.sh
# registers the bridge as the termux-services (runit) service
# $PREFIX/var/service/ham-bridge, so the service is driven with `sv`.
is_termux() {
  [ -n "${TERMUX_VERSION:-}" ] && return 0
  case "${PREFIX:-}" in /data/data/com.termux|/data/data/com.termux/*) return 0 ;; esac
  return 1
}

# --- Bridge-owned PTY host cleanup -------------------------------------------
# Stop only this bridge's hosts, including old unlinked binaries, and their
# descendants. Capture process identities before asking a daemon to shut down:
# its children may otherwise be reparented and become invisible to cleanup.
# One implementation with two process readers: /proc on Linux (NixOS units carry
# only the PATH they declare) and ps(1) everywhere else (macOS). This must run
# under macOS /bin/bash 3.2: no associative arrays or mapfile, and empty arrays
# are expanded with ${a[@]+...} for set -u. PIDs index sparse arrays.

# Resolve a path like realpath(3) without requiring it to exist; sets CANON.
# macOS realpath(1) has no -m and readlink(1) no -f, so walk the components.
canonical_path() {
  local rest="$1" out='' comp target links=0
  case "$rest" in /*) ;; *) rest="$(pwd -P)/$rest" ;; esac
  while [ -n "$rest" ]; do
    case "$rest" in
      */*) comp="${rest%%/*}" rest="${rest#*/}" ;;
      *) comp="$rest" rest='' ;;
    esac
    case "$comp" in
      ''|.) continue ;;
      ..) out="${out%/*}"; continue ;;
    esac
    if [ -L "$out/$comp" ] && [ "$links" -lt 40 ]; then
      links=$((links + 1))
      target="$(readlink "$out/$comp" 2>/dev/null || true)"
      case "$target" in /*) out='' ;; esac
      rest="$target${rest:+/$rest}"
    else
      out="$out/$comp"
    fi
  done
  CANON="${out:-/}"
}

# Run a command for at most $1 seconds (macOS has no timeout(1)).
run_bounded() {
  local limit="$1" pid ticks=0
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$limit" "$@"
    return
  fi
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$ticks" -lt $((limit * 20)) ]; do
    sleep 0.05
    ticks=$((ticks + 1))
  done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null
}

# Process readers. *_read_process PID sets PROC_BORN (start time identity) for a
# live, non-zombie process owned by this user; *_snapshot calls pty_consider for
# every such process.
procfs_read_process() {
  local stat rest
  local -a fields
  [ -O "/proc/$1" ] || return 1
  read -r stat 2>/dev/null < "/proc/$1/stat" || return 1
  rest="${stat##*) }"
  read -r -a fields <<< "$rest"
  [ "${#fields[@]}" -gt 19 ] && [ "${fields[0]}" != Z ] || return 1
  PROC_PPID="${fields[1]}" PROC_BORN="${fields[19]}"
}

procfs_snapshot() {
  local dir pid arg exe is_command
  for dir in /proc/[0-9]*; do
    pid="${dir#/proc/}"
    procfs_read_process "$pid" || continue
    PTY_ARGV=()
    { while IFS= read -r -d '' arg || [ -n "$arg" ]; do
        [ -z "$arg" ] || PTY_ARGV+=("$arg")
      done < "/proc/$pid/cmdline"; } 2>/dev/null || continue
    # Only a host command needs its executable; skip the readlink otherwise.
    exe='' is_command=false
    for arg in ${PTY_ARGV[@]+"${PTY_ARGV[@]}"}; do
      case "$arg" in daemon|run) is_command=true ;; esac
    done
    if "$is_command"; then
      exe="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
      exe="${exe% (deleted)}"
    fi
    pty_consider "$pid" "$PROC_PPID" "$PROC_BORN" "$exe"
  done
}

PS_ROW_FIELDS='pid=,uid=,stat=,lstart='
ps_read_process() {
  local row pid uid stat l1 l2 l3 l4 l5
  row="$(ps -o "$PS_ROW_FIELDS" -p "$1" 2>/dev/null)" || return 1
  read -r pid uid stat l1 l2 l3 l4 l5 <<< "$row"
  [ "$pid" = "$1" ] && [ "$uid" = "$PTY_UID" ] && [ -n "$l5" ] || return 1
  case "$stat" in Z*) return 1 ;; esac
  PROC_BORN="$l1 $l2 $l3 $l4 $l5"
}

# ps on macOS does not quote argv paths containing spaces. The native daemon's
# final --socket argument is recovered without splitting it; other arguments
# are split on whitespace. Sets PTY_EXE and PTY_ARGV.
ps_split_command() {
  local command="$1" rest="$1" prefix='' head tail socket marker='/ham-pty-host '
  local -a words
  PTY_EXE='' PTY_ARGV=()
  while [[ "$rest" == *"$marker"* ]]; do
    head="${rest%%"$marker"*}" tail="${rest#*"$marker"}"
    case "$tail" in
      'daemon '*|'run '*|'--socket '*) PTY_EXE="$prefix$head/ham-pty-host"; break ;;
    esac
    prefix="$prefix$head$marker" rest="$tail"
  done
  if [ -n "$PTY_EXE" ]; then
    tail="${command:${#PTY_EXE}+1}"
    case "$tail" in
      'daemon --socket '*) PTY_ARGV=("$PTY_EXE" daemon --socket "${tail#daemon --socket }"); return ;;
      '--socket '*' daemon')
        socket="${tail#--socket }"
        PTY_ARGV=("$PTY_EXE" --socket "${socket% daemon}" daemon)
        return
        ;;
    esac
    PTY_ARGV=("$PTY_EXE")
  else
    tail="$command"
  fi
  read -r -a words <<< "$tail"
  PTY_ARGV+=(${words[@]+"${words[@]}"})
}

ps_snapshot() {
  local listing pid ppid uid stat l1 l2 l3 l4 l5 command
  listing="$(ps -axww -o pid=,ppid=,uid=,stat=,lstart=,command= 2>/dev/null)" || return 1
  [ -n "$listing" ] || return 1
  while read -r pid ppid uid stat l1 l2 l3 l4 l5 command; do
    case "$pid$ppid" in ''|*[!0-9]*) continue ;; esac
    [ "$uid" = "$PTY_UID" ] && [ -n "$l5" ] || continue
    case "$stat" in Z*) continue ;; esac
    ps_split_command "$command"
    pty_consider "$pid" "$ppid" "$l1 $l2 $l3 $l4 $l5" "$PTY_EXE"
  done <<< "$listing"
}

# Record one process (argv in PTY_ARGV) and decide whether it is a host this
# bridge owns: its binary is in this private installation's bin/ (or a swap
# directory), or it serves exactly this bridge's socket.
pty_consider() {
  local pid="$1" exe="$4" arg host socket='' index is_command=false
  local owned_binary=false owned_socket=false parent_dir
  local -a hosts=()
  P_PARENT[$pid]="$2" P_BORN[$pid]="$3"
  [ "${#PTY_ARGV[@]}" -gt 0 ] || return 0
  for arg in "${PTY_ARGV[@]}"; do
    case "$arg" in daemon|run) is_command=true ;; esac
  done
  "$is_command" || return 0
  # An interpreter can run a test/script host; real release binaries use argv[0].
  for host in "$exe" "${PTY_ARGV[@]:0:2}"; do
    [ "${host##*/}" != ham-pty-host ] || hosts+=("$host")
  done
  [ "${#hosts[@]}" -gt 0 ] || return 0
  for ((index = 0; index < ${#PTY_ARGV[@]}; index++)); do
    arg="${PTY_ARGV[index]}"
    if [ "$arg" = --socket ] && [ $((index + 1)) -lt ${#PTY_ARGV[@]} ]; then socket="${PTY_ARGV[index + 1]}"
    elif [[ "$arg" == --socket=* ]]; then socket="${arg#--socket=}"
    fi
  done
  if "$PTY_PRIVATE_INSTALL"; then
    for host in "${hosts[@]}"; do
      parent_dir=''
      case "$host" in */*) parent_dir="${host%/*}" parent_dir="${parent_dir##*/}" ;; esac
      case "$parent_dir" in bin|bin.old|bin.bak|bin.failed) ;; *) continue ;; esac
      canonical_path "$host"
      CANON="${CANON%/*}" CANON="${CANON%/*}"
      [ "${CANON:-/}" != "$PTY_DATA" ] || owned_binary=true
    done
  fi
  if [ -n "$PTY_EXPECTED_SOCKET" ] && [ -n "$socket" ]; then
    canonical_path "$socket"
    [ "$CANON" != "$PTY_EXPECTED_SOCKET" ] || owned_socket=true
  fi
  if "$owned_binary" || "$owned_socket"; then
    P_OWNED[$pid]=1
    [ -z "$socket" ] || PTY_SOCKETS+=("$socket")
  fi
}

# The process is still the one captured in the snapshot (start time unchanged).
pty_alive() {
  "${PTY_READER}_read_process" "$1" && [ "$PROC_BORN" = "${P_BORN[$1]}" ]
}

pty_any_alive() {
  local pid uid stat l1 l2 l3 l4 l5 rows list
  if [ "$PTY_READER" = ps ]; then
    # One ps call for every owned process; per-PID calls would stretch the bounds.
    list="$(printf '%s,' "${!P_OWNED[@]}")"
    rows="$(ps -o "$PS_ROW_FIELDS" -p "${list%,}" 2>/dev/null || true)"
    while read -r pid uid stat l1 l2 l3 l4 l5; do
      [ -n "$pid" ] && [ -n "${P_OWNED[$pid]:-}" ] && [ "$uid" = "$PTY_UID" ] || continue
      case "$stat" in Z*) continue ;; esac
      [ "$l1 $l2 $l3 $l4 $l5" != "${P_BORN[$pid]}" ] || return 0
    done <<< "$rows"
    return 1
  fi
  for pid in "${!P_OWNED[@]}"; do pty_alive "$pid" && return 0; done
  return 1
}

# Signal only after re-checking identity, so a reused PID is never signalled.
pty_send() {
  if pty_alive "$1"; then kill -s "$2" "$1" 2>/dev/null || true; fi
}

stop_pty_hosts() {
  local pid socket client deadline changed
  PTY_READER="${PTY_PROCESS_READER:-}"
  if [ -z "$PTY_READER" ]; then
    if [ -r /proc/self/stat ]; then PTY_READER=procfs
    elif command -v ps >/dev/null 2>&1; then PTY_READER=ps
    fi
  fi
  case "$PTY_READER" in
    procfs|ps) ;;
    *)
      # Exit 3 tells the Bridge cleanup could not run at all: nothing was signalled.
      log_err "Neither /proc nor ps is available to find bridge-owned PTY hosts; no process was stopped"
      return 3
      ;;
  esac
  PTY_UID="$(id -u)"
  canonical_path "$DATA_DIR"
  PTY_DATA="$CANON" PTY_EXPECTED_SOCKET='' PTY_PRIVATE_INSTALL=false
  if [ -n "$PTY_HOST_SOCKET" ]; then canonical_path "$PTY_HOST_SOCKET"; PTY_EXPECTED_SOCKET="$CANON"; fi
  CANON="${PTY_DATA%/*}"
  [ "${CANON##*/}" != bridges ] || PTY_PRIVATE_INSTALL=true
  P_PARENT=() P_BORN=() P_OWNED=() PTY_SOCKETS=()

  if ! "${PTY_READER}_snapshot"; then
    log_err "Could not list processes through $PTY_READER to find bridge-owned PTY hosts; no process was stopped"
    return 3
  fi

  changed=true
  while "$changed"; do
    changed=false
    for pid in ${P_PARENT[@]+"${!P_PARENT[@]}"}; do
      [ -z "${P_OWNED[$pid]:-}" ] && [ -n "${P_OWNED[${P_PARENT[$pid]}]:-}" ] || continue
      P_OWNED[$pid]=1 changed=true
    done
  done
  [ "${#P_OWNED[@]}" -gt 0 ] || return 0

  # Best effort protocol shutdown lets the PTY host terminate/reap its own agents.
  client="$PTY_DATA/bin/ham-pty-host"
  if [ "${#PTY_SOCKETS[@]}" -gt 0 ] && [ -f "$client" ] && [ -x "$client" ]; then
    while IFS= read -r socket; do
      run_bounded 3 "$client" --socket "$socket" stop >/dev/null 2>&1 || true
    done < <(printf '%s\n' "${PTY_SOCKETS[@]}" | sort -u)
  fi

  log "stopping bridge-owned PTY processes: $(printf '%s, ' "${!P_OWNED[@]}" | sed 's/, $//') (found through $PTY_READER)"
  for pid in "${!P_OWNED[@]}"; do pty_send "$pid" TERM; done
  deadline=$((SECONDS + 3))
  while pty_any_alive && [ "$SECONDS" -le "$deadline" ]; do sleep 0.05; done
  for pid in "${!P_OWNED[@]}"; do pty_send "$pid" KILL; done
  deadline=$((SECONDS + 2))
  while pty_any_alive && [ "$SECONDS" -le "$deadline" ]; do sleep 0.05; done
  if pty_any_alive; then
    log_err 'Bridge-owned PTY processes did not stop; refusing binary swap.'
    return 1
  fi
}

# --- Version hooks -----------------------------------------------------------
# The one place for release-specific update logic. The Bridge runs the staged
# (target) bundle's copy of this script, so a release can carry a fix for the
# Bridges it upgrades from. Hooks run before anything is stopped, cleaned up or
# swapped, in both modes (PHASE is "update" or "stop-pty-hosts-only"). A hook
# that must abort calls log_err and exits non-zero, which leaves the running
# Bridge untouched. Match exact versions or globs on FROM_VERSION/TO_VERSION in
# the case statements, and ranges with version_before/version_at_least (false
# for a non-SemVer version, so a range hook never fires on one), e.g.
#   if version_before "$FROM_VERSION" 0.7.0; then migrate_old_layout; fi
# Legacy callers (Bridges that predate interface 2) send no versions and get no
# hooks: a fix they need belongs in the version-independent flow.
run_version_hooks() {
  local phase="$1"
  if [ -z "$FROM_VERSION" ]; then
    log "Legacy caller (interface $INTERFACE, no --from-version): $phase runs the version-independent flow without version hooks"
    return 0
  fi
  log "Version hooks ($phase): interface $INTERFACE, from ${FROM_VERSION} to ${TO_VERSION:-unknown}"
  if [ -n "$TO_VERSION" ] && semver_compare "$FROM_VERSION" "$TO_VERSION"; then
    case "$SEMVER_CMP" in
      -1) log "  direction: upgrade" ;;
      0) log "  direction: reinstall of the running version" ;;
      1) log "  direction: downgrade" ;;
    esac
  else
    log "  direction: unknown (a version is not SemVer); range hooks do not apply"
  fi

  case "$FROM_VERSION" in
    0.5.*|v0.5.*)
      # Logging only: the 0.5 line introduced this interface and needs no
      # compatibility step.
      log "  hook: from-version $FROM_VERSION (0.5 line): no compatibility steps required"
      ;;
  esac

  # Hooks keyed on the version being installed go here.
  case "${TO_VERSION:-}" in
    *) ;;
  esac
}

if "$STOP_PTY_HOSTS_ONLY"; then
  run_version_hooks stop-pty-hosts-only
  stop_pty_hosts
  exit 0
fi

log "Starting supervisor execution"
log "  INTERFACE:      $INTERFACE"
log "  FROM_VERSION:   ${FROM_VERSION:-unset (legacy caller)}"
log "  TO_VERSION:     ${TO_VERSION:-unset}"
log "  DATA_DIR:       $DATA_DIR"
log "  STAGE_DIR:      $STAGE_DIR"
log "  BRIDGE_PORT:    $BRIDGE_PORT"
log "  HEALTH_URL:     $HEALTH_URL"
log "  HEALTH_METHOD:  $HEALTH_METHOD"
log "  HEALTH_TIMEOUT: ${HEALTH_TIMEOUT}s"
log "  BRIDGE_PID:     ${BRIDGE_PID:-unset}"
log "  SESSION:        ${HEIMDALL_UPDATE_SUPERVISOR_DETACHED:+detached }pgid $(ps -o pgid= -p $$ 2>/dev/null | tr -d '[:space:]')"

run_version_hooks update

# Locate staged binaries
STAGE_BIN=""
STAGE_ROOT="$STAGE_DIR"
if [ -d "$STAGE_DIR/bin" ]; then
  STAGE_BIN="$STAGE_DIR/bin"
elif [ -d "$STAGE_DIR/extract/bin" ]; then
  STAGE_ROOT="$STAGE_DIR/extract"
  STAGE_BIN="$STAGE_DIR/extract/bin"
elif [ -d "$STAGE_DIR/heimdall-cloudtop/bin" ]; then
  STAGE_ROOT="$STAGE_DIR/heimdall-cloudtop"
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
# Print the string value of a top-level key of a JSON object file (the last
# one wins, as in a JSON parser); print nothing for a non-string value. Fails
# on an unterminated string, unbalanced brackets or a non-object document.
json_top_level_string() {
  awk -v want="$2" '
    function hexval(h,   i, c, v) {
      v = 0; h = tolower(h)
      for (i = 1; i <= 4; i++) {
        c = index("0123456789abcdef", substr(h, i, 1))
        if (!c) return -1
        v = v * 16 + c - 1
      }
      return v
    }
    { doc = doc $0 "\n" }
    END {
      n = length(doc); depth = 0; top = ""; expect_key = 0; pending = 0; key = ""; result = ""
      for (i = 1; i <= n; i++) {
        c = substr(doc, i, 1)
        if (c == "\"") {
          s = ""
          for (i++; i <= n; i++) {
            c = substr(doc, i, 1)
            if (c == "\"") break
            if (c != "\\") { s = s c; continue }
            e = substr(doc, ++i, 1)
            if (e == "n") s = s "\n"; else if (e == "t") s = s "\t"; else if (e == "r") s = s "\r"
            else if (e == "b") s = s "\b"; else if (e == "f") s = s "\f"
            else if (e == "u") {
              v = hexval(substr(doc, i + 1, 4))
              if (v > 0 && v < 128) { s = s sprintf("%c", v); i += 4 } else s = s "\\u"
            } else s = s e
          }
          if (i > n) exit 1
          if (depth == 1 && top == "{") {
            if (expect_key) { key = s; expect_key = 0 }
            else if (pending) { if (key == want) result = s; pending = 0 }
          }
          continue
        }
        if (c == "{" || c == "[") {
          if (depth == 0) { if (top != "") exit 1; top = c; expect_key = (c == "{") }
          else if (depth == 1 && pending) { if (key == want) result = ""; pending = 0 }
          depth++
          continue
        }
        if (c == "}" || c == "]") { if (--depth < 0) exit 1; continue }
        if (depth == 1 && top == "{") {
          if (c == ":") pending = 1
          else if (c == ",") { expect_key = 1; pending = 0 }
          else if (pending && c !~ /[ \t\r\n]/) { if (key == want) result = ""; pending = 0 }
        }
      }
      if (depth != 0 || top != "{") exit 1
      print result
    }' "$1"
}

if is_termux; then
  staged_target="$(json_top_level_string "$STAGE_BIN/../METADATA.json" target 2>/dev/null || true)"
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
# The first word of a shell-quoted command line (POSIX shlex rules: quotes,
# backslash escapes, whitespace separation); sets SHELL_WORD. Fails on an
# unterminated quote or a trailing backslash anywhere in the line.
shell_first_word() {
  local line="$1" i=0 n=${#1} c quote='' word='' started=false finished=false
  SHELL_WORD=''
  while [ "$i" -lt "$n" ]; do
    c="${line:i:1}"
    if [ "$quote" = "'" ]; then
      if [ "$c" = "'" ]; then quote=''; else "$finished" || word+="$c"; fi
    elif [ "$quote" = '"' ]; then
      if [ "$c" = '"' ]; then
        quote=''
      else
        if [ "$c" = '\' ]; then
          i=$((i + 1))
          [ "$i" -lt "$n" ] || return 1
          case "${line:i:1}" in '"'|'\') c="${line:i:1}" ;; *) c="\\${line:i:1}" ;; esac
        fi
        "$finished" || word+="$c"
      fi
    else
      case "$c" in
        ' '|$'\t'|$'\r'|$'\n') ! "$started" || finished=true ;;
        "'"|'"') quote="$c" started=true ;;
        '\')
          i=$((i + 1))
          [ "$i" -lt "$n" ] || return 1
          "$finished" || word+="${line:i:1}"
          started=true
          ;;
        *) "$finished" || word+="$c"; started=true ;;
      esac
    fi
    i=$((i + 1))
  done
  [ -z "$quote" ] && "$started" || return 1
  SHELL_WORD="$word"
}

# Print a string value of a launchd plist key path (e.g. ProgramArguments.0).
plist_string() {
  command -v plutil >/dev/null 2>&1 || return 1
  plutil -extract "$2" raw -o - "$1" 2>/dev/null && return 0
  # macOS before 12 has no raw format: unwrap the one-value XML document.
  plutil -extract "$2" xml1 -o - "$1" 2>/dev/null \
    | sed -n 's:^[[:space:]]*<string>\(.*\)</string>[[:space:]]*$:\1:p' \
    | sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e "s/&apos;/'/g" -e 's/&amp;/\&/g' \
    | grep . || return 1
}

# Find the systemd user unit or LaunchAgent whose program is this bridge's
# installed ham-bridge; sets SERVICE_NAME (empty when there is none). Refuses
# to guess between several.
find_bridge_service() {
  local exe unit line plist value pct='%%' dollars='$$' matches=0 match='' match_plist=''
  exe="$DATA_DIR/bin/ham-bridge"
  while [[ "$exe" == *//* ]]; do exe="${exe//\/\///}"; done
  while [[ "$exe" == */./* ]]; do exe="${exe//\/.\///}"; done
  for unit in "$HOME/.config/systemd/user"/*.service; do
    [ -f "$unit" ] && [ -r "$unit" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      case "$line" in ExecStart=*) ;; *) continue ;; esac
      shell_first_word "${line#ExecStart=}" || continue
      value="${SHELL_WORD//"$pct"/%}"
      value="${value//"$dollars"/\$}"
      if [ "$value" = "$exe" ]; then
        matches=$((matches + 1)) match="${unit##*/}"
        break
      fi
    done < "$unit"
  done
  for plist in "$HOME/Library/LaunchAgents"/*.plist; do
    [ -f "$plist" ] || continue
    value="$(plist_string "$plist" ProgramArguments.0)" || continue
    [ "$value" = "$exe" ] || continue
    value="$(plist_string "$plist" Label)" || continue
    matches=$((matches + 1)) match="$value" match_plist="$plist"
  done
  if [ "$matches" -gt 1 ]; then
    log_err "Multiple services reference this bridge; specify --service-name."
    exit 1
  fi
  SERVICE_NAME="$match"
  LAUNCHD_PLIST="$match_plist"
}

# Resolve the plist needed to load a named LaunchAgent after its KeepAlive job
# has been booted out. The label alone is enough to stop a loaded job, but
# launchctl bootstrap requires the original plist path. Match both label and
# executable so another user's or installation's similarly named job is never
# loaded into this bridge's place.
find_bridge_launchd_plist() {
  local exe plist program label matches=0 match=''
  exe="$DATA_DIR/bin/ham-bridge"
  while [[ "$exe" == *//* ]]; do exe="${exe//\/\///}"; done
  while [[ "$exe" == */./* ]]; do exe="${exe//\/.\///}"; done
  for plist in "$HOME/Library/LaunchAgents"/*.plist; do
    [ -f "$plist" ] || continue
    program="$(plist_string "$plist" ProgramArguments.0)" || continue
    [ "$program" = "$exe" ] || continue
    label="$(plist_string "$plist" Label)" || continue
    [ "$label" = "$SERVICE_NAME" ] || continue
    matches=$((matches + 1)) match="$plist"
  done
  if [ "$matches" -ne 1 ]; then
    log_err "Expected one LaunchAgent plist for $SERVICE_NAME and $exe; found $matches."
    return 1
  fi
  LAUNCHD_PLIST="$match"
}

if [ -z "$SERVICE_NAME" ] && [ -z "$RESTART_HOOK" ]; then
  find_bridge_service
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
    [ -n "$LAUNCHD_PLIST" ] || find_bridge_launchd_plist || exit 1
    launchctl print "gui/$(id -u)/$SERVICE_NAME" >/dev/null || {
      log_err "Managed LaunchAgent not found: $SERVICE_NAME"; exit 1;
    }
    LAUNCHD_LOADED=true
    log "  LAUNCHD_PLIST:  $LAUNCHD_PLIST"
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
  elif [ -n "$SERVICE_NAME" ] && [[ "$(uname -s)" = Darwin ]]; then
    # A signal is not a stop operation for a KeepAlive LaunchAgent: launchd may
    # immediately replace the exact PID we killed, leaving that replacement on
    # the bridge port while the new binary starts. Unload the job so no process
    # can respawn during the swap. Rollback takes this path again for the newly
    # bootstrapped job instead of trying the now-stale original BRIDGE_PID.
    if "$LAUNCHD_LOADED" || launchctl print "gui/$(id -u)/$SERVICE_NAME" >/dev/null 2>&1; then
      launchctl bootout "gui/$(id -u)/$SERVICE_NAME" || {
        log_err "Failed to unload LaunchAgent $SERVICE_NAME"
        return 1
      }
    fi
    LAUNCHD_LOADED=false
    if [[ "$BRIDGE_PID" =~ ^[1-9][0-9]*$ ]]; then
      deadline=$((SECONDS + 10))
      while bridge_pid_running "$BRIDGE_PID" && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.1; done
      if bridge_pid_running "$BRIDGE_PID"; then
        log_err "Bridge PID $BRIDGE_PID did not exit after launchctl bootout"
        return 1
      fi
    fi
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
    [ -n "$LAUNCHD_PLIST" ] || { log_err "LaunchAgent plist is unknown for $SERVICE_NAME"; return 1; }
    launchctl bootstrap "gui/$(id -u)" "$LAUNCHD_PLIST" || {
      log_err "Failed to load LaunchAgent $SERVICE_NAME from $LAUNCHD_PLIST"
      return 1
    }
    LAUNCHD_LOADED=true
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

# Prepare assets before stopping anything. Select paths relative to the resolved
# binary directory so direct, extract/, and Cloudtop archive layouts all work.
EXTENSION_TRANSACTION=""
EXTENSION_SOURCE=""
for candidate in "$STAGE_BIN/../share/heimdall/extensions" "$STAGE_BIN/../share/extensions" "$STAGE_BIN/../extensions" "$STAGE_BIN/share/heimdall/extensions" "$STAGE_BIN/share/extensions" "$STAGE_BIN/extensions"; do
  if [ -d "$candidate" ]; then EXTENSION_SOURCE="$candidate"; break; fi
done
if [ -n "$EXTENSION_SOURCE" ]; then
  # The Bridge copies only this supervisor into DATA_DIR/updates before launch.
  # Load the matching helper from the resolved bundle, including wrapper layouts.
  EXTENSION_HELPER="$STAGE_ROOT/scripts/refresh-provider-extensions.sh"
  if [ ! -f "$EXTENSION_HELPER" ]; then
    log_err "Update bundle is missing refresh-provider-extensions.sh"
    exit 1
  fi
  source "$EXTENSION_HELPER"
  mkdir -p "$DATA_DIR"
  EXTENSION_TRANSACTION="$(mktemp -d "$DATA_DIR/.extensions-update.XXXXXX")"
  trap 'cleanup_provider_extension_transaction "$EXTENSION_TRANSACTION" "$DATA_DIR/extensions"' EXIT
  prepare_provider_extensions "$EXTENSION_SOURCE" "$DATA_DIR/extensions" "$EXTENSION_TRANSACTION/new"
fi

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

if [ -n "$EXTENSION_TRANSACTION" ]; then
  log "Activating provider extensions at $DATA_DIR/extensions"
  swap_provider_extensions "$EXTENSION_TRANSACTION/new" "$DATA_DIR/extensions" "$EXTENSION_TRANSACTION/old"
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
  # F10: register/repair every detected provider's extension from the activated
  # bundle (self-healing). Best effort: the bridge is healthy, and the Hub can retry.
  if [ -n "$EXTENSION_TRANSACTION" ] && [ -x "$DATA_DIR/bin/ham-bridge" ]; then
    log "Syncing provider extensions from $DATA_DIR/extensions"
    "$DATA_DIR/bin/ham-bridge" extensions sync --data-dir "$DATA_DIR" --source "$DATA_DIR/extensions" 2>&1 | while IFS= read -r line; do log "  $line"; done || true
  fi
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

  if [ -n "$EXTENSION_TRANSACTION" ]; then
    rm -rf "$DATA_DIR/extensions"
    if [ -d "$EXTENSION_TRANSACTION/old" ]; then
      mv "$EXTENSION_TRANSACTION/old" "$DATA_DIR/extensions"
    fi
  fi

  log "Restarting rolled-back service..."
  start_service || true

  mkdir -p "$DATA_DIR/logs"
  rollback_log="$DATA_DIR/logs/update_rollback.log"
  echo "Update failed: Health check timed out or failed after ${HEALTH_TIMEOUT}s on $(date -u +'%Y-%m-%dT%H:%M:%SZ')" >> "$rollback_log"
  log_err "Rollback complete. Log written to $rollback_log"
  exit 1
fi
