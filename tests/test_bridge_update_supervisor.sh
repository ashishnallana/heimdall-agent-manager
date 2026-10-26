#!/usr/bin/env bash
# tests/test_bridge_update_supervisor.sh
# Synthetic tests for scripts/apply-bridge-update.sh
# Covers:
# 1. Healthcheck timeout -> automated rollback to bin.bak
# 2. Process crash on restart -> automated rollback to bin.bak
# 3. Default OPTIONS readiness probe -> atomic replacement and cleanup
# 4. PID-scoped stop leaves an unrelated bridge-like process alive
# 5. Supervisor survives its service manager killing the bridge's process group
# 6. --already-detached / HEIMDALL_UPDATE_SUPERVISOR_DETACHED=1 skips the setsid re-exec
# 7. Without setsid(1) the supervisor warns and still updates
# 8. Unsupported or incomplete --interface callers are refused before any change
# 9. Legacy (no --from-version) and interface 2 callers both apply the update
# 10. Version hooks fire for a matching from-version, also in --stop-pty-hosts-only
# 11. semver_compare follows SemVer 2.0 precedence
# The supervisor runs with failing python3/perl stubs first on its PATH.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SUPERVISOR="$REPO_ROOT/scripts/apply-bridge-update.sh"
# Never inherit a live bridge's service or session settings from the caller.
unset SERVICE_NAME HEIMDALL_BRIDGE_SERVICE_NAME BRIDGE_PID PTY_HOST_SOCKET HEIMDALL_UPDATE_SUPERVISOR_DETACHED PTY_PROCESS_READER

[ -x "$SUPERVISOR" ] || { echo "FAIL: $SUPERVISOR is not executable" >&2; exit 1; }

