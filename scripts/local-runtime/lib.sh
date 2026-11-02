# shellcheck shell=bash
# Shared helpers for scripts/local-hub.sh and scripts/local-bridge.sh.
#
# The contract these helpers implement (state layout, instance.env keys, process
# records, ownership rule) is written down in scripts/local-runtime/CONTRACT.md so
# the PowerShell launchers and the preview integration can follow it exactly.
# Sourced, never executed. Every function is prefixed lr_.

LR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LR_HELPERS="$LR_ROOT/scripts/local-runtime"

lr_log() { printf '[%s] %s\n' "${LR_TAG:-local}" "$*"; }
lr_die() { printf '[%s] error: %s\n' "${LR_TAG:-local}" "$*" >&2; exit 1; }

# lr_state_root is where every named instance lives. Never inside the checkout
# (several worktrees share the same instances) and never the production data dir.
lr_state_root() {
  printf '%s\n' "${HEIMDALL_LOCAL_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/heimdall-local}"
}

# lr_valid_name: instance names become directory names and process markers.
lr_valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]]; }

# lr_instance_dir <kind> <name>; kind is hub or bridge.
lr_instance_dir() { printf '%s/%ss/%s\n' "$(lr_state_root)" "$1" "$2"; }

# lr_env_get <instance.env> <KEY> prints the recorded value ('' when absent).
lr_env_get() {
  [ -f "$1" ] || return 0
  # A missing key is not an error: grep's exit 1 would fail the caller under
  # `set -o pipefail` (and silently exit it under `set -e`).
  { grep -E "^$2=" "$1" || true; } | tail -1 | cut -d= -f2-
}

# lr_env_write <file> KEY=VALUE... writes the record atomically.
lr_env_write() {
  local file="$1"; shift
  local tmp="$file.tmp.$$"
  printf '%s\n' "$@" > "$tmp"
  mv -f "$tmp" "$file"
}

# lr_port_valid accepts 1024-65535 only: launchers never bind privileged ports.
lr_port_valid() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]; }

# lr_port_in_use <port>: true when something on this host accepts on 127.0.0.1:<port>.
lr_port_in_use() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && { exec 3>&- 3<&-; return 0; }
  return 1
}

# lr_port_claimed_by <port> <own-instance-dir> prints the other instance whose record
# claims the port, so a stopped instance's ports are not silently reused by another.
lr_port_claimed_by() {
  local port="$1" own="$2" env key
  for env in "$(lr_state_root)"/hubs/*/instance.env "$(lr_state_root)"/bridges/*/instance.env; do
    [ -f "$env" ] || continue
    [ "$(dirname "$env")" = "$own" ] && continue
    for key in HUB_PORT PROXY_PORT UI_PORT BRIDGE_PORT LOCAL_ENDPOINT_PORT; do
      if [ "$(lr_env_get "$env" "$key")" = "$port" ]; then
        printf '%s\n' "$(dirname "$env")"; return 0
      fi
    done
  done
  return 1
}

# lr_check_ports <instance-dir> <port>...: refuse duplicates, claimed and busy ports.
lr_check_ports() {
  local own="$1"; shift
  local seen=" " p other
  for p in "$@"; do
    lr_port_valid "$p" || lr_die "invalid port '$p' (need 1024-65535)"
    case "$seen" in *" $p "*) lr_die "port $p is given for two services";; esac
    seen="$seen$p "
    if other="$(lr_port_claimed_by "$p" "$own")"; then
      lr_die "port $p is recorded by instance $other; pick another port or remove that instance"
    fi
    lr_port_in_use "$p" && lr_die "port $p is already in use on 127.0.0.1"
  done
  return 0
}

# --- process records -------------------------------------------------------
# A record is <dir>/run/<svc>.pid holding "<pid> <start-time>". A process is OURS
# only if it is alive AND its start time still matches, so a recycled pid is never
# signalled. Processes run in their own session (setsid), so pid == process group.

