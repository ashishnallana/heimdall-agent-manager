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

if [ -e "$FORBIDDEN" ]; then
  echo "FAIL: the supervisor ran python3/perl:" >&2
  cat "$FORBIDDEN" >&2
  exit 1
fi
echo "ALL SUPERVISOR TESTS PASSED SUCCESSFULLY!"
