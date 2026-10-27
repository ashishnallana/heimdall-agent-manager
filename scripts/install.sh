#!/usr/bin/env bash
# Clean, per-Hub user-service installer. Keep execution behind main for curl | bash.
# Output style, set up lazily by the first helper that needs it. Colour only on
# a terminal, without NO_COLOR and with a TERM other than dumb; the spinner only
# on a terminal stderr. HEIMDALL_INSTALL_PLAIN=1 turns off both. Bash 3.2
# (macOS) and Termux safe: no associative arrays, no {fd} redirections.
ui_init() {
  UI_READY=1 UI_COLOUR=0 UI_SPIN=0 UI_TICK=1 UI_FRAMES='| / - \'
  UI_LABEL='' UI_DEPTH=0 UI_SPIN_PID='' UI_STEP_ERR='' UI_EXIT_CMD=''
  [ "${HEIMDALL_INSTALL_PLAIN:-0}" != 1 ] && [ "${TERM:-}" != dumb ] || return 0
  # https://no-color.org: any non-empty NO_COLOR.
  [ -n "${NO_COLOR:-}" ] || UI_COLOUR=1
  UI_SPIN=1
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) UI_FRAMES='⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏' ;;
  esac
  # BusyBox sleep may reject fractions; the spinner then ticks once a second.
  if sleep 0.01 2>/dev/null; then UI_TICK=0.2; fi
}
# Whether fd $1 gets colour.
ui_colour() {
  [ -n "${UI_READY:-}" ] || ui_init
  [ "$UI_COLOUR" = 1 ] && [ -t "$1" ]
}
# Erase a running spinner's line before writing to fd $1, when it is a terminal.
ui_clear_line() {
  if [ -n "${UI_SPIN_PID:-}" ] && [ -t "$1" ]; then printf '\r\033[K' >&"$1"; fi
}
ui_duration() {
  if [ "$1" -ge 60 ]; then printf '%dm%02ds' "$(($1 / 60))" "$(($1 % 60))"; else printf '%ds' "$1"; fi
}
log() {
  local c=2
  case "$1" in OK) c=32 ;; WARN) c=33 ;; ERROR) c=31 ;; esac
  ui_clear_line 1
  if ui_colour 1; then printf '\033[%sm[%s]\033[0m %s\n' "$c" "$1" "$2"
  else printf '[%s] %s\n' "$1" "$2"; fi
}
STEP_TOTAL=9
# step N TITLE: the "[N/9] TITLE" heading of one of main's steps; an empty N
# prints TITLE alone (the dry-run plan).
step() {
  local n="${1:+[$1/$STEP_TOTAL] }"
  ui_clear_line 1
  if ui_colour 1; then printf '\n\033[1;36m%s\033[0m\033[1m%s\033[0m\n' "$n" "$2"; else printf '\n%s%s\n' "$n" "$2"; fi
}
# banner VERSION HUB PROFILE: a box with an accent border on a colour terminal
# (ASCII corners outside UTF-8 locales); plain lines otherwise. Content stays
# ASCII so ${#line} is its display width in any locale.
banner() {
  local title='Heimdall Bridge Installer' tagline='Your agents, connected locally'
  local -a info=("Version  ${1:-latest release}" "Hub      ${2:-asked below}")
  [ -z "$3" ] || info[${#info[@]}]="Profile  $3"
  if ! ui_colour 1; then
    printf '\n%s - %s\n' "$title" "$tagline"
    printf '  %s\n' "${info[@]}"
    return 0
  fi
  local line i width=${#tagline} tl='+' tr='+' bl='+' br='+' h='-' v='|' rule=''
  for line in "${info[@]}"; do [ "${#line}" -le "$width" ] || width=${#line}; done
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) tl='╭' tr='╮' bl='╰' br='╯' h='─' v='│' ;;
  esac
  # Count, not ${#rule}: without an installed UTF-8 locale bash counts bytes.
  for ((i = 0; i < width + 4; i++)); do rule="$rule$h"; done
  # Accent (cyan) border; bold title, dim tagline and details.
  printf '\n\033[36m%s%s%s\033[0m\n' "$tl" "$rule" "$tr"
  printf '\033[36m%s\033[0m  \033[1m%-*s\033[0m  \033[36m%s\033[0m\n' "$v" "$width" "$title" "$v"
  printf '\033[36m%s\033[0m  \033[2m%-*s\033[0m  \033[36m%s\033[0m\n' "$v" "$width" "$tagline" "$v"
  printf '\033[36m%s\033[0m  %-*s  \033[36m%s\033[0m\n' "$v" "$width" '' "$v"
  for line in "${info[@]}"; do
    printf '\033[36m%s\033[0m  \033[2m%-*s\033[0m  \033[36m%s\033[0m\n' "$v" "$width" "$line" "$v"
  done
  printf '\033[36m%s%s%s\033[0m\n' "$bl" "$rule" "$br"
}
# Stops any spinner first, showing the failing step's stderr, then exits the shell.
fail() {
  spin_stop --failed
  if ui_colour 2; then printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
  else printf '\n[ERROR] %s\n' "$*" >&2; fi
  exit 1
}
# Redraws the spinner on fd 4 (the terminal) until killed or until the
# installer shell itself is gone, so no exit path can leave it running.
ui_ticker() {
  local frames=($UI_FRAMES) i=0 e label="$UI_LABEL" cols=80
  cols="$(stty size < /dev/tty 2>/dev/null)" && cols="${cols#* }" && [ "$cols" -gt 20 ] 2>/dev/null || cols=80
  [ "${#label}" -le $((cols - 14)) ] || label="${label:0:$((cols - 17))}..."
  while kill -0 "$UI_SHELL_PID" 2>/dev/null; do
    e=$((SECONDS - UI_START))
    # Inline time format: no subshell per tick.
    if [ "$e" -ge 60 ]; then e="$((e / 60))m$((e % 60 / 10))$((e % 10))s"; else e="${e}s"; fi
    printf '\r  %s %s  %s\033[K' "${frames[$((i % ${#frames[@]}))]}" "$label" "$e" >&4
    i=$((i + 1))
    sleep "$UI_TICK" || return 0
  done
}
ui_keep_exit_cmd() { UI_EXIT_CMD="$2"; }
ui_exit_trap() {
  local cmd="$UI_EXIT_CMD"
  spin_stop --failed
  eval "$cmd"
}
# spin_start LABEL: until the matching spin_stop, show LABEL with a spinner and
# the elapsed time on a terminal (stderr), or print a plain start line. Only the
# ticker runs in the background: the work stays in this shell (it may set
# globals, and fail must exit it). Meanwhile the step's stderr is held in a file
# (spin_stop replays it, fail shows its tail) and the EXIT trap also stops the
# spinner. Nested calls only count depth.
spin_start() {
  [ -n "${UI_READY:-}" ] || ui_init
  if [ "$UI_DEPTH" -gt 0 ]; then UI_DEPTH=$((UI_DEPTH + 1)); return 0; fi
  UI_DEPTH=1 UI_LABEL="$1" UI_START=$SECONDS UI_STEP_ERR='' UI_EXIT_CMD=''
  local dir="${work_dir:-}"
  [ -d "$dir" ] || dir="${TMPDIR:-/tmp}"
  if [ "$UI_SPIN" = 1 ] && [ -t 2 ] && UI_STEP_ERR="$(mktemp "$dir/.step-stderr.XXXXXX")"; then
    # Chain the current EXIT trap (trap -p into a file: bash 3.2 has no
    # parent traps inside $(...)).
    trap -p EXIT > "$UI_STEP_ERR"
    if [ -s "$UI_STEP_ERR" ]; then eval "ui_keep_exit_cmd $(sed 's/^trap //' "$UI_STEP_ERR")"; fi
    : > "$UI_STEP_ERR"
    trap ui_exit_trap EXIT
    exec 4>&2 2>"$UI_STEP_ERR"
    UI_SHELL_PID=$$
    ui_ticker < /dev/null &
    UI_SPIN_PID=$!
  else
    UI_STEP_ERR=''
    log INFO "$1"
  fi
}
# spin_stop [TAG MESSAGE | --failed]: end the spinner and replay the step's
# stderr, then print TAG MESSAGE, by default "[OK] LABEL (time)". --failed
# (fail, the EXIT trap) prints only the tail of that stderr.
spin_stop() {
  [ -n "${UI_READY:-}" ] && [ "$UI_DEPTH" -gt 0 ] || return 0
  if [ "${1:-}" != --failed ] && [ "$UI_DEPTH" -gt 1 ]; then
    UI_DEPTH=$((UI_DEPTH - 1))
    if [ "$#" -ge 2 ]; then log "$1" "$2"; fi
    return 0
  fi
  local elapsed=$((SECONDS - UI_START)) label="$UI_LABEL" err="$UI_STEP_ERR"
  UI_DEPTH=0 UI_LABEL='' UI_STEP_ERR=''
  if [ -n "$UI_SPIN_PID" ]; then
    kill "$UI_SPIN_PID" 2>/dev/null || :
    wait "$UI_SPIN_PID" 2>/dev/null || :
    UI_SPIN_PID=''
    printf '\r\033[K' >&4
    exec 2>&4 4>&-
    if [ -n "$UI_EXIT_CMD" ]; then trap -- "$UI_EXIT_CMD" EXIT; else trap - EXIT; fi
    UI_EXIT_CMD=''
  fi
  if [ -n "$err" ]; then
    if [ "${1:-}" = --failed ]; then tail -n 20 "$err" | sed 's/^/  | /' >&2
    else cat "$err" >&2; fi
    rm -f "$err"
  fi
  [ "${1:-}" != --failed ] || return 0
  if [ "$#" -ge 2 ]; then log "$1" "$2"; else log OK "$label ($(ui_duration "$elapsed"))"; fi
}
# Termux (Android) exports TERMUX_VERSION and keeps $PREFIX in the app's data dir.
is_termux() {
  [ -n "${TERMUX_VERSION:-}" ] && return 0
  case "${PREFIX:-}" in /data/data/com.termux|/data/data/com.termux/*) return 0 ;; esac
  return 1
}
# termux-services supervises with runsvdir, started by a login shell or a Termux
# restart after `pkg install termux-services`; without it nothing ever starts.
runsvdir_running() {
  # 1. Functional proof: a supervised service has a live supervise/ok fifo
  #    (runsv creates it; a stopped runsvdir leaves none). This also covers a
  #    previous ham-bridge install's log service. Android hides other apps'
  #    processes and Termux may lack pgrep, so this comes before any scan.
  local ok f
  for ok in "${PREFIX:-/nonexistent}"/var/service/*/supervise/ok "${PREFIX:-/nonexistent}"/var/service/*/log/supervise/ok; do
    [ -e "$ok" ] && return 0
  done
  # 2. Process scan (pgrep, else own-UID /proc).
  if command -v pgrep >/dev/null && pgrep -f runsvdir >/dev/null 2>&1; then return 0; fi
  for f in /proc/[0-9]*/cmdline; do
    case "$(tr '\0' ' ' < "$f" 2>/dev/null)" in *runsvdir*) return 0 ;; esac
  done
  # 3. Operator override when the checks cannot see the supervisor.
  [ "${HEIMDALL_ASSUME_RUNSVDIR:-0}" = 1 ]
}
usage() {
  cat <<'HELP'
Heimdall Bridge installer — Linux systemd / macOS LaunchAgent / Termux runit
Usage: install.sh [--hub URL] [--version TAG] [--dry-run] [--uninstall]
                  [--re-enroll [--new-bridge] | --keep-enrollment] [--non-interactive]
                  [--bundle FILE --checksum-file FILE]
                  [--name PROFILE]
Hub must be an HTTP(S) origin, e.g. https://hub.mundus.in or http://localhost:8080.
Without --hub, asks on the terminal. Existing enrollment prompts before re-enrolling.
Re-enrolling offers the approver this machine's previous bridge id for reuse (same
bridge, same history); --new-bridge registers a new bridge instead (implies --re-enroll).
--non-interactive preserves existing enrollment and prints a command for new enrollment.
--bundle installs the already-downloaded release bundle after verifying it against
--checksum-file. Both paths must name regular files; --version is also required.
This is used by the signed macOS app so installation never redownloads its embedded Bridge.
--uninstall removes only this Hub's service and binaries; credentials/data are kept.
--name PROFILE (or HEIMDALL_BRIDGE_NAME) installs a separate bridge to the same Hub
for this OS user, e.g. one per Heimdall account: service heimdall-bridge-<hub>_PROFILE
with its own enrollment, ports and ham-ctl wrapper. PROFILE is 1-31 of [a-z0-9-],
starting with a letter or digit. Pass the same --name to --uninstall or --re-enroll it.
Not supported on Termux.
Requires bash, curl, tar and sha256sum (or shasum). The binaries carry their own
HTTPS and secure WebSocket client (libcurl, linked statically;
Linux builds are fully static), so no libcurl or OpenSSL is needed on this machine.
The Hub is checked first (20 s budget, exact failure reason). Verified release
tarballs are cached in ${XDG_CACHE_HOME:-~/.cache}/heimdall/releases and reused
when their SHA-256 still matches the release's SHA256SUMS.
Termux (Android): also requires the Termux:API app with `pkg install termux-api termux-services`;
one Termux install runs one Hub as the runit service `ham-bridge`.
Run as your login user, without sudo.
HELP
}
prompt() {
  printf '%s' "$1" >&2
  if [ -t 0 ]; then IFS= read -r answer
  # -r /dev/tty also holds with no controlling terminal; the open then fails.
  elif [ -r /dev/tty ] && { IFS= read -r answer < /dev/tty; } 2>/dev/null; then :
  else return 1
  fi
}
# A credential alone is not an enrollment: ham-bridge also needs the identity
# record enrollment wrote, or it refuses to start ("holds no readable enrollment").
# Linux keeps it as a file (keystore_linux.odin); Keychain/Android Keystore
# entries cannot be checked from here, so those trust the credential.
identity_missing() {
  local config="$1" id
  [ "$svc" = systemd ] && [ "$os" = linux ] && [ -f "$config" ] || return 1
  id="$(sed -n 's/^[[:space:]]*daemon_id[[:space:]]*=[[:space:]]*"\(brg_[A-Za-z0-9_.-]*\)".*/\1/p' "$config" | head -n 1)"
  [ -n "$id" ] || return 1
  # The record lives in the bridge's per-(hub, id) scope directory, <id>_<hash>.
  local rec
  for rec in "$HOME/.config/heimdall/bridges/${id}_"*/identity_key; do
    [ ! -s "$rec" ] || return 1
  done
  return 0
}
# Small downloads (release list, SHA256SUMS) under a spinner; curl's error is
# shown and its status returned on failure.
download() {
  local status=0
  spin_start "Fetching ${2##*/}"
  curl --fail --location --silent --show-error --connect-timeout 15 \
    --max-time 600 --speed-limit 1024 --speed-time 60 "$1" --output "$2" || status=$?
  if [ "$status" -eq 0 ]; then spin_stop; return 0; fi
  spin_stop --failed
  log ERROR "Download failed (curl exit $status): $1"
  return "$status"
}
# Large downloads show curl's progress bar on a terminal (not with
# HEIMDALL_INSTALL_PLAIN=1); quiet otherwise.
download_progress() {
  local quiet=--silent
  [ -n "${UI_READY:-}" ] || ui_init
  if [ "$UI_SPIN" = 1 ] && [ -t 2 ]; then quiet=--progress-bar; fi
  curl --fail --location $quiet --show-error --connect-timeout 15 \
    --max-time 600 --speed-limit 1024 --speed-time 60 "$1" --output "$2"
}
HUB_CONNECT_TIMEOUT_SECONDS=20
# Explicit Hub reachability check before anything is installed: one fixed
# budget, a spinner with the elapsed time on a terminal, and curl's exact reason
# on failure (DNS, TLS verification, refused, timeout) instead of a silent hang
# or an unexplained half-second failure. Any HTTP answer counts: a Hub behind
# forward-auth redirects unauthenticated requests, which still proves TCP+TLS.
wait_for_hub() {
  local url="$hub_url/api/v1/health" err="$work_dir/hub-check.err" code status=0 start=$SECONDS
  spin_start "Checking Hub $hub_url (up to ${HUB_CONNECT_TIMEOUT_SECONDS}s)"
  code="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --connect-timeout "$HUB_CONNECT_TIMEOUT_SECONDS" --max-time "$HUB_CONNECT_TIMEOUT_SECONDS" \
    "$url" 2> "$err")" || status=$?
  if [ "$status" -eq 0 ]; then
    spin_stop OK "Hub reachable: HTTP $code after $((SECONDS - start))s"
  else
    fail "Hub $hub_url not reachable (gave up after $((SECONDS - start))s of ${HUB_CONNECT_TIMEOUT_SECONDS}s): $(tr -d '\n' < "$err")"
  fi
}
# The helpers below need only bash, POSIX userland, tar and sha256sum/shasum:
# no python3 or perl, so the installer runs on stock macOS and Termux too.
# Keep them bash 3.2 compatible (macOS /bin/bash): no associative arrays.

# POSIX sh quoting; safe words stay bare, as Python's shlex.quote did.
sh_quote() {
  local safe='^[A-Za-z0-9_@%+=:,./-]+$' sq="'" esc="'\"'\"'"
  if [[ $1 =~ $safe ]]; then printf '%s' "$1"
  else printf "'%s'" "${1//$sq/$esc}"; fi
}
# Backslash-escape \ and " for a JSON/TOML/systemd double-quoted string.
dq_escape() { printf '%s' "$1" | sed 's/[\\"]/\\&/g'; }
# systemd quoting: "..." with \ " escaped and % doubled (specifiers).
systemd_quote() { printf '"%s"' "$(dq_escape "$1" | sed 's/%/%%/g')"; }
# An ExecStart= word: systemd_quote plus $ doubled (no variable expansion).
systemd_exec_quote() { systemd_quote "$1" | sed 's/\$/$$/g'; }
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
# Absolute path of executable $1 in the PATH-style list $2.
find_in_path() {
  local rest="$2:" dir
  while [ -n "$rest" ]; do
    dir="${rest%%:*}"; rest="${rest#*:}"
    case "$dir" in /*) [ -f "$dir/$1" ] && [ -x "$dir/$1" ] && { printf '%s\n' "$dir/$1"; return 0; } ;; esac
  done
  return 1
}
# One enrollment shim (systemctl or launchctl) mapping the legacy service name
# that released ham-bridge binaries restart onto this Hub's service.
write_enroll_shim() {
  local path="$1" real="$2" name="$3" uid="$4" q_real
  q_real="$(sh_quote "$real")"
  {
    printf '#!/bin/sh\n'
    if [ "${path##*/}" = systemctl ]; then
      printf 'if [ "$*" = "--user restart heimdall-bridge" ]; then\n  set -- --user restart %s\nfi\n' "$(sh_quote "$name")"
    else
      # kickstart needs a loaded job; enroll() boots it out, so bootstrap it again first.
      local label
      label="$(sh_quote "gui/$uid/$name")"
      printf 'if [ "$*" = "kickstart -k gui/%s/works.earendil.heimdall-bridge" ]; then\n' "$uid"
      printf '  %s print %s >/dev/null 2>&1 || %s bootstrap %s %s || exit 1\n' "$q_real" "$label" "$q_real" \
        "$(sh_quote "gui/$uid")" "$(sh_quote "$HOME/Library/LaunchAgents/$name.plist")"
      printf '  set -- kickstart -k %s\nfi\n' "$label"
    fi
    printf 'exec %s "$@"\n' "$q_real"
  } > "$path"
  chmod 700 "$path"
}
# Lower-case compressed IPv6 text (RFC 5952, as Python's ipaddress), or fail.
ipv6_compress() {
  local LC_ALL=C addr="$1" head tail part v4 n i best=-1 bestlen=1 run=0 out=''
  local -a groups=() hp=() tp=()
  case "$addr" in *:::*|*[!0-9a-f:.]*) return 1 ;; esac
  # An IPv4 tail ("::ffff:192.0.2.1") becomes two hex groups.
  if [[ $addr == *.* ]]; then
    v4="${addr##*:}"
    [[ $v4 =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]] || return 1
    for i in 1 2 3 4; do [ "${BASH_REMATCH[$i]}" -le 255 ] || return 1; done
    addr="${addr%:*}:$(printf '%x:%x' $((BASH_REMATCH[1]*256+BASH_REMATCH[2])) $((BASH_REMATCH[3]*256+BASH_REMATCH[4])))"
  fi
  if [[ $addr == *::* ]]; then
    head="${addr%%::*}"; tail="${addr#*::}"
    [[ $tail != *::* ]] || return 1
    [ -z "$head" ] || { local IFS=:; hp=($head); }
    [ -z "$tail" ] || { local IFS=:; tp=($tail); }
    n=$((8 - ${#hp[@]} - ${#tp[@]}))
    [ "$n" -ge 1 ] || return 1
    groups=(${hp[@]+"${hp[@]}"})
    for ((i = 0; i < n; i++)); do groups[${#groups[@]}]=0; done
    groups+=(${tp[@]+"${tp[@]}"})
  else
    case "$addr" in :*|*:) return 1 ;; esac
    local IFS=:; groups=($addr)
  fi
  [ "${#groups[@]}" -eq 8 ] || return 1
  for ((i = 0; i < 8; i++)); do
    part="${groups[$i]}"
    [[ $part =~ ^[0-9a-f]{1,4}$ ]] || return 1
    groups[$i]="$(printf '%x' "0x$part")"
  done
  # IPv4-mapped addresses keep the dotted tail (Python >= 3.13 spelling).
  if [ "${groups[0]}${groups[1]}${groups[2]}${groups[3]}${groups[4]}:${groups[5]}" = 00000:ffff ]; then
    printf '::ffff:%d.%d.%d.%d\n' $((0x${groups[6]} >> 8)) $((0x${groups[6]} & 255)) $((0x${groups[7]} >> 8)) $((0x${groups[7]} & 255))
    return 0
  fi
  # Replace the longest run (>1, leftmost on ties) of zero groups with "::".
  for ((i = 0; i <= 8; i++)); do
    if [ "$i" -lt 8 ] && [ "${groups[$i]}" = 0 ]; then run=$((run+1)); continue; fi
    if [ "$run" -gt "$bestlen" ]; then best=$((i-run)); bestlen=$run; fi
    run=0
  done
  for ((i = 0; i < 8; i++)); do
    if [ "$i" -eq "$best" ]; then out="$out::"; i=$((i+bestlen-1)); continue; fi
    case "$out" in ''|*:) out="$out${groups[$i]}" ;; *) out="$out:${groups[$i]}" ;; esac
  done
  printf '%s\n' "$out"
}
# Canonical Hub origin (line 1) and service name (line 2). Canonical origins
# include explicit non-default ports; IPv4, IPv6 and DNS names all map to safe
# filenames. Rejects rather than collapses ambiguous IDs.
canonical_hub() {
  local LC_ALL=C url="$1" scheme rest netloc after host port='' name
  local bad='Invalid Hub URL: use an HTTP(S) origin with no path, credentials, query, or fragment.'
  url="${url#"${url%%[![:space:]]*}"}"; url="${url%"${url##*[![:space:]]}"}"
  case "$url" in *[![:graph:]]*) printf '%s\n' "$bad" >&2; return 1 ;; esac
  [[ $url =~ ^([A-Za-z][A-Za-z0-9+.-]*)://(.*)$ ]] || { printf '%s\n' "$bad" >&2; return 1; }
  scheme="$(printf '%s' "${BASH_REMATCH[1]}" | tr 'A-Z' 'a-z')"; rest="${BASH_REMATCH[2]}"
  netloc="${rest%%[/?#]*}"; after="${rest#"$netloc"}"
  # Only an empty path or "/", with no query or fragment (an empty "?" or "#" is none).
  case "$after" in ''|/|'?'|'#'|'?#'|'/?'|'/#'|'/?#') ;; *) printf '%s\n' "$bad" >&2; return 1 ;; esac
  case "$scheme" in http|https) ;; *) printf '%s\n' "$bad" >&2; return 1 ;; esac
  case "$netloc" in *@*) printf '%s\n' "$bad" >&2; return 1 ;; esac
  if [[ $netloc == \[* ]]; then
    [[ $netloc =~ ^\[([^]]*)\](:([0-9]*))?$ ]] || { printf '%s\n' "$bad" >&2; return 1; }
    host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[3]}"
  else
    host="${netloc%%:*}"
    [ "$host" = "$netloc" ] || port="${netloc#*:}"
  fi
  host="$(printf '%s' "$host" | tr 'A-Z' 'a-z')"
  [[ $port =~ ^[0-9]*$ ]] && [ -n "$host" ] || { printf '%s\n' "$bad" >&2; return 1; }
  if [ -n "$port" ]; then
    port="${port#"${port%%[!0]*}"}"
    [ "${#port}" -le 5 ] && [ "${port:-0}" -ge 1 ] && [ "$port" -le 65535 ] || { printf '%s\n' "$bad" >&2; return 1; }
    { [ "$scheme" = http ] && [ "$port" = 80 ]; } || { [ "$scheme" = https ] && [ "$port" = 443 ]; } && port=''
  fi
  if [[ $host == *:* ]]; then
    host="$(ipv6_compress "$host")" || { printf '%s\n' "$bad" >&2; return 1; }
  else
    # DNS name or IPv4 literal: labels of 1-63 characters (a trailing dot is
    # dropped), only [a-z0-9.-], no leading/trailing punctuation.
    # Internationalized names must be given in their ASCII (xn--) form.
    local label labels="$host."
    while [ "${labels#*.}" != "" ]; do
      label="${labels%%.*}"; labels="${labels#*.}"
      [ "${#label}" -ge 1 ] && [ "${#label}" -le 63 ] || { printf '%s\n' "$bad" >&2; return 1; }
    done
    [ "${#labels}" -le 64 ] || { printf '%s\n' "$bad" >&2; return 1; }
    host="${host%"${host##*[!.]}"}"
    [[ $host =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || { printf '%s\n' "$bad" >&2; return 1; }
  fi
  name="${host//[!a-z0-9-]/-}${port:+-$port}"
  [ "${#name}" -le 160 ] || { printf '%s\n' "$bad" >&2; return 1; }
  case "$host" in *:*) host="[$host]" ;; esac
  printf '%s://%s%s\nheimdall-bridge-%s\n' "$scheme" "$host" "${port:+:$port}" "$name"
}
# A bridge profile name (--name) becomes part of every path and unit name: keep it
# filename- and systemd-safe. canonical_hub never emits '_', so the service name
# "<hub name>_<profile>" cannot collide with another Hub's. C locale: ASCII ranges.
valid_profile() {
  local LC_ALL=C
  [[ $1 =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]]
}
# The --hub value of a legacy (pre per-Hub) service definition, if any.
legacy_service_hub() {
  case "$1" in
    *.plist)
      # The string after "--hub" among the <array> strings (ProgramArguments).
      LC_ALL=C awk 'BEGIN { RS = "<" }
        /^array[[:space:]>]/ { depth++; next }
        /^\/array[[:space:]>]/ { if (depth) depth--; next }
        depth && (/^string>/ || /^string\/>/) {
          v = /^string>/ ? substr($0, 8) : ""
          gsub(/&lt;/, "<", v); gsub(/&gt;/, ">", v); gsub(/&quot;/, "\"", v); gsub(/&apos;/, "\047", v); gsub(/&amp;/, "\\&", v)
          if (want) { print v; exit }
          want = (v == "--hub")
        }' "$1" ;;
    *)
      grep -oE -- "--hub[[:space:]]+[\"']?[^[:space:]\"'\\\\]+" "$1" | head -n 1 | sed -E "s/^--hub[[:space:]]+[\"']?//" ;;
  esac
}
# Whether the legacy service file $1 serves exactly Hub $2.
legacy_service_matches() {
  local value
  value="$(legacy_service_hub "$1")" || return 1
  while [ "${value%/}" != "$value" ]; do value="${value%/}"; done
  [ -n "$value" ] && [ "$value" = "$2" ]
}
# JSON tokens, one per line (strings keep their quotes and escapes).
json_tokens() {
  LC_ALL=C grep -oE '"([^"\\]|\\.)*"|[][{}:,]|true|false|null|-?[0-9][0-9.eE+-]*' "$1"
}
# Newest promoted (non-draft, non-prerelease) release in GitHub's release list
# $1 carrying SHA256SUMS and the bundle of the first target in $2.. that any
# listed release carries. Exit 2: not a release list; 1: no such release.
select_release() {
  local file="$1"; shift
  { json_tokens "$file" || true; } | LC_ALL=C awk -v targets="$*" '
    # The text of a JSON string token; \uXXXX escapes are kept as they are.
    function unq(s,  out, c) {
      s = substr(s, 2, length(s) - 2); out = ""
      while (match(s, /\\./)) {
        c = substr(s, RSTART + 1, 1)
        out = out substr(s, 1, RSTART - 1) (c == "n" ? "\n" : c == "t" ? "\t" : c == "r" ? "\r" : c == "u" ? "\\u" : c)
        s = substr(s, RSTART + 2)
      }
      return out s
    }
    function truthy(t) { return !(t == "false" || t == "null" || t == "0" || t == "\"\"") }
    function value(t,  i) {
      if (d < 2 || typ[1] != "a" || typ[2] != "o") return
      i = idx[1]
      if (d == 2) {
        if (key[2] == "tag_name" && t ~ /^"/) tag[i] = unq(t)
        else if (key[2] == "draft") draft[i] = truthy(t)
        else if (key[2] == "prerelease") pre[i] = truthy(t)
      } else if (d == 4 && key[2] == "assets" && typ[3] == "a" && typ[4] == "o" && key[4] == "name" && t ~ /^"/) {
        has[i, unq(t)] = 1
      }
    }
    NR == 1 && $0 != "[" { exit 2 }
    { t = $0; seen = 1 }
    t == "{" || t == "[" {
      if (d == 1 && typ[1] == "a") n = idx[1] + 1
      d++; typ[d] = (t == "{") ? "o" : "a"; idx[d] = 0; ek[d] = (t == "{"); key[d] = ""; next
    }
    t == "}" || t == "]" { d--; next }
    t == ":" { ek[d] = 0; next }
    t == "," { if (typ[d] == "a") idx[d]++; else ek[d] = 1; next }
    typ[d] == "o" && ek[d] { key[d] = unq(t); next }
    { value(t) }
    END {
      if (!seen) exit 2
      split(targets, list, " ")
      for (j = 1; (j in list); j++)
        for (i = 0; i < n; i++)
          if (!draft[i] && !pre[i] && ((i, "SHA256SUMS") in has) && ((i, "heimdall-local-" list[j] "-" tag[i] ".tar.gz") in has)) {
            print tag[i]; exit 0
          }
      exit 1
    }'
}
sha256_of() {
  local out
  if command -v sha256sum >/dev/null; then out="$(sha256sum < "$1")" || return 1
  else out="$(shasum -a 256 < "$1")" || return 1; fi
  printf '%s\n' "${out%% *}"
}
# Whether file $2 matches the single SHA256SUMS ($1) entry named $3. A match
# is remembered in SHA256_VERIFIED (sums file, name, size) so extract_bundle
# need not hash a verified cached copy again.
sha256_matches() {
  local expected actual
  SHA256_VERIFIED=''
  expected="$(awk -v n="$3" '{ sub(/\r$/, "") } NF == 2 { f = $2; sub(/^\*+/, "", f); if (f == n) { c++; h = $1 } }
    END { if (c == 1) print h; else exit 1 }' "$1")" || return 1
  actual="$(sha256_of "$2")" || return 1
  [ -n "$actual" ] && [ "$actual" = "$expected" ] || return 1
  SHA256_VERIFIED="$1|$3|$(($(wc -c < "$2")))"
}
# posixpath.normpath for a relative path.
normpath() {
  local rest="$1/" part out=''
  while [ -n "$rest" ]; do
    part="${rest%%/*}"; rest="${rest#*/}"
    case "$part" in
      ''|.) ;;
      ..) case "$out" in ''|..|*/..) out="${out:+$out/}.." ;; */*) out="${out%/*}" ;; *) out='' ;; esac ;;
      *) out="${out:+$out/}$part" ;;
    esac
  done
  printf '%s\n' "${out:-.}"
}
# -rwxr-xr-x -> MODE_OCTAL=755 (setuid/setgid/sticky dropped). Sets a variable
# instead of printing: extract_bundle calls it per member, without subshells.
mode_octal() {
  local i digit=0
  MODE_OCTAL=''
  for i in 1 2 3 4 5 6 7 8 9; do
    case "${1:$i:1}" in
      r) digit=$((digit+4)) ;; w) digit=$((digit+2)) ;; x|s|t) digit=$((digit+1)) ;;
    esac
    if [ $((i % 3)) -eq 0 ]; then MODE_OCTAL="$MODE_OCTAL$digit"; digit=0; fi
  done
}
# Exactly one regular member of extract_bundle's listing (raw, kind, n) named $1
# (a leading ./ ignored); prints its raw name.
bundle_member() {
  local i found=''
  for ((i = 0; i < n; i++)); do
    [ "${raw[$i]#./}" = "$1" ] || continue
    [ -z "$found" ] && [ "${kind[$i]}" = - ] || return 1
    found="${raw[$i]}"
  done
  [ -n "$found" ] && printf '%s\n' "$found"
}
# Verify bundle $2 in $1 against $1/SHA256SUMS (skipped when sha256_matches
# just verified this same file, the cached copy), then extract only the required
# regular binaries, the update supervisor and the provider extension tree into
# $1. Every member is checked from the archive listing before anything is
# extracted: no links or unsafe paths outside the extension tree's own links.
# One verbose listing pass gives names, kinds, link targets and modes.
extract_bundle() {
  local root="$1" archive="$1/$2" prefix=share/heimdall/extensions
  spin_start "Verifying and unpacking $2"
  if [ "${SHA256_VERIFIED:-}" != "$root/SHA256SUMS|$2|$(($(wc -c < "$archive")))" ]; then
    sha256_matches "$root/SHA256SUMS" "$archive" "$2" || fail 'SHA-256 verification failed; nothing installed.'
  fi
  local -a raw=() kind=() link=() mode=() select=() bins=()
  local line rest k fields i n name binary target seen=$'\n' parent assets=0 helper='' supervisor=''
  LC_ALL=C tar -tvzf "$archive" > "$root/.members-long" || fail 'Unable to list the release bundle; nothing installed.'
  while IFS= read -r line; do
    i=${#raw[@]}
    # Columns before the name: GNU and BusyBox tar print mode, owner/group,
    # size, date, time; bsdtar (macOS) mode, links, owner, group, size, month,
    # day, time or year. Runs of blanks separate them, one blank precedes the
    # name. A misparsed name can only fail the checks or the extraction below.
    rest="${line#"${line%%[ ]*}"}"; rest="${rest#"${rest%%[! ]*}"}"; rest="${rest%% *}"
    case "$rest" in */*) fields=5 ;; *) fields=8 ;; esac
    rest="$line"
    for ((k = 1; k < fields; k++)); do
      rest="${rest#"${rest%%[ ]*}"}"; rest="${rest#"${rest%%[! ]*}"}"
    done
    case "$rest" in *" "?*) rest="${rest#* }" ;; *) fail 'Unreadable release bundle listing; nothing installed.' ;; esac
    # GNU tar marks hard links "h"; bsdtar lists them as "-" ... "link to".
    case "$line" in -*" link to "*) k=h ;; *) k="${line:0:1}" ;; esac
    kind[$i]="$k"; link[$i]=''; mode[$i]=''
    case "$k" in
      l) link[$i]="${rest#*" -> "}"; rest="${rest%%" -> "*}" ;;
      h) rest="${rest%%" link to "*}" ;;
      -) mode_octal "$line"; mode[$i]="$MODE_OCTAL" ;;
    esac
    raw[$i]="$rest"
  done < "$root/.members-long"
  rm -f "$root/.members-long"
  n=${#raw[@]}
  for binary in heimdall ham-bridge ham-pty-host ham-ctl; do
    bins[${#bins[@]}]="$(bundle_member "bin/$binary")" || fail "Missing/unsafe binary: $binary"
  done
  select=("${bins[@]}")
  for ((i = 0; i < n; i++)); do
    [ "${raw[$i]#./}" = scripts/apply-bridge-update.sh ] || continue
    supervisor="$(bundle_member scripts/apply-bridge-update.sh)" || fail 'Unsafe update supervisor'
    select[${#select[@]}]="$supervisor"; break
  done
  # The extension tree: check every path and link before writing anything.
  for ((i = 0; i < n; i++)); do
    name="${raw[$i]#./}"
    while [ "${name%/}" != "$name" ]; do name="${name%/}"; done
    [ "$name" = "$prefix" ] || [ "${name#"$prefix"/}" != "$name" ] || continue
    case "/$name/" in */../*|*//*|*/./*) fail "Unsafe/duplicate extension path: $name" ;; esac
    case "$name" in *[!A-Za-z0-9._/@+=,~-]*) fail "Unsafe/duplicate extension path: $name" ;; esac
    case "$seen" in *$'\n'?"$name"$'\n'*) fail "Unsafe/duplicate extension path: $name" ;; esac
    case "${kind[$i]}" in d|-|l) ;; *) fail "Unsafe extension member: $name" ;; esac
    if [ "${kind[$i]}" = l ]; then
      target="$(normpath "${name%/*}/${link[$i]}")"
      case "${link[$i]}" in /*) fail "Unsafe extension symlink: $name" ;; esac
      [ "${target#"$prefix"/}" != "$target" ] || fail "Unsafe extension symlink: $name"
    fi
    seen="$seen${kind[$i]}$name"$'\n'
    select[${#select[@]}]="${raw[$i]}"; assets=$((assets+1))
  done
  while IFS= read -r line; do
    name="${line#?}"; parent="$name"
    while [ "${parent%/*}" != "$parent" ]; do
      parent="${parent%/*}"
      case "$seen" in *$'\n'[!d]"$parent"$'\n'*) fail "Non-directory extension parent: $parent" ;; esac
    done
  done <<< "${seen#$'\n'}"
  if [ "$assets" -gt 0 ]; then
    helper="$(bundle_member scripts/refresh-provider-extensions.sh)" || fail 'Missing/unsafe extension staging helper'
    select[${#select[@]}]="$helper"
  fi
  # Only checked members are extracted, into a private staging directory.
  local stage="$root/.bundle"
  mkdir "$stage"
  LC_ALL=C tar --no-recursion -xzf "$archive" -C "$stage" "${select[@]}" || fail 'Unable to extract the release bundle; nothing installed.'
  i=0
  for binary in heimdall ham-bridge ham-pty-host ham-ctl; do
    mv -f "$stage/${bins[$i]}" "$root/$binary"; i=$((i+1))
  done
  [ -z "$supervisor" ] || mv -f "$stage/$supervisor" "$root/apply-bridge-update.sh"
  if [ "$assets" -gt 0 ]; then
    mv -f "$stage/$helper" "$root/refresh-provider-extensions.sh"
    # Regular files keep exactly their archive permission bits.
    for ((i = 0; i < n; i++)); do
      name="${raw[$i]#./}"
      [ "${kind[$i]}" = - ] && [ "${name#"$prefix"/}" != "$name" ] && chmod "${mode[$i]}" "$stage/$name"
    done
    mkdir -p "$root/share/heimdall"
    mv "$stage/$prefix" "$root/$prefix"
  fi
  rm -rf "$stage"
  spin_stop
}
# True when something accepts TCP connections on 127.0.0.1:$1.
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
# The integers of a flat JSON integer list such as [49323, 49324], or fail.
json_int_list() {
  local text
  text="$(tr -d ' \t\r\n' < "$1")" || return 1
  [[ $text =~ ^\[([0-9]+(,[0-9]+)*)?\]$ ]] || return 1
  text="${text#[}"; printf '%s\n' "${text%]}" | tr ',' ' '
}
# Two free loopback ports for this Hub's bridge and agent endpoint: keep this
# installation's previous pair when still free, never take another Hub's.
# Prints "<bridge> <endpoint>" and records them in $2/ports.json.
allocate_ports() {
  local root="$1" own="$2" file nums reserved=' ' preferred='49323 49324' result=' ' start port
  for file in "$root"/*/ports.json; do
    [ -f "$file" ] || continue
    nums="$(json_int_list "$file")" || continue
    if [ "${file%/ports.json}" = "$own" ]; then
      set -- $nums; [ "$#" -ne 2 ] || preferred="$nums"
    else reserved="$reserved$nums "; fi
  done
  for start in $preferred; do
    port=$((10#$start < 1024 ? 1024 : 10#$start))
    while [ "$port" -le 65535 ]; do
      case "$reserved$result" in *" $port "*) ;; *) port_busy "$port" || break ;; esac
      port=$((port+1))
    done
    [ "$port" -le 65535 ] || fail 'No free bridge ports available.'
    result="$result$port "
  done
  set -- $result
  printf '[%s, %s]\n' "$1" "$2" > "$own/ports.json"
  printf '%s %s\n' "$1" "$2"
}
# Write config.toml (when missing), the per-Hub ham-ctl wrapper and the
# service definition: systemd unit, launchd plist or runit run file.
render_service() {
  local svc="$1" file="$2" name="$3" hub="$4" bin="$5" state="$6" data="$7" port="$8" endpoint="$9"
  local path="${10}" prefix="${11}" termux_version="${12}" profile="${13:-}"
  local -a args=("$bin/ham-bridge" --hub "$hub" --config "$state/config.toml" --bridge-token-file "$state/bridge-token"
    --data-dir "$data" --bind-host 127.0.0.1 --port "$port" --local-endpoint-port "$endpoint" --local-run-dir "$data/run")
  local config="$state/config.toml" wrapper="$bin/ham-ctl-$name" service_env a k
  if [ ! -e "$config" ]; then
    printf '[daemon]\ndaemon_url = "%s"\ndata_dir = "%s"\n\n[wrapper]\ndaemon_url = "%s"\n' \
      "$(dq_escape "$hub")" "$(dq_escape "$data")" "$(dq_escape "$hub")" > "$config"
  fi
  chmod 600 "$config"
  case "$svc" in runit) service_env=ham-bridge ;; launchd) service_env="$name" ;; *) service_env="$name.service" ;; esac
  # Do not override the endpoint injected into agent run directories.
  printf '#!/bin/sh\n: "${HEIMDALL_BRIDGE_ENDPOINT:=tcp:127.0.0.1:%s}"\nexport HEIMDALL_BRIDGE_ENDPOINT\nexec %s --config %s "$@"\n' \
    "$endpoint" "$(sh_quote "$bin/ham-ctl")" "$(sh_quote "$config")" > "$wrapper"
  chmod 755 "$wrapper"
  # The service environment, in this order (keys sorted for the plist).
  local -a env=("PATH=$bin:$path" "HEIMDALL_HAM_PTY_HOST_BIN=$bin/ham-pty-host" HEIMDALL_BRIDGE_PTY_HOST=true
    "HEIMDALL_HAM_CTL_BIN=$wrapper" "HEIMDALL_BRIDGE_ENDPOINT=tcp:127.0.0.1:$endpoint" "HEIMDALL_BRIDGE_SERVICE_NAME=$service_env")
  case "$svc" in
    runit)
      # termux-services run file: exec the bridge under runsv with the same
      # environment the systemd unit would carry; stderr joins stdout for svlogd.
      # runsvdir usually inherits the login shell's TERMUX_VERSION/PREFIX, but the
      # bridge selects its Android keystore backend and the update script its runit
      # path from exactly those two, so export them explicitly: an environment
      # without them would silently pick the Linux keyring (seccomp-killed) path.
      {
        printf '#!%s/bin/sh\nexec 2>&1\n' "$prefix"
        printf 'export PREFIX=%s\n' "$(sh_quote "$prefix")"
        printf 'export TERMUX_VERSION=%s\n' "$(sh_quote "${termux_version:-installed}")"
        # Services started by runsvdir may lack the login shell's TMPDIR; without it
        # the bridge and PTY host fall back to /tmp, which Android does not have.
        printf 'export TMPDIR=%s\n' "$(sh_quote "$prefix/tmp")"
        for a in "${env[@]}"; do printf 'export %s=%s\n' "${a%%=*}" "$(sh_quote "${a#*=}")"; done
        printf 'exec'
        for a in "${args[@]}"; do printf ' %s' "$(sh_quote "$a")"; done
        printf '\n'
      } > "$file"
      chmod 755 "$file" ;;
    launchd)
      {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        printf '<plist version="1.0">\n<dict>\n\t<key>AbandonProcessGroup</key>\n\t<true/>\n\t<key>EnvironmentVariables</key>\n\t<dict>\n'
        for a in "${env[@]}"; do printf '%s\n' "$a"; done | LC_ALL=C sort -t = -k 1,1 | while IFS= read -r a; do
          printf '\t\t<key>%s</key>\n\t\t<string>%s</string>\n' "${a%%=*}" "$(xml_escape "${a#*=}")"
        done
        printf '\t</dict>\n\t<key>KeepAlive</key>\n\t<dict>\n\t\t<key>SuccessfulExit</key>\n\t\t<false/>\n\t</dict>\n'
        printf '\t<key>Label</key>\n\t<string>%s</string>\n\t<key>ProgramArguments</key>\n\t<array>\n' "$(xml_escape "$name")"
        for a in "${args[@]}"; do printf '\t\t<string>%s</string>\n' "$(xml_escape "$a")"; done
        printf '\t</array>\n\t<key>RunAtLoad</key>\n\t<true/>\n'
        printf '\t<key>StandardErrorPath</key>\n\t<string>%s</string>\n' "$(xml_escape "$data/logs/bridge.err.log")"
        printf '\t<key>StandardOutPath</key>\n\t<string>%s</string>\n' "$(xml_escape "$data/logs/bridge.out.log")"
        printf '\t<key>ThrottleInterval</key>\n\t<integer>5</integer>\n</dict>\n</plist>\n'
      } > "$file" ;;
    *)
      local supervisor="$data/updates/apply-bridge-update.sh" bash_path
      {
        printf '[Unit]\nDescription=Heimdall Bridge %s%s\nAfter=network-online.target\n\n[Service]\nType=simple\nExecStart=' \
          "$hub" "${profile:+ (profile $profile)}"
        k=''
        for a in "${args[@]}"; do printf '%s%s' "$k" "$(systemd_exec_quote "$a")"; k=' '; done
        printf '\n'
        for a in "${env[@]}"; do printf 'Environment=%s\n' "$(systemd_quote "$a")"; done
        if [ -f "$supervisor" ]; then
          bash_path="$(find_in_path bash "$path")" || fail 'bash was not found while rendering the systemd unit'
          printf 'ExecStopPost='
          k=''
          for a in "$bash_path" "$supervisor" --data-dir "$data" --stop-pty-hosts-only; do
            printf '%s%s' "$k" "$(systemd_exec_quote "$a")"; k=' '
          done
          printf '\n'
        fi
        printf 'Restart=on-failure\nRestartSec=5\nKillMode=process\n\n[Install]\nWantedBy=default.target\n'
      } > "$file" ;;
  esac
}
# Released ham-bridge binaries restart the legacy service after enrollment.
# Scope a compatibility shim to this enrollment invocation; never affect the host PATH.
# `ham-bridge enroll` refuses while a bridge runs on the same config, so a running
# service is stopped first (also when enroll.sh is run later, after the installer
# left it started). The shim's restart/kickstart brings it back afterwards.
# Extra arguments (--new-bridge) are passed to `ham-bridge enroll`. The config is
# kept as it is: its daemon_id is what ham-bridge offers the approver for reuse.
enroll() {
  local compat="$state_dir/enroll-tools" tool real
  mkdir -p "$compat"
  for tool in systemctl launchctl; do
    real="$(command -v "$tool" || true)"
    [ -n "$real" ] || continue
    write_enroll_shim "$compat/$tool" "$real" "$service_name" "$uid"
  done
  # A credential from before owner headers makes `ham-bridge enroll` refuse
  # ("no owner record"). Re-enrolling replaces it anyway; keep a backup.
  local f stamp
  if [ -s "$token_file" ] && ! head -n 1 "$token_file" | grep -q '^heimdall-bridge-credential/v1 '; then
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    for f in "$token_file" "$token_file.refresh"; do
      [ ! -e "$f" ] || mv "$f" "$f.pre-reenroll-$stamp"
    done
    log INFO "Moved legacy credential aside: $token_file.pre-reenroll-$stamp"
  fi
  if command -v systemctl >/dev/null && systemctl --user is-active --quiet "$service_name" 2>/dev/null; then
    systemctl --user stop "$service_name"
  elif command -v launchctl >/dev/null && launchctl print "gui/$uid/$service_name" >/dev/null 2>&1; then
    launchctl bootout "gui/$uid/$service_name"
  fi
  local status=0
  # Same tool paths the service's unit/run file exports, so the enrolling
  # process can start the PTY host and ham-ctl too (it was "ham-pty-host Not_Exist").
  PATH="$compat:$bin_dir:$PATH" HEIMDALL_HAM_PTY_HOST_BIN="$bin_dir/ham-pty-host" HEIMDALL_BRIDGE_PTY_HOST=true \
    HEIMDALL_HAM_CTL_BIN="$bin_dir/ham-ctl" "$bin_dir/ham-bridge" enroll --hub "$hub_url" \
    --bridge-token-file "$token_file" --config "$state_dir/config.toml" \
    --data-dir "$data_dir" --port "$bridge_port" --local-endpoint-port "$endpoint_port" \
    --local-run-dir "$run_dir" "$@" || status=$?
  rm -rf "$compat"
  if [ "$status" -eq 3 ] && [ -s "$token_file" ]; then
    # ham-bridge exit 3: enrolled and persisted, only its own service restart
    # failed. The registration/readiness steps below start and verify the service.
    log WARN 'Enrollment succeeded; the bridge could not restart its service itself. Continuing with service start and readiness checks.'
  else
    [ "$status" -eq 0 ] || fail "Enrollment failed (status $status). The service is installed but not running. Re-run the installer with --re-enroll, or enroll later with $state_dir/enroll.sh and then start the service (runit: sv-enable ham-bridge; systemd: systemctl --user restart $service_name)."
  fi
  [ -s "$token_file" ] || fail 'Enrollment did not write a credential.'
  chmod 600 "$token_file"
}
remove_service() {
  local file="$1" name="$2"
  [ -e "$file" ] || return 0
  spin_start "Stopping $name"
  case "$svc" in
    systemd)
      # Require a reachable user manager before replacing a running installation.
      systemctl --user stop "$name"
      systemctl --user disable "$name"
      rm "$file" ;;
    launchd)
      # An unloaded plist needs no bootout. A loaded service must stop successfully.
      if launchctl print "gui/$uid/$name" >/dev/null 2>&1; then
        launchctl bootout "gui/$uid/$name"
      fi
      rm "$file" ;;
    runit)
      # $file is <service dir>/run. Stop under runsv when it is supervised, then
      # remove the whole service directory; runsvdir drops the service itself.
      sv down "${file%/run}" >/dev/null 2>&1 || true
      rm -rf "${file%/run}" ;;
  esac
  spin_stop OK "Removed service $name"
}
main() {
  set -euo pipefail
  local hub_url='' version='' dry_run=false uninstall=false noninteractive=false enrollment=ask answer='' new_bridge=false
  local local_bundle='' local_checksums=''
  local profile="${HEIMDALL_BRIDGE_NAME:-}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --hub|--hub-url|--version|--name|--bundle|--checksum-file)
        [ "$#" -ge 2 ] && [ -n "$2" ] || fail "$1 requires a value"
        case "$1" in
          --version) version="$2" ;;
          --name) profile="$2" ;;
          --bundle) local_bundle="$2" ;;
          --checksum-file) local_checksums="$2" ;;
          *) hub_url="$2" ;;
        esac
        shift 2 ;;
      --dry-run) dry_run=true; shift ;;
      --uninstall) uninstall=true; shift ;;
      --non-interactive) noninteractive=true; shift ;;
      --re-enroll) enrollment=yes; shift ;;
      --new-bridge) enrollment=yes; new_bridge=true; shift ;;
      --keep-enrollment) enrollment=no; shift ;;
      --force|--force-service|-f) shift ;; # Clean replacement is now the default.
      --help|-h) usage; return ;;
      *) fail "Unknown argument: $1 (see --help)" ;;
    esac
  done
  [ "${HEIMDALL_NON_INTERACTIVE:-0}" != 1 ] || noninteractive=true
  [ "${DEBIAN_FRONTEND:-}" != noninteractive ] || noninteractive=true
  if [ -n "$local_bundle" ] || [ -n "$local_checksums" ]; then
    [ -n "$local_bundle" ] && [ -n "$local_checksums" ] ||
      fail '--bundle and --checksum-file must be provided together.'
    [ -f "$local_bundle" ] && [ ! -L "$local_bundle" ] || fail "Bundle is not a regular file: $local_bundle"
    [ -f "$local_checksums" ] && [ ! -L "$local_checksums" ] || fail "Checksum file is not a regular file: $local_checksums"
    [ -n "$version" ] || fail '--version is required with --bundle.'
    case "$local_bundle" in /*) ;; *) local_bundle="$(cd "$(dirname "$local_bundle")" && pwd -P)/$(basename "$local_bundle")" ;; esac
    case "$local_checksums" in /*) ;; *) local_checksums="$(cd "$(dirname "$local_checksums")" && pwd -P)/$(basename "$local_checksums")" ;; esac
  fi
  [ -z "$profile" ] || valid_profile "$profile" ||
    fail "Invalid profile name '$profile' (--name/HEIMDALL_BRIDGE_NAME): use 1-31 lower-case letters, digits or '-', starting with a letter or digit."
  banner "$version" "$hub_url" "$profile"
  step 1 'Hub & platform'
  if [ -z "$hub_url" ]; then
    "$noninteractive" && fail '--hub is required in non-interactive mode.'
    prompt 'Hub URL: ' || fail 'No terminal available. Pass --hub URL.'
    hub_url="$answer"
  fi
  local identity
  identity="$(canonical_hub "$hub_url")" || fail 'Unable to validate Hub URL.'
  hub_url="${identity%%$'\n'*}"; local service_name="${identity#*$'\n'}${profile:+_$profile}"
  local os arch uid
  case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) fail 'Supported platforms: Linux and macOS.' ;; esac
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) fail 'Supported architectures: amd64 and arm64.' ;; esac
  # On Android the vault key is sealed with the Android Keystore; there is no
  # plaintext fallback, so refuse before installing anything (SELF_HOSTING.md, Termux).
  # svc is the supervisor: systemd (Linux), launchd (macOS) or runit (Termux).
  local svc=systemd
  if is_termux; then
    # The released ham-bridge restarts exactly the runit service ham-bridge, so
    # one Termux install can only ever run one bridge.
    [ -z "$profile" ] || fail "Bridge profiles (--name/HEIMDALL_BRIDGE_NAME) are not supported on Termux: one Termux install runs one bridge (the runit service ham-bridge). Re-run without --name."
    command -v termux-keystore >/dev/null || fail 'Termux detected but termux-keystore is missing. Install the Termux:API app, then run: pkg install termux-api'
    svc=runit
  elif [ "$os" = darwin ]; then svc=launchd; fi
  # Release bundle target. Android's app seccomp SIGSYS-kills the glibc-static
  # linux-* binaries at start-up (set_robust_list), so Termux takes the
  # musl-static termux-* bundle, falling back to linux-* only for releases that
  # predate it (v0.3.29); see SELF_HOSTING.md, Termux.
  local target="$os-$arch" fallback_target=''
  if [ "$svc" = runit ]; then target="termux-$arch"; fallback_target="$os-$arch"; fi
  uid="$(id -u)"
  [ "$uid" != 0 ] || fail 'Run as your login user without sudo; this installs a user service.'
  local state_root="$HOME/.config/heimdall/bridges" state_dir="$HOME/.config/heimdall/bridges/$service_name"
  local data_dir="$HOME/.local/share/heimdall/bridges/$service_name"
  local bin_dir="$data_dir/bin" token_file="$state_dir/bridge-token" run_dir="$data_dir/run" log_dir="$data_dir/logs"
  local service_file legacy_file='' legacy_name='' runit_dir=''
  case "$svc" in
    systemd)
      command -v systemctl >/dev/null || fail 'systemctl is required.'
      service_file="$HOME/.config/systemd/user/$service_name.service"
      legacy_file="$HOME/.config/systemd/user/heimdall-bridge.service"; legacy_name=heimdall-bridge ;;
    launchd)
      command -v launchctl >/dev/null || fail 'launchctl is required.'
      service_file="$HOME/Library/LaunchAgents/$service_name.plist"
      legacy_file="$HOME/Library/LaunchAgents/works.earendil.heimdall-bridge.plist"; legacy_name=works.earendil.heimdall-bridge ;;
    runit)
      # termux-services supervises $PREFIX/var/service/<name>. The released
      # ham-bridge restarts exactly $PREFIX/var/service/ham-bridge after
      # enrollment, so one Termux install serves one Hub under that fixed name;
      # per-Hub state and data directories are kept as on other platforms.
      command -v sv >/dev/null || fail 'termux-services is required: pkg install termux-services, then restart Termux.'
      [ -n "${PREFIX:-}" ] && [ -d "$PREFIX/var/service" ] || fail 'termux-services service directory not found ($PREFIX/var/service). Install termux-services and restart Termux.'
      runit_dir="$PREFIX/var/service/ham-bridge"; service_file="$runit_dir/run" ;;
  esac
  log INFO "Hub: $hub_url"; log INFO "Service: $service_name ($os/$arch, $svc)"
  [ -z "$profile" ] || log INFO "Profile: $profile"
  [ "$svc" != runit ] || log INFO "runit service: $runit_dir"
  log INFO "Config/token: $state_dir"; log INFO "Data/binaries: $data_dir"
  if [ -f "$state_dir/hub-url" ] && [ "$(cat "$state_dir/hub-url")" != "$hub_url" ]; then
    fail "Name collision with $(cat "$state_dir/hub-url"). Use a distinct hostname/port."
  fi
  if [ "$svc" = runit ] && [ -f "$runit_dir/hub-url" ] && [ "$(cat "$runit_dir/hub-url")" != "$hub_url" ]; then
    fail "Termux runs one bridge service (ham-bridge), already installed for $(cat "$runit_dir/hub-url"). Uninstall it first: install.sh --hub $(cat "$runit_dir/hub-url") --uninstall"
  fi
  if "$uninstall"; then
    if "$dry_run"; then log PLAN "Remove $service_file and $bin_dir; preserve $state_dir and $data_dir"; return; fi
    remove_service "$service_file" "$service_name"
    rm -rf "$bin_dir"
    [ "$svc" != systemd ] || systemctl --user daemon-reload
    log OK 'Uninstalled. Enrollment and agent data preserved.'; return
  fi
  local migrate=false existing=false
  # Only retire a legacy service whose explicit Hub matches this installation,
  # and only for the default (unnamed) bridge: the legacy service is that one.
  if [ -z "$profile" ] && [ -n "$legacy_file" ] && [ -f "$legacy_file" ] && legacy_service_matches "$legacy_file" "$hub_url"; then migrate=true; fi
  [ ! -s "$token_file" ] || existing=true
  if "$migrate" && [ -s "$HOME/.config/heimdall/bridge-token" ]; then existing=true; fi
  if "$existing" && [ -s "$token_file" ] && identity_missing "$state_dir/config.toml"; then
    if [ "$enrollment" = no ]; then
      log WARN 'Existing credential has no identity record on this machine; the bridge will refuse to start until it is re-enrolled.'
    else
      log WARN 'Existing credential has no identity record on this machine (enrolled by an older release?); re-enrolling.'
      existing=false
    fi
  fi
  if "$existing" && [ "$enrollment" = ask ]; then
    if "$noninteractive" || "$dry_run"; then enrollment=no
    elif prompt 'Existing enrollment found. Re-enroll this bridge? [y/N]: '; then
      case "$answer" in y|Y|yes|YES) enrollment=yes ;; *) enrollment=no ;; esac
    else enrollment=no
    fi
  elif ! "$existing"; then enrollment=yes
  fi
  if "$dry_run"; then
    step '' 'Dry-run plan'
    log PLAN "Replace $service_file ($svc); enrollment=$enrollment$("$new_bridge" && printf ' (new bridge)'); matching legacy migration=$migrate"
    [ "$svc" != runit ] || log PLAN "Create runit service $runit_dir (run, log/run) and sv-enable ham-bridge."
    log PLAN 'Choose two free loopback ports; create a per-Hub ham-ctl wrapper and service.'
    if [ -n "$local_bundle" ]; then
      log PLAN "Verify and install packaged bundle $local_bundle using $local_checksums."
    else
      log PLAN "Download heimdall-local-$target-${version:-LATEST}.tar.gz${fallback_target:+ (or heimdall-local-$fallback_target if the release has none)} and verify SHA256SUMS."
    fi
    return
  fi
  step 2 'Hub check'
  command -v curl >/dev/null || fail 'curl is required.'
  command -v tar >/dev/null || fail 'tar is required.'
  command -v sha256sum >/dev/null || command -v shasum >/dev/null || fail 'sha256sum (coreutils) or shasum is required.'
  case "$svc" in
    systemd) systemctl --user show-environment >/dev/null || fail 'No systemd user session. Run in your login session.' ;;
    launchd) launchctl print "gui/$uid" >/dev/null || fail 'No launchd GUI session. Run as the logged-in macOS user.' ;;
    runit) runsvdir_running || fail 'termux-services does not appear to be running (no supervised service and no runsvdir process). Run: . $PREFIX/etc/profile.d/start-services.sh — or restart Termux — then re-run. If `sv status` works for another service, re-run with HEIMDALL_ASSUME_RUNSVDIR=1.' ;;
  esac
  local work_dir lock_dir="$state_root/.install-lock"
  mkdir -p "$state_root"
  mkdir "$lock_dir" 2>/dev/null || fail "Another installer is running (lock: $lock_dir)."
  trap "$(printf 'rmdir %q' "$lock_dir")" EXIT
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/heimdall-install.XXXXXX")"
  trap "$(printf 'rm -rf %q; rmdir %q' "$work_dir" "$lock_dir")" EXIT
  wait_for_hub
  step 3 'Resolve release'
  if [ -z "$local_bundle" ] && [ -z "$version" ]; then
    # Releases start as prereleases (candidates on the canary hub) and are promoted
    # later; without --version, resolve only promoted releases. A hub's own
    # /public/install.sh passes --version, so its bridges get the hub's release.
    download 'https://api.github.com/repos/tanmayv/heimdall-agent-manager/releases?per_page=30' "$work_dir/releases.json"
    # Newest release carrying the preferred target's bundle; only when no
    # listed release has one, the newest carrying the fallback target's.
    local picked=0
    version="$(select_release "$work_dir/releases.json" "$target" "$fallback_target")" || picked=$?
    [ "$picked" != 2 ] || fail 'GitHub did not return a release list; pass --version TAG.'
    [ "$picked" = 0 ] || fail 'No promoted release bundle for this platform. Pass --version TAG.'
  fi
  [[ "$version" =~ ^[a-zA-Z0-9._-]+$ ]] || fail 'Invalid release tag.'
  local archive="heimdall-local-$target-$version.tar.gz" base="https://github.com/tanmayv/heimdall-agent-manager/releases/download/$version"
  log INFO "Release: $version"
  step 4 'Download & verify'
  # Reuse a previously verified tarball of this exact release when its SHA-256
  # still matches the release's SHA256SUMS; otherwise download (with a progress
  # bar on a terminal). The cache only ever holds GitHub-release bundles.
  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/heimdall/releases" cached=false
  if [ -n "$local_bundle" ]; then
    archive="$(basename "$local_bundle")"
    case "$archive" in
      heimdall-local-$target*.tar.gz) ;;
      *) fail "Packaged bundle $archive does not match this machine's target $target." ;;
    esac
    cp "$local_checksums" "$work_dir/SHA256SUMS"
    cp "$local_bundle" "$work_dir/$archive"
    sha256_matches "$work_dir/SHA256SUMS" "$work_dir/$archive" "$archive" ||
      fail 'Packaged bundle SHA-256 verification failed; nothing installed.'
    log OK "Using packaged $archive (SHA-256 verified; no download)"
  else
    # SHA256SUMS first: it lists every bundle of the release, so it also tells
    # whether this release ships the preferred (Termux) bundle at all.
    download "$base/SHA256SUMS" "$work_dir/SHA256SUMS"
    if [ -n "$fallback_target" ] && ! awk -v n="$archive" '{ sub(/^\*/, "", $2) } $2 == n { found = 1 } END { exit !found }' "$work_dir/SHA256SUMS"; then
      log WARN "Release $version has no $target bundle; installing heimdall-local-$fallback_target instead. Its glibc binaries are killed by Android's seccomp at start-up (set_robust_list); Termux bundles ship from v0.3.29 -- re-run without --version or pass a newer one."
      archive="heimdall-local-$fallback_target-$version.tar.gz"
    fi
    mkdir -p "$cache_dir"; chmod 700 "$cache_dir"
    if [ -f "$cache_dir/$archive" ]; then
      spin_start "Checking cached $archive"
      if sha256_matches "$work_dir/SHA256SUMS" "$cache_dir/$archive" "$archive"; then
        cp "$cache_dir/$archive" "$work_dir/$archive"
        cached=true
        spin_stop OK "Using cached $archive (SHA-256 matches release $version; no download)"
      else
        spin_stop INFO "Cached $archive does not match release $version; downloading it again"
      fi
    fi
    if ! "$cached"; then
      log INFO "Downloading $archive"
      download_progress "$base/$archive" "$work_dir/$archive"
    fi
  fi
  extract_bundle "$work_dir" "$archive"
  step 5 'Bridge preflight'
  # Preflight through the BRIDGE's own HTTPS client (its static libcurl),
  # before any service is replaced: the curl CLI reaching the Hub says nothing
  # about whether this binary can.
  chmod 700 "$work_dir/ham-bridge"
  # --probe-hub exists from 0.3.36; an older bridge ignores unknown flags and
  # would start as a daemon in the foreground, so gate on the binary's version.
  local bridge_version version_out probe_out
  spin_start "Checking the downloaded ham-bridge against $hub_url"
  if ! version_out="$("$work_dir/ham-bridge" --version 2>&1)"; then
    fail "The downloaded ham-bridge does not start on this machine: ${version_out:-no output}. Check that the release target ($target) matches this machine. Nothing was replaced."
  fi
  # Take the "ham-bridge <version> ..." line, not line 1: stderr is merged above
  # (for the failure message), and an older dynamically linked release could
  # print a loader warning first.
  bridge_version="$(printf '%s\n' "$version_out" | awk '$1 == "ham-bridge" {print $2; exit}')"
  if [ -n "$bridge_version" ] && [ "$(printf '%s\n0.3.36\n' "$bridge_version" | sort -V | head -n1)" = "0.3.36" ]; then
    # Captured: stdout would break the spinner line. On failure it goes to
    # stderr, which fail shows under the error.
    if ! probe_out="$("$work_dir/ham-bridge" --probe-hub "$hub_url" 2>&1)"; then
      printf '%s\n' "$probe_out" >&2
      fail "The downloaded ham-bridge cannot reach $hub_url through its own HTTPS client (its static libcurl; the probe output names the TLS library and CA bundle it used) although the curl CLI could. Check TLS trust (HAM_TLS_CA_FILE / SSL_CERT_FILE) and the probe output above. Nothing was replaced."
    fi
    spin_stop OK "ham-bridge $bridge_version reaches the Hub through its own HTTPS client"
    [ -z "$probe_out" ] || printf '%s\n' "$probe_out" | sed 's/^/  /'
  else
    spin_stop INFO "Bridge ${bridge_version:-unknown} predates --probe-hub (0.3.36); transport preflight skipped."
  fi
  # Keep downloaded releases for next time. The signed app owns its embedded
  # copy, so a packaged bundle is not duplicated into the user's cache.
  if [ -z "$local_bundle" ]; then
    spin_start "Caching $archive"
    cp "$work_dir/$archive" "$cache_dir/$archive.tmp" && mv -f "$cache_dir/$archive.tmp" "$cache_dir/$archive"
    local old cache_prefix="${archive%-"$version".tar.gz}"
    for old in "$cache_dir/$cache_prefix"-*.tar.gz; do
      [ "$old" = "$cache_dir/$archive" ] || rm -f "$old"
    done
    spin_stop
  fi
  # Validate and copy the full new generation before stopping a service.
  local extension_transaction=""
  if [ -d "$work_dir/share/heimdall/extensions" ]; then
    source "$work_dir/refresh-provider-extensions.sh"
    mkdir -p "$data_dir"
    extension_transaction="$(mktemp -d "$data_dir/.extensions-install.XXXXXX")"
    # Set before spin_start, which chains whatever EXIT trap is current.
    trap "$(printf 'cleanup_provider_extension_transaction %q %q; rm -rf %q; rmdir %q' "$extension_transaction" "$data_dir/extensions" "$work_dir" "$lock_dir")" EXIT
    spin_start 'Preparing provider extensions'
    prepare_provider_extensions "$work_dir/share/heimdall/extensions" "$data_dir/extensions" "$extension_transaction/new"
    spin_stop
  fi
  step 6 'Replace service'
  remove_service "$service_file" "$service_name"
  if "$migrate"; then remove_service "$legacy_file" "$legacy_name"; fi
  mkdir -p "$state_dir" "$bin_dir" "$run_dir" "$log_dir" "$(dirname "$service_file")"
  chmod 700 "$state_dir" "$data_dir" "$run_dir" "$log_dir"
  # runsvdir picks a new directory up within seconds; keep it down until it is complete.
  [ "$svc" != runit ] || : > "$runit_dir/down"
  if "$migrate" && [ ! -s "$token_file" ]; then
    for file in bridge-token bridge-token.refresh config.toml; do
      [ ! -f "$HOME/.config/heimdall/$file" ] || cp -p "$HOME/.config/heimdall/$file" "$state_dir/$file"
    done
    log OK 'Copied matching legacy enrollment; original state preserved'
  fi
  for file in heimdall ham-bridge ham-pty-host ham-ctl; do
    install -m 0755 "$work_dir/$file" "$bin_dir/$file"
  done
  if [ -f "$work_dir/apply-bridge-update.sh" ]; then
    mkdir -p "$data_dir/updates"
    install -m 0755 "$work_dir/apply-bridge-update.sh" "$data_dir/updates/apply-bridge-update.sh"
  fi
  if [ -n "$extension_transaction" ]; then
    swap_provider_extensions "$extension_transaction/new" "$data_dir/extensions" "$extension_transaction/old"
    install -m 0755 "$work_dir/refresh-provider-extensions.sh" "$data_dir/updates/refresh-provider-extensions.sh"
  fi
  printf '%s\n' "$hub_url" > "$state_dir/hub-url"
  [ -z "$profile" ] || printf '%s\n' "$profile" > "$state_dir/profile"
  [ ! -d "$bin_dir" ] || chmod 700 "$bin_dir"
  step 7 'Ports & routing'
  local ports bridge_port endpoint_port
  ports="$(allocate_ports "$state_root" "$state_dir")"
  bridge_port="${ports% *}"; endpoint_port="${ports#* }"
  log OK "Bridge: 127.0.0.1:$bridge_port · Agent endpoint: 127.0.0.1:$endpoint_port"
  # Render with proper escaping for spaces, XML, shell, and systemd specifiers.
  render_service "$svc" "$service_file" "$service_name" "$hub_url" "$bin_dir" "$state_dir" "$data_dir" "$bridge_port" "$endpoint_port" "$PATH" "${PREFIX:-}" "${TERMUX_VERSION:-}" "$profile"
  if [ "$svc" = runit ]; then
    mkdir -p "$runit_dir/log"
    if [ -x "$PREFIX/share/termux-services/svlogger" ]; then
      ln -sf "$PREFIX/share/termux-services/svlogger" "$runit_dir/log/run"
    else
      printf '#!%s/bin/sh\nexec svlogd -tt %q\n' "$PREFIX" "$log_dir" > "$runit_dir/log/run"
      chmod 755 "$runit_dir/log/run"
    fi
    printf '%s\n' "$hub_url" > "$runit_dir/hub-url"
  fi
  # Persist a usable enrollment command even when the installer came from stdin.
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    declare -f ui_init ui_colour ui_clear_line log spin_stop fail sh_quote write_enroll_shim enroll
    for file in state_dir bin_dir service_name uid token_file hub_url data_dir bridge_port endpoint_port run_dir; do
      printf '%s=%q\n' "$file" "${!file}"
    done
    printf 'enroll "$@"\n'
  } > "$state_dir/enroll.sh"
  chmod 700 "$state_dir/enroll.sh"
  step 8 'Register & enroll'
  # Start the service now only when no enrollment runs in this invocation: a
  # running bridge holds the config and `ham-bridge enroll` refuses to proceed.
  # Enrollment restarts the service itself; the block after it covers exit 3.
  local enroll_now=false
  [ "$enrollment" != yes ] || "$noninteractive" || enroll_now=true
  case "$svc" in
    systemd)
      spin_start "Registering $service_name with systemd"
      systemctl --user daemon-reload
      if "$enroll_now"; then systemctl --user enable "$service_name"
      else systemctl --user enable --now "$service_name"; fi
      spin_stop ;;
    launchd)
      spin_start "Registering LaunchAgent $service_name"
      plutil -lint "$service_file" >/dev/null
      "$enroll_now" || launchctl bootstrap "gui/$uid" "$service_file"
      spin_stop ;;
    runit)
      # Give runsvdir (5 s scan) time to attach a runsv before anything uses
      # `sv` on this directory. The service itself stays DOWN until enrollment
      # has finished: runit restarts a token-less bridge every second, so an
      # enabled service would connect the moment the token file appears and the
      # Hub would drop the enrolling process mid vault delivery.
      local waited=0
      spin_start "Waiting for runsvdir to supervise ham-bridge (up to ${HEIMDALL_RUNSV_WAIT:-10}s)"
      until [ -d "$runit_dir/supervise" ] || [ "$waited" -ge "${HEIMDALL_RUNSV_WAIT:-10}" ]; do waited=$((waited+1)); sleep 1; done
      spin_stop ;;
  esac
  # Enrollment is interactive (browser approval), so it never runs under a spinner.
  if [ "$enrollment" = yes ]; then
    if "$noninteractive"; then
      log INFO 'Service installed; browser-approved enrollment is pending.'
      if "$new_bridge"; then printf 'Run: %q --new-bridge\n' "$state_dir/enroll.sh"
      else printf 'Run: %q\n' "$state_dir/enroll.sh"; fi
    elif "$new_bridge"; then enroll --new-bridge; log OK 'Browser-approved enrollment complete'
    else enroll; log OK 'Browser-approved enrollment complete'; fi
  else log OK 'Existing enrollment preserved'; fi
  if "$enroll_now"; then
    spin_start "Starting $service_name"
    case "$svc" in
      systemd) systemctl --user start "$service_name" ;;
      launchd) launchctl print "gui/$uid/$service_name" >/dev/null 2>&1 || launchctl bootstrap "gui/$uid" "$service_file" ;;
    esac
    spin_stop
  fi
  if [ "$svc" = runit ]; then
    # Enable only now (after enrollment, or at once when none runs): removes the
    # down file for future boots and starts the service if enrollment did not.
    spin_start 'Starting runit service ham-bridge (up to 15s)'
    if command -v sv-enable >/dev/null; then sv-enable ham-bridge
    else rm -f "$runit_dir/down"; sv up "$runit_dir"; fi
    local tries=0
    until sv status "$runit_dir" 2>/dev/null | grep -q '^run:'; do
      tries=$((tries+1)); [ "$tries" -lt 15 ] || break; sleep 1
    done
    spin_stop
  fi
  step 9 'Ready'
  case "$svc" in
    systemd)
      # is-active also holds between Restart= attempts; watch for a crash loop.
      local restarts tries=0
      spin_start "Checking that $service_name stays up (${HEIMDALL_READY_WAIT:-8}s)"
      restarts="$(systemctl --user show -p NRestarts --value "$service_name" 2>/dev/null || echo 0)"
      until [ "$tries" -ge "${HEIMDALL_READY_WAIT:-8}" ]; do
        sleep 1; tries=$((tries+1))
        systemctl --user is-active --quiet "$service_name" || break
        [ "$(systemctl --user show -p NRestarts --value "$service_name" 2>/dev/null || echo 0)" = "$restarts" ] || break
      done
      if [ "$tries" -lt "${HEIMDALL_READY_WAIT:-8}" ]; then
        # On a terminal this lands in the step's held stderr, which fail shows.
        journalctl --user -u "$service_name" -n 6 --no-pager -o cat >&2 2>/dev/null || true
        fail "Service is not staying up. Inspect: journalctl --user -u $service_name (re-enroll: re-run with --re-enroll)"
      fi
      spin_stop OK "Service active: $service_name"
      log INFO "Logs: journalctl --user -u $service_name -f" ;;
    launchd)
      launchctl print "gui/$uid/$service_name" >/dev/null || fail 'LaunchAgent registration failed.'
      log OK "LaunchAgent registered: $service_name"
      log INFO "Logs: $log_dir" ;;
    runit)
      sv status "$runit_dir" 2>/dev/null | grep -q '^run:' || fail "Service did not start under termux-services. Is runsvdir running (restart Termux)? Inspect: sv status ham-bridge; $PREFIX/var/log/sv/ham-bridge/current"
      log OK 'runit service running: ham-bridge'
      log INFO "Logs: $PREFIX/var/log/sv/ham-bridge/current (sv status ham-bridge)" ;;
  esac
  log INFO "Hub-specific CLI: $bin_dir/ham-ctl-$service_name"
  [ -z "$profile" ] || log INFO "Profile: $profile (pass --name $profile to --re-enroll or --uninstall this bridge)"
  log OK "Heimdall Bridge $version is ready for $hub_url${profile:+ (profile $profile)}"
  if [ -n "$extension_transaction" ]; then
    cleanup_provider_extension_transaction "$extension_transaction" "$data_dir/extensions"
  fi
  rm -rf "$work_dir"
  rmdir "$lock_dir"
  trap - EXIT
}
main "$@"
