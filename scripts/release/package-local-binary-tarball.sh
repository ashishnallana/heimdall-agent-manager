#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: package-local-binary-tarball.sh <target> <version> <out-dir> <ham-bridge-out> <ham-ctl-out> <heimdall-out> [ham-pty-host-out]

Creates dist tarball: <out-dir>/heimdall-local-<target>.tar.gz
Tarball root contains: bin/ham-bridge, bin/ham-ctl, bin/heimdall, share/heimdall/extensions/, README.md, LICENSE, METADATA.json
When the optional <ham-pty-host-out> is given, bin/ham-pty-host is also shipped
(self-contained; PTYH-4).
USAGE
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

if [ "$#" -lt 6 ] || [ "$#" -gt 7 ]; then
  usage
  exit 2
fi

target="$1"
version="$2"
out_dir="$3"
ham_bridge_out="$4"
ham_ctl_out="$5"
heimdall_out="$6"
ham_pty_host_out="${7:-}"

case "$target" in
  # termux-arm64 (T12): Android/Termux bundle. Same ELF layout and the same
  # fully-static gate as linux-*, but the Odin binaries are musl-static
  # (Android's app seccomp SIGSYS-kills glibc-static at set_robust_list).
  darwin-arm64|darwin-amd64|linux-amd64|linux-arm64|termux-arm64) ;;
  *) echo "unsupported release target: $target" >&2; exit 2 ;;
esac

for spec in \
  "$ham_bridge_out/bin/ham-bridge" \
  "$ham_ctl_out/bin/ham-ctl" \
  "$heimdall_out/bin/heimdall" \
  "README.md" \
  "LICENSE" \
  "scripts/apply-bridge-update.sh" \
  "scripts/refresh-provider-extensions.sh" \
  "extensions/antigravity/plugin.json" \
  "extensions/claude-code/.claude-plugin/plugin.json" \
  "extensions/codex/.codex-plugin/plugin.json" \
  "extensions/.claude-plugin/marketplace.json" \
  "extensions/.agents/plugins/marketplace.json" \
  "extensions/antigravity/hooks.json" \
  "extensions/antigravity/hooks/hooks.json" \
  "extensions/claude-code/hooks/hooks.json" \
  "extensions/codex/hooks/hooks.json"
do
  if [ ! -f "$spec" ]; then
    echo "missing required release input: $spec" >&2
    exit 1
  fi
done

mkdir -p "$out_dir"
work_dir="$(mktemp -d)"
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

stage="$work_dir/stage"
mkdir -p "$stage/bin" "$stage/scripts"
install -m 0755 scripts/apply-bridge-update.sh "$stage/scripts/apply-bridge-update.sh"
install -m 0755 scripts/refresh-provider-extensions.sh "$stage/scripts/refresh-provider-extensions.sh"
mkdir -p "$stage/share/heimdall/extensions"
cp -R -P -p extensions/. "$stage/share/heimdall/extensions/"
install -m 0755 "$ham_bridge_out/bin/ham-bridge" "$stage/bin/ham-bridge"
if [ -f "$ham_bridge_out/bin/openssl" ]; then
  install -m 0755 "$ham_bridge_out/bin/openssl" "$stage/bin/openssl"
fi
install -m 0755 "$ham_ctl_out/bin/ham-ctl" "$stage/bin/ham-ctl"
install -m 0755 "$heimdall_out/bin/heimdall" "$stage/bin/heimdall"
# PTYH-4: ship the self-contained PTY host binary when its Nix output is
# provided. Optional so callers that do not ship a PTY host keep working.
ham_pty_host_shipped=false
if [ -n "$ham_pty_host_out" ]; then
  if [ ! -f "$ham_pty_host_out/bin/ham-pty-host" ]; then
    echo "missing required release input: $ham_pty_host_out/bin/ham-pty-host" >&2
    exit 1
  fi
  install -m 0755 "$ham_pty_host_out/bin/ham-pty-host" "$stage/bin/ham-pty-host"
  ham_pty_host_shipped=true
fi
install -m 0644 README.md "$stage/README.md"
install -m 0644 LICENSE "$stage/LICENSE"