TMP_DIR="$(mktemp -d /tmp/ham-sup-test-XXXXXX)"
TARGET_PID=""
UNRELATED_PID=""
SERVER_PID=""
cleanup() {
  for pid in "$TARGET_PID" "$UNRELATED_PID" "$SERVER_PID"; do
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# The supervisor must run without python3 or perl: on its PATH both are stubs
# that record the call and fail. The harness itself still uses python3 ($PY)
# for health servers and process-group setup.
PY="$(command -v python3)"
FORBIDDEN="$TMP_DIR/forbidden"
mkdir -p "$TMP_DIR/nopy"
for tool in python3 python perl; do
  printf '#!/bin/sh\necho "$0 $*" >> "%s"\nexit 127\n' "$FORBIDDEN" > "$TMP_DIR/nopy/$tool"
  chmod +x "$TMP_DIR/nopy/$tool"
done
SUP_PATH="$TMP_DIR/nopy:$PATH"

TRUE_HOOK="$TMP_DIR/true-hook"
cat > "$TRUE_HOOK" <<'HOOK'
#!/usr/bin/env bash
exit 0
HOOK
chmod +x "$TRUE_HOOK"

echo "=== Test 1: Healthcheck timeout triggers automated rollback ==="
mkdir -p "$TMP_DIR/t1/data/bin" "$TMP_DIR/t1/stage/bin"
echo "original-v1.0" > "$TMP_DIR/t1/data/bin/ham-bridge"
echo "unresponsive-v2.0" > "$TMP_DIR/t1/stage/bin/ham-bridge"

set +e
PATH="$SUP_PATH" "$SUPERVISOR" \
  --data-dir "$TMP_DIR/t1/data" \
  --stage-dir "$TMP_DIR/t1/stage" \
  --bridge-port 58901 \
  --health-timeout 2 \
  --stop-hook "$TRUE_HOOK" \
  --restart-hook "$TRUE_HOOK"
EXIT_CODE=$?
set -e

if [ "$EXIT_CODE" -ne 1 ]; then
  echo "FAIL: Expected exit code 1 on timeout, got $EXIT_CODE" >&2
  exit 1
fi

RESTORED=$(cat "$TMP_DIR/t1/data/bin/ham-bridge")
if [ "$RESTORED" != "original-v1.0" ]; then
  echo "FAIL: Expected rollback to original-v1.0, got: $RESTORED" >&2
  exit 1
fi

if [ ! -f "$TMP_DIR/t1/data/logs/update_rollback.log" ]; then
  echo "FAIL: Rollback log was not written" >&2
  exit 1
fi
echo "PASS: Test 1 passed!"

echo "=== Test 2: Process crash on restart triggers automated rollback ==="
mkdir -p "$TMP_DIR/t2/data/bin" "$TMP_DIR/t2/stage/bin"
echo "stable-v1.0" > "$TMP_DIR/t2/data/bin/ham-bridge"
echo "crashing-v2.0" > "$TMP_DIR/t2/stage/bin/ham-bridge"

# Restart hook that simulates the new binary crashing with exit 1. After
# rollback restores the stable marker, the same hook succeeds.
CRASH_HOOK="$TMP_DIR/crash-hook"
cat > "$CRASH_HOOK" <<HOOK
#!/usr/bin/env bash
if [ "\$(cat "$TMP_DIR/t2/data/bin/ham-bridge" 2>/dev/null)" = "crashing-v2.0" ]; then
  exit 1
fi
exit 0
HOOK
chmod +x "$CRASH_HOOK"

set +e
PATH="$SUP_PATH" "$SUPERVISOR" \
  --data-dir "$TMP_DIR/t2/data" \
  --stage-dir "$TMP_DIR/t2/stage" \
  --bridge-port 58902 \
  --health-timeout 2 \
  --stop-hook "$TRUE_HOOK" \
  --restart-hook "$CRASH_HOOK"
EXIT_CODE=$?
set -e

if [ "$EXIT_CODE" -ne 1 ]; then
  echo "FAIL: Expected exit code 1 on crash, got $EXIT_CODE" >&2
  exit 1
fi

RESTORED_CRASH=$(cat "$TMP_DIR/t2/data/bin/ham-bridge")
if [ "$RESTORED_CRASH" != "stable-v1.0" ]; then
  echo "FAIL: Expected rollback to stable-v1.0, got: $RESTORED_CRASH" >&2
  exit 1
fi

if [ ! -f "$TMP_DIR/t2/data/logs/update_rollback.log" ]; then
  echo "FAIL: Rollback log was not written on crash" >&2
  exit 1
fi
echo "PASS: Test 2 passed!"

echo "=== Test 3: Default OPTIONS readiness probe applies update ==="
# Start a temporary healthcheck server on an OS-assigned port so concurrent or
# immediately repeated test runs cannot collide.
T3_PORT_FILE="$TMP_DIR/t3-health-port"
python3 - "$T3_PORT_FILE" <<'PY' &
import http.server, socketserver, sys
class Handler(http.server.BaseHTTPRequestHandler):
    def do_OPTIONS(self):
        if self.path != '/bridge/health':
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{"ok":true}')
with socketserver.TCPServer(('127.0.0.1', 0), Handler) as httpd:
    with open(sys.argv[1], 'w', encoding='utf-8') as port_file:
        port_file.write(str(httpd.server_address[1]))
        port_file.flush()
    httpd.handle_request()
PY
SERVER_PID=$!
for _ in $(seq 1 50); do
  [ -s "$T3_PORT_FILE" ] && break
  sleep 0.1
done
[ -s "$T3_PORT_FILE" ] || { echo "FAIL: health server did not publish its port" >&2; exit 1; }
T3_PORT="$(cat "$T3_PORT_FILE")"

mkdir -p "$TMP_DIR/t3/data/bin" "$TMP_DIR/t3/stage/bin"
echo "old-v1.0" > "$TMP_DIR/t3/data/bin/ham-bridge"
echo "verified-v2.0" > "$TMP_DIR/t3/stage/bin/ham-bridge"

PATH="$SUP_PATH" "$SUPERVISOR" \
  --data-dir "$TMP_DIR/t3/data" \
  --stage-dir "$TMP_DIR/t3/stage" \
  --bridge-port "$T3_PORT" \
  --health-timeout 5 \
  --stop-hook "$TRUE_HOOK" \
  --restart-hook "$TRUE_HOOK"

APPLIED=$(cat "$TMP_DIR/t3/data/bin/ham-bridge")
if [ "$APPLIED" != "verified-v2.0" ]; then
  echo "FAIL: Expected verified-v2.0 to be applied, got: $APPLIED" >&2
  exit 1
fi

if [ -d "$TMP_DIR/t3/data/bin.bak" ]; then
  echo "FAIL: bin.bak should be deleted after success" >&2
  exit 1
fi

if [ -d "$TMP_DIR/t3/stage" ]; then
  echo "FAIL: staging dir should be deleted after success" >&2
  exit 1
fi

wait $SERVER_PID 2>/dev/null || true
SERVER_PID=""
echo "PASS: Test 3 passed!"

echo "=== Test 4: PID-scoped stop preserves unrelated bridge-like process ==="
mkdir -p "$TMP_DIR/t4/data/bin" "$TMP_DIR/t4/stage/bin"
echo "old-v1.0" > "$TMP_DIR/t4/data/bin/ham-bridge"
echo "new-v2.0" > "$TMP_DIR/t4/stage/bin/ham-bridge"

bash -c 'while :; do sleep 1; done' ham-bridge-update-target &
TARGET_PID=$!
bash -c 'while :; do sleep 1; done' ham-bridge-unrelated &
UNRELATED_PID=$!

T4_PORT_FILE="$TMP_DIR/t4-health-port"
python3 - "$T4_PORT_FILE" <<'PY' &
import http.server, socketserver, sys
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{"ok":true}')
with socketserver.TCPServer(('127.0.0.1', 0), Handler) as httpd:
    with open(sys.argv[1], 'w', encoding='utf-8') as port_file:
        port_file.write(str(httpd.server_address[1]))
        port_file.flush()
    httpd.handle_request()
PY
SERVER_PID=$!
for _ in $(seq 1 50); do
  [ -s "$T4_PORT_FILE" ] && break
  sleep 0.1
done
[ -s "$T4_PORT_FILE" ] || { echo "FAIL: health server did not publish its port" >&2; exit 1; }
T4_PORT="$(cat "$T4_PORT_FILE")"

PATH="$SUP_PATH" "$SUPERVISOR" \
  --data-dir "$TMP_DIR/t4/data" \
  --stage-dir "$TMP_DIR/t4/stage" \
  --health-url "http://127.0.0.1:$T4_PORT/api/v1/health" \
  --health-timeout 5 \
  --bridge-pid "$TARGET_PID" \
  --restart-hook "$TRUE_HOOK"

if kill -0 "$TARGET_PID" 2>/dev/null; then
  target_stat="$(ps -o stat= -p "$TARGET_PID" 2>/dev/null | tr -d '[:space:]')"
  if [[ "$target_stat" != Z* ]]; then
    echo "FAIL: exact target PID $TARGET_PID is still running" >&2
    exit 1
  fi
fi
wait "$TARGET_PID" 2>/dev/null || true
TARGET_PID=""

if ! kill -0 "$UNRELATED_PID" 2>/dev/null; then
  echo "FAIL: unrelated bridge-like PID $UNRELATED_PID was stopped" >&2
  exit 1
fi
kill "$UNRELATED_PID" 2>/dev/null || true
wait "$UNRELATED_PID" 2>/dev/null || true
UNRELATED_PID=""
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
echo "PASS: Test 4 passed!"

echo "=== Test 5: Supervisor survives the bridge's process group being killed ==="
# launchd kills every process left in a job's process group when the job's main
# process exits. Model that: a fake bridge leads its own process group and starts
# the supervisor as a plain child (as the real bridge does), and the stop hook
# kills that whole group. The restart hook only runs if the supervisor survived.
# Run once as shipped, and once with self-detach suppressed as a negative
# control proving the harness really kills an undetached supervisor.
GROUP_KILL_HOOK="$TMP_DIR/group-kill-hook"
cat > "$GROUP_KILL_HOOK" <<'HOOK'
#!/usr/bin/env bash
kill -TERM -- "-$(cat "$GROUP_FILE")" 2>/dev/null || true
exit 0
HOOK
chmod +x "$GROUP_KILL_HOOK"
MARK_HOOK="$TMP_DIR/mark-hook"
cat > "$MARK_HOOK" <<'HOOK'
#!/usr/bin/env bash
touch "$RESTART_MARKER"
HOOK
chmod +x "$MARK_HOOK"

run_group_kill_case() {
  local dir="$1" detached_env="$2"
  mkdir -p "$dir/data/bin" "$dir/stage/bin"
  echo "old-v1.0" > "$dir/data/bin/ham-bridge"
  echo "new-v2.0" > "$dir/stage/bin/ham-bridge"
  GROUP_FILE="$dir/pgid" RESTART_MARKER="$dir/restarted" \
    HEIMDALL_UPDATE_SUPERVISOR_DETACHED="$detached_env" \
    PATH="$SUP_PATH" "$PY" -c '
import os, sys
os.setpgid(0, 0)
with open(os.environ["GROUP_FILE"], "w") as f: f.write(str(os.getpgrp()))
os.execvp("bash", ["bash", "-c", "\"$@\" & while :; do sleep 1; done", "fake-bridge"] + sys.argv[1:])
' "$SUPERVISOR" --data-dir "$dir/data" --stage-dir "$dir/stage" \
      --bridge-port 58905 --health-timeout 1 \
      --stop-hook "$GROUP_KILL_HOOK" --restart-hook "$MARK_HOOK" \
      >"$dir/out.log" 2>&1 &
  local fake_bridge=$!
  for _ in $(seq 1 100); do
    [ -f "$dir/data/logs/update_rollback.log" ] && break
    sleep 0.1
  done
  wait "$fake_bridge" 2>/dev/null || true
}

export GROUP_FILE RESTART_MARKER
run_group_kill_case "$TMP_DIR/t5" ""
if [ ! -f "$TMP_DIR/t5/restarted" ] || [ ! -f "$TMP_DIR/t5/data/logs/update_rollback.log" ]; then
  echo "FAIL: supervisor did not survive the bridge's process group being killed" >&2
  cat "$TMP_DIR/t5/out.log" >&2
  exit 1
fi
grep -q "SESSION:        detached" "$TMP_DIR/t5/out.log" || {
  echo "FAIL: supervisor did not report a detached session" >&2; cat "$TMP_DIR/t5/out.log" >&2; exit 1; }

run_group_kill_case "$TMP_DIR/t5-control" "1"
if [ -f "$TMP_DIR/t5-control/restarted" ]; then
  echo "FAIL: negative control: an undetached supervisor was expected to be killed with the group" >&2
  exit 1
fi
if [ -n "$(ls -A "$TMP_DIR/t5-control/data/bin" 2>/dev/null)" ] && [ "$(cat "$TMP_DIR/t5-control/data/bin/ham-bridge" 2>/dev/null)" = "new-v2.0" ]; then
  echo "FAIL: negative control unexpectedly completed the update" >&2
  exit 1
fi
echo "PASS: Test 5 passed!"

echo "=== Test 6: A caller that already detached the supervisor is not re-executed ==="
# macOS has no setsid(1): the Bridge starts the supervisor in a new session
# itself and says so. A setsid spy proves the supervisor does not re-exec.
mkdir -p "$TMP_DIR/spy"
REAL_SETSID="$(command -v setsid)"
printf '#!/bin/sh\necho "$*" >> "%s"\nexec "%s" "$@"\n' "$TMP_DIR/setsid-calls" "$REAL_SETSID" > "$TMP_DIR/spy/setsid"
chmod +x "$TMP_DIR/spy/setsid"
run_plain_update() {
  local dir="$1"; shift
  mkdir -p "$dir/data/bin" "$dir/stage/bin"
  echo "old-v1.0" > "$dir/data/bin/ham-bridge"
  echo "new-v2.0" > "$dir/stage/bin/ham-bridge"
  set +e
  "$@" --data-dir "$dir/data" --stage-dir "$dir/stage" --bridge-port 58906 --health-timeout 1 \
    --stop-hook "$TRUE_HOOK" --restart-hook "$TRUE_HOOK" >"$dir/out.log" 2>&1
  RUN_EXIT=$?
  set -e
}
for detach in flag env; do
  rm -f "$TMP_DIR/setsid-calls"
  if [ "$detach" = flag ]; then
    run_plain_update "$TMP_DIR/t6-$detach" env PATH="$TMP_DIR/spy:$SUP_PATH" "$SUPERVISOR" --already-detached
  else
    run_plain_update "$TMP_DIR/t6-$detach" env PATH="$TMP_DIR/spy:$SUP_PATH" HEIMDALL_UPDATE_SUPERVISOR_DETACHED=1 "$SUPERVISOR"
  fi
  [ "$RUN_EXIT" -eq 1 ] || { echo "FAIL: ($detach) expected the rollback exit 1, got $RUN_EXIT" >&2; cat "$TMP_DIR/t6-$detach/out.log" >&2; exit 1; }
  [ ! -e "$TMP_DIR/setsid-calls" ] || { echo "FAIL: ($detach) supervisor re-executed through setsid" >&2; exit 1; }
  grep -q "SESSION:        detached" "$TMP_DIR/t6-$detach/out.log" || {
    echo "FAIL: ($detach) supervisor did not report a detached session" >&2; cat "$TMP_DIR/t6-$detach/out.log" >&2; exit 1; }
done
# Control: without the signal the spy sees the re-exec.
rm -f "$TMP_DIR/setsid-calls"
run_plain_update "$TMP_DIR/t6-control" env PATH="$TMP_DIR/spy:$SUP_PATH" HEIMDALL_UPDATE_SUPERVISOR_DETACHED= "$SUPERVISOR"
[ -s "$TMP_DIR/setsid-calls" ] || { echo "FAIL: control: supervisor did not re-exec through setsid" >&2; exit 1; }
echo "PASS: Test 6 passed!"

echo "=== Test 7: Without setsid(1) the supervisor warns and still updates ==="
# A PATH of links to every tool except setsid (and python3/perl).
FARM="$TMP_DIR/farm"
mkdir -p "$FARM"
IFS=: read -r -a path_dirs <<< "$PATH"
for dir in "${path_dirs[@]}"; do
  for tool in "$dir"/*; do
    name="${tool##*/}"
    case "$name" in setsid|python*|perl*) continue ;; esac
    [ -x "$tool" ] && [ ! -e "$FARM/$name" ] && ln -s "$tool" "$FARM/$name" || true
  done
