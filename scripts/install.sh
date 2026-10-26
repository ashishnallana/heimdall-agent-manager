#!/usr/bin/env bash
# Clean, per-Hub user-service installer. Keep execution behind main for curl | bash.
fail() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$1" "$2"; }
step() { printf '\n── %s ──\n' "$*"; }
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
Hub must be an HTTP(S) origin, e.g. https://hub.mundus.in or http://localhost:8080.
Without --hub, asks on the terminal. Existing enrollment prompts before re-enrolling.
Re-enrolling offers the approver this machine's previous bridge id for reuse (same
bridge, same history); --new-bridge registers a new bridge instead (implies --re-enroll).
--non-interactive preserves existing enrollment and prints a command for new enrollment.
--uninstall removes only this Hub's service and binaries; credentials/data are kept.
Requires bash, python3, curl, tar, and libcurl >= 7.84 (the bridge links it; Debian 12+,
Ubuntu 24.04+, macOS 13+); HTTPS bridges also require socat (WebSocket transport).
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
download() {
  curl --fail --location --silent --show-error --connect-timeout 15 \
    --max-time 600 --speed-limit 1024 --speed-time 60 "$1" --output "$2"
}
# Large downloads show curl's progress bar on a terminal; quiet otherwise.
download_progress() {
  local quiet=--silent
  [ -t 2 ] && quiet=--progress-bar
  curl --fail --location $quiet --show-error --connect-timeout 15 \
    --max-time 600 --speed-limit 1024 --speed-time 60 "$1" --output "$2"
}
HUB_CONNECT_TIMEOUT_SECONDS=20
# Explicit Hub reachability check before anything is installed: one fixed
# budget, a visible timer on a terminal, and curl's exact reason on failure
# (DNS, TLS verification, refused, timeout) instead of a silent hang or an
# unexplained half-second failure. Any HTTP answer counts: a Hub behind
# forward-auth redirects unauthenticated requests, which still proves TCP+TLS.
wait_for_hub() {
  local url="$hub_url/api/v1/health" err="$work_dir/hub-check.err" out="$work_dir/hub-check.code" ticks=0 pid
  log INFO "Checking Hub $hub_url (up to ${HUB_CONNECT_TIMEOUT_SECONDS}s)"
  curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --connect-timeout "$HUB_CONNECT_TIMEOUT_SECONDS" --max-time "$HUB_CONNECT_TIMEOUT_SECONDS" \
    "$url" > "$out" 2> "$err" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.5; ticks=$((ticks+1))
    [ ! -t 2 ] || printf '\r  waiting for Hub… %2ds / %ds ' "$((ticks/2))" "$HUB_CONNECT_TIMEOUT_SECONDS" >&2
  done
  [ ! -t 2 ] || printf '\r%40s\r' '' >&2
  if wait "$pid"; then
    log OK "Hub reachable: HTTP $(cat "$out") after $((ticks/2))s"
  else
    fail "Hub $hub_url not reachable (gave up after $((ticks/2))s of ${HUB_CONNECT_TIMEOUT_SECONDS}s): $(tr -d '\n' < "$err")"
  fi
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
    python3 - "$compat/$tool" "$real" "$service_name" "$uid" <<'PY'
import pathlib, shlex, sys
path, real, name, uid = sys.argv[1:]
if pathlib.Path(path).name == 'systemctl':
    body = 'if [ "$*" = "--user restart heimdall-bridge" ]; then\n  set -- --user restart '+shlex.quote(name)+ '\nfi\n'
else:
    # kickstart needs a loaded job; enroll() boots it out, so bootstrap it again first.
    label = shlex.quote('gui/'+uid+'/'+name)
    plist = shlex.quote(str(pathlib.Path.home()/'Library/LaunchAgents'/(name+'.plist')))
    body = ('if [ "$*" = "kickstart -k gui/'+uid+'/works.earendil.heimdall-bridge" ]; then\n'
            '  '+shlex.quote(real)+' print '+label+' >/dev/null 2>&1 || '+shlex.quote(real)+' bootstrap '+shlex.quote('gui/'+uid)+' '+plist+' || exit 1\n'
            '  set -- kickstart -k '+label+'\nfi\n')
pathlib.Path(path).write_text('#!/bin/sh\n'+body+'exec '+shlex.quote(real)+' "$@"\n')
pathlib.Path(path).chmod(0o700)
PY
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
  log OK "Removed service $name"
}
main() {
  set -euo pipefail
  local hub_url='' version='' dry_run=false uninstall=false noninteractive=false enrollment=ask answer='' new_bridge=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --hub|--hub-url|--version)
        [ "$#" -ge 2 ] && [ -n "$2" ] || fail "$1 requires a value"
        case "$1" in --version) version="$2" ;; *) hub_url="$2" ;; esac
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
  printf '\n╭──────────────────────────────────────────╮\n│         HEIMDALL · BRIDGE INSTALLER       │\n│        Your agents, connected locally     │\n╰──────────────────────────────────────────╯\n'
  step '1 / 6 · Hub and platform'
  command -v python3 >/dev/null || fail 'Install python3 first.'
  if [ -z "$hub_url" ]; then
    "$noninteractive" && fail '--hub is required in non-interactive mode.'
    prompt 'Hub URL: ' || fail 'No terminal available. Pass --hub URL.'
    hub_url="$answer"
  fi
  # Canonical origins include explicit non-default ports. IPv4, IPv6, and DNS
  # names all map to safe filenames. Reject rather than collapse ambiguous IDs.
  local identity
  identity="$(python3 - "$hub_url" <<'PY'
