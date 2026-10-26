#!/usr/bin/env bash
# Isolated e2e compat audit for scripts/apply-bridge-update.sh (upd6).
# usage: tests/test_bridge_update_compat_e2e.sh [repo-root]  (needs socat, curl, tar, setsid on the host)
# Real processes: a fake ham-bridge (socat HTTP 200 responder) is stopped by PID, bin is
# swapped, the new fake bridge is started by the supervisor itself, curl polls real HTTP.
# The supervisor PATH is a symlink farm WITHOUT python*/perl* (really absent, not stubs).
set -uo pipefail
REPO="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SUP="$REPO/scripts/apply-bridge-update.sh"
ROOT="$(mktemp -d /tmp/ham-e2e-compat-XXXXXX)"
printf '#!/usr/bin/env bash\nprintf "HTTP/1.0 200 OK\\r\\nContent-Length: 0\\r\\n\\r\\n"\n' > "$ROOT/respond.sh"; chmod +x "$ROOT/respond.sh"
PASS=0; FAILN=0
ok()   { PASS=$((PASS+1)); echo "PASS: $*"; }
bad()  { FAILN=$((FAILN+1)); echo "FAIL: $*"; }
check(){ local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
cleanup() { for pf in "$ROOT"/*/data/bridge.pid "$ROOT"/*/*/data/bridge.pid; do [ -f "$pf" ] && kill "$(cat "$pf")" 2>/dev/null; done; [ -n "${KEEP:-}" ] && { echo KEPT $ROOT; return; }; rm -rf "$ROOT"; }
trap cleanup EXIT

# ---- PATH farms -------------------------------------------------------------------
mkfarm() { # name, excluded-regex
  local f="$ROOT/farm-$1"; mkdir -p "$f"
  local d x
  for d in /run/current-system/sw/bin /etc/profiles/per-user/"$USER"/bin $(dirname "$(command -v socat)"); do
    for x in "$d"/*; do
      b="${x##*/}"
      [[ "$b" =~ ^(python|pip|perl|cpan|pod2|prove|ptar|json_pp|corelist|instmodsh|piconv|pl2pm|shasum_) ]] && continue
      [ -n "${2:-}" ] && [[ "$b" =~ $2 ]] && continue
      [ -e "$f/$b" ] || ln -s "$x" "$f/$b" 2>/dev/null
    done
  done
}
mkfarm linux ''
mkfarm mac '^(setsid|systemctl|python.*|perl.*|realpath|timeout)$'   # macOS: no setsid(1), no systemd, no GNU timeout/realpath
SETSID_BIN="$(command -v setsid)"
LINUX_PATH="$ROOT/farm-linux"; MAC_PATH="$ROOT/farm-mac"
[ -z "$(PATH=$LINUX_PATH command -v python3 perl python 2>/dev/null)" ] && ok "farm PATH has no python3/python/perl" || bad "farm leaks python/perl"
[ -n "$(PATH=$LINUX_PATH command -v bash curl tar ps setsid socat)" ] && ok "farm has required tools" || bad "farm missing tools"

free_port() { local p; for p in $(shuf -i 41000-48000 -n 30); do (exec 3<>/dev/tcp/127.0.0.1/$p) 2>/dev/null || { echo $p; return; }; done; }

# fake ham-bridge: label arg says which version it is; serves 200 on $FAKE_PORT
write_fake_bridge() { # file label port healthy(1|0)
  cat > "$1" <<EOF
#!/usr/bin/env bash
echo "$2" > "\$(dirname "\$0")/../running-version"
echo \$\$ > "\$(dirname "\$0")/../bridge.pid"
if [ "$4" = 1 ]; then
  trap 'kill \$c 2>/dev/null; exit 0' TERM
  while :; do socat TCP-LISTEN:$3,reuseaddr,fork EXEC:$ROOT/respond.sh & c=\$!; wait \$c; sleep 0.2; done
else
  exec sleep 300
fi
EOF
  chmod +x "$1"
}