done
run_plain_update "$TMP_DIR/t7" env PATH="$TMP_DIR/nopy:$FARM" HEIMDALL_UPDATE_SUPERVISOR_DETACHED= "$SUPERVISOR"
[ "$RUN_EXIT" -eq 1 ] || { echo "FAIL: expected the rollback exit 1, got $RUN_EXIT" >&2; cat "$TMP_DIR/t7/out.log" >&2; exit 1; }
grep -q "WARNING: setsid unavailable; cannot leave the bridge's process group" "$TMP_DIR/t7/out.log" || {
  echo "FAIL: missing setsid warning" >&2; cat "$TMP_DIR/t7/out.log" >&2; exit 1; }
[ "$(cat "$TMP_DIR/t7/data/bin/ham-bridge")" = "old-v1.0" ] || { echo "FAIL: rollback did not restore old-v1.0" >&2; exit 1; }
echo "PASS: Test 7 passed!"

echo "=== Test 8: Unsupported or incomplete caller interfaces fail before any change ==="
# A spy stop hook proves nothing was stopped; data/bin and the stage stay as they were.
STOP_SPY="$TMP_DIR/stop-spy"
printf '#!/bin/sh\necho "stop $*" >> "%s"\nexit 0\n' "$TMP_DIR/stop-calls" > "$STOP_SPY"
chmod +x "$STOP_SPY"
expect_refused() {
  local name="$1" message="$2"; shift 2
  local dir="$TMP_DIR/t8-$name"
  mkdir -p "$dir/data/bin" "$dir/stage/bin"
  echo "old-v1.0" > "$dir/data/bin/ham-bridge"
  echo "new-v2.0" > "$dir/stage/bin/ham-bridge"
  rm -f "$TMP_DIR/stop-calls"
  set +e
  PATH="$SUP_PATH" "$SUPERVISOR" --data-dir "$dir/data" --stage-dir "$dir/stage" --bridge-port 58908 \
    --health-timeout 1 --stop-hook "$STOP_SPY" --restart-hook "$TRUE_HOOK" "$@" >"$dir/out.log" 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 2 ] || { echo "FAIL: ($name) expected exit 2, got $rc" >&2; cat "$dir/out.log" >&2; exit 1; }
  grep -qF "$message" "$dir/out.log" || { echo "FAIL: ($name) missing '$message'" >&2; cat "$dir/out.log" >&2; exit 1; }
  [ ! -e "$TMP_DIR/stop-calls" ] || { echo "FAIL: ($name) the bridge was stopped" >&2; exit 1; }
  [ "$(cat "$dir/data/bin/ham-bridge")" = "old-v1.0" ] && [ -f "$dir/stage/bin/ham-bridge" ] && [ ! -e "$dir/data/bin.bak" ] || {
    echo "FAIL: ($name) the installation or stage changed" >&2; exit 1; }
  if grep -q "Starting supervisor execution" "$dir/out.log"; then
    echo "FAIL: ($name) the update flow started" >&2; exit 1
  fi
}
expect_refused future "Unsupported supervisor interface 3: this apply-bridge-update.sh supports interfaces 1-2; refusing before any change" \
  --interface 3 --from-version 0.5.6 --to-version 0.9.0