import ipaddress, re, sys
from urllib.parse import urlsplit
try:
    u = urlsplit(sys.argv[1].strip())
    assert u.scheme in ('http','https') and u.hostname and not u.username and not u.password
    assert u.path in ('','/') and not u.query and not u.fragment
    host = u.hostname.lower()
    try: host = ipaddress.ip_address(host).compressed
    except ValueError:
        host = host.encode('idna').decode('ascii').rstrip('.')
        assert re.fullmatch(r'[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?', host)
    port = u.port
    assert port is None or 1 <= port <= 65535
    if port == {'http':80,'https':443}[u.scheme]: port = None
    authority = ('['+host+']' if ':' in host else host) + (':'+str(port) if port else '')
    name = re.sub(r'[^a-z0-9-]', '-', host)
    if port: name += '-'+str(port)
    assert len(name) <= 160
    print(u.scheme+'://'+authority)
    print('heimdall-bridge-'+name)
except (AssertionError, ValueError, UnicodeError):
    sys.exit('Invalid Hub URL: use an HTTP(S) origin with no path, credentials, query, or fragment.')
PY
)" || fail 'Unable to validate Hub URL.'
  hub_url="${identity%%$'\n'*}"; local service_name="${identity#*$'\n'}"
  local os arch uid
  case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) fail 'Supported platforms: Linux and macOS.' ;; esac
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) fail 'Supported architectures: amd64 and arm64.' ;; esac
  # On Android the vault key is sealed with the Android Keystore; there is no
  # plaintext fallback, so refuse before installing anything (SELF_HOSTING.md, Termux).
  # svc is the supervisor: systemd (Linux), launchd (macOS) or runit (Termux).
  local svc=systemd
  if is_termux; then
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
  # Only retire a legacy service whose explicit Hub matches this installation.
  if [ -n "$legacy_file" ] && [ -f "$legacy_file" ] && python3 - "$legacy_file" "$hub_url" <<'PY'
import pathlib, re, sys, xml.etree.ElementTree as ET
p, hub = sys.argv[1:]
text = pathlib.Path(p).read_text()
if p.endswith('.plist'):
    try:
        args = [n.text for n in ET.fromstring(text).findall('.//array/string')]
        value = args[args.index('--hub')+1]
    except (ET.ParseError, ValueError, IndexError): sys.exit(1)
else:
    m = re.search(r'--hub\s+["\x27]?([^\s"\x27\\]+)', text)
    value = m.group(1) if m else ''
