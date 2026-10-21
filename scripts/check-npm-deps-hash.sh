#!/usr/bin/env bash
# Fails when flake.nix's npmDepsHash does not match package-lock.json.
#
# A stale hash is not caught by a local `nix build`: npmDeps is a fixed-output
# derivation, so any machine that still has the old hash in its store reuses the
# old dependencies without refetching. The build only breaks on a fresh machine
# or deploy, so check it explicitly.
#
# Usage: scripts/check-npm-deps-hash.sh [--staged]
#   --staged  check the index (what is about to be committed), and do nothing
#             unless package-lock.json or flake.nix is staged. Used by pre-commit.
# Skips (exit 0) when nix is not on PATH.
set -euo pipefail

if ! command -v nix >/dev/null 2>&1; then
  exit 0
fi

root="$(git rev-parse --show-toplevel)"
cd "$root"

staged=0
[[ "${1:-}" == "--staged" ]] && staged=1

tmp="$(mktemp -d "${TMPDIR:-/tmp}/npm-deps-hash.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

if [[ $staged -eq 1 ]]; then
  if ! git diff --cached --name-only | grep -qxE 'package-lock\.json|flake\.nix'; then
    exit 0
  fi
  git show :package-lock.json >"$tmp/package-lock.json"
  git show :flake.nix >"$tmp/flake.nix"
else
  cp package-lock.json "$tmp/package-lock.json"
  cp flake.nix "$tmp/flake.nix"
fi

declared="$(grep -oE 'npmDepsHash = "[^"]+"' "$tmp/flake.nix" | head -1 | cut -d'"' -f2)"
if [[ -z "$declared" ]]; then
  echo "check-npm-deps-hash: no npmDepsHash found in flake.nix" >&2
  exit 1
fi

# Use the flake's pinned nixpkgs so the hash matches what the build computes.
if ! actual="$(nix run --inputs-from . nixpkgs#prefetch-npm-deps -- "$tmp/package-lock.json" 2>"$tmp/err" | tail -1)" || [[ -z "$actual" ]]; then
  echo "check-npm-deps-hash: could not compute the hash (skipping):" >&2
  cat "$tmp/err" >&2
  exit 0
fi

if [[ "$declared" != "$actual" ]]; then
  cat >&2 <<EOF
check-npm-deps-hash: flake.nix npmDepsHash is out of date for package-lock.json
  flake.nix:         $declared
  package-lock.json: $actual
Fix with:
  sed -i 's|$declared|$actual|' flake.nix && git add flake.nix
EOF
  exit 1
fi