expect_refused future-stop-only "Unsupported supervisor interface 17" \
  --interface 17 --from-version 0.5.6 --to-version 0.9.0 --stop-pty-hosts-only
expect_refused not-a-number "Invalid --interface value: two" --interface two --from-version 0.5.6 --to-version 0.9.0
expect_refused zero "Invalid --interface value: 0" --interface 0
expect_refused v2-without-from "Supervisor interface 2 requires --from-version and --to-version" --interface 2 --to-version 0.9.0
expect_refused v2-without-to "Supervisor interface 2 requires --from-version and --to-version" --interface 2 --from-version 0.5.6
expect_refused missing-value "Missing value for --from-version" --interface 2 --to-version 0.9.0 --from-version
echo "PASS: Test 8 passed!"

echo "=== Test 9: Legacy and interface 2 callers both apply the update ==="
# curl is shimmed to report a healthy bridge, so each run takes the success path.
mkdir -p "$TMP_DIR/healthy"
printf '#!/bin/sh\nprintf 200\n' > "$TMP_DIR/healthy/curl"
chmod +x "$TMP_DIR/healthy/curl"
run_healthy_update() {
  local dir="$1"; shift
  mkdir -p "$dir/data/bin" "$dir/stage/bin"
  echo "old-v1.0" > "$dir/data/bin/ham-bridge"
  echo "new-v2.0" > "$dir/stage/bin/ham-bridge"
  set +e
  PATH="$TMP_DIR/healthy:$SUP_PATH" "$SUPERVISOR" --data-dir "$dir/data" --stage-dir "$dir/stage" --bridge-port 58909 \
    --health-timeout 5 --stop-hook "$TRUE_HOOK" --restart-hook "$TRUE_HOOK" "$@" >"$dir/out.log" 2>&1
  RUN_EXIT=$?
  set -e
  [ "$RUN_EXIT" -eq 0 ] && [ "$(cat "$dir/data/bin/ham-bridge")" = "new-v2.0" ] && [ ! -e "$dir/stage" ] || {
    echo "FAIL: ($dir) expected a completed update, got exit $RUN_EXIT" >&2; cat "$dir/out.log" >&2; exit 1; }
}
# Deployed Bridges send the original argv: no --interface and no versions.
run_healthy_update "$TMP_DIR/t9-legacy"
grep -q "Legacy caller (interface 1, no --from-version): update runs the version-independent flow without version hooks" "$TMP_DIR/t9-legacy/out.log" || {
  echo "FAIL: legacy caller was not logged" >&2; cat "$TMP_DIR/t9-legacy/out.log" >&2; exit 1; }