# REQ-INST-16: the release tarballs target stock Linux/macOS hosts that have no
# /nix/store. Gate the staged tree HERE, at the single chokepoint every release
# path shares, before the tarball exists:
#   * Linux  -- every shipped ELF is either fully static (no program
#     interpreter: ham-pty-host, and everything in the termux bundle) or a
#     release-* Odin binary linked against the host's glibc and libcurl.so.4
#     (src/lib/httpc): then the interpreter must be the standard FHS loader
#     (a /nix/store one is the historical bug), there is no RPATH/RUNPATH, and
#     every NEEDED entry is a glibc library or libcurl.so.4.
#   * Darwin -- Mach-O binaries get nix-store dylib install names rewritten to
#     the system equivalents below (libiconv from the Rust build; libsqlite3
#     and libcurl from the Odin builds, which link the OS copies at runtime).
#     Any OTHER /nix/store dylib, or any /nix/store rpath, is a hard error.
# Non-binary payloads (shell stubs, README) are skipped by magic bytes, so test
# fixtures that stage #!/bin/sh stubs keep passing.
file_magic() {
  od -A n -t x1 -N 4 "$1" 2>/dev/null | tr -d ' \n'
}

gate_linux_elf() {
  local bin="$1" interp
  command -v readelf >/dev/null 2>&1 || {
    echo "error: readelf is required to audit Linux release binaries" >&2
    exit 1
  }
  interp="$(readelf -l "$bin" 2>/dev/null | sed -n 's/.*Requesting program interpreter: \(.*\)].*/\1/p')"
  if readelf -d "$bin" 2>/dev/null | grep -q '/nix/store'; then
    echo "error: $bin has RUNPATH/NEEDED under /nix/store" >&2
    exit 1
  fi
  [ -z "$interp" ] && return 0
  if [ "$target" = termux-arm64 ]; then
    echo "error: $bin has a program interpreter ($interp); termux binaries must be fully static" >&2
    exit 1
  fi
  case "$interp" in
    /lib64/ld-linux-x86-64.so.2|/lib/ld-linux-aarch64.so.1) ;;
    *) echo "error: $bin has program interpreter $interp; release binaries must use the FHS loader (build the release-* flake attrs)" >&2; exit 1 ;;
  esac
  if readelf -d "$bin" 2>/dev/null | grep -qE '\((RPATH|RUNPATH)\)'; then
    echo "error: $bin has an RPATH/RUNPATH; release binaries resolve libraries from the host only" >&2
    exit 1
  fi
  local lib
  while IFS= read -r lib; do
    case "$lib" in
      libc.so.6|libm.so.6|libpthread.so.0|libdl.so.2|librt.so.1|libcurl.so.4|ld-linux-x86-64.so.2|ld-linux-aarch64.so.1) ;;
      *) echo "error: $bin needs $lib; release binaries may depend only on glibc and libcurl.so.4" >&2; exit 1 ;;
    esac
  done < <(readelf -d "$bin" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p')
}

