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
control  Negative control: exit 0 only if the probe REJECTS <glibc-binary> and
         names set_robust_list, proving the probe can see what killed the
         device. Exit 1 if the probe passes it.

Exit codes: 0 pass, 1 denylisted syscall found (or control not rejected),
2 usage, 3 the probe could not trace at all.
USAGE
}

DENYLIST='set_robust_list|rseq|clone3|io_uring_[a-z_]+|add_key|keyctl|request_key|memfd_secret'
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
  check|control) ;;
  *) usage; exit 2 ;;
esac
[ "$#" -ge 1 ] || { usage; exit 2; }
command -v strace >/dev/null 2>&1 || { log 'FAIL: strace is required'; exit 3; }
for bin in "$@"; do
  [ -f "$bin" ] && [ -x "$bin" ] || { log "FAIL: not an executable file: $bin"; exit 2; }
done

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