grep -q "Version hooks (" "$TMP_DIR/t9-legacy/out.log" && { echo "FAIL: version hooks ran for a legacy caller" >&2; exit 1; }
run_healthy_update "$TMP_DIR/t9-v2" --interface 2 --from-version 1.4.0 --to-version 1.5.0-rc.1
grep -q "INTERFACE:      2" "$TMP_DIR/t9-v2/out.log" && grep -q "FROM_VERSION:   1.4.0" "$TMP_DIR/t9-v2/out.log" &&
  grep -q "Version hooks (update): interface 2, from 1.4.0 to 1.5.0-rc.1" "$TMP_DIR/t9-v2/out.log" &&
  grep -q "direction: upgrade" "$TMP_DIR/t9-v2/out.log" || {
  echo "FAIL: interface 2 caller was not reported" >&2; cat "$TMP_DIR/t9-v2/out.log" >&2; exit 1; }
grep -q "Legacy caller" "$TMP_DIR/t9-v2/out.log" && { echo "FAIL: an interface 2 caller was logged as legacy" >&2; exit 1; }
# Hooks run before the bridge is stopped.
hook_line="$(grep -n "Version hooks (update)" "$TMP_DIR/t9-v2/out.log" | cut -d: -f1)"
stop_line="$(grep -n "Stopping active bridge service" "$TMP_DIR/t9-v2/out.log" | cut -d: -f1)"
[ "$hook_line" -lt "$stop_line" ] || { echo "FAIL: version hooks ran after the stop" >&2; exit 1; }
echo "PASS: Test 9 passed!"