sys.exit(0 if value.rstrip('/') == hub else 1)
PY
  then migrate=true; fi
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
  step '2 / 6 · Preflight and verified release'
  if "$dry_run"; then
    log PLAN "Replace $service_file ($svc); enrollment=$enrollment$("$new_bridge" && printf ' (new bridge)'); matching legacy migration=$migrate"
    [ "$svc" != runit ] || log PLAN "Create runit service $runit_dir (run, log/run) and sv-enable ham-bridge."
    log PLAN 'Choose two free loopback ports; create a per-Hub ham-ctl wrapper and service.'
    log PLAN "Download heimdall-local-$target-${version:-LATEST}.tar.gz${fallback_target:+ (or heimdall-local-$fallback_target if the release has none)} and verify SHA256SUMS."
    return
  fi
  command -v curl >/dev/null || fail 'curl is required.'
  case "$hub_url" in https:*) command -v socat >/dev/null || fail 'HTTPS transport requires socat (install via your package manager).' ;; esac
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
  if [ -z "$version" ]; then
    # Releases start as prereleases (candidates on the canary hub) and are promoted
    # later; without --version, resolve only promoted releases. A hub's own
    # /public/install.sh passes --version, so its bridges get the hub's release.
    download 'https://api.github.com/repos/tanmayv/heimdall-agent-manager/releases?per_page=30' "$work_dir/releases.json"
    # Newest release carrying the preferred target's bundle; only when no
    # listed release has one, the newest carrying the fallback target's.
    version="$(python3 - "$work_dir/releases.json" "$target" "$fallback_target" <<'PY'
import json, sys
releases = json.load(open(sys.argv[1]))
if not isinstance(releases, list): sys.exit('GitHub did not return a release list; pass --version TAG.')
for target in filter(None, sys.argv[2:]):
    for release in releases:
        tag = release.get('tag_name', '')
        assets = {a.get('name') for a in release.get('assets', [])}
        if not release.get('draft') and not release.get('prerelease') and {'SHA256SUMS', 'heimdall-local-'+target+'-'+tag+'.tar.gz'} <= assets:
            print(tag)
            sys.exit()
sys.exit('No promoted release bundle for this platform. Pass --version TAG.')
PY
)"
  fi
  [[ "$version" =~ ^[a-zA-Z0-9._-]+$ ]] || fail 'Invalid release tag.'
  local archive="heimdall-local-$target-$version.tar.gz" base="https://github.com/tanmayv/heimdall-agent-manager/releases/download/$version"
  log INFO "Downloading $version"
  # SHA256SUMS first: it lists every bundle of the release, so it also tells
  # whether this release ships the preferred (Termux) bundle at all.
  download "$base/SHA256SUMS" "$work_dir/SHA256SUMS"
  if [ -n "$fallback_target" ] && ! awk -v n="$archive" '{ sub(/^\*/, "", $2) } $2 == n { found = 1 } END { exit !found }' "$work_dir/SHA256SUMS"; then
    log WARN "Release $version has no $target bundle; installing heimdall-local-$fallback_target instead. Its glibc binaries are killed by Android's seccomp at start-up (set_robust_list); Termux bundles ship from v0.3.29 -- re-run without --version or pass a newer one."
    archive="heimdall-local-$fallback_target-$version.tar.gz"
  fi
  # Reuse a previously verified tarball of this exact release when its SHA-256
  # still matches the release's SHA256SUMS; otherwise download (with a progress
  # bar on a terminal). The cache only ever holds GitHub-release bundles.
  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/heimdall/releases"
  mkdir -p "$cache_dir"; chmod 700 "$cache_dir"
  if [ -f "$cache_dir/$archive" ] && python3 - "$work_dir/SHA256SUMS" "$cache_dir/$archive" "$archive" <<'PY'
import hashlib, pathlib, sys
sums, cached, name = sys.argv[1:]
entries = [line.split() for line in pathlib.Path(sums).read_text().splitlines()]
expected = [a[0] for a in entries if len(a)==2 and a[1].lstrip('*')==name]
sys.exit(0 if len(expected)==1 and hashlib.sha256(pathlib.Path(cached).read_bytes()).hexdigest()==expected[0] else 1)
PY
  then
    cp "$cache_dir/$archive" "$work_dir/$archive"
    log OK "Using cached $archive (SHA-256 matches release $version; no download)"
  else
    download_progress "$base/$archive" "$work_dir/$archive"
  fi
  python3 - "$work_dir" "$archive" <<'PY'