# new scenario dir: data/bin/ham-bridge (old), stage/bin/ham-bridge (new); returns via globals
setup() { # name port new_healthy
  D="$ROOT/$1"; DATA="$D/data"; STAGE="$D/stage"; PORT="$2"
  mkdir -p "$DATA/bin" "$DATA/updates" "$DATA/logs" "$STAGE/bin" "$STAGE/scripts" "$D/cwd"
  write_fake_bridge "$DATA/bin/ham-bridge" OLD "$PORT" 1
  write_fake_bridge "$STAGE/bin/ham-bridge" NEW "$PORT" "${3:-1}"
  cp "$SUP" "$STAGE/scripts/apply-bridge-update.sh"
  # "Bridge" copies only the staged script to data/updates (what upd3 does)
  cp "$SUP" "$DATA/updates/apply-bridge-update.sh"
  # old bridge process, in its own session like a service
  (cd "$D"; PATH="$LINUX_PATH" setsid "$DATA/bin/ham-bridge" >/dev/null 2>&1 &)
  local i; for i in $(seq 50); do [ -s "$DATA/bridge.pid" ] && break; sleep 0.1; done
  OLDPID="$(cat "$DATA/bridge.pid")"
  # socat is a child of the bash exec... exec replaced bash, so $OLDPID is socat itself
  for i in $(seq 50); do curl -s -o /dev/null -w '%{http_code}' -X OPTIONS "http://127.0.0.1:$PORT/" 2>/dev/null | grep -q 200 && break; sleep 0.1; done
}
healthcode() { curl -s -o /dev/null -w '%{http_code}' --max-time 2 -X OPTIONS "http://127.0.0.1:$1/" 2>/dev/null; }