echo "=== Test 10: A version hook fires only for a matching from-version ==="
run_healthy_update "$TMP_DIR/t10-match" --interface 2 --from-version 0.5.6 --to-version 0.6.0
grep -q "hook: from-version 0.5.6 (0.5 line): no compatibility steps required" "$TMP_DIR/t10-match/out.log" || {
  echo "FAIL: the 0.5 hook did not fire for 0.5.6" >&2; cat "$TMP_DIR/t10-match/out.log" >&2; exit 1; }
for from in 0.6.0 1.5.0 0.50.1; do
  run_healthy_update "$TMP_DIR/t10-$from" --interface 2 --from-version "$from" --to-version 0.5.9
  grep -q "hook: from-version" "$TMP_DIR/t10-$from/out.log" && {
    echo "FAIL: the 0.5 hook fired for $from" >&2; exit 1; }
  grep -q "direction: downgrade" "$TMP_DIR/t10-$from/out.log" || {
    echo "FAIL: $from -> 0.5.9 was not reported as a downgrade" >&2; cat "$TMP_DIR/t10-$from/out.log" >&2; exit 1; }
done
# A non-SemVer version still updates; only range hooks are skipped.
run_healthy_update "$TMP_DIR/t10-dev" --interface 2 --from-version dev-build --to-version 0.6.0
grep -q "direction: unknown (a version is not SemVer)" "$TMP_DIR/t10-dev/out.log" || {
  echo "FAIL: non-SemVer from-version not reported" >&2; cat "$TMP_DIR/t10-dev/out.log" >&2; exit 1; }