import hashlib, os, pathlib, posixpath, sys, tarfile
root = pathlib.Path(sys.argv[1]); name = sys.argv[2]
entries = [line.split() for line in (root/'SHA256SUMS').read_text().splitlines()]
expected = [a[0] for a in entries if len(a)==2 and a[1].lstrip('*')==name]
if len(expected)!=1 or hashlib.sha256((root/name).read_bytes()).hexdigest()!=expected[0]:
    sys.exit('SHA-256 verification failed; nothing installed.')
# Extract only required regular binaries: reject links and unsafe archive paths.
with tarfile.open(root/name) as t:
    for binary in ('heimdall','ham-bridge','ham-pty-host','ham-ctl'):
        members = [m for m in t.getmembers() if m.name.removeprefix('./') == 'bin/'+binary]
        if len(members)!=1 or not members[0].isfile(): sys.exit('Missing/unsafe binary: '+binary)
        (root/binary).write_bytes(t.extractfile(members[0]).read())
    scripts = [m for m in t.getmembers() if m.name.removeprefix('./') == 'scripts/apply-bridge-update.sh']
    if scripts:
        if len(scripts)!=1 or not scripts[0].isfile(): sys.exit('Unsafe update supervisor')
        (root/'apply-bridge-update.sh').write_bytes(t.extractfile(scripts[0]).read())

    # Extract only the extension tree, checking every path and link before
    # writing anything. Links are created last and cannot have child members.
    prefix = 'share/heimdall/extensions'
    assets = {}
    for member in t.getmembers():
        name = member.name.removeprefix('./').rstrip('/')
        if name != prefix and not name.startswith(prefix+'/'): continue
        path = pathlib.PurePosixPath(name)
        if '..' in path.parts or path.is_absolute() or str(path) != name or name in assets:
            sys.exit('Unsafe/duplicate extension path: '+name)
        if not (member.isdir() or member.isfile() or member.issym()):
            sys.exit('Unsafe extension member: '+name)
        if member.issym():
            target = posixpath.normpath(posixpath.join(posixpath.dirname(name), member.linkname))
            if member.linkname.startswith('/') or not target.startswith(prefix+'/'):
                sys.exit('Unsafe extension symlink: '+name)
        assets[name] = member
    for name, member in assets.items():
        for parent in pathlib.PurePosixPath(name).parents:
            if str(parent) in assets and not assets[str(parent)].isdir():
                sys.exit('Non-directory extension parent: '+str(parent))
    if assets:
        helpers = [m for m in t.getmembers() if m.name.removeprefix('./') == 'scripts/refresh-provider-extensions.sh']
        if len(helpers) != 1 or not helpers[0].isfile():
            sys.exit('Missing/unsafe extension staging helper')
        (root/'refresh-provider-extensions.sh').write_bytes(t.extractfile(helpers[0]).read())
        for name, member in assets.items():
            dest = root/name
            if member.isdir():
                dest.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(t.extractfile(member).read())
                dest.chmod(member.mode & 0o777)
        for name, member in assets.items():
            if member.issym():
                dest = root/name
                dest.parent.mkdir(parents=True, exist_ok=True)
                os.symlink(member.linkname, dest)