rewrite_darwin_macho() {
  local bin="$1" dump line path base
  if command -v llvm-objdump >/dev/null 2>&1; then
    dump="$(llvm-objdump --macho --dylibs-used "$bin" 2>/dev/null)"
  elif command -v otool >/dev/null 2>&1; then
    dump="$(otool -L "$bin" 2>/dev/null)"
  else
    echo "error: need llvm-objdump or otool to audit $bin" >&2
    exit 1
  fi
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      /nix/store/*)
        path="${line%%[[:space:]]*}"
        base="$(basename "$path")"
        case "$base" in
          libiconv*.dylib)
            install_name_tool -change "$path" /usr/lib/libiconv.2.dylib "$bin" ;;
          libsqlite3*.dylib)
            install_name_tool -change "$path" /usr/lib/libsqlite3.dylib "$bin" ;;
          libcurl*.dylib)
            install_name_tool -change "$path" /usr/lib/libcurl.4.dylib "$bin" ;;
          *)
            echo "error: $bin links nix-store dylib with no system mapping: $path" >&2
            exit 1 ;;
        esac ;;
    esac
  done <<EOF
$dump
EOF
  if command -v llvm-objdump >/dev/null 2>&1; then
    if llvm-objdump --macho --rpaths "$bin" 2>/dev/null | grep -q '/nix/store'; then
      echo "error: $bin has an rpath under /nix/store" >&2
      exit 1
    fi
  fi
}

for staged in "$stage"/bin/*; do
  magic="$(file_magic "$staged")"
  case "$magic" in
    7f454c46)
      case "$target" in
        linux-*|termux-*) gate_linux_elf "$staged" ;;
        *) echo "error: ELF binary $staged staged for $target" >&2; exit 1 ;;
      esac ;;
    cffaedfe|cefaedfe|cafebabe|cafebabf|feedface|feedfacf)
      case "$target" in
        darwin-*) rewrite_darwin_macho "$staged" ;;
        *) echo "error: Mach-O binary $staged staged for $target" >&2; exit 1 ;;
      esac ;;
    *)  # not a recognised binary; a SHELL SCRIPT must still not reference the
        # nix store -- the historical REQ-INST-16 bug shipped bin/ham-bridge as
        # the 652-byte nix wrapper, whose shebang and exec both live under
        # /nix/store and die with ENOENT on any stock host.
      if head -c 2 "$staged" | grep -q '^#!' && grep -q '/nix/store' "$staged"; then
        echo "error: script $staged references /nix/store (nix wrapper scripts are not portable)" >&2
        exit 1
      fi ;;
  esac
done

commit="${GITHUB_SHA:-$(git rev-parse --short=12 HEAD 2>/dev/null || printf unknown)}"
built_at="${SOURCE_DATE_EPOCH:-}"
if [ -n "$built_at" ]; then
  built_at_iso="$(date -u -r "$built_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$built_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf unknown)"
else
  built_at_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi
if [ "$ham_pty_host_shipped" = true ]; then
  binaries_json='["ham-bridge", "ham-ctl", "heimdall", "ham-pty-host"]'
else
  binaries_json='["ham-bridge", "ham-ctl", "heimdall"]'
fi
cat > "$stage/METADATA.json" <<META
{
  "product": "heimdall-local",
  "version": "$version",
  "target": "$target",
  "commit": "$commit",
  "built_at": "$built_at_iso",
  "binaries": $binaries_json,
  "http_dependency": "libcurl >= 7.80 (libcurl.so.4 on Linux -- e.g. Debian 12+, Ubuntu 22.04+; /usr/lib/libcurl.4.dylib on macOS 13+). Outbound HTTPS goes through it; NOT bundled.",
  "tls_dependency": "socat (DEFAULT bridge->hub WebSocket TLS transport; NOT bundled -- install it with your system package manager). OpenSSL s_client is the legacy fallback, used only when HAM_TLS_BACKEND=s_client; it is resolved from the system PATH and is NOT bundled in this tarball."
}
META

tarball="$out_dir/heimdall-local-$target.tar.gz"
tar -C "$stage" -czf "$tarball" bin scripts share README.md LICENSE METADATA.json

required_entries=(
  "bin/ham-bridge"
  "bin/ham-ctl"
  "bin/heimdall"
  "scripts/apply-bridge-update.sh"
  "scripts/refresh-provider-extensions.sh"
  "share/heimdall/extensions/.agents/plugins/marketplace.json"
  "share/heimdall/extensions/.claude-plugin/marketplace.json"
  "share/heimdall/extensions/antigravity/plugin.json"
  "share/heimdall/extensions/claude-code/.claude-plugin/plugin.json"
  "share/heimdall/extensions/codex/.codex-plugin/plugin.json"
  "README.md"
  "LICENSE"
)
if [ "$ham_pty_host_shipped" = true ]; then
  required_entries+=("bin/ham-pty-host")
fi
# List once into a file: piping tar into `grep -q` races under pipefail
# (grep exits on first match -> tar hits EPIPE -> false "missing entry").
tar -tzf "$tarball" > "$work_dir/tarball-entries.txt"
for entry in "${required_entries[@]}"; do
  if ! grep -Fxq "$entry" "$work_dir/tarball-entries.txt"; then
    echo "tarball missing required entry: $entry" >&2
    exit 1
  fi
done

printf '%s\n' "$tarball"
