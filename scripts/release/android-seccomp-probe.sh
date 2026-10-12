#!/usr/bin/env bash
# T12: prove a release binary starts under Android's app seccomp policy.
#
# Why this exists. Real device, Android 15 / Termux, v0.3.28 linux-arm64
# ham-bridge (glibc-static), killed before main:
#   execve(...) = 0 / brk / brk / set_tid_address / set_robust_list(...)
#   --- SIGSYS {si_code=SYS_SECCOMP, si_syscall=__NR_set_robust_list,
#               si_arch=AUDIT_ARCH_AARCH64} --- +++ killed by SIGSYS +++
# Zygote-spawned apps (Termux included) run under a seccomp allowlist derived
# from bionic; any syscall outside it is a SIGSYS kill. Static glibc calls
# set_robust_list unconditionally in __libc_setup_tls, so the termux-* bundle
# links its Odin binaries against musl instead (flake.nix, mkTermuxOdinPackage).
#
# DENYLIST below is not a guess. It is every syscall from the candidate list
# reviewed for T12 that is ABSENT from the app policy, which is
#   SYSCALLS.TXT - SECCOMP_BLOCKLIST_APP.TXT + SECCOMP_ALLOWLIST_COMMON.TXT
#   (+ SECCOMP_ALLOWLIST_APP.TXT)
# in AOSP platform/bionic/libc, checked at tags android-12.0.0_r1 and
# android-15.0.0_r1 (android.googlesource.com):
#   set_robust_list  absent on 12 and 15 (the device trace above)
#   rseq             absent on 12 and 15
#   clone3           absent on 12; allowed from a later release (15 allows it)
#   io_uring_*       absent on 12 and 15
#   add_key, keyctl, request_key  absent on 12 and 15 (keystore_linux.odin is
#                    bypassed on Termux by keystore_android_selected)
#   memfd_secret     absent on 12 and 15
# Deliberately NOT listed, because both policies ALLOW them: statx (Odin's
# core:os calls it directly at runtime), membarrier, personality, setns,
# unshare. Listing them would fail correct binaries.
#
# The probe traces start-up only (`--version`, `--help`): that is where the
# device died, and it is deterministic. strace output goes to a file: `-o -`
# is NOT stdout to strace, it writes a file literally named "-".
#
# It never passes vacuously: a trace without a successful execve of the probed
# binary (strace missing, ptrace denied) is an error, not a pass. `control`
# is the differential negative control -- a glibc binary MUST be rejected, the
# same philosophy as storeless-exec.sh.
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: android-seccomp-probe.sh check <binary> [binary...]
       android-seccomp-probe.sh control <glibc-binary>

check    Trace `<binary> --version` and `<binary> --help` under strace -f and
         exit 1 if any denylisted syscall appears (offending lines printed).
serve    Start `<ham-bridge>` as an isolated service (unreachable hub, loopback
         listeners, temp run dir) under strace -f, connect to its TCP and Unix
         endpoints so the listeners actually accept, then stop it and apply the
         same denylist to the whole runtime trace (exit codes as for check).
control  Negative control: exit 0 only if the probe REJECTS <glibc-binary> and
         names set_robust_list, proving the probe can see what killed the
         device. Exit 1 if the probe passes it.

Exit codes: 0 pass, 1 denylisted syscall found (or control not rejected),
2 usage, 3 the probe could not trace at all.
USAGE
}

# accept: bionic implements accept() as accept4(), so plain accept(2) is not
# allowlisted — observed as SIGSYS __NR_accept on an Android 15 device when the
# bridge's Unix listener (libc accept via musl) took its first connection.
# accept4 is allowed and is what the pattern deliberately does not match.
DENYLIST='set_robust_list|rseq|clone3|io_uring_[a-z_]+|add_key|keyctl|request_key|memfd_secret|accept'
# A syscall strace cannot name is printed as syscall_0x<nr>; it may be a newer
# denylisted one, so it fails too rather than slipping through undecoded.
PATTERN="^([0-9]+ +)?(<\\.\\.\\. +)?(${DENYLIST}|syscall_0x[0-9a-f]+)[ (]"

log() { printf 'android-seccomp-probe: %s\n' "$*" >&2; }

# probe_one <binary> <arg>: prints violating trace lines on stdout, returns
# 0 clean, 1 violations, 3 untraceable.
probe_one() {
  local bin="$1" arg="$2" trace rc=0
  trace="$(mktemp)"
  # The binary's own exit status is not the question here; storeless-exec.sh
  # checks that --version works. Only the syscalls it made are.
  strace -f -o "$trace" "$bin" "$arg" >/dev/null 2>&1 || true
  if ! grep -Eq '^([0-9]+ +)?execve\(.*\) = 0$' "$trace"; then
    log "FAIL: no successful execve of $bin in the trace; strace could not trace it"
    sed -n '1,5p' "$trace" >&2
    rm -f "$trace"
    return 3
  fi
  if grep -E "$PATTERN" "$trace"; then rc=1; fi
  if grep -E '^([0-9]+ +)?\+\+\+ killed by' "$trace"; then rc=1; fi
  rm -f "$trace"
  return "$rc"
}