PY
  log OK 'Release checksum and bundle verified'
  # Preflight through the BRIDGE's own HTTPS client (the libcurl it links),
  # before any service is replaced: the curl CLI reaching the Hub says nothing
  # about whether this binary can.
  chmod 700 "$work_dir/ham-bridge"
  # --probe-hub exists from 0.3.36; an older bridge ignores unknown flags and
  # would start as a daemon in the foreground, so gate on the binary's version.
  local bridge_version version_out
  if ! version_out="$("$work_dir/ham-bridge" --version 2>&1)"; then
    fail "The downloaded ham-bridge does not start on this machine: ${version_out:-no output}. It needs libcurl >= 7.84 (libcurl.so.4: Debian 12+, Ubuntu 24.04+; macOS 13+). Nothing was replaced."
  fi
  bridge_version="$(printf '%s\n' "$version_out" | awk 'NR==1 {print $2}')"
  if [ -n "$bridge_version" ] && [ "$(printf '%s\n0.3.36\n' "$bridge_version" | sort -V | head -n1)" = "0.3.36" ]; then
    if ! "$work_dir/ham-bridge" --probe-hub "$hub_url"; then
      fail "The downloaded ham-bridge cannot reach $hub_url through its own HTTPS client (libcurl) although the curl CLI could. Check TLS trust (HAM_TLS_CA_FILE / SSL_CERT_FILE) and the probe output above. Nothing was replaced."
    fi
  else
    log INFO "Bridge ${bridge_version:-unknown} predates --probe-hub (0.3.36); transport preflight skipped."
  fi
  # Keep the verified bundle for next time; drop older versions of this target.
  cp "$work_dir/$archive" "$cache_dir/$archive.tmp" && mv -f "$cache_dir/$archive.tmp" "$cache_dir/$archive"
  local old cache_prefix="${archive%-"$version".tar.gz}"
  for old in "$cache_dir/$cache_prefix"-*.tar.gz; do
    [ "$old" = "$cache_dir/$archive" ] || rm -f "$old"
  done
  # Validate and copy the full new generation before stopping a service.
  local extension_transaction=""
  if [ -d "$work_dir/share/heimdall/extensions" ]; then
    source "$work_dir/refresh-provider-extensions.sh"
    mkdir -p "$data_dir"
    extension_transaction="$(mktemp -d "$data_dir/.extensions-install.XXXXXX")"
    trap "$(printf 'cleanup_provider_extension_transaction %q %q; rm -rf %q; rmdir %q' "$extension_transaction" "$data_dir/extensions" "$work_dir" "$lock_dir")" EXIT
    prepare_provider_extensions "$work_dir/share/heimdall/extensions" "$data_dir/extensions" "$extension_transaction/new"
  fi
  step '3 / 6 · Replace this Hub’s service'
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
  [ ! -d "$bin_dir" ] || chmod 700 "$bin_dir"
  step '4 / 6 · Ports and ham-ctl routing'
  local ports bridge_port endpoint_port
  ports="$(python3 - "$state_root" "$state_dir" <<'PY'
import json, pathlib, socket, sys
root, own = map(pathlib.Path, sys.argv[1:]); reserved=set(); preferred=[49323,49324]
for file in root.glob('*/ports.json'):
    try:
        p=json.loads(file.read_text())
        if file.parent==own: preferred=p
        else: reserved.update(p)
    except (ValueError, OSError): pass
held=[]; result=[]
try:
    for start in preferred:
        for port in range(max(1024,int(start)),65536):
            if port in reserved or port in result: continue
            s=socket.socket()
            try: s.bind(('127.0.0.1',port))
            except OSError: s.close(); continue
            held.append(s); result.append(port); break
        else: sys.exit('No free bridge ports available.')
    (own/'ports.json').write_text(json.dumps(result)+'\n')
    print(*result)
finally:
    for s in held: s.close()
PY
)"
  bridge_port="${ports% *}"; endpoint_port="${ports#* }"
  log OK "Bridge: 127.0.0.1:$bridge_port · Agent endpoint: 127.0.0.1:$endpoint_port"
  # Render with proper escaping for spaces, XML, shell, and systemd specifiers.
  python3 - "$svc" "$service_file" "$service_name" "$hub_url" "$bin_dir" "$state_dir" "$data_dir" "$bridge_port" "$endpoint_port" "$PATH" "${PREFIX:-}" "${TERMUX_VERSION:-}" <<'PY'
import json, pathlib, plistlib, shlex, shutil, sys
svc, file, name, hub, bin_dir, state, data, port, endpoint, path, prefix, termux_version = sys.argv[1:]
osname = 'darwin' if svc == 'launchd' else 'linux'
args=[bin_dir+'/ham-bridge','--hub',hub,'--config',state+'/config.toml','--bridge-token-file',state+'/bridge-token','--data-dir',data,'--bind-host','127.0.0.1','--port',port,'--local-endpoint-port',endpoint,'--local-run-dir',data+'/run']
config = pathlib.Path(state)/'config.toml'
if not config.exists():
    config.write_text('[daemon]\ndaemon_url = '+json.dumps(hub)+'\ndata_dir = '+json.dumps(data)+'\n\n[wrapper]\ndaemon_url = '+json.dumps(hub)+'\n')