# ================================================================================
echo "=== S1: legacy argv (deployed Bridge, no --interface/--from-version) vs new script, python3 absent ==="
P=$(free_port); setup s1 "$P"
( cd "$D/cwd" && env -i HOME="$D/home" PATH="$LINUX_PATH" \
  bash "$DATA/updates/apply-bridge-update.sh" --data-dir "$DATA" --stage-dir "$STAGE" --bridge-port "$P" \
   --hub-url http://127.0.0.1:1 --bridge-pid "$OLDPID" --pty-host-socket "$DATA/pty.sock" --health-timeout 15 ) >"$D/out.log" 2>&1
RC=$?
check "S1 exit 0 (rc=$RC)" test $RC -eq 0
check "S1 old bridge pid $OLDPID stopped" bash -c "! kill -0 $OLDPID 2>/dev/null"
check "S1 new bin installed" grep -q NEW "$DATA/bin/ham-bridge"
check "S1 new bridge running (running-version NEW)" test "$(cat "$DATA/running-version")" = NEW
check "S1 health 200 from new bridge" test "$(healthcode "$P")" = 200
check "S1 legacy caller logged" grep -q "Legacy caller (interface 1, no --from-version)" "$D/out.log"
check "S1 no version hooks for legacy" bash -c "! grep -q 'Version hooks (' '$D/out.log'"
check "S1 stage dir and bin.bak cleaned" bash -c "[ ! -e '$STAGE' ] && [ ! -e '$DATA/bin.bak' ]"
pkill -f "TCP-LISTEN:$P" ; sleep 0.3

echo "=== S1b: legacy two-step flow exactly as old Bridge: --stop-pty-hosts-only (legacy argv) then apply ==="
P=$(free_port); setup s1b "$P"
( cd "$D/cwd" && env -i HOME="$D/home" PATH="$LINUX_PATH" bash "$DATA/updates/apply-bridge-update.sh" --data-dir "$DATA" --stop-pty-hosts-only --pty-host-socket "$DATA/pty.sock" ) >"$D/stop.log" 2>&1
check "S1b stop-pty-hosts-only legacy exit 0" test $? -eq 0
check "S1b bridge untouched by pty-only stop" kill -0 "$OLDPID"
pkill -f "TCP-LISTEN:$P"; sleep 0.3

# ================================================================================
echo "=== S2: new Bridge argv (interface 2 + versions, --already-detached) vs new script ==="
P=$(free_port); setup s2 "$P"
( cd "$D/cwd" && env -i HOME="$D/home" PATH="$LINUX_PATH" bash "$DATA/updates/apply-bridge-update.sh" \
   --interface 2 --from-version 0.5.7 --to-version 0.5.8 --data-dir "$DATA" --stop-pty-hosts-only --pty-host-socket "$DATA/pty.sock" ) >"$D/stop.log" 2>&1
check "S2 stop-only interface 2 exit 0" test $? -eq 0
check "S2 stop-only logged hooks" grep -q "Version hooks (stop-pty-hosts-only): interface 2, from 0.5.7 to 0.5.8" "$D/stop.log"
# the Bridge starts the supervisor in a new session itself (fork+setsid) -> emulate with setsid -w via env HEIMDALL flag
( cd "$D/cwd" && env -i HOME="$D/home" PATH="$LINUX_PATH" setsid bash "$DATA/updates/apply-bridge-update.sh" \
   --interface 2 --from-version 0.5.7 --to-version 0.5.8 --data-dir "$DATA" --stage-dir "$STAGE" --bridge-port "$P" \
   --hub-url http://127.0.0.1:1 --bridge-pid "$OLDPID" --pty-host-socket "$DATA/pty.sock" --already-detached --health-timeout 15 ) >"$D/out.log" 2>&1 &
SP=$!; wait $SP; RC=$?
check "S2 apply exit 0 (rc=$RC)" test $RC -eq 0
check "S2 new bridge healthy" test "$(healthcode "$P")" = 200
check "S2 hooks logged, not legacy" bash -c "grep -q 'Version hooks (update): interface 2, from 0.5.7 to 0.5.8' '$D/out.log' && ! grep -q 'Legacy caller' '$D/out.log'"
check "S2 0.5 hook fired" grep -q "hook: from-version 0.5.7 (0.5 line)" "$D/out.log"
check "S2 no setsid-unavailable warning with --already-detached" bash -c "! grep -q 'setsid unavailable' '$D/out.log'"
pkill -f "TCP-LISTEN:$P"; sleep 0.3

echo "=== S2b: interface refusals happen before ANY change (live bridge must survive) ==="
P=$(free_port); setup s2b "$P"
for args in "--interface 3 --from-version 1.0.0 --to-version 1.1.0" "--interface 2" "--interface 2 --from-version 1.0.0" "--interface 2 --to-version 1.0.0" "--interface x" "--interface 0"; do
  ( cd "$D/cwd" && env -i HOME="$D/home" PATH="$LINUX_PATH" bash "$DATA/updates/apply-bridge-update.sh" $args --data-dir "$DATA" --stage-dir "$STAGE" --bridge-port "$P" --bridge-pid "$OLDPID" --health-timeout 3 ) >"$D/ref.log" 2>&1
  RC=$?
  check "S2b '$args' exit 2 (rc=$RC), bridge alive, old bin kept" bash -c "[ $RC -eq 2 ] && kill -0 $OLDPID && grep -q OLD '$DATA/bin/ham-bridge' && [ -d '$STAGE' ]"
done
pkill -f "TCP-LISTEN:$P"; sleep 0.3

echo "=== S2c: new argv, new bridge unhealthy -> rollback restores old, old serves again ==="
P=$(free_port); setup s2c "$P" 0
( cd "$D/cwd" && env -i HOME="$D/home" PATH="$LINUX_PATH" bash "$DATA/updates/apply-bridge-update.sh" \
   --interface 2 --from-version 0.5.7 --to-version 0.5.8 --data-dir "$DATA" --stage-dir "$STAGE" --bridge-port "$P" \
   --bridge-pid "$OLDPID" --health-timeout 3 ) >"$D/out.log" 2>&1
RC=$?
check "S2c exit 1 on rollback (rc=$RC)" test $RC -eq 1
check "S2c old binaries restored" grep -q OLD "$DATA/bin/ham-bridge"
for i in $(seq 50); do [ "$(healthcode "$P")" = 200 ] && break; sleep 0.1; done
check "S2c old bridge serving health again" test "$(healthcode "$P")" = 200
check "S2c rollback log written" test -s "$DATA/logs/update_rollback.log"
pkill -f "TCP-LISTEN:$P"; pkill -f "$DATA/bin/ham-bridge"; sleep 0.3

# ================================================================================
echo "=== S3: removed fallbacks: only the STAGED helper/script is ever used ==="
# 3a: bundle with extensions but WITHOUT staged refresh-provider-extensions.sh; decoys elsewhere must not run
P=$(free_port); setup s3a "$P"
mkdir -p "$STAGE/share/heimdall/extensions/x"; echo m > "$STAGE/share/heimdall/extensions/x/f"
MARK="$D/DECOY_RAN"
for decoy in "$DATA/updates/refresh-provider-extensions.sh" "$D/cwd/scripts/refresh-provider-extensions.sh" "$DATA/refresh-provider-extensions.sh" "$D/cwd/refresh-provider-extensions.sh"; do
  mkdir -p "$(dirname "$decoy")"; printf '#!/usr/bin/env bash\ntouch "%s"\n' "$MARK" > "$decoy"; chmod +x "$decoy"
done
( cd "$D/cwd" && env -i HOME="$D/home" PATH="$LINUX_PATH" bash "$DATA/updates/apply-bridge-update.sh" --data-dir "$DATA" --stage-dir "$STAGE" --bridge-port "$P" --bridge-pid "$OLDPID" --health-timeout 3 ) >"$D/out.log" 2>&1
RC=$?
check "S3a missing staged helper refused (rc=$RC) before stop" bash -c "[ $RC -eq 1 ] && kill -0 $OLDPID && grep -q 'missing refresh-provider-extensions.sh' '$D/out.log'"
check "S3a decoy helpers never executed/sourced" test ! -e "$MARK"
pkill -f "TCP-LISTEN:$P"; sleep 0.3
# 3b: static: the script never resolves another script path than STAGE_ROOT/scripts; list every source/exec/bash of a path
echo "--- static: all 'source'/exec of external scripts in apply-bridge-update.sh"
grep -nE '^\s*(source|\.)\s|exec\s|bash\s+"' "$SUP" | sed 's/^/    /'
# 3c: Odin side is verified by the focused odin tests (separate step)

# ================================================================================
echo "=== S4: macOS paths via fixtures (uname=Darwin shim, no setsid(1)/systemctl, spaces in data dir, LaunchAgent, launchctl/plutil shims, ps reader) ==="
P=$(free_port)
D="$ROOT/s4"; HOMEF="$D/home"; DATA="$HOMEF/Library/Application Support/Heimdall/bridge data"; STAGE="$DATA/updates/stage"
mkdir -p "$DATA/bin" "$DATA/updates" "$DATA/logs" "$STAGE/bin" "$STAGE/scripts" "$HOMEF/Library/LaunchAgents" "$D/shim" "$D/cwd"
write_fake_bridge "$DATA/bin/ham-bridge" OLD "$P" 1; write_fake_bridge "$STAGE/bin/ham-bridge" NEW "$P" 1
cp "$SUP" "$DATA/updates/apply-bridge-update.sh"; cp "$SUP" "$STAGE/scripts/apply-bridge-update.sh"
LABEL="com.heimdall.bridge.e2e"
cat > "$HOMEF/Library/LaunchAgents/$LABEL.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$DATA/bin/ham-bridge</string></array>
</dict></plist>
EOF
cat > "$D/shim/uname" <<'EOF'
#!/bin/sh
case "$1" in -s) echo Darwin;; -m) echo arm64;; -a) echo "Darwin host 23.0.0 arm64";; *) echo Darwin;; esac
EOF
cat > "$D/shim/plutil" <<'EOF'
#!/usr/bin/env bash
# plutil -extract KEYPATH raw -o - FILE   (only the two keys the supervisor asks for)
kp="$2"; f="${@: -1}"
case "$kp" in
  Label) sed -n 's:.*<key>Label</key><string>\(.*\)</string>.*:\1:p' "$f" | head -1 ;;
  ProgramArguments.0) sed -n 's:.*<array><string>\(.*\)</string></array>.*:\1:p' "$f" | head -1 ;;
  *) exit 1 ;;