# The stop-only mode accepts the version flags and runs the same hooks first.
mkdir -p "$TMP_DIR/t10-stop/data/bin"
for args in "--interface 2 --from-version 0.5.6 --to-version 0.6.0" ""; do
  set +e
  # shellcheck disable=SC2086
  PATH="$SUP_PATH" "$SUPERVISOR" --data-dir "$TMP_DIR/t10-stop/data" --stop-pty-hosts-only \
    --pty-host-socket "$TMP_DIR/t10-stop/data/pty.sock" $args >"$TMP_DIR/t10-stop/out.log" 2>&1
  RUN_EXIT=$?
  set -e
  [ "$RUN_EXIT" -eq 0 ] || { echo "FAIL: stop-only ($args) exited $RUN_EXIT" >&2; cat "$TMP_DIR/t10-stop/out.log" >&2; exit 1; }
  if [ -n "$args" ]; then
    expected="hook: from-version 0.5.6 (0.5 line)"
    grep -q "Version hooks (stop-pty-hosts-only): interface 2, from 0.5.6 to 0.6.0" "$TMP_DIR/t10-stop/out.log" || {
      echo "FAIL: stop-only did not run the version hooks" >&2; cat "$TMP_DIR/t10-stop/out.log" >&2; exit 1; }
  else
    expected="Legacy caller (interface 1, no --from-version): stop-pty-hosts-only"
  fi
  grep -qF "$expected" "$TMP_DIR/t10-stop/out.log" || {
    echo "FAIL: stop-only ($args) missing '$expected'" >&2; cat "$TMP_DIR/t10-stop/out.log" >&2; exit 1; }