# check_binary <binary>: 0 clean, 1 violations, 3 untraceable.
check_binary() {
  local bin="$1" arg out rc worst=0
  for arg in --version --help; do
    rc=0
    out="$(probe_one "$bin" "$arg")" || rc=$?
    if [ "$rc" -eq 3 ]; then return 3; fi
    if [ "$rc" -ne 0 ]; then
      log "FAIL: $(basename "$bin") $arg makes syscalls Android's app seccomp kills:"
      printf '%s\n' "$out" | sed 's/^/    /' >&2
      worst=1
    fi
  done
  return "$worst"
}

[ "$#" -ge 1 ] || { usage; exit 2; }
cmd="$1"; shift
case "$cmd" in
  -h|--help) usage; exit 0 ;;
  check|control|serve) ;;
  *) usage; exit 2 ;;
esac
[ "$#" -ge 1 ] || { usage; exit 2; }
command -v strace >/dev/null 2>&1 || { log 'FAIL: strace is required'; exit 3; }
for bin in "$@"; do
  [ -f "$bin" ] && [ -x "$bin" ] || { log "FAIL: not an executable file: $bin"; exit 2; }
done

if [ "$cmd" = serve ]; then
  [ "$#" -eq 1 ] || { usage; exit 2; }
  bin="$1"; work="$(mktemp -d)"; trace="$work/trace"; out="$work/stdout"
  ports="$(python3 - <<'PY'
import socket
s=[socket.socket() for _ in range(2)]
for x in s: x.bind(('127.0.0.1',0))
print(*(x.getsockname()[1] for x in s))
for x in s: x.close()
PY
)"
  p1="${ports% *}"; p2="${ports#* }"
  HEIMDALL_BRIDGE_PTY_HOST=false HOME="$work/home" TMPDIR="$work/tmp" \
    strace -f -o "$trace" "$bin" --daemon-url http://127.0.0.1:9 --bridge-token probe-token \
      --bind-host 127.0.0.1 --port "$p1" --local-endpoint-port "$p2" --local-run-dir "$work/run" \
      --data-dir "$work/data" >"$out" 2>&1 &
  svc=$!
  mkdir -p "$work/home" "$work/tmp"
  # Wait for both listeners, then connect to each so accept() actually runs.
  python3 - "$p1" "$p2" "$out" <<'PY'
import socket, sys, time, re, os
p1, p2, outp = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
def poke(connect):
    for _ in range(100):
        try:
            s = connect(); s.settimeout(1)
            try: s.sendall(b"GET /probe HTTP/1.0\r\n\r\n"); s.recv(64)
            except Exception: pass
            s.close(); return True
        except Exception: time.sleep(0.1)
    return False
ok1 = poke(lambda: socket.create_connection(('127.0.0.1', p1), timeout=1))
ok2 = poke(lambda: socket.create_connection(('127.0.0.1', p2), timeout=1))
unix = None
for _ in range(50):
    m = re.search(r'local endpoint unix:(\S+)', open(outp).read() if os.path.exists(outp) else '')
    if m: unix = m.group(1); break
    time.sleep(0.1)
ok3 = False
if unix:
    def cu():
        s = socket.socket(socket.AF_UNIX); s.connect(unix); return s
    ok3 = poke(cu)
print(f"probe-serve: tcp:{p1}={'ok' if ok1 else 'NO'} tcp:{p2}={'ok' if ok2 else 'NO'} unix={'ok' if ok3 else ('NO ('+str(unix)+')')}", file=sys.stderr)
PY
  sleep 1
  kill "$svc" 2>/dev/null || true; wait "$svc" 2>/dev/null || true
  rc=0
  if ! grep -Eq '^([0-9]+ +)?execve\(.*\) = 0$' "$trace"; then log "FAIL: strace could not trace $bin"; rm -rf "$work"; exit 3; fi
  a4="$(grep -cE '^([0-9]+ +)?accept4\(' "$trace" || true)"; a1="$(grep -cE '^([0-9]+ +)?accept\(' "$trace" || true)"
  log "serve: accept4 calls=$a4 accept calls=$a1"
  if grep -E "$PATTERN" "$trace"; then rc=1; fi
  # The probe itself kills the service at the end; only a seccomp-style kill counts.
  if grep -E '^([0-9]+ +)?\+\+\+ killed by SIGSYS' "$trace"; then rc=1; fi
  if [ "$rc" -ne 0 ]; then log "FAIL: $(basename "$bin") runtime makes syscalls Android's app seccomp kills (see lines above)"; else log "ok: $(basename "$bin") runtime (listeners exercised) is clean"; fi
  rm -rf "$work"; exit "$rc"
fi

if [ "$cmd" = control ]; then
  [ "$#" -eq 1 ] || { usage; exit 2; }
  rc=0
  out="$(probe_one "$1" --version)" || rc=$?
  if [ "$rc" -eq 3 ]; then exit 3; fi
  if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'set_robust_list'; then
    log "control ok: $(basename "$1") rejected for set_robust_list"
    exit 0
  fi
  log "FAIL: negative control $1 was not rejected for set_robust_list; the probe has no teeth"
  exit 1
fi

status=0
for bin in "$@"; do
  rc=0
  check_binary "$bin" || rc=$?
  if [ "$rc" -eq 3 ]; then exit 3; fi
  if [ "$rc" -eq 0 ]; then log "ok: $(basename "$bin") (--version, --help)"; else status=1; fi
done
exit "$status"