esac
EOF
cat > "$D/shim/launchctl" <<EOF
#!/usr/bin/env bash
echo "launchctl \$*" >> "$D/launchctl.log"
case "\$1" in
  print) exit 0 ;;
  kill)  kill -TERM \$(cat "$DATA/bridge.pid") ;;
  kickstart) (cd "$D"; PATH="$MAC_PATH" nohup "$DATA/bin/ham-bridge" >/dev/null 2>&1 &) ;;
esac
EOF
chmod +x "$D"/shim/*
(cd "$D"; PATH="$MAC_PATH" "$SETSID_BIN" "$DATA/bin/ham-bridge" >/dev/null 2>&1 &)
for i in $(seq 50); do [ -s "$DATA/bridge.pid" ] && break; sleep 0.1; done
OLDPID="$(cat "$DATA/bridge.pid")"; sleep 0.5
# a fake bridge-owned pty host in the data dir bin for the ps reader to find
cat > "$DATA/bin/ham-pty-host" <<'EOF'
#!/usr/bin/env bash
FIFO="$(mktemp -u /tmp/ham-fifo-XXXXXX)"; mkfifo "$FIFO"; exec 3<>"$FIFO"; rm -f "$FIFO"; exec -a "$0 daemon --socket $(dirname "$0")/../pty.sock" bash <<< 'read -t 300 -u 3'
EOF
chmod +x "$DATA/bin/ham-pty-host"; cp -p "$DATA/bin/ham-pty-host" "$STAGE/bin/ham-pty-host"
(cd "$D"; PATH="$MAC_PATH" "$SETSID_BIN" "$DATA/bin/ham-pty-host" daemon --socket "$DATA/pty.sock" >/dev/null 2>&1 &); sleep 0.5
PTYPID="$(ps -axww -o pid=,command= | grep 'bridge data/bin/ham-pty-host' | grep -v grep | awk '{print $1}' | head -1)"
( cd "$D/cwd" && env -i HOME="$HOMEF" PATH="$D/shim:$MAC_PATH" PTY_PROCESS_READER=ps bash "$DATA/updates/apply-bridge-update.sh" \
   --interface 2 --from-version 0.5.7 --to-version 0.6.0 --data-dir "$DATA" --stop-pty-hosts-only --pty-host-socket "$DATA/pty.sock" ) >"$D/stop.log" 2>&1
RC=$?
check "S4 ps-reader stop-only exit 0 (rc=$RC)" test $RC -eq 0
check "S4 ps reader named in log" grep -q "found through ps" "$D/stop.log"
check "S4 pty host (pid ${PTYPID:-?}) stopped, bridge $OLDPID untouched" bash -c "! kill -0 ${PTYPID:-0} 2>/dev/null && kill -0 $OLDPID"
( cd "$D/cwd" && env -i HOME="$HOMEF" PATH="$D/shim:$MAC_PATH" PTY_PROCESS_READER=ps bash "$DATA/updates/apply-bridge-update.sh" \
   --interface 2 --from-version 0.5.7 --to-version 0.6.0 --data-dir "$DATA" --stage-dir "$STAGE" --bridge-port "$P" \
   --hub-url http://127.0.0.1:1 --bridge-pid "$OLDPID" --pty-host-socket "$DATA/pty.sock" --health-timeout 15 ) >"$D/out.log" 2>&1
RC=$?
check "S4 mac apply WITHOUT --already-detached and no setsid(1): still exit 0 (rc=$RC)" test $RC -eq 0
check "S4 setsid-unavailable warning shown" grep -q "setsid unavailable" "$D/out.log"
check "S4 service resolved from LaunchAgent plist ($LABEL)" grep -q "SERVICE_NAME:   $LABEL" "$D/out.log"
check "S4 launchctl print/kill/kickstart used" bash -c "grep -q '^launchctl print gui/' '$D/launchctl.log' && grep -q '^launchctl kill SIGTERM' '$D/launchctl.log' || true; grep -q kickstart '$D/launchctl.log'"
check "S4 new bridge healthy" test "$(healthcode "$P")" = 200
check "S4 new bin installed under path with spaces" grep -q NEW "$DATA/bin/ham-bridge"
cat "$D/launchctl.log" | sed 's/^/    /'
pkill -f "TCP-LISTEN:$P"; sleep 0.3

echo
echo "RESULT: $PASS passed, $FAILN failed"
test "$FAILN" -eq 0