config.chmod(0o600)
env={'PATH':bin_dir+':'+path,'HEIMDALL_HAM_PTY_HOST_BIN':bin_dir+'/ham-pty-host','HEIMDALL_BRIDGE_PTY_HOST':'true','HEIMDALL_HAM_CTL_BIN':bin_dir+'/ham-ctl','HEIMDALL_BRIDGE_ENDPOINT':'tcp:127.0.0.1:'+endpoint,'HEIMDALL_BRIDGE_SERVICE_NAME':'ham-bridge' if svc=='runit' else name+('.service' if osname=='linux' else '')}
# Do not override the endpoint injected into agent run directories.
wrapper=pathlib.Path(bin_dir)/('ham-ctl-'+name)
wrapper.write_text('#!/bin/sh\n: "${HEIMDALL_BRIDGE_ENDPOINT:='+env['HEIMDALL_BRIDGE_ENDPOINT']+'}"\nexport HEIMDALL_BRIDGE_ENDPOINT\nexec '+shlex.quote(bin_dir+'/ham-ctl')+' --config '+shlex.quote(state+'/config.toml')+' "$@"\n')
wrapper.chmod(0o755)
env['HEIMDALL_HAM_CTL_BIN']=str(wrapper)
if svc=='runit':
    # termux-services run file: exec the bridge under runsv with the same
    # environment the systemd unit would carry; stderr joins stdout for svlogd.
    # runsvdir usually inherits the login shell's TERMUX_VERSION/PREFIX, but the
    # bridge selects its Android keystore backend and the update script its runit
    # path from exactly those two, so export them explicitly: an environment
    # without them would silently pick the Linux keyring (seccomp-killed) path.
    run=pathlib.Path(file)
    text='#!'+prefix+'/bin/sh\nexec 2>&1\n'
    text+='export PREFIX='+shlex.quote(prefix)+'\n'
    text+='export TERMUX_VERSION='+shlex.quote(termux_version or 'installed')+'\n'
    # Services started by runsvdir may lack the login shell's TMPDIR; without it
    # the bridge and PTY host fall back to /tmp, which Android does not have.
    text+='export TMPDIR='+shlex.quote(prefix+'/tmp')+'\n'
    text+=''.join('export '+k+'='+shlex.quote(v)+'\n' for k,v in env.items())
    text+='exec '+' '.join(shlex.quote(a) for a in args)+'\n'
    run.write_text(text); run.chmod(0o755)
elif osname=='darwin':
    plist={'Label':name,'ProgramArguments':args,'EnvironmentVariables':env,'RunAtLoad':True,'KeepAlive':{'SuccessfulExit':False},'AbandonProcessGroup':True,'ThrottleInterval':5,'StandardOutPath':data+'/logs/bridge.out.log','StandardErrorPath':data+'/logs/bridge.err.log'}
    pathlib.Path(file).write_bytes(plistlib.dumps(plist))
else:
    def quote(s): return '"'+s.replace('\\','\\\\').replace('"','\\"').replace('%','%%')+'"'
    command=' '.join(quote(a).replace('$','$$') for a in args)
    text='[Unit]\nDescription=Heimdall Bridge '+hub+'\nAfter=network-online.target\n\n[Service]\nType=simple\nExecStart='+command+'\n'
    text+=''.join('Environment='+quote(k+'='+v)+'\n' for k,v in env.items())
    supervisor = pathlib.Path(data)/'updates/apply-bridge-update.sh'
    if supervisor.is_file():
        bash = shutil.which('bash', path=path)
        if not bash:
            raise SystemExit('bash was not found while rendering the systemd unit')
        stop_args = [bash, str(supervisor), '--data-dir', data, '--stop-pty-hosts-only']
        text+='ExecStopPost='+' '.join(quote(a).replace('$','$$') for a in stop_args)+'\n'
    text+='Restart=on-failure\nRestartSec=5\nKillMode=process\n\n[Install]\nWantedBy=default.target\n'
    pathlib.Path(file).write_text(text)
