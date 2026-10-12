#!/usr/bin/env bash
# REQ-4/REQ-5 packaging regression: the BUILT ham-hub wrapper must put both TLS
# helpers on PATH by itself.
#
# Why this test exists. The hub's outbound https:// calls (the Paddle billing API,
# among others) go through src/lib/http_client, which terminates TLS by launching a
# subprocess: `socat` by default, or `openssl s_client` when HAM_TLS_BACKEND=s_client
# (src/lib/http_client/http_client.odin, tls_client_command_for_backend). flake.nix
# packaged ham-hub with only pkgs.sqlite, so on a machine whose global PATH happens
# not to carry socat/openssl -- which is every NixOS host running the wrapped hub --
# the subprocess could not spawn at all. Every Paddle call then failed before leaving
# the box and surfaced as a generic "could not contact Paddle; retry later", with the
# credentials and the network both perfectly fine. Production checkout was down on
# exactly this.
#
# WHAT MAKES THIS AN ACTUAL TEST: it runs the probe under `env -i` with ONLY the
# wrapper's own PATH prefix. The obvious probe --
#
#     PATH="$(dirname "$(readlink -f result/bin/ham-hub)"):$PATH" command -v socat
#
# -- keeps the host PATH and therefore PASSES WITH NO BUILD AT ALL on any host that
# has socat installed (a NixOS host normally does, via /run/current-system). It proves
# nothing about the package. Do not "simplify" this script back into that shape.
#
# Usage:
#   tests/hub_package_tls_helpers_test.sh
#
# Env (optional):
#   HUB_TLS_FLAKE   flake ref to build  (default: the repo root containing this test)
#
# Exits 0 on pass, non-zero with a diagnosis on failure. Builds into a temp dir that
# is removed on exit; it writes nothing into the repo and touches no global state.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
flake_ref="${HUB_TLS_FLAKE:-$repo_root}"

# Helpers that MUST be resolvable from the wrapper's own PATH, and why each is needed.
required_helpers=(socat openssl)

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

echo "== building ${flake_ref}#ham-hub"
nix build "${flake_ref}#ham-hub" --out-link "$tmpdir/result" \
	|| fail "nix build ${flake_ref}#ham-hub did not succeed"

hub_bin="$tmpdir/result/bin/ham-hub"
[[ -x "$hub_bin" ]] || fail "no executable at result/bin/ham-hub after a successful build"

# The wrapper is a generated shell script; the real binary sits beside it as
# .ham-hub-wrapped. If ham-hub is NOT a wrapper, wrapProgram did not run and the
# runtimeInputs never made it into PATH -- that is the regression, so say so clearly.
if ! head -c 2 "$hub_bin" | grep -q '#!'; then
	fail "result/bin/ham-hub is not a generated wrapper script, so no PATH prefix is applied (did wrapProgram run?)"
fi

# Reproduce the wrapper's PATH by SOURCING the wrapper's own prologue -- everything
# up to the final `exec` of the real binary -- rather than pattern-matching a PATH
# assignment. makeWrapper's emitted shape is an implementation detail that changes
# between nixpkgs revisions (it currently emits a multi-line dedup-then-prepend block
# per entry, not one `export PATH=...` line), and a probe that greps for one specific
# shape silently stops testing anything the day that changes.
prologue="$tmpdir/prologue.sh"
sed '/^exec /,$d' "$hub_bin" | tail -n +2 >"$prologue" # drop shebang + the exec tail
grep -q 'PATH' "$prologue" \
	|| fail "the ham-hub wrapper does not touch PATH at all, so runtimeInputs are not exposed. Wrapper was:
$(cat "$hub_bin")"

# env -i clears the environment and PATH starts EMPTY, so whatever resolves below was
# contributed by the wrapper itself -- nothing is inherited from this shell or the host.
bash_bin="$(command -v bash)"
wrapper_path="$(env -i "$bash_bin" -c 'PATH=""; . "$1"; printf %s "$PATH"' _ "$prologue")"
echo "== PATH contributed by the wrapper (from an empty PATH)"
tr ':' '\n' <<<"$wrapper_path" | sed 's/^/   /'

for helper in "${required_helpers[@]}"; do
	resolved="$(env -i "$bash_bin" -c 'PATH=""; . "$1"; command -v "$2"' _ "$prologue" "$helper" || true)"
	[[ -n "$resolved" ]] \
		|| fail "'$helper' does NOT resolve from the ham-hub wrapper's own PATH. Add pkgs.$helper to the ham-hub runtimeInputs in flake.nix (see packages.ham-hub)."
	case "$resolved" in
		/nix/store/*) ;;
		*) fail "'$helper' resolved to '$resolved', which is outside /nix/store -- the package is depending on host state, not on its own closure" ;;
	esac
	echo "PASS: $helper -> $resolved"
done

echo
echo "PASS: ham-hub packages both TLS helpers (${required_helpers[*]}) in its own wrapper PATH."