done
echo "PASS: Test 10 passed!"

echo "=== Test 11: semver_compare follows SemVer 2.0 precedence ==="
SEMVER_LIB="$TMP_DIR/semver.sh"
sed -n '/^# --- Version comparison/,/^version_at_least()/p' "$SUPERVISOR" > "$SEMVER_LIB"
grep -q '^version_at_least()' "$SEMVER_LIB" || { echo "FAIL: could not extract the version helpers" >&2; exit 1; }
PATH="$SUP_PATH" bash -euo pipefail -c '
  source "$1"
  fail=0
  ordered=(1.0.0-alpha 1.0.0-alpha.1 1.0.0-alpha.beta 1.0.0-beta 1.0.0-beta.2 1.0.0-beta.11 1.0.0-rc.1 1.0.0
           1.0.1 1.2.0 1.10.0 2.0.0 99999999999999999998.0.0 99999999999999999999.0.0)
  for ((i = 0; i + 1 < ${#ordered[@]}; i++)); do
    a="${ordered[$i]}" b="${ordered[$((i + 1))]}"
    semver_compare "$a" "$b" && [ "$SEMVER_CMP" = -1 ] || { echo "FAIL: $a < $b gave ${SEMVER_CMP:-error}" >&2; fail=1; }
    semver_compare "$b" "$a" && [ "$SEMVER_CMP" = 1 ] || { echo "FAIL: $b > $a gave ${SEMVER_CMP:-error}" >&2; fail=1; }
  done
  for pair in "v0.5.6 0.5.6" "0.5.6+build.7 0.5.6" "1.0.0-rc.1+x 1.0.0-rc.1"; do
    semver_compare ${pair} && [ "$SEMVER_CMP" = 0 ] || { echo "FAIL: $pair should be equal" >&2; fail=1; }
  done
  for bad in 1.0 01.0.0 1.0.0- dev "" 1.0.0-a..b "1.0.0 "; do
    if semver_compare "$bad" 1.0.0; then echo "FAIL: \"$bad\" accepted" >&2; fail=1; fi
    [ -z "$SEMVER_CMP" ] || { echo "FAIL: \"$bad\" left SEMVER_CMP set" >&2; fail=1; }
  done
  version_before 0.5.6 0.6.0 && version_at_least 0.6.0 0.6.0 && ! version_before 0.6.0 0.6.0 &&
    ! version_before dev 1.0.0 && ! version_at_least dev 0.0.0 || { echo "FAIL: range helpers" >&2; fail=1; }
  exit "$fail"
' semver-test "$SEMVER_LIB" || exit 1
echo "PASS: Test 11 passed!"

if [ -e "$FORBIDDEN" ]; then
  echo "FAIL: the supervisor ran python3/perl:" >&2
  cat "$FORBIDDEN" >&2
  exit 1
fi
echo "ALL SUPERVISOR TESTS PASSED SUCCESSFULLY!"