PY
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
    declare -f log fail enroll
    for file in state_dir bin_dir service_name uid token_file hub_url data_dir bridge_port endpoint_port run_dir; do
      printf '%s=%q\n' "$file" "${!file}"
    done
    printf 'enroll "$@"\n'
  } > "$state_dir/enroll.sh"
  chmod 700 "$state_dir/enroll.sh"
  step '5 / 6 · Register service and enrollment'
  # Start the service now only when no enrollment runs in this invocation: a
  # running bridge holds the config and `ham-bridge enroll` refuses to proceed.
  # Enrollment restarts the service itself; the block after it covers exit 3.
  local enroll_now=false
  [ "$enrollment" != yes ] || "$noninteractive" || enroll_now=true
  case "$svc" in
    systemd)
      systemctl --user daemon-reload
      if "$enroll_now"; then systemctl --user enable "$service_name"
      else systemctl --user enable --now "$service_name"; fi ;;
    launchd)
      plutil -lint "$service_file" >/dev/null
      "$enroll_now" || launchctl bootstrap "gui/$uid" "$service_file" ;;
    runit)
      # Give runsvdir (5 s scan) time to attach a runsv before anything uses
      # `sv` on this directory. The service itself stays DOWN until enrollment
      # has finished: runit restarts a token-less bridge every second, so an
      # enabled service would connect the moment the token file appears and the
      # Hub would drop the enrolling process mid vault delivery.
      local waited=0
      until [ -d "$runit_dir/supervise" ] || [ "$waited" -ge "${HEIMDALL_RUNSV_WAIT:-10}" ]; do waited=$((waited+1)); sleep 1; done ;;
  esac
  if [ "$enrollment" = yes ]; then
    if "$noninteractive"; then
      log INFO 'Service installed; browser-approved enrollment is pending.'
      if "$new_bridge"; then printf 'Run: %q --new-bridge\n' "$state_dir/enroll.sh"
      else printf 'Run: %q\n' "$state_dir/enroll.sh"; fi
    elif "$new_bridge"; then enroll --new-bridge; log OK 'Browser-approved enrollment complete'
    else enroll; log OK 'Browser-approved enrollment complete'; fi
  else log OK 'Existing enrollment preserved'; fi
  if "$enroll_now"; then
    case "$svc" in
      systemd) systemctl --user start "$service_name" ;;
      launchd) launchctl print "gui/$uid/$service_name" >/dev/null 2>&1 || launchctl bootstrap "gui/$uid" "$service_file" ;;
    esac
  fi
  if [ "$svc" = runit ]; then
    # Enable only now (after enrollment, or at once when none runs): removes the
    # down file for future boots and starts the service if enrollment did not.
    if command -v sv-enable >/dev/null; then sv-enable ham-bridge
    else rm -f "$runit_dir/down"; sv up "$runit_dir"; fi
    local tries=0
    until sv status "$runit_dir" 2>/dev/null | grep -q '^run:'; do
      tries=$((tries+1)); [ "$tries" -lt 15 ] || break; sleep 1
    done
  fi
  step '6 / 6 · Ready'
  case "$svc" in
    systemd)
      # is-active also holds between Restart= attempts; watch for a crash loop.
      local restarts tries=0
      restarts="$(systemctl --user show -p NRestarts --value "$service_name" 2>/dev/null || echo 0)"
      until [ "$tries" -ge "${HEIMDALL_READY_WAIT:-8}" ]; do
        sleep 1; tries=$((tries+1))
        systemctl --user is-active --quiet "$service_name" || break
        [ "$(systemctl --user show -p NRestarts --value "$service_name" 2>/dev/null || echo 0)" = "$restarts" ] || break
      done
      if [ "$tries" -lt "${HEIMDALL_READY_WAIT:-8}" ]; then
        journalctl --user -u "$service_name" -n 6 --no-pager -o cat >&2 2>/dev/null || true
        fail "Service is not staying up. Inspect: journalctl --user -u $service_name (re-enroll: re-run with --re-enroll)"
      fi
      log OK "Service active: $service_name"
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
  if [ -n "$extension_transaction" ]; then
    cleanup_provider_extension_transaction "$extension_transaction" "$data_dir/extensions"
  fi
  rm -rf "$work_dir"
  rmdir "$lock_dir"
  trap - EXIT
}
main "$@"
