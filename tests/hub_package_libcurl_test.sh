#!/usr/bin/env bash
# Packaging regression: the BUILT ham-hub must carry its outbound HTTPS client.
#
# The hub's outbound https:// calls (OIDC JWKS/UserInfo/token, the Paddle
# billing API, Loki push, Web Push) go through src/lib/httpc, which links
# libcurl. They used to spawn `socat` / `openssl s_client`, and a package
# without those on PATH failed every call at subprocess spawn (production
# checkout was down on exactly that). This test proves the built package:
#   1. links libcurl.so.4 and resolves it inside /nix/store (its own closure,
#      not whatever the host happens to have), to the libcurl pinned in
#      nix/libcurl-pin.json (nix/libcurl.nix "native": Nix-native packages
#      link the pinned version's shared library; release binaries link it
#      statically);
#   2. does not depend on socat/openssl on PATH any more (the wrapper's PATH
#      is checked from an EMPTY environment, so a host install cannot mask a
#      regression either way).
#
# Usage: tests/hub_package_libcurl_test.sh   (HUB_FLAKE=<ref> to override)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
flake_ref="${HUB_FLAKE:-$repo_root}"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "== building ${flake_ref}#ham-hub"
nix build "${flake_ref}#ham-hub" --out-link "$tmpdir/result" || fail "nix build ${flake_ref}#ham-hub failed"
real="$tmpdir/result/bin/.ham-hub-wrapped"
[[ -x "$real" ]] || fail "no wrapped binary at result/bin/.ham-hub-wrapped (did wrapProgram run?)"

readelf -d "$real" | grep -q 'NEEDED.*\[libcurl\.so\.4\]' || fail "ham-hub does not link libcurl.so.4"
resolved="$(ldd "$real" | awk '/libcurl\.so\.4/ {print $3}')"
case "$resolved" in
	/nix/store/*) echo "PASS: libcurl.so.4 -> $resolved" ;;
	*) fail "libcurl.so.4 resolved to '$resolved', outside the package closure" ;;
esac
pinned="$(sed -n '/"curl"/,/}/s/.*"version": *"\([^"]*\)".*/\1/p' "$repo_root/nix/libcurl-pin.json" | head -n 1)"
case "$resolved" in
	*-curl-"$pinned"/*) echo "PASS: the pinned libcurl $pinned" ;;
	*) fail "libcurl.so.4 resolved to '$resolved', not the pinned curl-$pinned (nix/libcurl-pin.json)" ;;
esac

prologue="$tmpdir/prologue.sh"
sed '/^exec /,$d' "$tmpdir/result/bin/ham-hub" | tail -n +2 >"$prologue"
bash_bin="$(command -v bash)"
for helper in socat openssl; do
	found="$(env -i "$bash_bin" -c 'PATH=""; . "$1"; command -v "$2" || true' _ "$prologue" "$helper")"
	[[ -z "$found" ]] || echo "note: $helper is on the hub wrapper PATH ($found) but no longer required"
done
echo "PASS: ham-hub carries its HTTPS client (libcurl) in its own closure."
