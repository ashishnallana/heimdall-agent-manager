#!/usr/bin/env bash
# Installs the repo's pre-commit checks into .git/hooks/pre-commit (shared by
# every worktree). Leaves other hooks and any existing pre-commit content alone;
# re-running is a no-op. Checks:
#   - scripts/check-npm-deps-hash.sh --staged (flake npmDepsHash vs lockfile)
#   - scripts/check-http-boundary.sh (only src/lib/httpc touches libcurl)
set -euo pipefail

hooks="$(git rev-parse --git-common-dir)/hooks"
hook="$hooks/pre-commit"
marker="# heimdall: check-npm-deps-hash"
boundary_marker="# heimdall: check-http-boundary"

mkdir -p "$hooks"
[[ -f "$hook" ]] || printf '#!/bin/sh\n' >"$hook"
installed=0
if ! grep -qF "$marker" "$hook"; then
  cat >>"$hook" <<EOF

$marker
script="\$(git rev-parse --show-toplevel)/scripts/check-npm-deps-hash.sh"
if [ -x "\$script" ]; then "\$script" --staged || exit 1; fi
EOF
  installed=1
fi
if ! grep -qF "$boundary_marker" "$hook"; then
  cat >>"$hook" <<EOF

$boundary_marker
script="\$(git rev-parse --show-toplevel)/scripts/check-http-boundary.sh"
if [ -x "\$script" ]; then "\$script" >/dev/null || exit 1; fi
EOF
  installed=1
fi
chmod +x "$hook"
if [[ $installed == 1 ]]; then
  echo "installed pre-commit hook: $hook"
else
  echo "pre-commit hook already installed: $hook"
fi