lr_proc_start() { ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//;s/ *$//'; }

lr_owned_pid() { # <dir> <svc> -> prints pid when the recorded process is ours
  local rec="$1/run/$2.pid" pid start
  [ -f "$rec" ] || return 1
  read -r pid start < "$rec" || true
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [ -n "$start" ] && [ "$(lr_proc_start "$pid" | tr ' ' '_')" = "$start" ] || return 1
  printf '%s\n' "$pid"
}

# lr_spawn <dir> <svc> <log> <cmd...>: start detached in a new session and record it.
# Extra environment is passed by the caller with `env` in the command.
lr_spawn() {
  local dir="$1" svc="$2" log="$3"; shift 3
  mkdir -p "$dir/run" "$(dirname "$log")"
  if command -v setsid >/dev/null 2>&1; then
    nohup setsid "$@" >>"$log" 2>&1 < /dev/null &
  else
    nohup "$@" >>"$log" 2>&1 < /dev/null &
  fi
  local pid=$!
  local start=""
  for _ in 1 2 3 4 5; do start="$(lr_proc_start "$pid")"; [ -n "$start" ] && break; sleep 0.1; done
  printf '%s %s\n' "$pid" "$(printf '%s' "$start" | tr ' ' '_')" > "$dir/run/$svc.pid"
  disown "$pid" 2>/dev/null || true
}

# lr_stop_svc <dir> <svc>: TERM then KILL the recorded process group; never anything else.
lr_stop_svc() {
  local dir="$1" svc="$2" pid
  if pid="$(lr_owned_pid "$dir" "$svc")"; then
    lr_log "stopping $svc (pid $pid)"
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$dir/run/$svc.pid"
}

lr_svc_status() { # <dir> <svc>
  local pid
  if pid="$(lr_owned_pid "$1" "$2")"; then echo "  $2: running (pid $pid)"; else echo "  $2: stopped"; fi
}

# lr_wait_http <url> <seconds>: poll until the URL answers 2xx/3xx/4xx.
lr_wait_http() {
  local url="$1" secs="$2" i
  for i in $(seq 1 $((secs * 2))); do
    curl -s -o /dev/null -m 2 "$url" && return 0
    sleep 0.5
  done
  return 1
}

# --- instance lock -----------------------------------------------------------
# One launcher command per instance at a time (mkdir is atomic everywhere).
lr_lock() {
  local dir="$1"
  mkdir -p "$dir"
  if ! mkdir "$dir/.lock" 2>/dev/null; then
    local holder; holder="$(cat "$dir/.lock/pid" 2>/dev/null || true)"
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
      lr_die "instance $dir is busy (launcher pid $holder)"
    fi
    rm -rf "$dir/.lock"; mkdir "$dir/.lock" || lr_die "cannot lock $dir"
  fi
  echo $$ > "$dir/.lock/pid"
  # shellcheck disable=SC2064
  trap "rm -rf '$dir/.lock'" EXIT
}

# --- builds --------------------------------------------------------------------
# lr_build <out-dir> <component...>; components: hub bridge ctl dev-proxy pty-host.
# Mode from HEIMDALL_LOCAL_BUILD: nix (default; pinned toolchain), odin (compiler on
# PATH; pty-host needs cargo) or none (use --bin-dir binaries as they are).
# lr_nix_portable: true when `nix` exists but the host has no /nix/store, i.e. a
# rootless nix-portable whose store is only mounted inside its own namespace.
lr_nix_portable() { command -v nix >/dev/null && [ ! -d /nix/store ]; }

lr_build() {
  local out="$1"; shift
  local mode="${HEIMDALL_LOCAL_BUILD:-nix}" c pkg src
  mkdir -p "$out"
  for c in "$@"; do
    case "$c" in
      hub) pkg=ham-hub src=src/hub ;;
      bridge) pkg=ham-bridge src=src/bridge ;;
      ctl) pkg=ham-ctl src=src/ctl ;;
      dev-proxy) pkg=ham-dev-proxy src=src/dev_proxy ;;
      pty-host) pkg=ham-pty-host src="" ;;
      *) lr_die "unknown component $c" ;;
    esac
    case "$mode" in
      nix)
        command -v nix >/dev/null || lr_die "nix not found; use --build odin or --bin-dir <dir>"
        lr_nix_portable && lr_die "nix is nix-portable: its outputs only run inside its own user namespace, where the bridge keystore's kernel keyring is not the host's; pass --bin-dir <host-runnable binaries>"
        lr_log "nix build .#$pkg"
        nix build "$LR_ROOT#$pkg" -o "$out/result-$pkg" || lr_die "nix build $pkg failed"
        ln -sfn "result-$pkg/bin/$pkg" "$out/$pkg"
        ;;
      odin)
        if [ -z "$src" ]; then
          command -v cargo >/dev/null || lr_die "ham-pty-host needs cargo (or --bin-dir with a prebuilt ham-pty-host)"
          (cd "$LR_ROOT/tools/pty_host" && CARGO_TARGET_DIR="$out/cargo" cargo build --release) || lr_die "cargo build failed"
          ln -sfn "cargo/release/ham-pty-host" "$out/ham-pty-host"
          continue
        fi
        command -v odin >/dev/null || lr_die "odin not found on PATH"
        lr_log "odin build $src"
        (cd "$LR_ROOT" && odin build "$src" -collection:odin_test=src -out:"$out/$pkg") || lr_die "odin build $pkg failed"
        ;;
      none) ;;
      *) lr_die "HEIMDALL_LOCAL_BUILD must be nix, odin or none" ;;
    esac
  done
}

# lr_bin <bin-dir> <name>: resolve a binary, failing with a clear message.
lr_bin() {
  [ -x "$1/$2" ] || lr_die "$2 not found in $1 (build it, or pass --bin-dir)"
  printf '%s\n' "$1/$2"
}

# lr_enroll_prompt <enroll.log> prints "<approval-url> <pairing-code>" once
# `ham-bridge enroll` has printed both (src/bridge/enroll_device_flow.odin "Enroll
# this machine"): the URL ends in /api/v1/device/add and the pairing code
# (src/lib/vault/pairing.odin, 14 symbols of A-Z2-7 grouped 4-4-4-2) sits alone on
# its line. Prints nothing while either is missing.
lr_enroll_prompt() {
  local url code
  url="$(grep -aoE '^[[:space:]]+https?://[^[:space:]]+/api/v1/device/add[[:space:]]*$' "$1" 2>/dev/null | tail -1 | tr -d '[:space:]' || true)"
  code="$(grep -aoE '^[[:space:]]+[A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{2}[[:space:]]*$' "$1" 2>/dev/null | tail -1 | tr -d '[:space:]' || true)"
  [ -n "$url" ] && [ -n "$code" ] && printf '%s %s\n' "$url" "$code"
  return 0
}
